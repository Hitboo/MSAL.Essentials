<#
    Behaviour tests for the connection commands:
        Connect-MsalEssentials
        Get-MsalEssentialsToken (including silent renewal)
        Disconnect-MsalEssentials
    and their errors: not connected, nothing to refresh yet, sign-in failed.

    No browser and no network are used. The sign-in helper
    (Get-MsalEssentialsDelegatedTokenSystemBrowser) is mocked, and the MSAL
    client it would return is replaced by a small fake that records calls.

    Why global: the mock bodies run in the module's scope and cannot see
    variables or functions from this file's scope, but they can see global
    ones. Everything global here starts with MsalTest and is removed in
    AfterAll.
#>

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:TenantId     = 'hitboo.test'
    $script:ClientId     = '11111111-1111-1111-1111-111111111111'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # A fake MSAL AuthenticationResult with only what the module reads.
    function global:New-MsalTestAuthResult {
        param (
            [string]$AccessToken = 'initial-access-token',
            [double]$ExpiresInMinutes = 60
        )

        [pscustomobject]@{
            AccessToken = $AccessToken
            ExpiresOn   = [System.DateTimeOffset]::UtcNow.AddMinutes($ExpiresInMinutes)
            TenantId    = '00000000-0000-0000-0000-000000000001'
            Scopes      = [string[]]@('User.Read')
            Account     = [pscustomobject]@{ Username = 'user@hitboo.test' }
        }
    }

    # A fake MSAL "task": GetAwaiter().GetResult() runs the Work script block.
    function global:New-MsalTestTask {
        param (
            $Client,
            $Argument,
            [scriptblock]$Work
        )

        $task = [pscustomobject]@{ Client = $Client; Argument = $Argument; Work = $Work }
        $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetAwaiter' -Value { $this }
        $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetResult' -Value { & $this.Work $this }
        $task
    }

    # A fake IPublicClientApplication: AcquireTokenSilent, GetAccountsAsync and
    # RemoveAsync, recording how they were called.
    function global:New-MsalTestClient {
        param (
            [Parameter(Mandatory)]
            $SilentResult,

            $SilentFailure = $null
        )

        $client = [pscustomobject]@{
            SilentResult    = $SilentResult
            SilentFailure   = $SilentFailure
            SilentCallCount = 0
            SilentScopes    = $null
            ForceRefresh    = $null
            Accounts        = @([pscustomobject]@{ Username = 'user@hitboo.test' })
            RemovedAccounts = [System.Collections.Generic.List[object]]::new()
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'AcquireTokenSilent' -Value {
            param ($Scopes, $Account)

            $this.SilentCallCount++
            $this.SilentScopes = $Scopes

            $builder = [pscustomobject]@{ Client = $this }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'WithForceRefresh' -Value {
                param ($ForceRefresh)

                $this.Client.ForceRefresh = $ForceRefresh
                $this # return the builder so the calls can be chained, like in MSAL
            }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'ExecuteAsync' -Value {
                New-MsalTestTask -Client $this.Client -Work {
                    param ($Task)
                    if ($Task.Client.SilentFailure) { throw $Task.Client.SilentFailure }
                    $Task.Client.SilentResult
                }
            }
            $builder
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'GetAccountsAsync' -Value {
            New-MsalTestTask -Client $this -Work {
                param ($Task)
                @($Task.Client.Accounts)
            }
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'RemoveAsync' -Value {
            param ($Account)

            New-MsalTestTask -Client $this -Argument $Account -Work {
                param ($Task)
                $Task.Client.RemovedAccounts.Add($Task.Argument)

                # The real RemoveAsync returns a Task that yields a
                # VoidTaskResult. Return a value, so a missing discard in
                # the module shows up as pipeline output.
                [pscustomobject]@{ TypeName = 'System.Threading.Tasks.VoidTaskResult' }
            }
        }

        $client
    }

    # Sets what the mocked sign-in returns (or throws) and how the fake client
    # behaves when the token is renewed silently.
    function global:New-MsalTestScenario {
        param (
            [double]$ExpiresInMinutes = 60,
            [double]$RenewedExpiresInMinutes = 60,
            [string]$AccessToken = 'initial-access-token',
            $SilentFailure = $null,
            $AuthFailure = $null
        )

        $renewedResult = New-MsalTestAuthResult -AccessToken 'renewed-access-token' -ExpiresInMinutes $RenewedExpiresInMinutes

        $global:MsalTest = @{
            AuthResult  = New-MsalTestAuthResult -AccessToken $AccessToken -ExpiresInMinutes $ExpiresInMinutes
            Client      = New-MsalTestClient -SilentResult $renewedResult -SilentFailure $SilentFailure
            AuthFailure = $AuthFailure
        }
    }

    # Runs a script block and returns the error it threw, or $null if it did not throw.
    function global:Get-MsalTestError {
        param (
            [scriptblock]$ScriptBlock
        )

        $caughtError = $null
        try {
            $null = & $ScriptBlock
        }
        catch {
            $caughtError = $_
        }
        $caughtError
    }
}

AfterAll {
    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'

    Remove-Item -Path 'Function:\New-MsalTestAuthResult', 'Function:\New-MsalTestTask', 'Function:\New-MsalTestClient', 'Function:\New-MsalTestScenario', 'Function:\Get-MsalTestError' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials connection commands (simulated)' {
    BeforeEach {
        # Start every test without a stored connection.
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
        }

        New-MsalTestScenario

        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
            $scenario = $global:MsalTest

            if ($scenario.AuthFailure) {
                throw $scenario.AuthFailure
            }

            if ($ApplicationReference) {
                $ApplicationReference.Value = $scenario.Client
            }

            $scenario.AuthResult
        }
    }

    Context 'Connect-MsalEssentials' {
        It 'stores the connection and returns nothing without -PassThru' {
            $result = Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $result |
                Should -BeNullOrEmpty
            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-access-token'
        }

        It 'returns the connection with -PassThru' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -PassThru

            $connection.PSObject.TypeNames |
                Should -Contain 'MsalEssentials.Connection'
            $connection.AuthenticationType |
                Should -Be 'Delegated'
            $connection.TenantId |
                Should -Be '00000000-0000-0000-0000-000000000001'
            $connection.ClientId |
                Should -Be $script:ClientId
            $connection.Username |
                Should -Be 'user@hitboo.test'
            $connection.Scopes |
                Should -Contain 'User.Read'
            $connection.AccessToken |
                Should -Be 'initial-access-token'
            $connection.ExpiresOn |
                Should -BeOfType ([System.DateTimeOffset])
        }

        It 'creates an authorization header' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -PassThru

            $connection.CreateAuthorizationHeader() |
                Should -Be 'Bearer initial-access-token'
        }

        It 'keeps the access token out of the default display' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -PassThru

            $connection.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
                Should -Not -Contain 'AccessToken'
            $connection.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames |
                Should -Contain 'Username'
            ($connection | Out-String) |
                Should -Not -Match 'initial-access-token'
            # Still available as a normal property.
            $connection.AccessToken |
                Should -Be 'initial-access-token'
        }

        It 'passes -Scopes and -TimeoutSeconds to the sign-in' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -Scopes 'Mail.Read' -TimeoutSeconds 30

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
                $Scopes -contains 'Mail.Read' -and $TimeoutSeconds -eq 30
            }
        }

        It 'requests the Microsoft Graph default scope when no scopes are given' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
                $Scopes -contains 'https://graph.microsoft.com/.default'
            }
        }

        It 'replaces an existing connection' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            New-MsalTestScenario -AccessToken 'second-access-token'
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'second-access-token'
        }

        It 'passes -RedirectUri to the sign-in' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -RedirectUri 'http://localhost:1234/app'

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
                $RedirectUri -eq 'http://localhost:1234/app'
            }
        }

        It 'passes -LoginHintUpn to the sign-in' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -LoginHintUpn 'user@hitboo.test'

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
                $LoginHintUpn -eq 'user@hitboo.test'
            }
        }

        It 'does not pass -LoginHintUpn to the sign-in when it is not given' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('LoginHintUpn')
            }
        }

        It 'rejects -LoginHintUpn <Name>' -ForEach @(
            @{ Name = 'without an @';          Value = 'not-a-upn' }
            @{ Name = 'without a user name';   Value = '@hitboo.test' }
            @{ Name = 'without a domain';      Value = 'user@' }
            @{ Name = 'without a domain dot';  Value = 'user@hitboo' }
            @{ Name = 'with two @';            Value = 'user@@hitboo.test' }
            @{ Name = 'with a space';          Value = 'us er@hitboo.test' }
            @{ Name = 'that is empty';         Value = '' }
            @{ Name = 'that is null';          Value = $null }
        ) {
            # Calls the real sign-in helper (not the mock). Parameter
            # validation fails before any MSAL code runs.
            $caught = InModuleScope -ModuleName $script:ModuleName -Parameters @{ Value = $Value } -ScriptBlock {
                try {
                    Get-MsalEssentialsDelegatedTokenSystemBrowser -TenantId 'hitboo.test' -ClientID '11111111-1111-1111-1111-111111111111' -LoginHintUpn $Value
                }
                catch {
                    $_
                }
            }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'ParameterArgumentValidationError*'
        }
    }

    Context 'Get-MsalEssentialsToken' {
        It 'returns the connection object' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $token = Get-MsalEssentialsToken

            $token.PSObject.TypeNames |
                Should -Contain 'MsalEssentials.Connection'
            $token.AccessToken |
                Should -Be 'initial-access-token'
            $token.CreateAuthorizationHeader() |
                Should -Be 'Bearer initial-access-token'
        }

        It 'does not renew a token that has more than 15 minutes left' {
            New-MsalTestScenario -ExpiresInMinutes 60
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $token = Get-MsalEssentialsToken

            $token.AccessToken |
                Should -Be 'initial-access-token'
            $global:MsalTest.Client.SilentCallCount |
                Should -Be 0
        }
    }

    Context 'Silent renewal' {
        It 'renews silently when the token expires within 15 minutes' {
            New-MsalTestScenario -ExpiresInMinutes 10
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -PassThru

            $token = Get-MsalEssentialsToken

            $token.AccessToken |
                Should -Be 'renewed-access-token'
            $token.ExpiresOn |
                Should -BeGreaterThan $connection.ExpiresOn
            $global:MsalTest.Client.SilentCallCount |
                Should -Be 1
        }

        It 'forces a refresh so MSAL does not return the cached token' {
            New-MsalTestScenario -ExpiresInMinutes 10
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $null = Get-MsalEssentialsToken

            $global:MsalTest.Client.ForceRefresh |
                Should -BeTrue
        }

        It 'renews with the scopes the connection was created with' {
            New-MsalTestScenario -ExpiresInMinutes 10
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -Scopes 'Mail.Read'

            $null = Get-MsalEssentialsToken

            $global:MsalTest.Client.SilentScopes |
                Should -Contain 'Mail.Read'
        }

        It 'does not renew again once the renewed token is fresh' {
            New-MsalTestScenario -ExpiresInMinutes 10 -RenewedExpiresInMinutes 60
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $null = Get-MsalEssentialsToken
            $null = Get-MsalEssentialsToken

            $global:MsalTest.Client.SilentCallCount |
                Should -Be 1
        }

        It 'uses -RefreshBeforeExpiryMinutes to decide when to renew' {
            New-MsalTestScenario -ExpiresInMinutes 30
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $null = Get-MsalEssentialsToken
            $global:MsalTest.Client.SilentCallCount |
                Should -Be 0

            $token = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 45
            $token.AccessToken |
                Should -Be 'renewed-access-token'
            $global:MsalTest.Client.SilentCallCount |
                Should -Be 1
        }

        It 'never starts a sign-in while renewing' {
            New-MsalTestScenario -ExpiresInMinutes 10
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $null = Get-MsalEssentialsToken

            # Only the sign-in from Connect-MsalEssentials.
            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly
        }

        It 'returns the current token with a warning when renewal fails but the token is still valid' {
            New-MsalTestScenario -ExpiresInMinutes 10 -SilentFailure ([System.InvalidOperationException]::new('network down'))
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $token = Get-MsalEssentialsToken -WarningVariable renewalWarning -WarningAction SilentlyContinue

            $token.AccessToken |
                Should -Be 'initial-access-token'
            ($renewalWarning -join ' ') |
                Should -Match 'could not be renewed'
            ($renewalWarning -join ' ') |
                Should -Match 'network down'
        }

        It 'fails with MsalEssentials.ReconnectRequired when the token expired and a new sign-in is needed' {
            $uiRequired = [Microsoft.Identity.Client.MsalUiRequiredException]::new('interaction_required', 'The refresh token has expired.')
            New-MsalTestScenario -ExpiresInMinutes -5 -SilentFailure $uiRequired
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.ReconnectRequired*'
            $caught.Exception.Message |
                Should -BeLike '*Run Connect-MsalEssentials*'
            $caught.Exception.InnerException |
                Should -BeOfType 'Microsoft.Identity.Client.MsalUiRequiredException'
        }

        It 'passes other renewal errors through when the token expired' {
            New-MsalTestScenario -ExpiresInMinutes -5 -SilentFailure ([System.InvalidOperationException]::new('network down'))
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -Not -BeLike 'MsalEssentials.ReconnectRequired*'
            $caught.Exception.Message |
                Should -BeLike '*network down*'
        }

        It 'never starts a sign-in when the token expired and cannot be renewed' {
            $uiRequired = [Microsoft.Identity.Client.MsalUiRequiredException]::new('interaction_required', 'The refresh token has expired.')
            New-MsalTestScenario -ExpiresInMinutes -5 -SilentFailure $uiRequired
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $null = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            # Only the sign-in from Connect-MsalEssentials.
            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 1 -Exactly
        }
    }

    Context 'Disconnect-MsalEssentials' {
        It 'clears the connection' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Disconnect-MsalEssentials -InformationAction SilentlyContinue

            InModuleScope -ModuleName $script:ModuleName -ScriptBlock { $script:MsalEssentialsSession } |
                Should -BeNullOrEmpty
            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }

        It 'removes the accounts from the MSAL token cache' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Disconnect-MsalEssentials -InformationAction SilentlyContinue

            $global:MsalTest.Client.RemovedAccounts.Count |
                Should -Be 1
            $global:MsalTest.Client.RemovedAccounts[0].Username |
                Should -Be 'user@hitboo.test'
        }

        It 'writes nothing to the pipeline' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $output = @(Disconnect-MsalEssentials -InformationAction SilentlyContinue)

            $output.Count |
                Should -Be 0
        }

        It 'shows a hint to remove variables that hold the token' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Disconnect-MsalEssentials -InformationVariable disconnectHint -InformationAction SilentlyContinue

            ($disconnectHint.MessageData -join ' ') |
                Should -Match 'Remove-Variable'
        }

        It 'does nothing and shows no hint when there is no connection' {
            { Disconnect-MsalEssentials -InformationVariable disconnectHint -ErrorAction 'Stop' } |
                Should -Not -Throw
            $disconnectHint |
                Should -BeNullOrEmpty
        }

        It 'can be run twice' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            Disconnect-MsalEssentials -InformationAction SilentlyContinue

            { Disconnect-MsalEssentials -InformationAction SilentlyContinue -ErrorAction 'Stop' } |
                Should -Not -Throw
        }
    }

    Context 'Errors: not connected, nothing to refresh yet' {
        It 'fails with MsalEssentials.NotConnected before any connection exists' {
            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
            $caught.Exception.Message |
                Should -BeLike '*Run Connect-MsalEssentials first*'
        }

        It 'fails with MsalEssentials.NotConnected after Disconnect-MsalEssentials' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId
            Disconnect-MsalEssentials -InformationAction SilentlyContinue

            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }

        It 'has nothing to renew when a renewal is requested without a connection' {
            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
            $global:MsalTest.Client.SilentCallCount |
                Should -Be 0
        }

        It 'fails with MsalEssentials.NotConnected when the session holds no token' {
            InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                $script:MsalEssentialsSession = @{ AuthenticationType = 'Delegated'; AuthenticationResult = $null }
            }

            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }

        It 'never signs in by itself' {
            $null = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            Should -Invoke -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -ModuleName $script:ModuleName -Times 0 -Exactly
        }
    }

    Context 'Errors: sign-in failed' {
        It 'passes the <Id> error through unchanged' -ForEach @(
            @{ Id = 'MsalEssentials.Timeout';           Category = [System.Management.Automation.ErrorCategory]::OperationTimeout }
            @{ Id = 'MsalEssentials.Cancelled';         Category = [System.Management.Automation.ErrorCategory]::OperationStopped }
            @{ Id = 'MsalEssentials.AppConfiguration';  Category = [System.Management.Automation.ErrorCategory]::InvalidOperation }
            @{ Id = 'MsalEssentials.Unauthorized';      Category = [System.Management.Automation.ErrorCategory]::PermissionDenied }
            @{ Id = 'MsalEssentials.ConditionalAccess'; Category = [System.Management.Automation.ErrorCategory]::SecurityError }
            @{ Id = 'MsalEssentials.Authentication';    Category = [System.Management.Automation.ErrorCategory]::AuthenticationError }
        ) {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Sign-in failed: simulated'),
                $Id,
                $Category,
                $null
            )
            New-MsalTestScenario -AuthFailure $authFailure

            $caught = Get-MsalTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -BeLike ('{0}*' -f $Id)
            $caught.Exception.Message |
                Should -Be 'Sign-in failed: simulated'
        }

        It 'does not store a connection when sign-in fails' {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Sign-in failed: simulated'),
                'MsalEssentials.Authentication',
                [System.Management.Automation.ErrorCategory]::AuthenticationError,
                $null
            )
            New-MsalTestScenario -AuthFailure $authFailure

            $null = Get-MsalTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -ErrorAction 'Stop' }

            $caught = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }

        It 'keeps the previous connection when a new sign-in fails' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId

            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Sign-in failed: simulated'),
                'MsalEssentials.Authentication',
                [System.Management.Automation.ErrorCategory]::AuthenticationError,
                $null
            )
            $global:MsalTest.AuthFailure = $authFailure

            $caught = Get-MsalTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-access-token'
        }

        It 'fails with MsalEssentials.NoToken when sign-in returns no access token' {
            New-MsalTestScenario -AccessToken ''

            $caught = Get-MsalTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientID $script:ClientId -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NoToken*'

            $notConnected = Get-MsalTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}