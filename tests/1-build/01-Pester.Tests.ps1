BeforeDiscovery {
    $minimumPesterVersion = [version]'6.2.0'
}

BeforeAll {
    $script:minimumPesterVersion = $minimumPesterVersion
    $script:loadedPesterModules  = @(Get-Module -Name 'Pester')

    $script:activePesterVersion = $script:loadedPesterModules |
        Sort-Object -Property 'Version' -Descending |
        Select-Object -First 1 -ExpandProperty 'Version'
}

Describe 'Pester version' {

    It 'is loaded in this session' {
        $script:loadedPesterModules | Should -Not -BeNullOrEmpty
    }

    It 'is the only Pester version loaded' {
        $loadedVersionList = ($script:loadedPesterModules.Version |
            ForEach-Object -Process { $_.ToString() }) -join ', '
        $script:loadedPesterModules |
            Should -HaveCount 1 -Because ('several versions are loaded: {0}' -f $loadedVersionList)
    }

    It ('is at least the minimum required version ''{0}''' -f $minimumPesterVersion) {
        $script:activePesterVersion |
            Should -BeGreaterOrEqual $script:minimumPesterVersion -Because (
                'the tests require Pester {0} or newer but {1} is active' -f $script:minimumPesterVersion, $script:activePesterVersion
            )
    }
}