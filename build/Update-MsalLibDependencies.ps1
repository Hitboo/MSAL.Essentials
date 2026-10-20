<#
    .SYNOPSIS
        Fetches Microsoft.Identity.Client and its full, correctly-resolved
        transitive dependency graph, checks it, and places the DLLs under
        src\lib\<target>\ for Windows PowerShell 5.1 (net472) and
        PowerShell 7+ (netstandard2.0).

    .DESCRIPTION
        Resolution is done by NuGet's real restore engine (via `dotnet build`
        on a throwaway project), once per target framework. That gives:
          - only the dependency group that applies to that TFM
          - the package versions NuGet itself resolves (what the packages
            declare they need), not "latest of everything"
          - the right lib\<tfm> asset picked per package

        Requires the .NET SDK (`dotnet`) on the machine running this script.
        The vulnerability check needs .NET SDK 8.0.100 or later.

        Before anything is copied into src\lib, every target is fetched into
        a temporary folder and checked:

          1. Vulnerability audit. NuGet's audit runs on the whole graph,
             including transitive packages. A finding at or above
             -FailOnVulnerabilitySeverity (default Moderate) stops the update;
             lower findings are shown as warnings. If the vulnerability data
             cannot be retrieved, the update also stops, because "not checked"
             is not "safe". Use -SkipVulnerabilityCheck to bypass the check.
          2. Authenticode signatures (Windows only). Every DLL must have a
             valid signature from Microsoft Corporation. Use
             -SkipSignatureCheck to bypass the check.

        Only when all targets pass, the DLLs are copied and dependencies.json
        is rewritten. It records the package versions, what NuGet resolved
        per target ("Resolved") and the SHA-256 of every DLL ("Hashes").
        Test-MsalLibIntegrity compares the folders to those hashes, so a DLL
        that was replaced or edited by hand is detected.

        NuGet resolves the lowest version each package declares, so the audit
        can flag a transitive package that has a patched version. Pin the
        patched version with -PackageOverrides (recorded as "Overrides").

    .NOTES
        `dotnet build` also imports MSBuild files (.props and .targets) that
        a package ships, and those can run code. That is acceptable for the
        Microsoft packages this module bundles. Think twice before pointing
        -PackageId at a package you don't trust.

        Windows PowerShell 5.1 is not affected by .NET binding redirects, so
        the module's AssemblyResolve fallback has to cover version mismatches
        that the reference check reports for net472.

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies -WhatIf
        Update-MsalLibDependencies

        Loads the functions, previews the update, then runs it.

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies -Force -Version 4.43.1

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies -PackageOverrides @{ 'System.Text.Json' = '8.0.5' }

        Pins a patched version of a transitive package that the audit flagged.

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Test-MsalLibIntegrity

        Lists problems if a DLL in src\lib differs from dependencies.json. No output means no problems.
#>

function Get-LatestNuGetPackageVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $PackageId
    )

    $uri = 'https://api.nuget.org/v3-flatcontainer/{0}/index.json' -f $PackageId.ToLower()

    (Invoke-RestMethod -Method 'Get' -Uri $uri).versions -notmatch '-' |
        Sort-Object -Property { [version]$_ } |
        Select-Object -Last 1
}

function Get-NuGetAuditFinding {
    # Reads the NuGet audit warnings (NU1900 to NU1904) from `dotnet build`
    # output. The same warning is printed during restore and during build,
    # so duplicates are removed.
    [CmdletBinding()]
    param(
        [string]
        $BuildOutput
    )

    $severityByCode = @{
        NU1900 = 'Unknown'   # the vulnerability data could not be retrieved
        NU1901 = 'Low'
        NU1902 = 'Moderate'
        NU1903 = 'High'
        NU1904 = 'Critical'
    }

    $alreadySeen = @{}

    foreach ($match in [regex]::Matches($BuildOutput, '(?m)warning (?<code>NU190[0-4]): (?<message>[^\r\n]+)')) {
        $code    = $match.Groups['code'].Value
        $message = ($match.Groups['message'].Value -replace '\s+\[[^\]]*\]\s*$', '').Trim()
        $key     = '{0}|{1}' -f $code, $message

        if ($alreadySeen.ContainsKey($key)) {
            continue
        }
        $alreadySeen[$key] = $true

        [pscustomobject]@{
            Code     = $code
            Severity = $severityByCode[$code]
            Message  = $message
        }
    }
}

function Test-LibAssemblySignatures {
    # Every DLL must carry a valid Authenticode signature from Microsoft
    # Corporation (the certificate subject is "Microsoft Corporation" or
    # "Microsoft 3rd Party Application Component", both with that organization).
    # Returns one string per problem; no output means no problems.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $FolderPath
    )

    if (-not (Get-Command -Name 'Get-AuthenticodeSignature' -ErrorAction 'SilentlyContinue')) {
        Write-Warning 'Get-AuthenticodeSignature is not available on this platform - the signature check was skipped.'
        return @()
    }

    $problems = foreach ($dll in Get-ChildItem -Path $FolderPath -Filter '*.dll' -File) {
        $signature = Get-AuthenticodeSignature -FilePath $dll.FullName

        if ($signature.Status -ne 'Valid') {
            '{0}: signature status is {1}' -f $dll.Name, $signature.Status
        }
        elseif ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            '{0}: signed by "{1}", not by Microsoft Corporation' -f $dll.Name, $signature.SignerCertificate.Subject
        }
    }

    return @($problems | Where-Object -FilterScript { $_ })
}

function Test-LibAssemblyReferences {
    # Loads every DLL in a target folder in a throwaway child process and
    # checks that every assembly's compiled references match, version for
    # version, what's physically on disk. Must run via the SAME host that will
    # load this folder (powershell.exe for net472, pwsh.exe for netstandard2.0);
    # pwsh supplies its own copies of many of these assemblies from the .NET
    # shared framework, so checking net472 files through pwsh gives false results.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $LibFolderPath,

        [Parameter(Mandatory)]
        [ValidateSet('powershell', 'pwsh')]
        [string]
        $HostExecutableName
    )

    $resolvedHostCommand = Get-Command -Name $HostExecutableName -ErrorAction 'SilentlyContinue'
    if (-not $resolvedHostCommand) {
        Write-Warning ('{0} is not installed on this machine - skipping the reference check for {1}.' -f $HostExecutableName, $LibFolderPath)
        return @()
    }

    $probeScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'probes/Update-MsalLibDependenciesProbe.ps1'

    $resultLines   = & $resolvedHostCommand.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeScriptPath -LibFolderPath $LibFolderPath 2>&1
    $probeExitCode = $LASTEXITCODE
    $rawOutput     = $resultLines | Out-String

    # A probe that crashed or printed nothing must not look like "no mismatches".
    if ($probeExitCode -ne 0) {
        throw ('The reference probe failed in {0} (exit code {1}): {2}' -f $HostExecutableName, $probeExitCode, $rawOutput)
    }

    try {
        $parsedResult = $resultLines | Select-Object -Last 1 | ConvertFrom-Json
    }
    catch {
        throw ('The reference probe returned output that is not JSON: {0}' -f $rawOutput)
    }

    return @($parsedResult.Mismatches) | Where-Object -FilterScript { $_ }
}

function Test-MsalLibIntegrity {
    # Compares the DLLs in src\lib with the SHA-256 hashes in dependencies.json.
    # Returns one string per problem; no output means no problems.
    [CmdletBinding()]
    param(
        [string]
        $LibRoot = (Join-Path -Path $PSScriptRoot -ChildPath '../src/lib')
    )

    $libRootPath  = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LibRoot)
    $manifestPath = Join-Path -Path $libRootPath -ChildPath 'dependencies.json'

    if (-not (Test-Path -Path $manifestPath)) {
        return @('dependencies.json was not found.')
    }

    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

    if (-not $manifest.PSObject.Properties['Hashes']) {
        return @('dependencies.json has no Hashes section. Run Update-MsalLibDependencies -Force to create it.')
    }

    $problems = foreach ($targetProperty in $manifest.Hashes.PSObject.Properties) {
        $folderPath = Join-Path -Path $libRootPath -ChildPath $targetProperty.Name

        $expectedHashes = @{}
        foreach ($fileProperty in $targetProperty.Value.PSObject.Properties) {
            $expectedHashes[$fileProperty.Name] = $fileProperty.Value
        }

        foreach ($fileName in $expectedHashes.Keys) {
            $filePath = Join-Path -Path $folderPath -ChildPath $fileName

            if (-not (Test-Path -Path $filePath)) {
                '{0}/{1}: file is missing' -f $targetProperty.Name, $fileName
            }
            elseif ((Get-FileHash -Path $filePath -Algorithm 'SHA256').Hash -ne $expectedHashes[$fileName]) {
                '{0}/{1}: hash does not match dependencies.json' -f $targetProperty.Name, $fileName
            }
        }

        if (Test-Path -Path $folderPath) {
            foreach ($dll in Get-ChildItem -Path $folderPath -Filter '*.dll' -File) {
                if (-not $expectedHashes.ContainsKey($dll.Name)) {
                    '{0}/{1}: file is not listed in dependencies.json' -f $targetProperty.Name, $dll.Name
                }
            }
        }
        else {
            '{0}: folder is missing' -f $targetProperty.Name
        }
    }

    return @($problems | Where-Object -FilterScript { $_ })
}

function Update-MsalLibDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]
        $LibRoot = (Join-Path -Path $PSScriptRoot -ChildPath '../src/lib'),

        # Name = output folder under $LibRoot, Tfm = the target framework
        # NuGet resolves the dependency graph for.
        [hashtable[]]
        $Targets = @(
            @{ Name = 'net472';         Tfm = 'net472';         HostExe = 'powershell' } # Windows PowerShell 5.1
            @{ Name = 'netstandard2.0'; Tfm = 'netstandard2.0'; HostExe = 'pwsh' }       # PowerShell 7+
        ),

        # Used in a generated project file, so only plain package ID characters are accepted.
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string]
        $PackageId = 'Microsoft.Identity.Client',

        # Pin a specific stable version (e.g. '4.43.1'). Default: latest stable.
        [ValidatePattern('^\d+(\.\d+){1,3}$')]
        [string]
        $Version,

        # Packages are only fetched over HTTPS.
        [ValidatePattern('^https://')]
        [string]
        $NuGetSource = 'https://api.nuget.org/v3/index.json',

        # Pin a version of a transitive package, for example a patched version
        # after the audit flagged the one NuGet resolved: @{ 'System.Text.Json' = '8.0.5' }
        [hashtable]
        $PackageOverrides = @{},

        # The update stops when the audit finds a vulnerability of this
        # severity or higher. Lower severities are shown as warnings.
        [ValidateSet('Low', 'Moderate', 'High', 'Critical')]
        [string]
        $FailOnVulnerabilitySeverity = 'Moderate',

        [switch]
        $SkipVulnerabilityCheck,

        [switch]
        $SkipSignatureCheck,

        [switch]
        $Force
    )

    # NuGet's endpoints require TLS 1.2+; Windows PowerShell 5.1 doesn't always default to it.
    # Add TLS 1.2 without removing newer protocols the machine already allows.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Command -Name 'dotnet' -ErrorAction 'SilentlyContinue')) {
        throw 'The .NET SDK (dotnet) is required to resolve the dependency graph. Install it from https://dot.net and re-run.'
    }

    if (-not $SkipVulnerabilityCheck) {
        # Older SDKs silently ignore the audit settings, which would look like "no vulnerabilities".
        $dotnetVersionText = @(& dotnet --version)[0]
        if ($dotnetVersionText -notmatch '^(?<version>\d+\.\d+\.\d+)') {
            throw ('Could not read the .NET SDK version from "{0}".' -f $dotnetVersionText)
        }
        if ([version]$Matches['version'] -lt [version]'8.0.100') {
            throw ('The vulnerability check needs .NET SDK 8.0.100 or later (found {0}). Update the SDK, or pass -SkipVulnerabilityCheck.' -f $dotnetVersionText)
        }
    }

    foreach ($target in $Targets) {
        if ($target.Name -notmatch '^[A-Za-z0-9._-]+$' -or $target.Tfm -notmatch '^[A-Za-z0-9._-]+$') {
            throw ('Invalid target "{0}" / "{1}": only letters, digits, ".", "_" and "-" are allowed.' -f $target.Name, $target.Tfm)
        }
    }

    foreach ($overrideId in $PackageOverrides.Keys) {
        if ($overrideId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or [string]$PackageOverrides[$overrideId] -notmatch '^\d+(\.\d+){1,3}$') {
            throw ('Invalid package override "{0}" = "{1}". Use a package ID and a stable version such as ''8.0.5''.' -f $overrideId, $PackageOverrides[$overrideId])
        }
    }

    $libRootPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LibRoot)
    New-Item -Force -ItemType 'Directory' -Path $libRootPath | Out-Null

    # Manifest (built by hand from ConvertFrom-Json; -AsHashtable isn't in 5.1)
    $manifestPath = Join-Path -Path $libRootPath -ChildPath 'dependencies.json'
    $manifest     = [ordered]@{}

    if (Test-Path -Path $manifestPath) {
        $manifestContent = Get-Content -Path $manifestPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($manifestContent)) {
            $manifestObject = ConvertFrom-Json -InputObject $manifestContent
            foreach ($property in $manifestObject.PSObject.Properties) {
                $manifest[$property.Name] = $property.Value
            }
        }
    }

    $resolvedVersion = if ($PSBoundParameters.ContainsKey('Version') -and $Version) {
        $Version
    } else {
        Get-LatestNuGetPackageVersion -PackageId $PackageId
    }

    $currentVersion = $manifest[$PackageId]

    if (-not $Force -and $currentVersion -eq $resolvedVersion) {
        Write-Host ('{0} already up to date ({1}).' -f $PackageId, $currentVersion)
        return
    }

    if (-not $PSCmdlet.ShouldProcess($PackageId, ('Update from ''{0}'' to ''{1}''' -f $currentVersion, $resolvedVersion))) {
        return
    }

    $severityRank = @{ Low = 1; Moderate = 2; High = 3; Critical = 4 }

    $resolvedByTarget = [ordered]@{}
    $hashesByTarget   = [ordered]@{}
    $stagedDllFolders = [ordered]@{}

    # Everything is fetched and checked in an unpredictable temporary folder
    # first. src\lib is only touched when every target has passed.
    $stagingRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('msal-fetch-{0}' -f [guid]::NewGuid())

    try {
        foreach ($target in $Targets) {
            $workDir  = Join-Path -Path $stagingRoot -ChildPath ('{0}/work' -f $target.Name)
            $outDir   = Join-Path -Path $stagingRoot -ChildPath ('{0}/out' -f $target.Name)
            $dllStage = Join-Path -Path $stagingRoot -ChildPath ('{0}/dlls' -f $target.Name)
            New-Item -Force -ItemType 'Directory' -Path $workDir, $outDir, $dllStage | Out-Null

            $projectName = 'MsalFetch'
            $projectPath = Join-Path -Path $workDir -ChildPath ('{0}.csproj' -f $projectName)

            $packageReferences = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $packageReferences.Add(('    <PackageReference Include="{0}" Version="{1}" />' -f $PackageId, $resolvedVersion))
            foreach ($overrideId in ($PackageOverrides.Keys | Sort-Object)) {
                $packageReferences.Add(('    <PackageReference Include="{0}" Version="{1}" />' -f $overrideId, $PackageOverrides[$overrideId]))
            }

            $auditEnabled = if ($SkipVulnerabilityCheck) { 'false' } else { 'true' }

            # Empty library project whose only job is to make NuGet resolve the
            # graph for ONE target framework and copy the runtime assets locally.
            # NuGetAuditMode=all audits transitive packages too, and
            # NuGetAuditLevel=low reports every severity.
            $projectXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$($target.Tfm)</TargetFramework>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>
    <GenerateDependencyFile>false</GenerateDependencyFile>
    <SatelliteResourceLanguages>en</SatelliteResourceLanguages>
    <DebugType>none</DebugType>
    <NuGetAudit>$auditEnabled</NuGetAudit>
    <NuGetAuditMode>all</NuGetAuditMode>
    <NuGetAuditLevel>low</NuGetAuditLevel>
  </PropertyGroup>
  <ItemGroup>
$($packageReferences -join [Environment]::NewLine)
  </ItemGroup>
</Project>
"@
            Set-Content -Path $projectPath -Value $projectXml -Encoding 'UTF8'

            $buildOutput = & dotnet build $projectPath -c Release -o $outDir --nologo -v q "-p:RestoreSources=$NuGetSource" 2>&1
            $buildExitCode = $LASTEXITCODE
            $buildText     = $buildOutput | Out-String

            if ($buildExitCode -ne 0) {
                throw ('dotnet build failed for {0} {1} on {2} (exit {3}):{4}{5}' -f $PackageId, $resolvedVersion, $target.Tfm, $buildExitCode, [Environment]::NewLine, $buildText)
            }

            #region Vulnerability audit
            if (-not $SkipVulnerabilityCheck) {
                $findings = @(Get-NuGetAuditFinding -BuildOutput $buildText)

                if ($findings | Where-Object -FilterScript { $_.Code -eq 'NU1900' }) {
                    throw ('The vulnerability data could not be retrieved for {0}, so the packages were not checked. Check the network connection and re-run, or pass -SkipVulnerabilityCheck.' -f $target.Tfm)
                }

                foreach ($finding in $findings) {
                    Write-Warning ('{0}: [{1}] {2}' -f $target.Tfm, $finding.Severity, $finding.Message)
                }

                $blockingFindings = @($findings | Where-Object -FilterScript { $severityRank[$_.Severity] -ge $severityRank[$FailOnVulnerabilitySeverity] })
                if ($blockingFindings.Count -gt 0) {
                    throw ('{0} known vulnerabilit{1} of severity {2} or higher found for {3}. Nothing was copied. Pin patched versions with -PackageOverrides, or lower -FailOnVulnerabilitySeverity if you accept the risk.' -f $blockingFindings.Count, $(if ($blockingFindings.Count -eq 1) { 'y' } else { 'ies' }), $FailOnVulnerabilitySeverity, $target.Tfm)
                }
            }
            #endregion Vulnerability audit

            # Everything except the empty project's own assembly.
            $dlls = @(Get-ChildItem -Path $outDir -Filter '*.dll' -File |
                Where-Object -FilterScript { $_.BaseName -ne $projectName })

            if ($dlls.Count -eq 0) {
                throw ('No DLLs were produced for {0} {1} on {2}.' -f $PackageId, $resolvedVersion, $target.Tfm)
            }

            $dlls | Copy-Item -Force -Destination $dllStage

            #region Signature check
            if (-not $SkipSignatureCheck) {
                $signatureProblems = @(Test-LibAssemblySignatures -FolderPath $dllStage)
                if ($signatureProblems.Count -gt 0) {
                    throw ('Signature check failed for {0}. Nothing was copied.{1}  {2}{1}Pass -SkipSignatureCheck only if you have verified the files another way.' -f $target.Tfm, [Environment]::NewLine, ($signatureProblems -join ([Environment]::NewLine + '  ')))
                }
            }
            #endregion Signature check

            # Record exactly which package versions NuGet resolved (for the log + manifest)
            $assetsPath = Join-Path -Path $workDir -ChildPath 'obj/project.assets.json'
            if (Test-Path -Path $assetsPath) {
                $assets   = Get-Content -Path $assetsPath -Raw | ConvertFrom-Json
                $tfmGraph = @($assets.targets.PSObject.Properties)[0].Value
                $resolvedByTarget[$target.Name] = @(
                    $tfmGraph.PSObject.Properties |
                        Where-Object -FilterScript { $_.Value.PSObject.Properties['runtime'] } |
                        ForEach-Object -Process { $_.Name }
                )
            }

            # SHA-256 of every DLL, so changes to the files are detectable later.
            $fileHashes = [ordered]@{}
            foreach ($stagedDll in (Get-ChildItem -Path $dllStage -Filter '*.dll' -File | Sort-Object -Property 'Name')) {
                $fileHashes[$stagedDll.Name] = (Get-FileHash -Path $stagedDll.FullName -Algorithm 'SHA256').Hash
            }
            $hashesByTarget[$target.Name] = $fileHashes

            $stagedDllFolders[$target.Name] = $dllStage
        }

        # Every target passed: only now the destination is touched.
        foreach ($target in $Targets) {
            $destDir = Join-Path -Path $libRootPath -ChildPath $target.Name
            New-Item -Force -ItemType 'Directory' -Path $destDir | Out-Null
            Get-ChildItem -Path $destDir -Filter '*.dll' | Remove-Item -Force
            Get-ChildItem -Path $stagedDllFolders[$target.Name] -Filter '*.dll' -File | Copy-Item -Force -Destination $destDir

            Write-Host ('{0}: {1} DLL(s) copied to {2}' -f $target.Name, $hashesByTarget[$target.Name].Count, $destDir)
            foreach ($entry in $resolvedByTarget[$target.Name]) {
                Write-Host ('    {0}' -f $entry)
            }
        }
    }
    finally {
        Remove-Item -Recurse -Force -Path $stagingRoot -ErrorAction 'SilentlyContinue'
    }

    # Fresh manifest: the old per-dependency keys no longer apply.
    $newManifest = [ordered]@{
        $PackageId = $resolvedVersion
        Resolved   = $resolvedByTarget
        Hashes     = $hashesByTarget
    }
    if ($PackageOverrides.Count -gt 0) {
        $overridesForManifest = [ordered]@{}
        foreach ($overrideId in ($PackageOverrides.Keys | Sort-Object)) {
            $overridesForManifest[$overrideId] = [string]$PackageOverrides[$overrideId]
        }
        $newManifest['Overrides'] = $overridesForManifest
    }

    # UTF-8 without a byte order mark, the same in both PowerShell editions.
    $manifestJson = $newManifest | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

    if ($currentVersion -eq $resolvedVersion) {
        Write-Host ('{0} re-fetched at version {1}.' -f $PackageId, $resolvedVersion)
    } else {
        Write-Host ('{0} updated from version {1} to {2}.' -f $PackageId, $currentVersion, $resolvedVersion)
    }

    if ($SkipVulnerabilityCheck) {
        Write-Warning 'The vulnerability check was skipped.'
    }
    else {
        Write-Host ('Vulnerability check passed (NuGet audit, transitive packages included, fail level {0}).' -f $FailOnVulnerabilitySeverity)
    }

    if ($SkipSignatureCheck) {
        Write-Warning 'The signature check was skipped.'
    }

    # Reference check, once, at the end.
    foreach ($target in $Targets) {
        $destDir = Join-Path -Path $libRootPath -ChildPath $target.Name
        if (-not (Test-Path -Path $destDir)) {
            continue
        }

        try {
            $mismatches = Test-LibAssemblyReferences -LibFolderPath $destDir -HostExecutableName $target.HostExe
        }
        catch {
            Write-Warning ('The reference check for {0} could not run: {1}' -f $destDir, $_.Exception.Message)
            continue
        }

        if ($mismatches) {
            if ($target.HostExe -eq 'powershell') {
                Write-Warning ('Assembly version mismatches found in {0}:' -f $destDir)
                foreach ($mismatch in $mismatches) {
                    Write-Warning ('  {0}' -f $mismatch)
                }
                Write-Warning 'Windows PowerShell has no binding redirects, so these need the module''s AssemblyResolve fallback.'
            }
            else {
                Write-Host ('Note: {0} difference(s) reported for {1} are expected - pwsh supplies many of these assemblies from the .NET shared framework.' -f @($mismatches).Count, $destDir)
            }
        }
        else {
            Write-Host ('No assembly version mismatches found in {0}.' -f $destDir)
        }
    }
}