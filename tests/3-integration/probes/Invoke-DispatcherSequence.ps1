<#
    .SYNOPSIS
        Runs Connect > Disconnect > Connect on a WPF Dispatcher, the way a
        click handler in a WPF app would, against a real tenant.

        Run in a child process by 03-UiThreadDeadlock.Tests.ps1, because a
        deadlocked thread can't time itself out: the test kills this process
        when it does not finish in time.

        Writes one line per step to standard output as soon as the step
        starts, so the test can tell where it hung:
            STEP <number> <description>
            CONTEXT <SynchronizationContext type>
            PASSED
            FAILED <message>

    .PARAMETER ModuleManifestPath
        Path to the MSAL.Essentials.psd1 under test.

    .PARAMETER TenantId
        The tenant to sign in to.

    .PARAMETER ClientId
        The client ID to sign in with.

    .PARAMETER SignInTimeoutSeconds
        Passed to Connect-MsalEssentials -TimeoutSeconds.

    .PARAMETER LoginHintUpn
        Optional. Passed to Connect-MsalEssentials -LoginHintUpn.
#>
param (
    [Parameter(Mandatory)]
    [string]$ModuleManifestPath,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [int]$SignInTimeoutSeconds,

    [string]$LoginHintUpn
)

# Write-Host inside the Dispatcher callback is not reliably flushed when the
# process is killed, so write straight to standard output and flush.
function Write-SequenceLine {
    param (
        [string]$Line
    )

    [System.Console]::Out.WriteLine($Line)
    [System.Console]::Out.Flush()
}

Add-Type -AssemblyName 'WindowsBase'
Import-Module -Force -Name $ModuleManifestPath -ErrorAction 'Stop'

$connectParameters = @{
    TenantId       = $TenantId
    ClientId       = $ClientId
    Scopes         = 'User.Read'
    TimeoutSeconds = $SignInTimeoutSeconds
    ErrorAction    = 'Stop'
}
if (-not [string]::IsNullOrWhiteSpace($LoginHintUpn)) {
    $connectParameters['LoginHintUpn'] = $LoginHintUpn
}

$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

$null = $dispatcher.BeginInvoke([System.Action]{
    try {
        Write-SequenceLine -Line ('CONTEXT {0}' -f [System.Threading.SynchronizationContext]::Current.GetType().FullName)

        Write-SequenceLine -Line 'STEP 1 Connect (first sign-in)'
        Connect-MsalEssentials @connectParameters

        Write-SequenceLine -Line 'STEP 2 Get-MsalEssentialsToken with silent renewal'
        $null = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'

        Write-SequenceLine -Line 'STEP 3 Disconnect'
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'Stop'

        # Before the fix, this is where the UI thread deadlocks.
        Write-SequenceLine -Line 'STEP 4 Connect again (second sign-in)'
        Connect-MsalEssentials @connectParameters

        Write-SequenceLine -Line 'STEP 5 Disconnect'
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'Stop'

        Write-SequenceLine -Line 'PASSED'
    }
    catch {
        Write-SequenceLine -Line ('FAILED {0}' -f $_)
    }
    finally {
        $dispatcher.InvokeShutdown()
    }
})

[System.Windows.Threading.Dispatcher]::Run()
