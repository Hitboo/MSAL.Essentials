<#
    Verifies that MSAL.Essentials can be imported without errors/warnings
    and that the bundled DLLs (src\lib\net472 / src\lib\netstandard2.0) are present and load.

    Only the PowerShell edition running this file is tested. To cover both
    editions, run the suite once per shell (Start-Test.ps1 -AllEditions).
#>

BeforeDiscovery {
    $script:ExpectedCommands = @(
        'Connect-MsalEssentials',
        'Get-MsalEssentialsToken',
        'Disconnect-MsalEssentials'
    )
}

BeforeAll {
    $script:SrcPath      = Join-Path $PSScriptRoot '..\..\src' |
    Resolve-Path |
    Select-Object -ExpandProperty Path
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = Join-Path $script:SrcPath 'MSAL.Essentials.psd1'
    $script:PsmPath      = Join-Path $script:SrcPath 'MSAL.Essentials.psm1'

    # Windows PowerShell (Desktop) uses net472, PowerShell 7+ (Core) uses netstandard2.0
    $script:LibFolderName = if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net472' }
    $script:LibPath       = Join-Path $script:SrcPath ('lib\{0}' -f $script:LibFolderName)

    # Make sure we start clean
    Get-Module $script:ModuleName |
    Remove-Module -Force -ErrorAction SilentlyContinue
}

AfterAll {
    Get-Module $script:ModuleName |
    Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'MSAL.Essentials module files' {
    It 'psm1 exists' {
        $script:PsmPath | Should -Exist
    }

    It 'psd1 exists' {
        $script:ManifestPath | Should -Exist
    }

    It 'psd1 is a valid module manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'psm1 has no PowerShell syntax errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:PsmPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'lib folder for this PowerShell edition exists' {
        $script:LibPath | Should -Exist
    }

    It 'lib folder contains DLL files' {
        Get-ChildItem -Path $script:LibPath -Filter '*.dll' -File | Should -Not -BeNullOrEmpty
    }

    It 'Microsoft.Identity.Client.dll is present' {
        Join-Path $script:LibPath 'Microsoft.Identity.Client.dll' | Should -Exist
    }
}

Describe 'MSAL.Essentials import (in-process)' {
    BeforeAll {
        $script:ImportErrors     = $null
        $script:ImportWarnings   = $null
        $script:ErrorCountBefore = $Error.Count

        Get-Module $script:ModuleName | Remove-Module -Force -ErrorAction SilentlyContinue

        try {
            Import-Module -Name $script:ManifestPath -Force -ErrorAction Stop `
                -ErrorVariable  script:ImportErrors `
                -WarningVariable script:ImportWarnings
            $script:ImportException = $null
        }
        catch {
            $script:ImportException = $_
        }
    }

    It 'imports without throwing' {
        $script:ImportException | Should -BeNullOrEmpty -Because $script:ImportException
    }

    It 'produces no errors during import' {
        $script:ImportErrors | Should -BeNullOrEmpty
    }

    It 'produces no warnings during import' {
        $script:ImportWarnings | Should -BeNullOrEmpty
    }

    It 'module is loaded' {
        Get-Module -Name $script:ModuleName | Should -Not -BeNullOrEmpty
    }

    It 'loads Microsoft.Identity.Client assembly' {
        [AppDomain]::CurrentDomain.GetAssemblies().GetName().Name |
            Should -Contain 'Microsoft.Identity.Client'
    }

    It 'exports command <_>' -ForEach $script:ExpectedCommands {
        Get-Command -Module $script:ModuleName -Name $_ -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'can be removed cleanly' {
        { Remove-Module -Name $script:ModuleName -Force -ErrorAction Stop } | Should -Not -Throw
    }
}

# DLLs can't be unloaded from a process, so a fresh process gives a clean, reliable import check.
# The child process uses the same executable as the current session, so each edition
# is only tested when the suite is run under that edition.
Describe 'MSAL.Essentials import (fresh process)' {
    It ('imports without errors in a fresh {0} process' -f $PSVersionTable.PSEdition) {
        $manifest       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\src\MSAL.Essentials.psd1')).Path
        $hostExecutable = (Get-Process -Id $PID).Path

        $command = @"
`$ErrorActionPreference = 'Stop'
`$WarningPreference     = 'Continue'
try {
    Import-Module '$manifest' -Force -ErrorAction Stop
    if (-not (Get-Module 'MSAL.Essentials')) { throw 'Module not loaded after import.' }
    if ('Microsoft.Identity.Client' -notin [AppDomain]::CurrentDomain.GetAssemblies().GetName().Name) {
        throw 'Microsoft.Identity.Client assembly not loaded.'
    }
    'IMPORT_OK'
}
catch {
    Write-Error `$_
    exit 1
}
"@

        $output = & $hostExecutable -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1
        $exit   = $LASTEXITCODE

        $exit   | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'IMPORT_OK'
        # No warnings or errors in the output stream
        $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or
                                 $_ -is [System.Management.Automation.WarningRecord] } |
            Should -BeNullOrEmpty
    }
}