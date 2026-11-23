<#
    Behaviour tests for workload identity federation (application
    permissions with a federated token):
        Connect-MsalEssentials -FederatedToken
        Connect-MsalEssentials -FederatedTokenFile
        Get-MsalEssentialsToken (renewal of the connection)

    No network is used. The token helper (Get-MsalEssentialsApplicationToken)
    is mocked, and the MSAL client it would return is replaced by a small
    fake that records calls. The helper itself is tested in
    09-FederatedTokenHelper.Tests.ps1.

    Why global: the mock bodies run in the module's scope and cannot see
    variables or functions from this file's scope, but they can see global
    ones. Everything global here starts with MsalWifTest and is removed in
    AfterAll.
#>

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:TenantId     = 'hitboo.test'
    $script:ClientId     = '11111111-1111-1111-1111-111111111111'

    # Not a real token: only the shape (three parts separated by dots) matters.
    $script:FederatedToken = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJyZXBvOkhpdGJvby9NU0FMLkVzc2VudGlhbHM6cmVmOnJlZnMvaGVhZHMvbWFpbiJ9.c2lnbmF0dXJl'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # A fake MSAL AuthenticationResult for an application token: no account.
    function global:New-MsalWifTestAuthResult {
        param (
            [string]$AccessToken = 'initial-wif-token',
            [double]$ExpiresInMinutes = 60
        )

        [pscustomobject]@{
            AccessToken = $AccessToken
            ExpiresOn   = [System.DateTimeOffset]::UtcNow.AddMinutes($ExpiresInMinutes)
            TenantId    = '00000000-0000-0000-0000-000000000001'
            Scopes      = [string[]]@()
            Account     = $null
        }
    }

    # A fake IConfidentialClientApplication: AcquireTokenForClient only.
    function global:New-MsalWifTestClient {
        param (
            [Parameter(Mandatory)]
            $RenewedResult
        )

        $client = [pscustomobject]@{
            RenewedResult = $RenewedResult
            CallCount     = 0
            Scopes        = $null
            ForceRefresh  = $null
        }

        $client | Add-Member -MemberType 'ScriptMethod' -Name 'AcquireTokenForClient' -Value {
            param ($Scopes)

            $this.CallCount++
            $this.Scopes = $Scopes

            $builder = [pscustomobject]@{ Client = $this }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'WithForceRefresh' -Value {
                param ($ForceRefresh)

                $this.Client.ForceRefresh = $ForceRefresh
                $this
            }
            $builder | Add-Member -MemberType 'ScriptMethod' -Name 'ExecuteAsync' -Value {
                $task = [pscustomobject]@{ Client = $this.Client }
                $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetAwaiter' -Value { $this }
                $task | Add-Member -MemberType 'ScriptMethod' -Name 'GetResult' -Value { $this.Client.RenewedResult }
                $task
            }
            $builder
        }

        $client
    }

    function global:New-MsalWifTestScenario {
        param (
            [double]$ExpiresInMinutes = 60,
            $AuthFailure = $null
        )

        $global:MsalWifTest = @{
            AuthResult  = New-MsalWifTestAuthResult -ExpiresInMinutes $ExpiresInMinutes
            Client      = New-MsalWifTestClient -RenewedResult (New-MsalWifTestAuthResult -AccessToken 'renewed-wif-token')
            AuthFailure = $AuthFailure
            Calls       = [System.Collections.Generic.List[hashtable]]::new()
        }
    }

    function global:Get-MsalWifTestError {
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

    Remove-Item -Path 'Function:\New-MsalWifTestAuthResult', 'Function:\New-MsalWifTestClient', 'Function:\New-MsalWifTestScenario', 'Function:\Get-MsalWifTestError' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalWifTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials workload identity federation (simulated)' {
    BeforeEach {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
        }

        New-MsalWifTestScenario

        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsApplicationToken' -MockWith {
            $scenario = $global:MsalWifTest

            $scenario.Calls.Add(@{
                    TenantId           = $TenantId
                    ClientId           = $ClientId
                    Scopes             = $Scopes
                    FederatedToken     = $FederatedToken
                    FederatedTokenFile = $FederatedTokenFile
                    BoundCredentials   = @($PesterBoundParameters.Keys | Where-Object -FilterScript { $_ -in 'Certificate', 'ClientSecret', 'FederatedToken', 'FederatedTokenFile' })
                })

            if ($scenario.AuthFailure) {
                throw $scenario.AuthFailure
            }

            if ($ApplicationReference) {
                $ApplicationReference.Value = $scenario.Client
            }

            $scenario.AuthResult
        }

        # The delegated helpers must never run for an application connection.
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
            throw 'The browser sign-in must not be used for workload identity federation.'
        }
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenDeviceCode' -MockWith {
            throw 'The device code sign-in must not be used for workload identity federation.'
        }
    }

    Context 'Connect-MsalEssentials -FederatedToken' {
        It 'connects as an application and passes only the token on' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken $script:FederatedToken -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            # The tenant ID from the token, not the -TenantId as supplied.
            $connection.TenantId |
                Should -Be '00000000-0000-0000-0000-000000000001'
            $connection.ClientId |
                Should -Be $script:ClientId
            $connection.Username |
                Should -BeNullOrEmpty
            $connection.AccessToken |
                Should -Be 'initial-wif-token'
            $global:MsalWifTest.Calls.Count |
                Should -Be 1
            $global:MsalWifTest.Calls[0].FederatedToken |
                Should -Be $script:FederatedToken
            $global:MsalWifTest.Calls[0].BoundCredentials |
                Should -Be @('FederatedToken')
        }

        It 'accepts -ClientAssertion as an alias' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientAssertion $script:FederatedToken

            $global:MsalWifTest.Calls[0].FederatedToken |
                Should -Be $script:FederatedToken
        }

        It 'uses the Microsoft Graph .default scope unless told otherwise' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken $script:FederatedToken

            $global:MsalWifTest.Calls[0].Scopes |
                Should -Be 'https://graph.microsoft.com/.default'
        }

        It 'passes a custom scope on' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken $script:FederatedToken -Scopes 'https://management.azure.com/.default'

            $global:MsalWifTest.Calls[0].Scopes |
                Should -Be 'https://management.azure.com/.default'
        }

        It 'rejects an empty token' {
            $caught = Get-MsalWifTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken '' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalWifTest.Calls.Count |
                Should -Be 0
        }

        It 'makes -<Name> mandatory for <Set>' -ForEach @(
            @{ Name = 'TenantId'; Set = 'AppFederatedToken' }
            @{ Name = 'ClientId'; Set = 'AppFederatedToken' }
            @{ Name = 'TenantId'; Set = 'AppFederatedTokenFile' }
            @{ Name = 'ClientId'; Set = 'AppFederatedTokenFile' }
        ) {
            # A missing mandatory parameter would prompt in an interactive
            # session, so check the parameter metadata instead of calling.
            $setAttribute = (Get-Command -Name 'Connect-MsalEssentials').Parameters[$Name].Attributes |
                Where-Object -FilterScript { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.ParameterSetName -eq $Set }

            $setAttribute.Mandatory |
                Should -BeTrue
        }

        It 'does not accept <Other> together with -FederatedToken' -ForEach @(
            @{ Other = '-FederatedTokenFile'; Parameters = @{ FederatedTokenFile = 'token.jwt' } }
            @{ Other = '-ManagedIdentity';    Parameters = @{ ManagedIdentity = $true } }
            @{ Other = '-UseDeviceCode';      Parameters = @{ UseDeviceCode = $true } }
            @{ Other = '-RedirectUri';        Parameters = @{ RedirectUri = 'http://localhost' } }
        ) {
            $connectParameters = @{
                TenantId       = $script:TenantId
                ClientId       = $script:ClientId
                FederatedToken = $script:FederatedToken
                ErrorAction    = 'Stop'
            } + $Parameters

            $caught = Get-MsalWifTestError -ScriptBlock { Connect-MsalEssentials @connectParameters }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalWifTest.Calls.Count |
                Should -Be 0
        }
    }

    Context 'Connect-MsalEssentials -FederatedTokenFile' {
        It 'connects as an application and passes only the file on' {
            $tokenFile = Join-Path -Path $TestDrive -ChildPath 'azure-identity-token'

            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedTokenFile $tokenFile -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            $global:MsalWifTest.Calls[0].FederatedTokenFile |
                Should -Be $tokenFile
            $global:MsalWifTest.Calls[0].BoundCredentials |
                Should -Be @('FederatedTokenFile')
        }

        It 'rejects an empty path' {
            $caught = Get-MsalWifTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedTokenFile '' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalWifTest.Calls.Count |
                Should -Be 0
        }
    }

    Context 'Rejected federated token' {
        It 'passes MsalEssentials.Unauthorized through and stores no connection' {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('AADSTS700213: simulated'),
                'MsalEssentials.Unauthorized',
                [System.Management.Automation.ErrorCategory]::PermissionDenied,
                [pscustomobject]@{ Category = 'Unauthorized'; AadstsCode = '700213'; ClientId = $script:ClientId }
            )
            New-MsalWifTestScenario -AuthFailure $authFailure

            $caught = Get-MsalWifTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken $script:FederatedToken -ErrorAction 'Stop' }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.Unauthorized*'
            $caught.TargetObject.AadstsCode |
                Should -Be '700213'

            $notConnected = Get-MsalWifTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }

    Context 'Get-MsalEssentialsToken with a federated connection' {
        It 'returns the stored token while it is fresh' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedToken $script:FederatedToken

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-wif-token'
            $global:MsalWifTest.Client.CallCount |
                Should -Be 0
        }

        It 'renews through the same MSAL client, with a forced refresh and the connection''s scope' {
            New-MsalWifTestScenario -ExpiresInMinutes 2
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -FederatedTokenFile (Join-Path -Path $TestDrive -ChildPath 'token') -Scopes 'https://management.azure.com/.default'

            $token = Get-MsalEssentialsToken

            $token.AccessToken |
                Should -Be 'renewed-wif-token'
            $global:MsalWifTest.Client.CallCount |
                Should -Be 1
            $global:MsalWifTest.Client.ForceRefresh |
                Should -BeTrue
            $global:MsalWifTest.Client.Scopes |
                Should -Be 'https://management.azure.com/.default'
            # No new sign-in: the helper ran once, for Connect.
            $global:MsalWifTest.Calls.Count |
                Should -Be 1
        }
    }
}
