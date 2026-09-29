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
    # Guards against the -ForEach below silently generating zero tests
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