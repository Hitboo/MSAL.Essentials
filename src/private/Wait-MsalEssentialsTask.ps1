<#
    .SYNOPSIS
        Starts an MSAL async call and blocks until it completes, without
        deadlocking on a UI thread.

    .DESCRIPTION
        PowerShell can't await, so MSAL's async methods are waited on with
        GetAwaiter().GetResult(). That blocks the calling thread.

        When the calling thread has a SynchronizationContext (the Dispatcher
        of a WPF window, the message loop of a WinForms form), MSAL captures it
        and posts continuations back to it. That thread is blocked in
        GetResult(), so the continuation never runs and everything freezes.
        The console host has no SynchronizationContext, which is why this only
        shows up when the module is used from a UI.

        In MSAL this happens in the system browser sign-in, while it waits for
        the loopback listener. The first sign-in in a process escapes it,
        because its instance discovery request moves the rest of the call to
        the thread pool. MSAL caches that metadata for the process, so the
        second Connect-MsalEssentials (after Disconnect-MsalEssentials) is the
        one that freezes.

        This clears the SynchronizationContext while the task is started and
        waited on, so MSAL's continuations run on the thread pool instead, and
        restores it afterwards.

        The task must be created inside -ScriptBlock: MSAL captures the
        context when the call starts, so a task created before this function
        runs would already be bound to the UI thread.

    .PARAMETER ScriptBlock
        A script block that starts the MSAL call and returns its task, for
        example { $request.ExecuteAsync() }.

    .EXAMPLE
        $accounts = Wait-MsalEssentialsTask -ScriptBlock { $clientApplication.GetAccountsAsync() }
#>

function Wait-MsalEssentialsTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock]
        $ScriptBlock
    )

    $previousContext = [System.Threading.SynchronizationContext]::Current

    try {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)
        return (& $ScriptBlock).GetAwaiter().GetResult()
    }
    finally {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
}
