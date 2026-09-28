BeforeAll {
    $script:minimumPesterVersion = [version]'6.2.0'
    $script:loadedPesterModules  = @(Get-Module -Name 'Pester')

    $script:activePesterVersion = $script:loadedPesterModules |
        Sort-Object -Property 'Version' -Descending |
        Select-Object -First 1 -ExpandProperty 'Version'
}

Describe 'Pester version' -Tag 'Build' {

    It 'is loaded in this session' {
        $script:loadedPesterModules | Should -Not -BeNullOrEmpty
    }

    It 'is the only Pester version loaded' {
        $loadedVersionList = ($script:loadedPesterModules.Version | 
            ForEach-Object -Process { $_.ToString() }) -join ', '
        $script:loadedPesterModules |
            Should -HaveCount 1 -Because ('several versions are loaded: {0}' -f $loadedVersionList)
    }

    It ('is at least the minimum required version ''{0}''' -f $script:minimumPesterVersion) {
        $script:activePesterVersion | 
            Should -BeGreaterOrEqual $script:minimumPesterVersion -Because (
                'the tests require Pester {0} or newer but {1} is active' -f $script:minimumPesterVersion, $script:activePesterVersion
            )
    }

    It 'is the latest version on the PowerShell Gallery' -Tag 'Network' {
        if ($script:activePesterVersion -lt $script:minimumPesterVersion) {
            Set-ItResult -Skipped -Because (
                'Pester {0} is below the required minimum {1}, so the gallery check is not relevant' -f $script:activePesterVersion, $script:minimumPesterVersion
            )
            return
        }

        $latestModule  = Find-Module -Name 'Pester' -Repository 'PSGallery' -ErrorAction Stop
        $latestVersion = [version]($latestModule.Version -replace '-.*$', '')

        if ($script:activePesterVersion -lt $latestVersion) {
            Set-ItResult -Skipped -Because (
                'Pester {0} is available but {1} is active' -f $latestVersion, $script:activePesterVersion
            )
            return
        }

        $script:activePesterVersion |
            Should -BeGreaterOrEqual $latestVersion
    }
}