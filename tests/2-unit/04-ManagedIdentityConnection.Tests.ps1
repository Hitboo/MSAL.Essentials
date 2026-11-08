<#
    Behaviour tests for managed identity connections:
        Connect-MsalEssentials -ManagedIdentity (system-assigned)
        Connect-MsalEssentials -ManagedIdentity -ClientId (user-assigned)
        Get-MsalEssentialsToken (renewal of a managed identity connection)
        Disconnect-MsalEssentials

    No network is used. The token helper
    (Get-MsalEssentialsManagedIdentityToken) is mocked, and the MSAL client it
    would return is replaced by a small fake that records calls. The helper
    itself, with the real MSAL library, is tested against a simulated
    endpoint in 05-ManagedIdentityEndpoint.Tests.ps1.

    Why global: the mock bodies run in the module's scope and cannot see
    variables or functions from this file's scope, but they can see global
    ones. Everything global here starts with MsalMiTest and is removed in
    AfterAll.
#>

BeforeAll {
    $script:ModuleName           = 'MSAL.Essentials'
    $script:ManifestPath         = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:UserAssignedClientId = '33333333-3333-3333-3333-333333333333'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # A fake MSAL AuthenticationResult for a managed identity token: no
    # account, and the placeholder tenant MSAL reports for managed identities.
    function global:New-MsalMiTestAuthResult {
        param (
            [string]$AccessToken = 'initial-mi-token',
            [double]$ExpiresInMinutes = 60
        )

        [pscustomobject]@{
            AccessToken = $AccessToken
            ExpiresOn   = [System.DateTimeOffset]::UtcNow.AddMinutes($ExpiresInMinutes)
            TenantId    = 'managed_identity'
            Scopes      = [string[]]@('https://graph.microsoft.com')
            Account     = $null
        }
    }

    # A fake IManagedIdentityApplication: AcquireTokenForManagedIdentity only.
    function global:New-MsalMiTestClient {
        param (
            [Parameter(Mandatory)]
            $RenewedResult,

            $RenewFailure = $null
        )

        $client = [pscustomobject]@{
            RenewedResult = $RenewedResult
            RenewFailure  = $RenewFailure
            CallCount     = 0
            Resource      = $null
            ForceRefresh  = $null
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'AcquireTokenForManagedIdentity' -Value {
            param ($Resource)

            $this.CallCount++
            $this.Resource = $Resource

            $builder = [pscustomobject]@{ Client = $this }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'WithForceRefresh' -Value {
                param ($ForceRefresh)

                $this.Client.ForceRefresh = $ForceRefresh
                $this # return the builder so the calls can be chained, like in MSAL
            }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'ExecuteAsync' -Value {
                $task = [pscustomobject]@{ Client = $this.Client }
                $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetAwaiter' -Value { $this }
                $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetResult' -Value {
                    if ($this.Client.RenewFailure) { throw $this.Client.RenewFailure }
                    $this.Client.RenewedResult
                }
                $task
            }
            $builder
        }

        $client
    }

    function global:New-MsalMiTestScenario {
        param (
            [double]$ExpiresInMinutes = 60,
            $RenewFailure = $null,
            $AuthFailure = $null
        )

        $global:MsalMiTest = @{
            AuthResult  = New-MsalMiTestAuthResult -ExpiresInMinutes $ExpiresInMinutes
            Client      = New-MsalMiTestClient -RenewedResult (New-MsalMiTestAuthResult -AccessToken 'renewed-mi-token') -RenewFailure $RenewFailure
            AuthFailure = $AuthFailure
            Calls       = [System.Collections.Generic.List[hashtable]]::new()
        }
    }

    function global:Get-MsalMiTestError {
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

    Remove-Item -Path 'Function:\New-MsalMiTestAuthResult', 'Function:\New-MsalMiTestClient', 'Function:\New-MsalMiTestScenario', 'Function:\Get-MsalMiTestError' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalMiTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials managed identity (simulated)' {
    BeforeEach {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
        }

        New-MsalMiTestScenario

        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsManagedIdentityToken' -MockWith {
            $scenario = $global:MsalMiTest

            $scenario.Calls.Add(@{
                    ClientId    = $ClientId
                    HasClientId = $PesterBoundParameters.ContainsKey('ClientId')
                    Scopes      = $Scopes
                })

            if ($scenario.AuthFailure) {
                throw $scenario.AuthFailure
            }

            if ($ApplicationReference) {
                $ApplicationReference.Value = $scenario.Client
            }

            $scenario.AuthResult
        }

        # The other helpers must never run for a managed identity connection.
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
            throw 'The browser sign-in must not be used for a managed identity.'
        }
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsApplicationToken' -MockWith {
            throw 'The client credentials flow must not be used for a managed identity.'
        }
    }

    Context 'Connect-MsalEssentials -ManagedIdentity (system-assigned)' {
        It 'connects without a tenant or client ID' {
            $connection = Connect-MsalEssentials -ManagedIdentity -PassThru

            $connection.AuthenticationType |
                Should -Be 'ManagedIdentity'
            $connection.AccessToken |
                Should -Be 'initial-mi-token'
            $connection.Username |
                Should -BeNullOrEmpty
            $connection.ClientId |
                Should -BeNullOrEmpty
            $global:MsalMiTest.Calls.Count |
                Should -Be 1
            $global:MsalMiTest.Calls[0].HasClientId |
                Should -BeFalse
        }

        It 'shows no tenant instead of the placeholder MSAL reports' {
            $connection = Connect-MsalEssentials -ManagedIdentity -PassThru

            $connection.TenantId |
                Should -BeNullOrEmpty
        }

        It 'accepts -Identity as an alias' {
            Connect-MsalEssentials -Identity

            $global:MsalMiTest.Calls.Count |
                Should -Be 1
        }

        It 'uses the Microsoft Graph .default scope unless told otherwise' {
            Connect-MsalEssentials -ManagedIdentity

            $global:MsalMiTest.Calls[0].Scopes |
                Should -Be 'https://graph.microsoft.com/.default'
        }

        It 'passes a custom scope on' {
            Connect-MsalEssentials -ManagedIdentity -Scopes 'https://vault.azure.net/.default'

            $global:MsalMiTest.Calls[0].Scopes |
                Should -Be 'https://vault.azure.net/.default'
        }

        It 'does not accept <Name>' -ForEach @(
            @{ Name = '-TenantId';     Parameters = @{ TenantId = 'hitboo.test' } }
            @{ Name = '-RedirectUri';  Parameters = @{ RedirectUri = 'http://localhost' } }
            @{ Name = '-LoginHintUpn'; Parameters = @{ LoginHintUpn = 'user@hitboo.test' } }
        ) {
            $caught = Get-MsalMiTestError -ScriptBlock { Connect-MsalEssentials -ManagedIdentity @Parameters -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalMiTest.Calls.Count |
                Should -Be 0
        }

        It 'does not accept -ManagedIdentity together with -ClientSecret' {
            $secret = [System.Security.SecureString]::new()
            $secret.AppendChar('x')

            $caught = Get-MsalMiTestError -ScriptBlock { Connect-MsalEssentials -ManagedIdentity -ClientSecret $secret -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalMiTest.Calls.Count |
                Should -Be 0
        }
    }

    Context 'Connect-MsalEssentials -ManagedIdentity -ClientId (user-assigned)' {
        It 'passes the client ID of the user-assigned identity on' {
            $connection = Connect-MsalEssentials -ManagedIdentity -ClientId $script:UserAssignedClientId -PassThru

            $global:MsalMiTest.Calls[0].ClientId |
                Should -Be $script:UserAssignedClientId
            $connection.ClientId |
                Should -Be $script:UserAssignedClientId
            $connection.AuthenticationType |
                Should -Be 'ManagedIdentity'
        }
    }

    Context 'Connect-MsalEssentials -ManagedIdentity failures' {
        It 'passes MsalEssentials.ManagedIdentityUnavailable through and stores no connection' {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('simulated: no managed identity endpoint'),
                'MsalEssentials.ManagedIdentityUnavailable',
                [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                [pscustomobject]@{ Category = 'ManagedIdentityUnavailable'; ErrorCode = 'managed_identity_unreachable_network' }
            )
            New-MsalMiTestScenario -AuthFailure $authFailure

            $caught = Get-MsalMiTestError -ScriptBlock { Connect-MsalEssentials -ManagedIdentity -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.ManagedIdentityUnavailable*'
            $caught.TargetObject.ErrorCode |
                Should -Be 'managed_identity_unreachable_network'

            $notConnected = Get-MsalMiTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }

    Context 'Get-MsalEssentialsToken with a managed identity connection' {
        It 'returns the stored token while it is fresh' {
            Connect-MsalEssentials -ManagedIdentity

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-mi-token'
            $global:MsalMiTest.Client.CallCount |
                Should -Be 0
        }

        It 'requests a new token when the token expires within 5 minutes' {
            New-MsalMiTestScenario -ExpiresInMinutes 3
            Connect-MsalEssentials -ManagedIdentity

            $token = Get-MsalEssentialsToken

            $token.AccessToken |
                Should -Be 'renewed-mi-token'
            $token.AuthenticationType |
                Should -Be 'ManagedIdentity'
            $global:MsalMiTest.Client.CallCount |
                Should -Be 1
        }

        It 'forces a refresh and renews with the connection''s scope' {
            New-MsalMiTestScenario -ExpiresInMinutes 3
            Connect-MsalEssentials -ManagedIdentity -ClientId $script:UserAssignedClientId -Scopes 'https://vault.azure.net/.default'

            $null = Get-MsalEssentialsToken

            $global:MsalMiTest.Client.ForceRefresh |
                Should -BeTrue
            $global:MsalMiTest.Client.Resource |
                Should -Be 'https://vault.azure.net/.default'
        }

        It 'returns the current token with a warning when renewal fails but the token is still valid' {
            New-MsalMiTestScenario -ExpiresInMinutes 3 -RenewFailure ([System.InvalidOperationException]::new('simulated renewal failure'))
            Connect-MsalEssentials -ManagedIdentity

            $token = Get-MsalEssentialsToken -WarningVariable 'renewalWarning' -WarningAction 'SilentlyContinue'

            $token.AccessToken |
                Should -Be 'initial-mi-token'
            $renewalWarning |
                Should -Not -BeNullOrEmpty
        }

        It 'fails with the renewal error when the token has expired and renewal fails' {
            New-MsalMiTestScenario -ExpiresInMinutes -1 -RenewFailure ([System.InvalidOperationException]::new('simulated renewal failure'))
            Connect-MsalEssentials -ManagedIdentity

            $caught = Get-MsalMiTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.Exception.Message |
                Should -BeLike '*simulated renewal failure*'
        }
    }

    Context 'Disconnect-MsalEssentials with a managed identity connection' {
        It 'clears the connection without errors or output' {
            Connect-MsalEssentials -ManagedIdentity

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' |
                Should -BeNullOrEmpty

            $caught = Get-MsalMiTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
