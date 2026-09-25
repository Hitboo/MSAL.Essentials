<#
    .SYNOPSIS
        Fetches the latest Microsoft.Identity.Client and Microsoft.IdentityModel.Abstractions
        DLLs from NuGet and places them under src\lib\<framework>\.

    .EXAMPLE
        . .\build\Update-MsalLibDependencies.ps1
        Update-MsalLibDependencies
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

function Update-MsalLibDependencies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]
        $LibPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\src\lib'),

        [string[]]
        $TargetFrameworks = @('net472', 'netstandard2.0'),

        [switch]
        $Force
    )

    # NuGet's endpoints require TLS 1.2+; Windows PowerShell 5.1 doesn't always default to it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Packages = @(
        'Microsoft.IdentityModel.Abstractions',
        'Microsoft.Identity.Client'
    )

    $manifestPath = Join-Path -Path $LibPath -ChildPath 'dependencies.json'
    $manifest     = if (Test-Path -Path $manifestPath) {
        Add-Type -AssemblyName 'System.Web.Extensions'
        $serializer = New-Object -TypeName 'System.Web.Script.Serialization.JavaScriptSerializer'
        $serializer.Deserialize((Get-Content -Path $manifestPath -Raw), [System.Collections.Hashtable])
    } else {
        @{}
    }

    foreach ($packageId in $Packages) {
        $latestVersion  = Get-LatestNuGetPackageVersion -PackageId $packageId
        $currentVersion = $manifest[$packageId]

        if (-not $Force -and $currentVersion -eq $latestVersion) {
            Write-Host ('{0} already up to date ({1}).' -f $packageId, $currentVersion)
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($packageId, ('Update from ''{0}'' to ''{1}''' -f $currentVersion, $latestVersion))) {
            continue
        }

        $downloadUri = 'https://www.nuget.org/api/v2/package/{0}/{1}' -f $packageId, $latestVersion
        $tempRoot    = Join-Path -Path $env:TEMP -ChildPath ('nuget-fetch-{0}' -f (Get-Random))
        $nupkgPath   = Join-Path -Path $tempRoot -ChildPath 'package.zip'

        New-Item -Force -ItemType 'Directory' -Path $tempRoot | Out-Null

        try {
            Invoke-WebRequest -Uri $downloadUri -OutFile $nupkgPath

            $extractPath = Join-Path -Path $tempRoot -ChildPath 'extracted'
            Expand-Archive -Path $nupkgPath -DestinationPath $extractPath -Force

            foreach ($targetFramework in $TargetFrameworks) {
                $sourceLibDir = Join-Path -Path $extractPath -ChildPath ('lib\{0}' -f $targetFramework)

                if (-not (Test-Path -Path $sourceLibDir)) {
                    throw ('No ''{0}'' build found for {1} {2} at {3}' -f $targetFramework, $packageId, $latestVersion, $sourceLibDir)
                }

                $destDir = Join-Path -Path $LibPath -ChildPath $targetFramework
                New-Item -Force -ItemType 'Directory' -Path $destDir | Out-Null

                foreach ($dll in Get-ChildItem -Path $sourceLibDir -Filter '*.dll') {
                    Copy-Item -Path $dll.FullName -Destination $destDir -Force
                }
            }

            $manifest[$packageId] = $latestVersion
            Write-Host ('{0} updated to {1}.' -f $packageId, $latestVersion)
        }
        finally {
            Remove-Item -Recurse -Force -Path $tempRoot -ErrorAction 'SilentlyContinue'
        }
    }

    New-Item -Force -ItemType 'Directory' -Path $LibPath | Out-Null
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath
}