<#
    Integration test: Connect > Disconnect > Connect on a WPF Dispatcher,
    against a real Microsoft Entra ID tenant. Before the fix, the second
    Connect-MsalEssentials deadlocked the UI thread (see
    Wait-MsalEssentialsTask for the cause).
    2-unit\03-UiThreadDeadlock.Tests.ps1 covers the same without a tenant.

    The sequence runs twice: once with the browser sign-in, once with
    -UseDeviceCode (which waits through Wait-MsalEssentialsDeviceCodeTask).

    This test is INTERACTIVE:
        - Browser: it opens your default browser twice. Sign in in the first
          window; the second one usually completes by itself from the
          browser session.
        - Device code: it shows two device codes, one after the other. Enter
          each one on the page from the message and sign in.
    It is skipped unless a tenant is configured.

    Setup (once per PowerShell session), as for 01-SignIn.Tests.ps1:

        $env:MSAL_TEST_TENANT_ID = '<tenant id or verified domain>'

    Optional:

        $env:MSAL_TEST_CLIENT_ID      = '<client id>' # default: Microsoft Graph Command Line Tools
        $env:MSAL_TEST_LOGIN_HINT_UPN = '<user principal name>' # browser only

    The client must allow public client flows for the device code run.
    Microsoft Graph Command Line Tools does.

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration\03-UiThreadDeadlock.Tests.ps1

    The sequence runs in a child process (probes\Invoke-DispatcherSequence.ps1)
    with the same PowerShell edition, in STA mode like a WPF app. A
    deadlocked thread can't time itself out, so the child is killed after
    the watchdog time, and the tests report the step where it hung. The
    child's output (including the device codes) is shown while it runs.
#>

BeforeDiscovery {
    $script:SkipSignIn = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_TENANT_ID)

    if ($script:SkipSignIn) {
        Write-Host 'Dispatcher deadlock test skipped: set $env:MSAL_TEST_TENANT_ID to run it (see the top of 03-UiThreadDeadlock.Tests.ps1).' -ForegroundColor 'Yellow'
    }
}

Describe 'Connect > Disconnect > Connect on a WPF Dispatcher with <Name> (real tenant)' -Skip:$script:SkipSignIn -ForEach @(
    # Each sign-in may take SignInTimeoutSeconds: enough to unlock a password
    # manager and sign in. The watchdog covers the whole sequence.
    @{
        Name                 = 'the browser sign-in'
        UseDeviceCode        = $false
        SignInTimeoutSeconds = 30  # the second sign-in usually completes by itself
        WatchdogSeconds      = 40
        Banner               = @(
            'TWO BROWSER WINDOWS: sign in in the first one. The second one'
            'usually completes by itself; if it asks, sign in again.'
        )
    }
    @{
        Name                 = 'a device code'
        UseDeviceCode        = $true
        SignInTimeoutSeconds = 30  # paste the code and pick the signed-in account
        WatchdogSeconds      = 80
        Banner               = @(
            'TWO DEVICE CODES, one after the other: enter each one on the'
            'page from the message (child: INFO ...) and sign in within'
            '30 seconds.'
        )
    }
) {
    BeforeAll {
        $script:WatchdogSeconds = $WatchdogSeconds

        $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path

        $clientId = if ([string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID)) { '14d82eec-204b-4c2f-b7e8-296a70dab67e' } else { $env:MSAL_TEST_CLIENT_ID }

        # Start-Process joins the arguments with spaces, so quote the values
        # that may contain spaces.
        $childArguments = @(
            '-NoProfile'
            '-STA' # like a WPF app's UI thread
            '-ExecutionPolicy', 'Bypass'
            '-File', ('"{0}"' -f (Join-Path -Path $PSScriptRoot -ChildPath 'probes\Invoke-DispatcherSequence.ps1'))
            '-ModuleManifestPath', ('"{0}"' -f $script:ManifestPath)
            '-TenantId', ('"{0}"' -f $env:MSAL_TEST_TENANT_ID)
            '-ClientId', ('"{0}"' -f $clientId)
            '-SignInTimeoutSeconds', $SignInTimeoutSeconds
        )
        if ($UseDeviceCode) {
            $childArguments += '-UseDeviceCode'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:MSAL_TEST_LOGIN_HINT_UPN)) {
            $childArguments += '-LoginHintUpn', ('"{0}"' -f $env:MSAL_TEST_LOGIN_HINT_UPN)
        }

        $outputPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('MsalDispatcherSequence-{0}.log' -f [guid]::NewGuid())
        $errorPath  = '{0}.err' -f $outputPath

        $line = '=' * 72
        Write-Host ''
        Write-Host $line -ForegroundColor 'Green'
        Write-Host ('  Module: {0}' -f $script:ManifestPath) -ForegroundColor 'Green'
        foreach ($bannerLine in $Banner) {
            Write-Host ('  {0}' -f $bannerLine) -ForegroundColor 'Green'
        }
        Write-Host ('  Deadlock watchdog: {0} seconds.' -f $script:WatchdogSeconds) -ForegroundColor 'Green'
        Write-Host $line -ForegroundColor 'Green'
        Write-Host ''

        $processParameters = @{
            FilePath               = (Get-Process -Id $PID).Path # same PowerShell edition as this one
            ArgumentList           = $childArguments
            RedirectStandardOutput = $outputPath
            RedirectStandardError  = $errorPath
        }
        $childProcess = Start-Process -NoNewWindow -PassThru @processParameters

        # Show the child's lines while it runs: the device codes have to be
        # entered before the sequence can go on.
        $shownLineCount = 0
        $stopwatch      = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $hasExited = $childProcess.WaitForExit(500)

            $currentLines = @(Get-Content -Path $outputPath -ErrorAction 'SilentlyContinue')
            for ($index = $shownLineCount; $index -lt $currentLines.Count; $index++) {
                Write-Host ('  child: {0}' -f $currentLines[$index])
            }
            $shownLineCount = [System.Math]::Max($shownLineCount, $currentLines.Count)
        } until ($hasExited -or $stopwatch.Elapsed.TotalSeconds -ge $script:WatchdogSeconds)

        $script:Deadlocked = -not $hasExited
        if ($script:Deadlocked) {
            Stop-Process -Force -Id $childProcess.Id
            $childProcess.WaitForExit()
        }

        $script:SequenceLines = @(Get-Content -Path $outputPath -ErrorAction 'SilentlyContinue')
        $script:ErrorText     = (Get-Content -Raw -Path $errorPath -ErrorAction 'SilentlyContinue')
        Remove-Item -Path $outputPath, $errorPath -ErrorAction 'SilentlyContinue'

        for ($index = $shownLineCount; $index -lt $script:SequenceLines.Count; $index++) {
            Write-Host ('  child: {0}' -f $script:SequenceLines[$index])
        }

        # The steps that were started, and how far the sequence got.
        $script:StartedSteps = @(
            $script:SequenceLines |
                Where-Object -FilterScript { $_ -match '^STEP (?<number>\d+) ' } |
                ForEach-Object -Process { [int]($_ -replace '^STEP (\d+) .*$', '$1') }
        )
        $script:LastStep = if ($script:StartedSteps.Count -gt 0) { $script:StartedSteps[-1] } else { 0 }
        $script:Failure  = $script:SequenceLines |
            Where-Object -FilterScript { $_ -like 'FAILED *' } |
            Select-Object -First 1

        # A step counts as done when a later step was started, or the whole
        # sequence passed.
        function script:Test-StepCompleted {
            param (
                [int]$Step
            )

            return ($script:SequenceLines -contains 'PASSED') -or ($script:LastStep -gt $Step)
        }

        # Explains why a step did not complete, for the failure message.
        function script:Get-StepFailureReason {
            param (
                [int]$Step
            )

            if ($script:LastStep -lt $Step) {
                return ('step {0} was never reached (the sequence stopped at step {1})' -f $Step, $script:LastStep)
            }
            if ($script:Deadlocked) {
                return ('DEADLOCK: step {0} did not finish within the {1} second watchdog' -f $Step, $script:WatchdogSeconds)
            }
            if ($script:Failure) {
                return $script:Failure
            }
            return ('the child process ended without a result. Errors: {0}' -f $script:ErrorText)
        }
    }

    It 'runs on a WPF Dispatcher (the condition for the deadlock)' {
        $script:SequenceLines |
            Should -Contain 'CONTEXT System.Windows.Threading.DispatcherSynchronizationContext'
    }

    # Only the device code run shows a message, so only it gets this test.
    # The -ForEach data is available here during discovery.
    if ($UseDeviceCode) {
        It 'shows the device code message from the UI thread' {
            # One message per sign-in (steps 1 and 4).
            @($script:SequenceLines | Where-Object -FilterScript { $_ -like 'INFO *' -and $_ -match 'https://' }).Count |
                Should -Be 2 -Because 'each of the two sign-ins shows its device code'
        }
    }

    It 'step <Step>: <Name>' -ForEach @(
        @{ Step = 1; Name = 'first Connect' }
        @{ Step = 2; Name = 'silent renewal' }
        @{ Step = 3; Name = 'Disconnect' }
        @{ Step = 4; Name = 'second Connect (deadlocked before the fix)' }
        @{ Step = 5; Name = 'second Disconnect' }
    ) {
        Test-StepCompleted -Step $Step |
            Should -BeTrue -Because (Get-StepFailureReason -Step $Step)
    }

    It 'finishes without a deadlock' {
        $script:Deadlocked |
            Should -BeFalse -Because ('the sequence hung at step {0}' -f $script:LastStep)
    }
}
