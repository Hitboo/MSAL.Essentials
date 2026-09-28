BeforeDiscovery {
    $frameworkFolderNames = @('net472', 'netstandard2.0')
    $manifestPath         = Join-Path -Path $PSScriptRoot -ChildPath '../../src/lib/dependencies.json'

    $manifestEntries = if (Test-Path -Path $manifestPath) {
        $manifestContent = Get-Content -Path $manifestPath -Raw
        (ConvertFrom-Json -InputObject $manifestContent).PSObject.Properties
    } else {
        @()
    }

    $testCases = foreach ($manifestEntry in $manifestEntries) {
        foreach ($frameworkFolderName in $frameworkFolderNames) {
            @{
                PackageId       = $manifestEntry.Name
                ExpectedVersion = [string]$manifestEntry.Value
                FrameworkFolder = $frameworkFolderName
            }
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

Describe 'dependencies.json matches the DLLs in lib' -Tag 'Build' {
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