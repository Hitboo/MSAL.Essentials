<#
    .SYNOPSIS
        Runs the Pester test suite under tests\, making sure Pester 6.2.0+
        is loaded (not the Pester 3.4.0 built into Windows PowerShell), and
        optionally runs it under both Windows PowerShell 5.1 and PowerShell 7.

    .PARAMETER TestsPath
        Folder or file to run. Defaults to the tests\ folder this script
        lives in, so every *.Tests.ps1 under it is discovered.

    .PARAMETER Verbosity
        Pester console output verbosity: None, Minimal, Normal, Detailed or
        Diagnostic. Defaults to Detailed. Also passed on to the child
        processes when -AllEditions is used.

    .PARAMETER AllEditions
        Re-launches this script once under powershell (5.1) and once under
        pwsh (7), each as a clean child process. Exits non-zero if either
        edition fails. If only one of the two is installed, that one runs
        and the other is skipped with a warning.

    .EXAMPLE
        .\tests\Start-Test.ps1
        Runs the full suite in the current session's edition.

    .EXAMPLE
        .\tests\Start-Test.ps1 -TestsPath .\tests\1-build
        Runs only the tests under tests\1-build.

    .EXAMPLE
        .\tests\Start-Test.ps1 -Verbosity Normal
        Runs the full suite with less console output.

    .EXAMPLE
        .\tests\Start-Test.ps1 -AllEditions -Verbosity Minimal
        Runs the full suite in both Windows PowerShell 5.1 and PowerShell 7,
        with minimal output.
#>
[CmdletBinding()]
param(
    # Folder or file to run. Defaults to everything under tests/
    [string]$TestsPath = $PSScriptRoot,

    # Pester console output verbosity
    [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Detailed',

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

        # Windows PowerShell started from PowerShell 7 would inherit PowerShell 7's PSModulePath and
        # load the wrong PowerShellGet. Without the variable it uses its own default module paths.
        $originalModulePath = $env:PSModulePath
        if ($powerShellExecutable -eq 'powershell' -and $PSVersionTable.PSEdition -eq 'Core') {
            $env:PSModulePath = $null
        }

        Write-Host ('=== Running under {0} ===' -f $powerShellExecutable) -ForegroundColor 'Cyan'

        try {
            # Start-Process takes the executable path as a parameter value, so no
            # call operator (&) is needed, and -ArgumentList keeps each argument
            # separate instead of building one string that has to be quoted correctly.
            $childProcess = Start-Process -FilePath $resolvedCommand.Source -ArgumentList @(
                '-NoProfile'
                '-ExecutionPolicy', 'Bypass'
                '-File', $PSCommandPath
                '-TestsPath', $TestsPath
                '-Verbosity', $Verbosity
            ) -Wait -PassThru -NoNewWindow
        }
        finally {
            $env:PSModulePath = $originalModulePath
        }

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
        Install-PackageProvider -Force -Name 'NuGet' -MinimumVersion '2.8.5.201' -Scope 'CurrentUser' | Out-Null
    }
    Install-Module -Force -SkipPublisherCheck -Name 'Pester' -MinimumVersion $minimumPesterVersion -Scope 'CurrentUser'
}

Remove-Module -Name 'Pester' -ErrorAction 'SilentlyContinue'
Import-Module -Force -Name 'Pester' -MinimumVersion $minimumPesterVersion

Write-Host ('Running on {0} {1} with Pester {2}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, (Get-Module -Name 'Pester').Version)

$pesterConfiguration = New-PesterConfiguration
$pesterConfiguration.Run.Path         = $TestsPath
$pesterConfiguration.Run.Exit         = $true
$pesterConfiguration.Output.Verbosity = $Verbosity
Invoke-Pester -Configuration $pesterConfiguration