<#
    .SYNOPSIS
        Fetches Microsoft.Identity.Client (and its full transitive dependency
        graph) via nuget.exe and places the DLLs under src\lib\<framework>\,
        for both Windows PowerShell 5.1 (net472) and PowerShell 7 (netstandard2.0).

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies

    .EXAMPLE
        # Pin to a specific version instead of latest (e.g. to avoid the
        # dependency chain introduced in 4.45.0+)
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

function Resolve-PackageLibDir {
    # Finds the best-matching lib\<framework> folder inside an installed package,
    # walking down a compatibility fallback chain.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $PackageLibPath,

        [Parameter(Mandatory)]
        [string[]]
        $FrameworkFallbackOrder
    )

    foreach ($framework in $FrameworkFallbackOrder) {
        $candidate = Join-Path -Path $PackageLibPath -ChildPath $framework
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Update-MsalLibDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]
        $LibRoot = (Join-Path -Path $PSScriptRoot -ChildPath '..\src\lib'),

        # One nuget.exe install covers every target below - the downloaded
        # package already contains all of its lib\<tfm> folders, so we just
        # copy from a different one per target instead of re-downloading.
        [hashtable[]]
        $Targets = @(
            @{ Name = 'net472';         FallbackOrder = @('net472', 'net471', 'net47', 'net462', 'net461', 'net46', 'netstandard2.0') } # Windows PowerShell 5.1
            @{ Name = 'netstandard2.0'; FallbackOrder = @('netstandard2.0', 'net6.0', 'net5.0') }                                        # PowerShell 7+ (pwsh)
        ),

        # Pin a specific version (e.g. '4.43.1'). Omit to use the latest stable release.
        [string]
        $Version,

        [string]
        $NuGetSource = 'https://api.nuget.org/v3/index.json',

        [switch]
        $Force
    )

    # NuGet's endpoints require TLS 1.2+; Windows PowerShell 5.1 doesn't always default to it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Download the NuGet CLI if it's not already present in the build folder.
    $NugetExePath = Join-Path -Path $PSScriptRoot -ChildPath 'nuget.exe'
    if (-not (Test-Path -Path $NugetExePath)) {
        Write-Host 'nuget.exe not found - downloading...'
        Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $NugetExePath
    }

    # Only the top-level package needs to be listed here - nuget.exe install resolves
    # and downloads the whole dependency tree (Microsoft.IdentityModel.Abstractions,
    # System.Text.Json, System.Buffers, System.Memory, etc.) automatically.
    $Packages = @(
        'Microsoft.Identity.Client'
    )

    $manifestPath = Join-Path -Path $LibRoot -ChildPath 'dependencies.json'
    $manifest     = if (Test-Path -Path $manifestPath) {
        Add-Type -AssemblyName 'System.Web.Extensions'
        $serializer = New-Object -TypeName 'System.Web.Script.Serialization.JavaScriptSerializer'
        $serializer.Deserialize((Get-Content -Path $manifestPath -Raw), [System.Collections.Hashtable])
    } else {
        @{}
    }

    foreach ($packageId in $Packages) {
        $resolvedVersion = if ($PSBoundParameters.ContainsKey('Version') -and $Version) {
            $Version
        } else {
            Get-LatestNuGetPackageVersion -PackageId $packageId
        }

        $currentVersion = $manifest[$packageId]

        if (-not $Force -and $currentVersion -eq $resolvedVersion) {
            Write-Host ('{0} already up to date ({1}).' -f $packageId, $currentVersion)
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($packageId, ('Update from ''{0}'' to ''{1}''' -f $currentVersion, $resolvedVersion))) {
            continue
        }

        $tempRoot = Join-Path -Path $env:TEMP -ChildPath ('nuget-fetch-{0}' -f (Get-Random))
        New-Item -Force -ItemType 'Directory' -Path $tempRoot | Out-Null

        try {
            & $NugetExePath install $packageId `
                -Version $resolvedVersion `
                -Source $NuGetSource `
                -OutputDirectory $tempRoot `
                -ExcludeVersion `
                -NonInteractive `
                -Verbosity 'quiet'

            if ($LASTEXITCODE -ne 0) {
                throw ('nuget.exe install failed for {0} {1} (exit code {2})' -f $packageId, $resolvedVersion, $LASTEXITCODE)
            }

            $installedPackages = Get-ChildItem -Path $tempRoot -Directory

            if (-not $installedPackages) {
                throw ('nuget.exe reported success but no packages were found under {0}' -f $tempRoot)
            }

            foreach ($target in $Targets) {
                $destDir = Join-Path -Path $LibRoot -ChildPath $target.Name
                New-Item -Force -ItemType 'Directory' -Path $destDir | Out-Null

                $copiedAny = $false

                foreach ($installedPackage in $installedPackages) {
                    $pkgLibRoot = Join-Path -Path $installedPackage.FullName -ChildPath 'lib'

                    if (-not (Test-Path -Path $pkgLibRoot)) {
                        continue # e.g. build-only/analyzer-only packages have no lib\ folder
                    }

                    $sourceDir = Resolve-PackageLibDir -PackageLibPath $pkgLibRoot -FrameworkFallbackOrder $target.FallbackOrder

                    if (-not $sourceDir) {
                        Write-Warning ('No compatible build found for {0} under target ''{1}'' ({2}) - skipping.' -f $installedPackage.Name, $target.Name, ($target.FallbackOrder -join ', '))
                        continue
                    }

                    Get-ChildItem -Path $sourceDir -Filter '*.dll' | ForEach-Object {
                        Copy-Item -Path $_.FullName -Destination $destDir -Force
                        $copiedAny = $true
                    }
                }

                if (-not $copiedAny) {
                    throw ('No DLLs were copied for {0} {1} under target ''{2}'' - check {3} manually.' -f $packageId, $resolvedVersion, $target.Name, $tempRoot)
                }

                Write-Host ('  -> {0}: copied to {1}' -f $target.Name, $destDir)
            }

            $manifest[$packageId] = $resolvedVersion
            Write-Host ('{0} updated to {1}.' -f $packageId, $resolvedVersion)
        }
        finally {
            Remove-Item -Recurse -Force -Path $tempRoot -ErrorAction 'SilentlyContinue'
        }
    }

    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath
}