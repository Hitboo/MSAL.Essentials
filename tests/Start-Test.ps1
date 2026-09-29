<#
    .SYNOPSIS
        Runs the Pester test suite under tests\, making sure Pester 6.2.0+
        is loaded (not the Pester 3.4.0 built into Windows PowerShell), and
        optionally runs it under both Windows PowerShell 5.1 and PowerShell 7.

    .PARAMETER TestsPath
        Folder or file to run. Defaults to the tests\ folder this script
        lives in, so every *.Tests.ps1 under it is discovered.

    .PARAMETER AllEditions
        Re-launches this script once under powershell (5.1) and once under
        pwsh (7), each as a clean child process. Exits non-zero if either
        edition fails. If only one of the two is installed, that one runs
        and the other is skipped with a warning.

    .EXAMPLE
        .\tests\Start-Test.ps1
        Runs the full suite in the current session's edition.

    .EXAMPLE
        .\tests\Start-Test.ps1 -TestsPath .\tests\Build
        Runs only the tests under tests\Build.

    .EXAMPLE
        .\tests\Start-Test.ps1 -AllEditions
        Runs the full suite in both Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    # Folder or file to run. Defaults to everything under tests/
    [string]$TestsPath = $PSScriptRoot,

    # Re-run this script in Windows PowerShell 5.1 and in PowerShell 7
    [switch]$AllEditions
)

if ($AllEditions) {
    $anyEditionFailed = $false

    foreach ($powerShellExecutable in 'powershell', 'pwsh') {
        $resolvedCommand = Get-Command -Name $powerShellExecutable -ErrorAction 'SilentlyContinue'
        if (-not $resolvedCommand) {
            Write-Warning -Message ('{0} not found, skipping.' -f $powerShellExecutable)
            continue
        }

        Write-Host ('=== Running under {0} ===' -f $powerShellExecutable) -ForegroundColor 'Cyan'

        # Start-Process takes the executable path as a parameter value, so no
        # call operator (&) is needed, and -ArgumentList keeps each argument
        # separate instead of building one string that has to be quoted correctly.
        $childProcess = Start-Process -FilePath $resolvedCommand.Source -ArgumentList @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', $PSCommandPath
            '-TestsPath', $TestsPath
        ) -Wait -PassThru -NoNewWindow

        if ($childProcess.ExitCode -ne 0) {
            $anyEditionFailed = $true
        }
    }

    if ($anyEditionFailed) {
        exit 1
    }

    return
}

$minimumPesterVersion = [version]'6.2.0'

if (-not (Get-Module -Name 'Pester' -ListAvailable | Where-Object -Property 'Version' -GE $minimumPesterVersion)) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name 'NuGet' -MinimumVersion '2.8.5.201' -Force -Scope 'CurrentUser' | Out-Null
    }
    Install-Module -Name 'Pester' -MinimumVersion $minimumPesterVersion -Scope 'CurrentUser' -Force -SkipPublisherCheck
}

Remove-Module -Name 'Pester' -ErrorAction 'SilentlyContinue'
Import-Module -Name 'Pester' -MinimumVersion $minimumPesterVersion -Force

Write-Host ('Running on {0} {1} with Pester {2}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, (Get-Module -Name 'Pester').Version)

$pesterConfiguration = New-PesterConfiguration
$pesterConfiguration.Run.Path                    = $TestsPath
$pesterConfiguration.Run.Exit                    = $true
$pesterConfiguration.Output.Verbosity            = 'Detailed'
Invoke-Pester -Configuration $pesterConfiguration