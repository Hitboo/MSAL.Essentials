<#
    .SYNOPSIS
        Checks the libraries bundled in src\lib for known vulnerabilities and for
        a newer MSAL.NET release.

    .DESCRIPTION
        1. Vulnerabilities. For every target in the "Resolved" section of
           src\lib\dependencies.json, a throwaway project is created that
           references exactly those packages and versions. `dotnet restore`
           then runs NuGet's audit on them, transitive packages included.
           Only a restore is done, no build, so MSBuild files that a package
           ships are never run.
           The audit has to run: if NuGet could not retrieve the vulnerability
           data, that counts as a blocking finding, because "not checked" is
           not "safe".
        2. New version. The bundled version of the package (default
           Microsoft.Identity.Client) is compared with the latest stable
           version on nuget.org.

        Nothing is changed. Updating is done with
        Update-MsalLibDependencies (build\Update-MsalLibDependencies.ps1).

        Requires the .NET SDK 8.0.100 or later and internet access.

    .PARAMETER FailOnSeverity
        Findings of this severity or higher (and findings where the audit could
        not run) are returned as BlockingFindings. Lower ones are only listed.

    .EXAMPLE
        ./build/Test-MsalLibDependencies.ps1

    .OUTPUTS
        PackageId, BundledVersion, LatestVersion, UpdateAvailable, Findings
        (Target, Code, Severity, Message) and BlockingFindings.
#>
[CmdletBinding()]
param(
    [string]
    $LibRoot = (Join-Path -Path $PSScriptRoot -ChildPath '../src/lib'),

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]
    $PackageId = 'Microsoft.Identity.Client',

    [ValidatePattern('^https://')]
    [string]
    $NuGetSource = 'https://api.nuget.org/v3/index.json',

    [ValidateSet('Low', 'Moderate', 'High', 'Critical')]
    [string]
    $FailOnSeverity = 'Moderate'
)

$ErrorActionPreference = 'Stop'

# Dot-sourcing only defines functions (Get-NuGetAuditFinding, Get-LatestNuGetPackageVersion, ...).
. (Join-Path -Path $PSScriptRoot -ChildPath 'Update-MsalLibDependencies.ps1')

#region Requirements
if (-not (Get-Command -Name 'dotnet' -ErrorAction 'SilentlyContinue')) {
    throw 'The .NET SDK (dotnet) is required. Install it from https://dot.net.'
}

# Older SDKs silently ignore the audit settings, which would look like "no vulnerabilities".
$dotnetVersionText = @(& dotnet --version)[0]
if ($dotnetVersionText -notmatch '^(?<version>\d+\.\d+\.\d+)') {
    throw ('Could not read the .NET SDK version from "{0}".' -f $dotnetVersionText)
}
if ([version]$Matches['version'] -lt [version]'8.0.100') {
    throw ('The vulnerability check needs .NET SDK 8.0.100 or later (found {0}).' -f $dotnetVersionText)
}
#endregion Requirements

#region Read the manifest
$libRootPath  = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LibRoot)
$manifestPath = Join-Path -Path $libRootPath -ChildPath 'dependencies.json'

if (-not (Test-Path -Path $manifestPath)) {
    throw ('{0} was not found.' -f $manifestPath)
}

$manifest       = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
$bundledVersion = [string]$manifest.$PackageId

if (-not $bundledVersion) {
    throw ('dependencies.json has no version for {0}.' -f $PackageId)
}
if (-not $manifest.PSObject.Properties['Resolved']) {
    throw 'dependencies.json has no Resolved section. Run Update-MsalLibDependencies -Force to create it.'
}
#endregion Read the manifest

$severityRank = @{ Low = 1; Moderate = 2; High = 3; Critical = 4 }
$findings     = New-Object -TypeName 'System.Collections.Generic.List[psobject]'

$workRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('msal-audit-{0}' -f [guid]::NewGuid())

try {
    #region 1. Vulnerabilities in the shipped libraries
    foreach ($targetProperty in $manifest.Resolved.PSObject.Properties) {
        $targetFramework = $targetProperty.Name

        # Target names and package entries end up in a project file, so only plain values are accepted.
        if ($targetFramework -notmatch '^[A-Za-z0-9._-]+$') {
            throw ('Invalid target "{0}" in dependencies.json.' -f $targetFramework)
        }

        $packageReferences = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($entry in @($targetProperty.Value)) {
            if ($entry -match '^(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)/(?<version>\d+(\.\d+){1,3})$') {
                # [x.y.z] pins exactly this version.
                $packageReferences.Add(('    <PackageReference Include="{0}" Version="[{1}]" />' -f $Matches['id'], $Matches['version']))
            }
            else {
                throw ('Invalid package entry "{0}" in dependencies.json.' -f $entry)
            }
        }

        $projectDirectory = Join-Path -Path $workRoot -ChildPath $targetFramework
        New-Item -Force -ItemType 'Directory' -Path $projectDirectory | Out-Null
        $projectPath = Join-Path -Path $projectDirectory -ChildPath 'AuditShipped.csproj'

        $projectXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$targetFramework</TargetFramework>
    <NuGetAudit>true</NuGetAudit>
    <NuGetAuditMode>all</NuGetAuditMode>
    <NuGetAuditLevel>low</NuGetAuditLevel>
  </PropertyGroup>
  <ItemGroup>
$($packageReferences -join [Environment]::NewLine)
  </ItemGroup>
</Project>
"@
        Set-Content -Path $projectPath -Value $projectXml -Encoding 'UTF8'

        $restoreOutput   = & dotnet restore $projectPath --source $NuGetSource --nologo -v q 2>&1
        $restoreExitCode = $LASTEXITCODE
        $restoreText     = $restoreOutput | Out-String

        if ($restoreExitCode -ne 0) {
            throw ('dotnet restore failed for {0} (exit {1}):{2}{3}' -f $targetFramework, $restoreExitCode, [Environment]::NewLine, $restoreText)
        }

        foreach ($finding in @(Get-NuGetAuditFinding -BuildOutput $restoreText)) {
            $findings.Add([pscustomobject]@{
                Target   = $targetFramework
                Code     = $finding.Code
                Severity = $finding.Severity
                Message  = $finding.Message
            })
        }
    }
    #endregion 1. Vulnerabilities in the shipped libraries
}
finally {
    Remove-Item -Recurse -Force -Path $workRoot -ErrorAction 'SilentlyContinue'
}

# "Unknown" means the vulnerability data could not be retrieved: not checked, so it blocks.
$blockingFindings = @($findings | Where-Object -FilterScript {
        $_.Severity -eq 'Unknown' -or $severityRank[$_.Severity] -ge $severityRank[$FailOnSeverity]
    })

#region 2. New version
$latestVersion   = Get-LatestNuGetPackageVersion -PackageId $PackageId
$updateAvailable = [version]$latestVersion -gt [version]$bundledVersion
#endregion 2. New version

[pscustomobject]@{
    PackageId        = $PackageId
    BundledVersion   = $bundledVersion
    LatestVersion    = [string]$latestVersion
    UpdateAvailable  = $updateAvailable
    Findings         = @($findings)
    BlockingFindings = $blockingFindings
}