BeforeDiscovery {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '../../src/lib/dependencies.json'
    $currentFrameworkFolderName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'net472' } else { 'netstandard2.0' }

    $manifestEntries = if (Test-Path -Path $manifestPath) {
        $manifestContent = Get-Content -Path $manifestPath -Raw
        (ConvertFrom-Json -InputObject $manifestContent).PSObject.Properties
    } else {
        @()
    }

    # Only the current edition's folder is checked here: a Desktop (5.1)
    # process only ever loads net472, and a Core (7) process only ever
    # loads netstandard2.0. Running -AllEditions still covers both folders,
    # each validated once, by the edition that actually uses it.
    $testCases = foreach ($manifestEntry in $manifestEntries) {
        @{
            PackageId       = $manifestEntry.Name
            ExpectedVersion = [string]$manifestEntry.Value
            FrameworkFolder = $currentFrameworkFolderName
        }
    }
}

BeforeAll {
    $libRootPath = Join-Path -Path $PSScriptRoot -ChildPath '../../src/lib'
    $script:libRootPath = (Resolve-Path -Path $libRootPath).Path

    $manifestPath = Join-Path -Path $script:libRootPath -ChildPath 'dependencies.json'
    $manifestContent = Get-Content -Path $manifestPath -Raw
    $script:manifest = ConvertFrom-Json -InputObject $manifestContent
}

Describe ('dependencies.json matches the DLLs in lib/{0} (current edition: {1})' -f $currentFrameworkFolderName, $PSVersionTable.PSEdition) -Tag 'Build' {
    It 'lists at least one package' {
        $manifestEntryCount = @($script:manifest.PSObject.Properties).Count
        $manifestEntryCount | Should -BeGreaterThan 0
    }

    It '<PackageId> <ExpectedVersion> is in lib/<FrameworkFolder> at that version' -ForEach @($testCases) {
        $dllRelativePath = '{0}/{1}.dll' -f $FrameworkFolder, $PackageId
        $dllPath         = Join-Path -Path $script:libRootPath -ChildPath $dllRelativePath
        $dllPath | Should -Exist

        $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath)
        $actualVersion   = '{0}.{1}.{2}' -f $fileVersionInfo.FileMajorPart, $fileVersionInfo.FileMinorPart, $fileVersionInfo.FileBuildPart

        $actualVersion | Should -Be $ExpectedVersion -Because "the manifest says $PackageId $ExpectedVersion but $dllRelativePath is $($fileVersionInfo.FileVersion)"
    }
}

Describe ('an MSAL client can be built and an interactive request started from lib/{0} (current edition: {1})' -f $currentFrameworkFolderName, $PSVersionTable.PSEdition) -Tag 'Build' {

    BeforeAll {
        # Recomputed here rather than read from a BeforeDiscovery variable,
        # so this Describe doesn't depend on cross-phase scope sharing -
        # $PSVersionTable.PSEdition is identical and cheap to check in both.
        $frameworkFolderNameForThisEdition = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'net472' } else { 'netstandard2.0' }
        $script:libFolderPath     = Join-Path -Path $script:libRootPath -ChildPath $frameworkFolderNameForThisEdition
        $script:msalClientDllPath = Join-Path -Path $script:libFolderPath -ChildPath 'Microsoft.Identity.Client.dll'

        $probeScriptPath = Join-Path -Path $TestDrive -ChildPath 'Build-MsalClientProbe.ps1'
        $probeScriptContent = @'
param(
    [Parameter(Mandatory)]
    [string]$LibFolderPath
)

$ErrorActionPreference = 'Stop'

function Import-MsalDependencyFolder {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath
    )

    $loadedAssemblyNames = [System.AppDomain]::CurrentDomain.GetAssemblies().GetName().Name
    $dllFiles = Get-ChildItem -Path $FolderPath -Filter '*.dll' | Sort-Object -Property 'Name' -Descending

    foreach ($dllFile in $dllFiles) {
        $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($dllFile.Name)

        if ($assemblyName -in $loadedAssemblyNames) {
            continue
        }

        try {
            Add-Type -Path $dllFile.FullName
        }
        catch {
            throw ('Failed to load assembly {0}: {1}' -f $dllFile.FullName, $_)
        }
    }
}

try {
    Import-MsalDependencyFolder -FolderPath $LibFolderPath

    $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
        '00000000-0000-0000-0000-000000000000'
    ).WithAuthority(
        'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000'
    ).WithRedirectUri(
        'http://localhost'
    ).Build()

    # An already-cancelled token makes MSAL abort the request as early as
    # possible, before it opens a browser/webview, while still forcing it
    # to build the PKCE challenge and the request pipeline - the same code
    # paths that touch System.Memory, System.Buffers, etc. This is not a
    # real login attempt and should never require user interaction.
    $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new()
    $cancellationTokenSource.Cancel()
    $scopes = [string[]]@('User.Read')

    try {
        $publicClientApplication.AcquireTokenInteractive($scopes).ExecuteAsync($cancellationTokenSource.Token).GetAwaiter().GetResult()
    }
    catch {
        # PowerShell wraps exceptions from direct .NET method calls in a
        # MethodInvocationException, so the real exception has to be found
        # by walking InnerException rather than by a typed catch clause.
        $innermostException = $_.Exception
        while ($innermostException.InnerException) {
            $innermostException = $innermostException.InnerException
        }

        if ($innermostException -isnot [System.OperationCanceledException]) {
            throw $innermostException
        }
        # else: expected - we cancelled on purpose. Reaching this point
        # proves the call got into MSAL's pipeline without a missing- or
        # mismatched-assembly error.
    }

    [pscustomobject]@{
        Success      = $true
        ClientId     = $publicClientApplication.AppConfig.ClientId
        ErrorMessage = $null
    } | ConvertTo-Json -Compress
}
catch {
    $exceptionMessages = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $currentException  = $_.Exception

    while ($currentException) {
        $exceptionMessages.Add($currentException.Message)
        $currentException = $currentException.InnerException
    }

    [pscustomobject]@{
        Success      = $false
        ClientId     = $null
        ErrorMessage = ($exceptionMessages -join ' -> ')
    } | ConvertTo-Json -Compress
}
'@
        Set-Content -Path $probeScriptPath -Value $probeScriptContent -Encoding 'UTF8'

        $hostExecutablePath = (Get-Process -Id $PID).Path
        $probeOutputLines   = & $hostExecutablePath -NoProfile -NonInteractive -File $probeScriptPath -LibFolderPath $script:libFolderPath
        $script:probeExitCode  = $LASTEXITCODE
        $script:probeOutputRaw = $probeOutputLines | Out-String

        try {
            $script:probeResult = $probeOutputLines | Select-Object -Last 1 | ConvertFrom-Json
        }
        catch {
            $script:probeResult = $null
        }
    }

    It ('finds Microsoft.Identity.Client.dll in lib/{0}' -f $currentFrameworkFolderName) {
        $script:msalClientDllPath | Should -Exist -Because $script:msalClientDllPath
    }

    It 'the probe process produced parseable output' {
        $script:probeResult | Should -Not -BeNullOrEmpty -Because $script:probeOutputRaw
    }

    It 'loads every DLL in the folder, builds a client, and starts an interactive request without a dependency error' {
        $script:probeResult.Success | Should -BeTrue -Because $script:probeResult.ErrorMessage
    }
}