<#
    .SYNOPSIS
        Builds the MSAL.Essentials release package: a folder and a zip file that
        contain only the files the module needs.

    .DESCRIPTION
        Any failed check stops the build. The steps:

          1. Reads the version from src\MSAL.Essentials.psd1 (ModuleVersion and,
             for pre-releases, PrivateData.PSData.Prerelease).
          2. With -Tag: checks that the tag is exactly 'v<version>', for example
             v1.0.0 or v2.0.0-beta1.
          3. Checks that CHANGELOG.md has a section '## [<version>]' with text in
             it, and saves that text as release-notes.md.
          4. Checks that the DLLs in src\lib still match the hashes in
             dependencies.json (Test-MsalLibIntegrity).
          5. Copies the module files (src, LICENSE, THIRD-PARTY-NOTICES.md and
             README.md) to <OutputPath>\stage\MSAL.Essentials and runs
             Test-ModuleManifest on the result.
          6. Creates <OutputPath>\MSAL.Essentials-<version>.zip and
             <OutputPath>\SHA256SUMS.txt.

        Nothing is published. The release workflow (.github/workflows/release.yml)
        does that. You can run this script locally to rehearse a release.

        The output folder is deleted and created again. It must be a folder inside
        the repository (not the repository root and not src); the default is
        'output' in the repository root, which is ignored by git.

    .PARAMETER Tag
        The git tag that is being released, for example 'v1.0.0'. It has to match
        the version in the module manifest. Leave it out for a local rehearsal.

    .PARAMETER OutputPath
        Where the package is created. Defaults to 'output' in the repository root.

    .EXAMPLE
        ./build/Build-Module.ps1
        Builds the package for the version in the manifest, without a tag check.

    .EXAMPLE
        ./build/Build-Module.ps1 -Tag v1.0.0
        Builds the package and checks that the manifest says 1.0.0.

    .OUTPUTS
        A summary with Version, IsPrerelease, ModulePath, ZipPath, ChecksumPath and NotesPath.
#>
[CmdletBinding()]
param(
    [string]
    $Tag,

    [string]
    $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../output')
)

$ErrorActionPreference = 'Stop'

$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
$separator      = [System.IO.Path]::DirectorySeparatorChar

$repositoryRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$sourcePath     = Join-Path -Path $repositoryRoot -ChildPath 'src'
$manifestPath   = Join-Path -Path $sourcePath -ChildPath 'MSAL.Essentials.psd1'
$outputFullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath).TrimEnd('\', '/')

#region Guard: the output folder is deleted, so it must be a safe place
$isInsideRepository = $outputFullPath.StartsWith(($repositoryRoot.TrimEnd('\', '/') + $separator), [System.StringComparison]::OrdinalIgnoreCase)
$isInsideSource     = ($outputFullPath -eq $sourcePath) -or $outputFullPath.StartsWith(($sourcePath + $separator), [System.StringComparison]::OrdinalIgnoreCase)

if (-not $isInsideRepository -or $isInsideSource) {
    throw ('The output folder "{0}" must be a folder inside the repository, but not src or a folder inside it.' -f $outputFullPath)
}
#endregion Guard

#region 1. Version
$manifest      = Import-PowerShellDataFile -Path $manifestPath
$moduleVersion = [string]$manifest.ModuleVersion
$prerelease    = [string]$manifest.PrivateData.PSData.Prerelease

if ($moduleVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw ('ModuleVersion "{0}" must have three parts, for example 1.0.0.' -f $moduleVersion)
}
if ($prerelease -and $prerelease -notmatch '^[A-Za-z0-9]+$') {
    throw ('Prerelease "{0}" may only contain letters and digits, for example beta1.' -f $prerelease)
}

$fullVersion  = if ($prerelease) { '{0}-{1}' -f $moduleVersion, $prerelease } else { $moduleVersion }
$isPrerelease = [bool]$prerelease
Write-Host ('Version: {0}' -f $fullVersion)
#endregion 1. Version

#region 2. Tag
if ($Tag) {
    $expectedTag = 'v{0}' -f $fullVersion
    if ($Tag -ne $expectedTag) {
        throw ('The tag "{0}" does not match the module manifest, which says "{1}". Fix the manifest or tag again.' -f $Tag, $expectedTag)
    }
    Write-Host ('Tag {0} matches the manifest.' -f $Tag)
}
#endregion 2. Tag

#region 3. Release notes from the changelog
$changelogLines = @(Get-Content -Path (Join-Path -Path $repositoryRoot -ChildPath 'CHANGELOG.md'))
$headingPattern = '^##\s+\[{0}\]' -f [regex]::Escape($fullVersion)

$startIndex = -1
for ($index = 0; $index -lt $changelogLines.Count; $index++) {
    if ($changelogLines[$index] -match $headingPattern) {
        $startIndex = $index
        break
    }
}
if ($startIndex -lt 0) {
    throw ('CHANGELOG.md has no section "## [{0}]". Add one before releasing.' -f $fullVersion)
}

$noteLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
for ($index = $startIndex + 1; $index -lt $changelogLines.Count; $index++) {
    if ($changelogLines[$index] -match '^##\s+\[') {
        break
    }
    # Link reference definitions at the end of the file are not part of the notes.
    if ($changelogLines[$index] -match '^\[[^\]]+\]:\s*\S+') {
        continue
    }
    $noteLines.Add($changelogLines[$index])
}

$releaseNotes = ($noteLines -join "`n").Trim()
if (-not $releaseNotes) {
    throw ('The CHANGELOG.md section for {0} is empty.' -f $fullVersion)
}
#endregion 3. Release notes from the changelog

#region 4. Bundled libraries
# Dot-sourcing only defines functions; nothing is run.
. (Join-Path -Path $PSScriptRoot -ChildPath 'Update-MsalLibDependencies.ps1')

$integrityProblems = @(Test-MsalLibIntegrity -LibRoot (Join-Path -Path $sourcePath -ChildPath 'lib'))
if ($integrityProblems.Count -gt 0) {
    throw ('The libraries in src/lib do not match dependencies.json:{0}  {1}' -f [Environment]::NewLine, ($integrityProblems -join ([Environment]::NewLine + '  ')))
}
Write-Host 'The libraries match dependencies.json.'
#endregion 4. Bundled libraries

#region 5. Stage the module files
Remove-Item -Path $outputFullPath -Recurse -Force -ErrorAction 'SilentlyContinue'

$moduleStagePath = Join-Path -Path $outputFullPath -ChildPath 'stage/MSAL.Essentials'
New-Item -ItemType 'Directory' -Path $moduleStagePath -Force | Out-Null

Copy-Item -Path (Join-Path -Path $sourcePath -ChildPath '*') -Destination $moduleStagePath -Recurse -Force
foreach ($fileName in 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md') {
    Copy-Item -Path (Join-Path -Path $repositoryRoot -ChildPath $fileName) -Destination $moduleStagePath -Force
}

foreach ($requiredFile in 'MSAL.Essentials.psd1', 'MSAL.Essentials.psm1', 'lib/net472/Microsoft.Identity.Client.dll', 'lib/netstandard2.0/Microsoft.Identity.Client.dll') {
    if (-not (Test-Path -Path (Join-Path -Path $moduleStagePath -ChildPath $requiredFile))) {
        throw ('The package is missing {0}.' -f $requiredFile)
    }
}

$null = Test-ModuleManifest -Path (Join-Path -Path $moduleStagePath -ChildPath 'MSAL.Essentials.psd1')
Write-Host ('Staged the module in {0}' -f $moduleStagePath)
#endregion 5. Stage the module files

#region 6. Zip, checksum and notes
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

$zipPath = Join-Path -Path $outputFullPath -ChildPath ('MSAL.Essentials-{0}.zip' -f $fullVersion)
# The last argument keeps the MSAL.Essentials folder at the top of the zip.
[System.IO.Compression.ZipFile]::CreateFromDirectory($moduleStagePath, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)

$zipHash      = (Get-FileHash -Path $zipPath -Algorithm 'SHA256').Hash.ToLowerInvariant()
$checksumPath = Join-Path -Path $outputFullPath -ChildPath 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($checksumPath, ('{0}  {1}{2}' -f $zipHash, (Split-Path -Path $zipPath -Leaf), "`n"), $utf8WithoutBom)

$notesPath = Join-Path -Path $outputFullPath -ChildPath 'release-notes.md'
[System.IO.File]::WriteAllText($notesPath, ($releaseNotes + "`n"), $utf8WithoutBom)

Write-Host ('Created {0}' -f $zipPath)
Write-Host ('SHA-256: {0}' -f $zipHash)
#endregion 6. Zip, checksum and notes

[pscustomobject]@{
    Version      = $fullVersion
    IsPrerelease = $isPrerelease
    ModulePath   = $moduleStagePath
    ZipPath      = $zipPath
    ChecksumPath = $checksumPath
    NotesPath    = $notesPath
}