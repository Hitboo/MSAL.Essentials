<#
    .SYNOPSIS
        Starts an MSAL device code request, shows the device code to the
        user, and blocks until the sign-in completes.

    .DESCRIPTION
        MSAL hands the device code to a callback (Func<DeviceCodeResult,
        Task>) and then polls Entra ID until the user has signed in on
        another device. MSAL calls that callback on a thread pool thread. A
        PowerShell script block can't run there, because that thread has no
        PowerShell runspace, so the callback is a small compiled C# class
        (MsalEssentials.DeviceCodeReceiver) that only stores the result.

        This function waits in short steps on the calling thread, writes the
        message of the device code to the host as soon as it arrives, and
        returns the AuthenticationResult once the task completes. Waiting in
        short steps also lets Ctrl+C stop the wait.

        The code itself is also copied to the clipboard (Set-Clipboard), so
        it can be pasted on the sign-in page. This is best effort and silent:
        "The code is copied to the clipboard." is only shown when Get-Clipboard
        returns the code afterwards. Otherwise (Set-Clipboard fails, or a host
        without a usable clipboard accepts the call but keeps nothing) only
        the message is shown. In a remote session (SSH, PowerShell remoting) the
        clipboard is the one of the remote computer, or of the terminal if
        it supports that, so the code may not reach your own computer.

        The SynchronizationContext is cleared while the task is started and
        waited on, for the same reason as in Wait-MsalEssentialsTask: MSAL
        would otherwise post its continuations to a blocked UI thread.

        The C# class is compiled the first time this function runs, not at
        module import, so the other sign-in methods don't pay for it.

    .PARAMETER ScriptBlock
        A script block that starts the MSAL call and returns its task. It
        receives the device code callback as its only argument, for example
        { param ($deviceCodeCallback) $app.AcquireTokenWithDeviceCode($scopes, $deviceCodeCallback).ExecuteAsync() }.
        The task must be created inside the script block, see
        Wait-MsalEssentialsTask.

    .PARAMETER PollMilliseconds
        How long each wait step lasts. Defaults to 250 milliseconds.

    .EXAMPLE
        $result = Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
            param ($deviceCodeCallback)
            $publicClientApplication.AcquireTokenWithDeviceCode($scopes, $deviceCodeCallback).ExecuteAsync()
        }
#>

function Wait-MsalEssentialsDeviceCodeTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock]
        $ScriptBlock,

        [Parameter()]
        [ValidateRange(10, 5000)]
        [int]
        $PollMilliseconds = 250
    )

    if (-not ('MsalEssentials.DeviceCodeReceiver' -as [type])) {
        # Windows PowerShell 5.1 compiles with C# 5 - keep this source C# 5 compatible.
        # It does not reference MSAL on purpose: Receive takes an object, and
        # CreateDelegate below binds it to Func<DeviceCodeResult, Task>
        # (a delegate may take a more specific parameter type than its method).
        Add-Type -Language 'CSharp' -TypeDefinition @'
using System.Threading.Tasks;

namespace MsalEssentials
{
    public sealed class DeviceCodeReceiver
    {
        private volatile object _deviceCodeResult;

        public object DeviceCodeResult { get { return _deviceCodeResult; } }

        public Task Receive(object deviceCodeResult)
        {
            _deviceCodeResult = deviceCodeResult;
            return Task.FromResult(true);
        }
    }
}
'@
    }

    $receiver        = [MsalEssentials.DeviceCodeReceiver]::new()
    $previousContext = [System.Threading.SynchronizationContext]::Current

    try {
        $deviceCodeCallback = [System.Delegate]::CreateDelegate(
            [System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]],
            $receiver,
            [MsalEssentials.DeviceCodeReceiver].GetMethod('Receive')
        )

        [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)

        $task = & $ScriptBlock $deviceCodeCallback

        $deviceCodeShown = $false
        do {
            # WaitAny doesn't throw when the task failed, unlike Wait(), so the
            # error is raised once by GetResult() below, unwrapped.
            $isCompleted = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($task), $PollMilliseconds) -eq 0

            # MSAL calls the callback before it starts polling, so on success
            # the device code is always there before the task completes.
            if (-not $deviceCodeShown -and $receiver.DeviceCodeResult) {
                $deviceCodeResult = $receiver.DeviceCodeResult
                $deviceCodeShown  = $true

                Write-Verbose -Message ('Device code received, it expires {0}.' -f $deviceCodeResult.ExpiresOn)

                # Write-Host, not Write-Information or Write-Warning: the user
                # can't sign in without this message, so it must not depend on
                # $InformationPreference or -WarningAction. It can still be
                # redirected (6>) or captured, because Write-Host writes to the
                # information stream.
                Write-Host -Object $deviceCodeResult.Message

                # Runs on the calling thread, so Set-Clipboard works in an STA
                # host (Windows PowerShell 5.1) as well.
                try {
                    Set-Clipboard -Value $deviceCodeResult.UserCode -ErrorAction 'Stop'

                    # Some hosts accept Set-Clipboard but keep nothing, so
                    # only claim it when the clipboard really holds the code.
                    $clipboardText = (@(Get-Clipboard -ErrorAction 'Stop') -join '').Trim()
                    if ($clipboardText -eq $deviceCodeResult.UserCode) {
                        Write-Host -Object 'The code is copied to the clipboard.'
                    }
                    else {
                        Write-Verbose -Message 'The code was not found on the clipboard after copying it.'
                    }
                }
                catch {
                    Write-Verbose -Message ('The code could not be copied to the clipboard: {0}' -f $_)
                }
            }
        } until ($isCompleted)

        return $task.GetAwaiter().GetResult()
    }
    finally {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
}
