<#
    Behaviour tests for the device code sign-in:
        Connect-MsalEssentials -UseDeviceCode
        Get-MsalEssentialsToken (renewal of a device code connection)
        Disconnect-MsalEssentials

    No network is used. The token helper
    (Get-MsalEssentialsDelegatedTokenDeviceCode) is mocked, and the MSAL
    client it would return is replaced by a small fake that records calls.
    The helper itself is tested in 07-DeviceCodeHelper.Tests.ps1.

    Why global: the mock bodies run in the module's scope and cannot see
    variables or functions from this file's scope, but they can see global
    ones. Everything global here starts with MsalDcTest and is removed in
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

    # A fake MSAL AuthenticationResult for a delegated token.
    function global:New-MsalDcTestAuthResult {
        param (
            [string]$AccessToken = 'initial-device-code-token',
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
    function global:New-MsalDcTestTask {
        param (
            $Client,
            [scriptblock]$Work
        )

        $task = [pscustomobject]@{ Client = $Client; Work = $Work }
        $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetAwaiter' -Value { $this }
        $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetResult' -Value { & $this.Work $this }
        $task
    }

    # A fake IPublicClientApplication: AcquireTokenSilent, GetAccountsAsync and RemoveAsync.
    function global:New-MsalDcTestClient {
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
            SilentAccount   = $null
            ForceRefresh    = $null
            Accounts        = @([pscustomobject]@{ Username = 'user@hitboo.test' })
            RemovedAccounts = [System.Collections.Generic.List[object]]::new()
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'AcquireTokenSilent' -Value {
            param ($Scopes, $Account)

            $this.SilentCallCount++
            $this.SilentScopes  = $Scopes
            $this.SilentAccount = $Account

            $builder = [pscustomobject]@{ Client = $this }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'WithForceRefresh' -Value {
                param ($ForceRefresh)

                $this.Client.ForceRefresh = $ForceRefresh
                $this # return the builder so the calls can be chained, like in MSAL
            }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'ExecuteAsync' -Value {
                New-MsalDcTestTask -Client $this.Client -Work {
                    param ($Task)
                    if ($Task.Client.SilentFailure) { throw $Task.Client.SilentFailure }
                    $Task.Client.SilentResult
                }
            }
            $builder
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'GetAccountsAsync' -Value {
            New-MsalDcTestTask -Client $this -Work {
                param ($Task)
                @($Task.Client.Accounts)
            }
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'RemoveAsync' -Value {
            param ($Account)

            $this.RemovedAccounts.Add($Account)
            New-MsalDcTestTask -Client $this -Work { $null }
        }

        $client
    }

    function global:New-MsalDcTestScenario {
        param (
            [double]$ExpiresInMinutes = 60,
            $SilentFailure = $null,
            $AuthFailure = $null
        )

        $global:MsalDcTest = @{
            AuthResult  = New-MsalDcTestAuthResult -ExpiresInMinutes $ExpiresInMinutes
            Client      = New-MsalDcTestClient -SilentResult (New-MsalDcTestAuthResult -AccessToken 'renewed-device-code-token') -SilentFailure $SilentFailure
            AuthFailure = $AuthFailure
            Calls       = [System.Collections.Generic.List[hashtable]]::new()
        }
    }

    function global:Get-MsalDcTestError {
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

    Remove-Item -Path 'Function:\New-MsalDcTestAuthResult', 'Function:\New-MsalDcTestTask', 'Function:\New-MsalDcTestClient', 'Function:\New-MsalDcTestScenario', 'Function:\Get-MsalDcTestError' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalDcTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials device code sign-in (simulated)' {
    BeforeEach {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
        }

        New-MsalDcTestScenario

        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenDeviceCode' -MockWith {
            $scenario = $global:MsalDcTest

            $scenario.Calls.Add(@{
                    TenantId          = $TenantId
                    ClientId          = $ClientId
                    Scopes            = $Scopes
                    HasTimeoutSeconds = $PesterBoundParameters.ContainsKey('TimeoutSeconds')
                    TimeoutSeconds    = $TimeoutSeconds
                })

            if ($scenario.AuthFailure) {
                throw $scenario.AuthFailure
            }

            if ($ApplicationReference) {
                $ApplicationReference.Value = $scenario.Client
            }

            $scenario.AuthResult
        }

        # The browser sign-in must never run for a device code connection.
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
            throw 'The browser sign-in must not be used with -UseDeviceCode.'
        }
    }

    Context 'Connect-MsalEssentials -UseDeviceCode' {
        It 'connects as a delegated user' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -PassThru

            $connection.AuthenticationType |
                Should -Be 'Delegated'
            $connection.ClientId |
                Should -Be $script:ClientId
            $connection.Username |
                Should -Be 'user@hitboo.test'
            $connection.AccessToken |
                Should -Be 'initial-device-code-token'

            $global:MsalDcTest.Calls.Count |
                Should -Be 1
            $global:MsalDcTest.Calls[0].TenantId |
                Should -Be $script:TenantId
            $global:MsalDcTest.Calls[0].ClientId |
                Should -Be $script:ClientId

            Should -Invoke -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -Times 0 -Exactly
        }

        It 'accepts -DeviceCode as an alias' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -DeviceCode

            $global:MsalDcTest.Calls.Count |
                Should -Be 1
        }

        It 'returns nothing without -PassThru' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode |
                Should -BeNullOrEmpty
        }

        It 'uses the Microsoft Graph .default scope unless told otherwise' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode

            $global:MsalDcTest.Calls[0].Scopes |
                Should -Be 'https://graph.microsoft.com/.default'
        }

        It 'passes custom scopes on' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -Scopes 'User.Read', 'Mail.Read'

            $global:MsalDcTest.Calls[0].Scopes |
                Should -Be @('User.Read', 'Mail.Read')
        }

        It 'leaves the timeout to the helper unless -TimeoutSeconds is given' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode

            $global:MsalDcTest.Calls[0].HasTimeoutSeconds |
                Should -BeFalse
        }

        It 'passes -TimeoutSeconds on' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -TimeoutSeconds 300

            $global:MsalDcTest.Calls[0].HasTimeoutSeconds |
                Should -BeTrue
            $global:MsalDcTest.Calls[0].TimeoutSeconds |
                Should -Be 300
        }

        It 'rejects -TimeoutSeconds above 900, the usual lifetime of a device code' {
            $caught = Get-MsalDcTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -TimeoutSeconds 901 -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'ParameterArgumentValidationError*'
            $caught.Exception.Message |
                Should -Match 'TimeoutSeconds'
            $global:MsalDcTest.Calls.Count |
                Should -Be 0
        }

        It 'needs <Name>' -ForEach @(
            @{ Name = '-TenantId' }
            @{ Name = '-ClientId' }
        ) {
            # Mandatory parameters are prompted for in an interactive session,
            # so check the parameter set instead of calling the command.
            $parameterSet = (Get-Command -Name 'Connect-MsalEssentials').ParameterSets |
                Where-Object -FilterScript { $_.Name -eq 'DelegatedDeviceCode' }
            $parameterName = $Name.TrimStart('-')

            ($parameterSet.Parameters | Where-Object -FilterScript { $_.Name -eq $parameterName }).IsMandatory |
                Should -BeTrue
        }

        It 'does not accept <Name>' -ForEach @(
            @{ Name = '-RedirectUri';     Parameters = @{ RedirectUri = 'http://localhost' } }
            @{ Name = '-LoginHintUpn';    Parameters = @{ LoginHintUpn = 'user@hitboo.test' } }
            @{ Name = '-ManagedIdentity'; Parameters = @{ ManagedIdentity = $true } }
        ) {
            $caught = Get-MsalDcTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode @Parameters -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalDcTest.Calls.Count |
                Should -Be 0
        }

        It 'does not accept -UseDeviceCode together with -ClientSecret' {
            $secret = [System.Security.SecureString]::new()
            $secret.AppendChar('x')

            $caught = Get-MsalDcTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -ClientSecret $secret -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalDcTest.Calls.Count |
                Should -Be 0
        }
    }

    Context 'Connect-MsalEssentials -UseDeviceCode failures' {
        It 'passes MsalEssentials.ConditionalAccess through and stores no connection' {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('simulated: AADSTS53003 device code flow blocked'),
                'MsalEssentials.ConditionalAccess',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                [pscustomobject]@{ Category = 'ConditionalAccess'; AadstsCode = '53003' }
            )
            New-MsalDcTestScenario -AuthFailure $authFailure

            $caught = Get-MsalDcTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.ConditionalAccess*'
            $caught.TargetObject.AadstsCode |
                Should -Be '53003'

            $notConnected = Get-MsalDcTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }

        It 'fails with MsalEssentials.NoToken when the helper returns no token' {
            $global:MsalDcTest.AuthResult = $null

            $caught = Get-MsalDcTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NoToken*'
        }
    }

    Context 'Get-MsalEssentialsToken with a device code connection' {
        It 'returns the stored token while it is fresh' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-device-code-token'
            $global:MsalDcTest.Client.SilentCallCount |
                Should -Be 0
        }

        It 'renews silently with the scopes and account of the sign-in, without a new device code' {
            New-MsalDcTestScenario -ExpiresInMinutes 2
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -Scopes 'User.Read'

            $connection = Get-MsalEssentialsToken

            $connection.AccessToken |
                Should -Be 'renewed-device-code-token'
            $global:MsalDcTest.Client.SilentCallCount |
                Should -Be 1
            $global:MsalDcTest.Client.SilentScopes |
                Should -Be 'User.Read'
            $global:MsalDcTest.Client.SilentAccount.Username |
                Should -Be 'user@hitboo.test'
            $global:MsalDcTest.Client.ForceRefresh |
                Should -BeTrue

            # Renewal never shows a new device code.
            $global:MsalDcTest.Calls.Count |
                Should -Be 1
        }

        It 'fails with MsalEssentials.ReconnectRequired when the token has expired and a new sign-in is needed' {
            $uiRequired = [Microsoft.Identity.Client.MsalUiRequiredException]::new('invalid_grant', 'simulated: AADSTS700082 refresh token expired')
            New-MsalDcTestScenario -ExpiresInMinutes -1 -SilentFailure $uiRequired
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode

            $caught = Get-MsalDcTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.ReconnectRequired*'
            $global:MsalDcTest.Calls.Count |
                Should -Be 1
        }
    }

    Context 'Disconnect-MsalEssentials with a device code connection' {
        It 'removes the account from the MSAL cache and clears the connection' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' |
                Should -BeNullOrEmpty

            $global:MsalDcTest.Client.RemovedAccounts.Count |
                Should -Be 1

            $caught = Get-MsalDcTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
