<#
    .SYNOPSIS
        Fetches Microsoft.Identity.Client and its full, correctly-resolved
        transitive dependency graph, and places the DLLs under
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

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies -Force

    .EXAMPLE
        Update-MsalLibDependencies -Version 4.43.1 -Force
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

    $resultLines = & $resolvedHostCommand.Source -NoProfile -NonInteractive -File (Join-Path -Path $psscriptRoot -ChildPath 'Probes\Update-MsalLibDependenciesProbe.ps1') -LibFolderPath $LibFolderPath
    $resultJson  = $resultLines | Out-String

    if ([string]::IsNullOrWhiteSpace($resultJson)) {
        return @()
    }

    $parsedResult = $resultJson | ConvertFrom-Json
    return @($parsedResult.Mismatches) | Where-Object -FilterScript { $_ }
}

function Update-MsalLibDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]
        $LibRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\src\lib'),

        # Name = output folder under $LibRoot, Tfm = the target framework
        # NuGet resolves the dependency graph for.
        [hashtable[]]
        $Targets = @(
            @{ Name = 'net472';         Tfm = 'net472';         HostExe = 'powershell' } # Windows PowerShell 5.1
            @{ Name = 'netstandard2.0'; Tfm = 'netstandard2.0'; HostExe = 'pwsh' }       # PowerShell 7+
        ),

        [string]
        $PackageId = 'Microsoft.Identity.Client',

        # Pin a specific version (e.g. '4.43.1'). Default: latest stable.
        [string]
        $Version,

        [string]
        $NuGetSource = 'https://api.nuget.org/v3/index.json',

        [switch]
        $Force
    )

    # NuGet's endpoints require TLS 1.2+; Windows PowerShell 5.1 doesn't always default to it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Command -Name 'dotnet' -ErrorAction 'SilentlyContinue')) {
        throw 'The .NET SDK (dotnet) is required to resolve the dependency graph. Install it from https://dot.net and re-run.'
    }

    New-Item -Force -ItemType 'Directory' -Path $LibRoot | Out-Null

    # Manifest (built by hand from ConvertFrom-Json; -AsHashtable isn't in 5.1)
    $manifestPath = Join-Path -Path $LibRoot -ChildPath 'dependencies.json'
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

    $resolvedByTarget = [ordered]@{}

    foreach ($target in $Targets) {
        $workDir = Join-Path -Path $env:TEMP -ChildPath ('msal-fetch-{0}-{1}' -f $target.Name, (Get-Random))
        $outDir  = Join-Path -Path $workDir -ChildPath 'out'
        New-Item -Force -ItemType 'Directory' -Path $outDir | Out-Null

        try {
            $projectName = 'MsalFetch'
            $projectPath = Join-Path -Path $workDir -ChildPath ('{0}.csproj' -f $projectName)

            # Empty library project whose only job is to make NuGet resolve the
            # graph for ONE target framework and copy the runtime assets locally.
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
    <NuGetAudit>false</NuGetAudit>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="$PackageId" Version="$resolvedVersion" />
  </ItemGroup>
</Project>
"@
            Set-Content -Path $projectPath -Value $projectXml -Encoding 'UTF8'

            $buildOutput = & dotnet build $projectPath -c Release -o $outDir --nologo -v q "-p:RestoreSources=$NuGetSource" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('dotnet build failed for {0} {1} on {2} (exit {3}):{4}{5}' -f $PackageId, $resolvedVersion, $target.Tfm, $LASTEXITCODE, [Environment]::NewLine, ($buildOutput | Out-String))
            }

            # Everything except the empty project's own assembly.
            $dlls = @(Get-ChildItem -Path $outDir -Filter '*.dll' -File |
                Where-Object -FilterScript { $_.BaseName -ne $projectName })

            if ($dlls.Count -eq 0) {
                throw ('No DLLs were produced for {0} {1} on {2} - check {3}' -f $PackageId, $resolvedVersion, $target.Tfm, $workDir)
            }

            # Record exactly which package versions NuGet resolved (for the log + manifest)
            $assetsPath = Join-Path -Path $workDir -ChildPath 'obj\project.assets.json'
            if (Test-Path -Path $assetsPath) {
                $assets   = Get-Content -Path $assetsPath -Raw | ConvertFrom-Json
                $tfmGraph = @($assets.targets.PSObject.Properties)[0].Value
                $resolvedByTarget[$target.Name] = @(
                    $tfmGraph.PSObject.Properties |
                        Where-Object -FilterScript { $_.Value.PSObject.Properties['runtime'] } |
                        ForEach-Object -Process { $_.Name }
                )
            }

            # Only now that the build succeeded do we touch the destination.
            $destDir = Join-Path -Path $LibRoot -ChildPath $target.Name
            New-Item -Force -ItemType 'Directory' -Path $destDir | Out-Null
            Get-ChildItem -Path $destDir -Filter '*.dll' | Remove-Item -Force
            $dlls | Copy-Item -Destination $destDir -Force

            Write-Host ('{0}: {1} DLL(s) copied to {2}' -f $target.Name, $dlls.Count, $destDir)
            foreach ($entry in $resolvedByTarget[$target.Name]) {
                Write-Host ('    {0}' -f $entry)
            }
        }
        finally {
            Remove-Item -Recurse -Force -Path $workDir -ErrorAction 'SilentlyContinue'
        }
    }

    # Fresh manifest: the old per-dependency keys no longer apply.
    $newManifest = [ordered]@{ $PackageId = $resolvedVersion; Resolved = $resolvedByTarget }
    $newManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath

    if ($currentVersion -eq $resolvedVersion) {
        Write-Host ('{0} re-fetched at version {1}.' -f $PackageId, $resolvedVersion)
    } else {
        Write-Host ('{0} updated from version {1} to {2}.' -f $PackageId, $currentVersion, $resolvedVersion)
    }

    # Reference check, once, at the end.
    foreach ($target in $Targets) {
        $destDir = Join-Path -Path $LibRoot -ChildPath $target.Name
        if (-not (Test-Path -Path $destDir)) {
            continue
        }

        $mismatches = Test-LibAssemblyReferences -LibFolderPath $destDir -HostExecutableName $target.HostExe

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