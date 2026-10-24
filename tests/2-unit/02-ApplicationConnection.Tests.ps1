<#
    Behaviour tests for application permissions (client credentials):
        Connect-MsalEssentials -Certificate
        Connect-MsalEssentials -ClientSecret
        Get-MsalEssentialsToken (renewal of an application connection)

    No network is used. The token helper (Get-MsalEssentialsApplicationToken)
    is mocked, and the MSAL client it would return is replaced by a small
    fake that records calls.

    Why global: the mock bodies run in the module's scope and cannot see
    variables or functions from this file's scope, but they can see global
    ones. Everything global here starts with MsalAppTest and is removed in
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

    # A self-signed certificate with a private key, created in memory (not in the store).
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $certificateRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=MsalEssentialsTest',
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $script:Certificate = $certificateRequest.CreateSelfSigned(
        [System.DateTimeOffset]::UtcNow.AddDays(-1),
        [System.DateTimeOffset]::UtcNow.AddDays(1)
    )
    # The public part only: no private key.
    $script:PublicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:Certificate.RawData)

    $script:ClientSecret = [System.Security.SecureString]::new()
    foreach ($character in 'not-a-real-secret'.ToCharArray()) {
        $script:ClientSecret.AppendChar($character)
    }

    # A fake MSAL AuthenticationResult for an application token: no account.
    function global:New-MsalAppTestAuthResult {
        param (
            [string]$AccessToken = 'initial-app-token',
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
    function global:New-MsalAppTestClient {
        param (
            [Parameter(Mandatory)]
            $RenewedResult,

            $RenewFailure = $null
        )

        $client = [pscustomobject]@{
            RenewedResult = $RenewedResult
            RenewFailure  = $RenewFailure
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

    function global:New-MsalAppTestScenario {
        param (
            [double]$ExpiresInMinutes = 60,
            $RenewFailure = $null,
            $AuthFailure = $null
        )

        $global:MsalAppTest = @{
            AuthResult  = New-MsalAppTestAuthResult -ExpiresInMinutes $ExpiresInMinutes
            Client      = New-MsalAppTestClient -RenewedResult (New-MsalAppTestAuthResult -AccessToken 'renewed-app-token') -RenewFailure $RenewFailure
            AuthFailure = $AuthFailure
            Calls       = [System.Collections.Generic.List[hashtable]]::new()
        }
    }

    function global:Get-MsalAppTestError {
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

    Remove-Item -Path 'Function:\New-MsalAppTestAuthResult', 'Function:\New-MsalAppTestClient', 'Function:\New-MsalAppTestScenario', 'Function:\Get-MsalAppTestError' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalAppTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'

    $script:Certificate.Dispose()
    $script:PublicCertificate.Dispose()
    $script:ClientSecret.Dispose()
}

Describe 'MSAL.Essentials application permissions (simulated)' {
    BeforeEach {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
        }

        New-MsalAppTestScenario

        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsApplicationToken' -MockWith {
            $scenario = $global:MsalAppTest

            $scenario.Calls.Add(@{
                    TenantId       = $TenantId
                    ClientId       = $ClientId
                    Scopes         = $Scopes
                    HasCertificate = $PesterBoundParameters.ContainsKey('Certificate')
                    HasSecret      = $PesterBoundParameters.ContainsKey('ClientSecret')
                })

            if ($scenario.AuthFailure) {
                throw $scenario.AuthFailure
            }

            if ($ApplicationReference) {
                $ApplicationReference.Value = $scenario.Client
            }

            $scenario.AuthResult
        }

        # The delegated helper must never run for an application connection.
        Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
            throw 'The browser sign-in must not be used for application permissions.'
        }
    }

    Context 'Connect-MsalEssentials -Certificate' {
        It 'connects as an application and passes the certificate on' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            $connection.ClientId |
                Should -Be $script:ClientId
            $connection.Username |
                Should -BeNullOrEmpty
            $connection.AccessToken |
                Should -Be 'initial-app-token'
            $global:MsalAppTest.Calls.Count |
                Should -Be 1
            $global:MsalAppTest.Calls[0].HasCertificate |
                Should -BeTrue
            $global:MsalAppTest.Calls[0].HasSecret |
                Should -BeFalse
        }

        It 'uses the Microsoft Graph .default scope unless told otherwise' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate

            $global:MsalAppTest.Calls[0].Scopes |
                Should -Be 'https://graph.microsoft.com/.default'
        }

        It 'passes a custom scope on' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate -Scopes 'https://vault.azure.net/.default'

            $global:MsalAppTest.Calls[0].Scopes |
                Should -Be 'https://vault.azure.net/.default'
        }

        It 'rejects a certificate without a private key' {
            $caught = Get-MsalAppTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:PublicCertificate -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.Exception.Message |
                Should -BeLike '*no private key*'
            $global:MsalAppTest.Calls.Count |
                Should -Be 0
        }

        It 'does not accept -Certificate together with -ClientSecret' {
            $caught = Get-MsalAppTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate -ClientSecret $script:ClientSecret -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalAppTest.Calls.Count |
                Should -Be 0
        }

        It 'does not accept delegated-only parameters' {
            $caught = Get-MsalAppTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate -RedirectUri 'http://localhost' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalAppTest.Calls.Count |
                Should -Be 0
        }
    }

    Context 'Connect-MsalEssentials -ClientSecret' {
        It 'connects as an application and passes the secret on' {
            $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            $global:MsalAppTest.Calls[0].HasSecret |
                Should -BeTrue
            $global:MsalAppTest.Calls[0].HasCertificate |
                Should -BeFalse
        }

        It 'requires a SecureString, not a plain string' {
            $caught = Get-MsalAppTestError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret 'plain-text' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $global:MsalAppTest.Calls.Count |
                Should -Be 0
        }
    }

    # The same cases as tests/3-integration/02-ApplicationSignIn.Tests.ps1. Here the
    # token helper is mocked to fail the way it does when Entra ID rejects the
    # credential, so this checks that Connect-MsalEssentials passes the error
    # through unchanged and stores nothing. The AADSTS mapping itself is only
    # covered by the integration tests.
    Context 'Rejected credentials: <Name>' -ForEach @(
        @{ Name = 'a wrong secret';                               ClientId = '11111111-1111-1111-1111-111111111111'; Credential = 'Secret';      AadstsCode = '7000215' }
        @{ Name = 'a certificate that is not uploaded';           ClientId = '11111111-1111-1111-1111-111111111111'; Credential = 'Certificate'; AadstsCode = '700027' }
        @{ Name = 'a secret for an app without credentials';      ClientId = '22222222-2222-2222-2222-222222222222'; Credential = 'Secret';      AadstsCode = '7000215' }
        @{ Name = 'a certificate for an app without credentials'; ClientId = '22222222-2222-2222-2222-222222222222'; Credential = 'Certificate'; AadstsCode = '700027' }
    ) {
        It 'passes MsalEssentials.Unauthorized (AADSTS<AadstsCode>) through and stores no connection' {
            $authFailure = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(('AADSTS{0}: simulated' -f $AadstsCode)),
                'MsalEssentials.Unauthorized',
                [System.Management.Automation.ErrorCategory]::PermissionDenied,
                [pscustomobject]@{ Category = 'Unauthorized'; AadstsCode = $AadstsCode; ClientId = $ClientId }
            )
            New-MsalAppTestScenario -AuthFailure $authFailure

            $connectParameters = @{
                TenantId    = $script:TenantId
                ClientId    = $ClientId
                ErrorAction = 'Stop'
            }
            if ($Credential -eq 'Certificate') {
                $connectParameters['Certificate'] = $script:Certificate
            }
            else {
                $connectParameters['ClientSecret'] = $script:ClientSecret
            }

            $caught = Get-MsalAppTestError -ScriptBlock { Connect-MsalEssentials @connectParameters }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.Unauthorized*'
            $caught.TargetObject.AadstsCode |
                Should -Be $AadstsCode
            $global:MsalAppTest.Calls[0].ClientId |
                Should -Be $ClientId

            $notConnected = Get-MsalAppTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }

    Context 'Get-MsalEssentialsToken with an application connection' {
        It 'returns the stored token while it is fresh' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'initial-app-token'
            $global:MsalAppTest.Client.CallCount |
                Should -Be 0
        }

        It 'requests a new token when the token expires within 5 minutes' {
            New-MsalAppTestScenario -ExpiresInMinutes 3
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret

            (Get-MsalEssentialsToken).AccessToken |
                Should -Be 'renewed-app-token'
            $global:MsalAppTest.Client.CallCount |
                Should -Be 1
        }

        It 'forces a refresh and renews with the connection''s scopes' {
            New-MsalAppTestScenario -ExpiresInMinutes 3
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -Certificate $script:Certificate -Scopes 'https://vault.azure.net/.default'

            $null = Get-MsalEssentialsToken

            $global:MsalAppTest.Client.ForceRefresh |
                Should -BeTrue
            $global:MsalAppTest.Client.Scopes |
                Should -Be 'https://vault.azure.net/.default'
        }

        It 'returns the current token with a warning when renewal fails but the token is still valid' {
            New-MsalAppTestScenario -ExpiresInMinutes 3 -RenewFailure ([System.InvalidOperationException]::new('simulated renewal failure'))
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret

            $token = Get-MsalEssentialsToken -WarningVariable 'renewalWarning' -WarningAction 'SilentlyContinue'

            $token.AccessToken |
                Should -Be 'initial-app-token'
            $renewalWarning |
                Should -Not -BeNullOrEmpty
        }

        It 'fails with the renewal error when the token has expired and renewal fails' {
            New-MsalAppTestScenario -ExpiresInMinutes -1 -RenewFailure ([System.InvalidOperationException]::new('simulated renewal failure'))
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret

            $caught = Get-MsalAppTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.Exception.Message |
                Should -BeLike '*simulated renewal failure*'
        }
    }

    Context 'Disconnect-MsalEssentials with an application connection' {
        It 'clears the connection without errors or output' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' |
                Should -BeNullOrEmpty

            $caught = Get-MsalAppTestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
