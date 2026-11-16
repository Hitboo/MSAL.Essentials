<#
    Tests for the private device code helpers:
        Get-MsalEssentialsDelegatedTokenDeviceCode (errors -> MsalEssentials.* ids)
        Wait-MsalEssentialsDeviceCodeTask          (device code message, waiting)

    No network is used. For the token helper, Wait-MsalEssentialsDeviceCodeTask
    is mocked to return a result or throw the exception MSAL would throw; the
    MSAL client itself is real but never sends a request. The wait function
    gets a real task from a TaskCompletionSource.

    A real device code request against Entra ID is in
    tests/3-integration/05-DeviceCodeSignIn.Tests.ps1.
#>

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'
}

AfterAll {
    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Get-MsalEssentialsDelegatedTokenDeviceCode (simulated MSAL errors)' {
    BeforeAll {
        # Runs the helper with Wait-MsalEssentialsDeviceCodeTask throwing
        # $Failure, and returns the error record (or $null).
        function script:Get-DeviceCodeError {
            param (
                [Parameter(Mandatory)]
                $Failure,

                [int]$TimeoutSeconds = 60
            )

            InModuleScope -ModuleName $script:ModuleName -Parameters @{ Failure = $Failure; TimeoutSeconds = $TimeoutSeconds } -ScriptBlock {
                param ($Failure, $TimeoutSeconds)

                Mock -CommandName 'Wait-MsalEssentialsDeviceCodeTask' -MockWith { throw $Failure }.GetNewClosure()

                $caughtError = $null
                try {
                    $null = Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -TimeoutSeconds $TimeoutSeconds
                }
                catch {
                    $caughtError = $_
                }
                $caughtError
            }
        }
    }

    It 'returns the result of the wait and hands out the MSAL client' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Mock -CommandName 'Wait-MsalEssentialsDeviceCodeTask' -MockWith { [pscustomobject]@{ AccessToken = 'device-code-token' } }

            $clientApplication = $null
            $result = Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -ApplicationReference ([ref]$clientApplication)

            $result.AccessToken |
                Should -Be 'device-code-token'
            $clientApplication |
                Should -BeOfType 'Microsoft.Identity.Client.IPublicClientApplication'
            $clientApplication.Authority |
                Should -BeLike 'https://login.microsoftonline.com/hitboo.test/*'
        }
    }

    It 'waits 300 seconds by default' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Mock -CommandName 'Wait-MsalEssentialsDeviceCodeTask' -MockWith { [pscustomobject]@{ AccessToken = 'device-code-token' } }

            $verboseMessages = @(Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -Verbose 4>&1 |
                    Where-Object -FilterScript { $_ -is [System.Management.Automation.VerboseRecord] })

            $verboseMessages.Message |
                Should -Contain 'Requesting a device code, waiting up to 300 seconds for the sign-in to complete.'
        }
    }

    It 'accepts a timeout of 900 seconds, the usual lifetime of a device code' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Mock -CommandName 'Wait-MsalEssentialsDeviceCodeTask' -MockWith { [pscustomobject]@{ AccessToken = 'device-code-token' } }

            (Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -TimeoutSeconds 900).AccessToken |
                Should -Be 'device-code-token'
        }
    }

    It 'rejects a timeout of <Value> seconds' -ForEach @(
        @{ Value = 0 }
        @{ Value = 901 }
    ) {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ Value = $Value } -ScriptBlock {
            param ($Value)

            { Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -TimeoutSeconds $Value } |
                Should -Throw -ErrorId 'ParameterArgumentValidationError*'
        }
    }

    It 'maps <Name> to MsalEssentials.<Category>' -ForEach @(
        @{
            Name     = 'an expired device code (MSAL)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalClientException'; Arguments = @('code_expired', 'Verification code expired before contacting the server') }
            Category = 'Timeout'
            Hint     = '*enter the new code*'
        }
        @{
            Name     = 'an expired device code (Entra ID)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('expired_token', 'AADSTS70020: The provided value for the input parameter ''device_code'' is not valid. This device code has expired.') }
            Category = 'Timeout'
            Hint     = '*enter the new code*'
        }
        @{
            Name     = 'a declined sign-in'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('authorization_declined', 'AADSTS700171: The user declined the authorization request.') }
            Category = 'Cancelled'
            Hint     = '*phish*'
        }
        @{
            Name     = 'public client flows turned off (AADSTS7000218)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS7000218: The request body must contain the following parameter: ''client_assertion'' or ''client_secret''.') }
            Category = 'AppConfiguration'
            Hint     = '*Allow public client flows*'
        }
        @{
            Name     = 'an unknown app (AADSTS700016)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('unauthorized_client', 'AADSTS700016: Application with identifier ''x'' was not found in the directory.') }
            Category = 'AppConfiguration'
            Hint     = '*-ClientId*'
        }
        @{
            Name     = 'a Conditional Access block (AADSTS53003)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('access_blocked', 'AADSTS53003: Access has been blocked by Conditional Access policies.') }
            Category = 'ConditionalAccess'
            Hint     = '*Authentication flows*'
        }
        @{
            Name     = 'missing consent (AADSTS65001)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_grant', 'AADSTS65001: The user or administrator has not consented to use the application.') }
            Category = 'Unauthorized'
            Hint     = '*consent*'
        }
        @{
            Name     = 'an unknown error'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('something_new', 'AADSTS99999: Something new went wrong.') }
            Category = 'Authentication'
            Hint     = $null
        }
        @{
            Name     = 'a cancellation that is not the timeout'
            Failure  = @{ Type = 'System.OperationCanceledException'; Arguments = @('The operation was canceled.') }
            Category = 'Cancelled'
            Hint     = $null
        }
    ) {
        # Built here, not in -ForEach: discovery runs before the module (and MSAL) is loaded.
        $Failure = New-Object -TypeName $Failure.Type -ArgumentList $Failure.Arguments
        $caught  = Get-DeviceCodeError -Failure $Failure

        $caught.FullyQualifiedErrorId |
            Should -BeLike ('MsalEssentials.{0}*' -f $Category)
        $caught.TargetObject.Category |
            Should -Be $Category
        $caught.ErrorDetails.Message |
            Should -BeLike ('Sign-in failed `[{0}`]*' -f $Category)

        if ($Hint) {
            $caught.ErrorDetails.Message |
                Should -BeLike ('*Hint: {0}' -f $Hint)
        }
        else {
            $caught.ErrorDetails.Message |
                Should -Not -BeLike '*Hint:*'
        }

        # Except for the timeout, the original exception is kept.
        $caught.Exception |
            Should -Be $Failure
    }

    It 'keeps the AADSTS code, error code and client in TargetObject' {
        $failure = [Microsoft.Identity.Client.MsalServiceException]::new('access_blocked', 'AADSTS53003: Access has been blocked by Conditional Access policies.')

        $caught = Get-DeviceCodeError -Failure $failure

        $caught.TargetObject.AadstsCode |
            Should -Be '53003'
        $caught.TargetObject.ErrorCode |
            Should -Be 'access_blocked'
        $caught.TargetObject.TenantId |
            Should -Be 'hitboo.test'
        $caught.TargetObject.ClientId |
            Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'finds the MSAL exception when it is wrapped' {
        $inner   = [Microsoft.Identity.Client.MsalServiceException]::new('authorization_declined', 'AADSTS70000: The user declined the authorization request.')
        $wrapped = [System.AggregateException]::new($inner)

        $caught = Get-DeviceCodeError -Failure $wrapped

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Cancelled*'
        $caught.Exception |
            Should -Be $inner
    }

    It 'reports MsalEssentials.Timeout with a TimeoutException when -TimeoutSeconds elapses' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            # Simulates MSAL: it throws once the cancellation token fires.
            Mock -CommandName 'Wait-MsalEssentialsDeviceCodeTask' -MockWith {
                Start-Sleep -Milliseconds 1500
                throw [System.Threading.Tasks.TaskCanceledException]::new('A task was canceled.')
            }

            $caught = $null
            try {
                $null = Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -TimeoutSeconds 1
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.Timeout*'
            $caught.Exception |
                Should -BeOfType 'System.TimeoutException'
            $caught.ErrorDetails.Message |
                Should -BeLike '*not completed within 1 seconds*'
        }
    }
}

Describe 'Wait-MsalEssentialsDeviceCodeTask' {
    BeforeAll {
        # Stands in for MSAL's DeviceCodeResult, which has no public constructor.
        $script:FakeDeviceCode = [pscustomobject]@{
            Message   = 'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code TESTCODE1 to authenticate.'
            UserCode  = 'TESTCODE1'
            ExpiresOn = [System.DateTimeOffset]::UtcNow.AddMinutes(15)
        }
    }

    BeforeEach {
        # Never touch the real clipboard of the machine running the tests.
        # The fake clipboard keeps what was set, like a working one.
        $global:MsalDcTestClipboard = $null
        Mock -ModuleName $script:ModuleName -CommandName 'Set-Clipboard' -MockWith { $global:MsalDcTestClipboard = $Value }
        Mock -ModuleName $script:ModuleName -CommandName 'Get-Clipboard' -MockWith { $global:MsalDcTestClipboard }
    }

    AfterAll {
        Remove-Variable -Name 'MsalDcTestClipboard' -Scope 'Global' -ErrorAction 'SilentlyContinue'
    }

    It 'hands the script block a Func[DeviceCodeResult, Task] callback' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            $script:CallbackType = $null

            $null = Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
                param ($deviceCodeCallback)

                $script:CallbackType = $deviceCodeCallback.GetType()
                [System.Threading.Tasks.Task]::FromResult('done')
            } 6>$null

            $script:CallbackType |
                Should -Be ([System.Func[Microsoft.Identity.Client.DeviceCodeResult, System.Threading.Tasks.Task]])
        }
    }

    It 'shows the device code message once, copies the code and returns the result' {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ DeviceCode = $script:FakeDeviceCode } -ScriptBlock {
            param ($DeviceCode)

            $completion = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
            $completion.SetResult('device-code-token')

            # 6>&1 puts the Write-Host output into the pipeline, next to the result.
            $output = @(Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
                    param ($deviceCodeCallback)

                    # What MSAL does: hand over the device code, then poll.
                    $null = $deviceCodeCallback.Target.Receive($DeviceCode)
                    $completion.Task
                } 6>&1)

            $messages = @($output | Where-Object -FilterScript { $_ -is [System.Management.Automation.InformationRecord] })
            $results  = @($output | Where-Object -FilterScript { $_ -isnot [System.Management.Automation.InformationRecord] })

            $messages.Count |
                Should -Be 2
            $messages[0].MessageData.ToString() |
                Should -Be $DeviceCode.Message
            $messages[1].MessageData.ToString() |
                Should -Be 'The code is copied to the clipboard.'
            $results |
                Should -Be @('device-code-token')

            Should -Invoke -CommandName 'Set-Clipboard' -ModuleName 'MSAL.Essentials' -Times 1 -Exactly -ParameterFilter { $Value -eq 'TESTCODE1' }
        }
    }

    It 'still shows the message and returns the result when there is no clipboard (<Name>)' -ForEach @(
        @{ Name = 'Set-Clipboard fails';            SetFails = $true }
        @{ Name = 'the clipboard keeps nothing';    SetFails = $false }
    ) {
        if ($SetFails) {
            Mock -ModuleName $script:ModuleName -CommandName 'Set-Clipboard' -MockWith { throw 'simulated: no clipboard' }
        }
        else {
            Mock -ModuleName $script:ModuleName -CommandName 'Set-Clipboard' -MockWith { }
        }

        InModuleScope -ModuleName $script:ModuleName -Parameters @{ DeviceCode = $script:FakeDeviceCode } -ScriptBlock {
            param ($DeviceCode)

            $completion = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
            $completion.SetResult('device-code-token')

            $output = @(Wait-MsalEssentialsDeviceCodeTask -ErrorAction 'Stop' -ScriptBlock {
                    param ($deviceCodeCallback)

                    $null = $deviceCodeCallback.Target.Receive($DeviceCode)
                    $completion.Task
                } 6>&1)

            $messages = @($output | Where-Object -FilterScript { $_ -is [System.Management.Automation.InformationRecord] })
            $results  = @($output | Where-Object -FilterScript { $_ -isnot [System.Management.Automation.InformationRecord] })

            $messages.Count |
                Should -Be 1
            $messages[0].MessageData.ToString() |
                Should -Be $DeviceCode.Message
            $results |
                Should -Be @('device-code-token')
        }
    }

    It 'waits until the task completes' {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ DeviceCode = $script:FakeDeviceCode } -ScriptBlock {
            param ($DeviceCode)

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            $null = Wait-MsalEssentialsDeviceCodeTask -PollMilliseconds 20 -ScriptBlock {
                param ($deviceCodeCallback)

                $null = $deviceCodeCallback.Target.Receive($DeviceCode)
                [System.Threading.Tasks.Task]::Delay(400)
            } 6>$null

            $stopwatch.Elapsed.TotalMilliseconds |
                Should -BeGreaterOrEqual 350
        }
    }

    It 'shows nothing when MSAL fails before it has a device code, and throws the MSAL exception unwrapped' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            $failure    = [Microsoft.Identity.Client.MsalServiceException]::new('invalid_client', 'AADSTS7000218: simulated')
            $completion = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
            $completion.SetException($failure)

            $caught = $null
            $output = @(try {
                    Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
                        param ($deviceCodeCallback)
                        $completion.Task
                    } 6>&1
                }
                catch {
                    $caught = $_
                })

            $output.Count |
                Should -Be 0
            $caught |
                Should -Not -BeNullOrEmpty

            # GetResult() throws the MSAL exception itself, not an
            # AggregateException; PowerShell may wrap it once more.
            $innerException = $caught.Exception
            while ($innerException -and $innerException -isnot [Microsoft.Identity.Client.MsalServiceException]) {
                $innerException = $innerException.InnerException
            }
            $innerException |
                Should -Be $failure
            $caught.Exception |
                Should -Not -BeOfType 'System.AggregateException'
        }
    }

    It 'starts the task without a SynchronizationContext and restores it afterwards' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            $uiContext       = [System.Threading.SynchronizationContext]::new()
            $previousContext = [System.Threading.SynchronizationContext]::Current
            $script:ContextInside = 'not set'

            try {
                [System.Threading.SynchronizationContext]::SetSynchronizationContext($uiContext)

                $null = Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
                    param ($deviceCodeCallback)

                    $script:ContextInside = [System.Threading.SynchronizationContext]::Current
                    [System.Threading.Tasks.Task]::FromResult('done')
                } 6>$null

                $script:ContextInside |
                    Should -BeNullOrEmpty
                [System.Threading.SynchronizationContext]::Current |
                    Should -Be $uiContext
            }
            finally {
                [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
            }
        }
    }
}
