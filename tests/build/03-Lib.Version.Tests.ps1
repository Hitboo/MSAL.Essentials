BeforeDiscovery {
    $manifestPath               = Join-Path -Path $PSScriptRoot -ChildPath '../../src/lib/dependencies.json'
    $currentFrameworkFolderName = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'net472' } else { 'netstandard2.0' }

    # dependencies.json holds package -> version pairs (string values) plus a
    # 'Resolved' section (object value) that lists the resolved dependency
    # tree per framework. Only the string-valued properties are packages, so
    # 'Resolved' must not become a test case.
    $manifestEntries = if (Test-Path -Path $manifestPath) {
        $manifestContent = Get-Content -Path $manifestPath -Raw
        (ConvertFrom-Json -InputObject $manifestContent).PSObject.Properties |
            Where-Object -FilterScript { $_.Value -is [string] }
    } else {
        @()
    }

    # Only the current edition's folder is checked here: a Desktop (5.1)
    # process only ever loads net472, and a Core (7) process only ever
    # loads netstandard2.0. Running -AllEditions still covers both folders,
    # each validated once, by the edition that actually uses it.
    $testCases = @(
        foreach ($manifestEntry in $manifestEntries) {
            @{
                PackageId       = $manifestEntry.Name
                ExpectedVersion = [string]$manifestEntry.Value
                FrameworkFolder = $currentFrameworkFolderName
            }
        }
    )
}

BeforeAll {
    $libRootPath        = Join-Path -Path $PSScriptRoot -ChildPath '../../src/lib'
    $script:libRootPath = (Resolve-Path -Path $libRootPath).Path

    $manifestPath    = Join-Path -Path $script:libRootPath -ChildPath 'dependencies.json'
    $manifestContent = Get-Content -Path $manifestPath -Raw
    $script:manifest = ConvertFrom-Json -InputObject $manifestContent

    # Same filter as in BeforeDiscovery: package -> version pairs only.
    $script:packageEntries = @(
        $script:manifest.PSObject.Properties |
            Where-Object -FilterScript { $_.Value -is [string] }
    )
}

Describe ('dependencies.json matches the DLLs in lib/{0} (current edition: {1})' -f $currentFrameworkFolderName, $PSVersionTable.PSEdition) -Tag 'Build' {
    It 'lists at least one package' {
        $script:packageEntries.Count |
            Should -BeGreaterThan 0
    }

    It '<PackageId> <ExpectedVersion> is in lib/<FrameworkFolder> at that version' -ForEach $testCases {
        $dllRelativePath = '{0}/{1}.dll' -f $FrameworkFolder, $PackageId
        $dllPath         = Join-Path -Path $script:libRootPath -ChildPath $dllRelativePath
        $dllPath |
            Should -Exist

        $fileVersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath)
        $actualVersion   = '{0}.{1}.{2}' -f $fileVersionInfo.FileMajorPart, $fileVersionInfo.FileMinorPart, $fileVersionInfo.FileBuildPart

        $actualVersion |
            Should -Be $ExpectedVersion -Because (
                'the manifest says {0} {1} but {2} is {3}' -f
                    $PackageId, $ExpectedVersion, $dllRelativePath, $fileVersionInfo.FileVersion
            )
    }
}

Describe ('the module can be re-imported, builds an MSAL client, and starts a connection attempt (current edition: {0})' -f $PSVersionTable.PSEdition) -Tag 'Build' {
    BeforeAll {
        # Recomputed here rather than read from a BeforeDiscovery variable,
        # so this Describe doesn't depend on cross-phase scope sharing -
        # $PSVersionTable.PSEdition is identical and cheap to check in both.
        $frameworkFolderNameForThisEdition = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'net472' } else { 'netstandard2.0' }
        $script:libFolderPath              = Join-Path -Path $script:libRootPath   -ChildPath $frameworkFolderNameForThisEdition
        $script:msalClientDllPath          = Join-Path -Path $script:libFolderPath -ChildPath 'Microsoft.Identity.Client.dll'
        $script:moduleManifestPath         = Join-Path -Path (Split-Path -Path $script:libRootPath -Parent) -ChildPath 'MSAL.Essentials.psd1'
        $script:probeScriptPath            = Join-Path -Path $PSScriptRoot         -ChildPath 'Probes/Build-MsalClientProbe.ps1'

        # Run the probe in a clean child process of the same edition as this
        # test run. 2>&1 keeps stderr (e.g. a hard crash) in the captured
        # output so it shows up in the -Because message instead of the console.
        $hostExecutablePath   = (Get-Process -Id $PID).Path
        $probeOutputLines     = & $hostExecutablePath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:probeScriptPath -ModuleManifestPath $script:moduleManifestPath 2>&1
        $script:probeExitCode  = $LASTEXITCODE
        $script:probeOutputRaw = $probeOutputLines | Out-String

        try {
            $script:probeResult = $probeOutputLines |
                Select-Object -Last 1 |
                ConvertFrom-Json
        } catch {
            $script:probeResult = $null
        }
    }

    It 'the probe script exists' {
        $script:probeScriptPath |
            Should -Exist
    }

    It ('finds Microsoft.Identity.Client.dll in lib/{0}' -f $currentFrameworkFolderName) {
        $script:msalClientDllPath |
            Should -Exist -Because $script:msalClientDllPath
    }

    It 'the module manifest exists' {
        $script:moduleManifestPath |
            Should -Exist
    }

    It 'the probe process exited with code 0' {
        $script:probeExitCode |
            Should -Be 0 -Because $script:probeOutputRaw
    }

    It 'the probe process produced parseable output' {
        $script:probeResult |
            Should -Not -BeNullOrEmpty -Because $script:probeOutputRaw
    }

    It 'imports twice with -Force, builds a client, and starts a connection attempt without a dependency error' {
        $script:probeResult.Success |
            Should -BeTrue -Because $script:probeResult.ErrorMessage
    }
}