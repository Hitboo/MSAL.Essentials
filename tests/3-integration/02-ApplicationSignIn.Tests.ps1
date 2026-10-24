<#
    Integration tests: application sign-in (client credentials) against a real
    Microsoft Entra ID tenant. The same checks as the unit tests in
    tests/2-unit/02-ApplicationConnection.Tests.ps1, with real tokens.

    These tests are NOT interactive. No browser opens. Each part is skipped
    unless its app registration is configured.

    Setup (once per PowerShell session):

        $env:MSAL_TEST_TENANT_ID = '<tenant id or verified domain>'

        # An app registration with a client secret.
        $env:MSAL_TEST_APP_SECRET_CLIENT_ID = '<client id>'
        $env:MSAL_TEST_APP_SECRET           = '<secret value>'

        # The secret must be PLAIN TEXT (the test converts it to a SecureString).
        # Environment variables only hold strings: assigning a SecureString stores
        # the text 'System.Security.SecureString', which Entra ID rejects with
        # AADSTS7000215. Use single quotes, so a '$' in the secret stays intact.
        # To keep the secret out of the console history, read it securely:
        #   $env:MSAL_TEST_APP_SECRET = [System.Net.NetworkCredential]::new('', (Read-Host -Prompt 'Client secret' -AsSecureString)).Password

        # An app registration with a certificate. The certificate, with its
        # private key, must be in Cert:\CurrentUser\My.
        $env:MSAL_TEST_APP_CERT_CLIENT_ID  = '<client id>'
        $env:MSAL_TEST_APP_CERT_THUMBPRINT = '<thumbprint>'

        # An app registration WITHOUT any certificate or secret.
        $env:MSAL_TEST_APP_NO_CREDENTIALS_CLIENT_ID = '<client id>'

    The apps need no API permissions. Without permissions Entra ID still
    issues a token, Microsoft Graph then answers 403 instead of 401.

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration

    What is checked:
        - sign-in with a certificate and with a secret returns an Application
          connection with the expected properties and a token Microsoft Graph
          accepts
        - the default and a custom scope
        - invalid parameter combinations are rejected before any request
        - wrong secret, certificate not uploaded and an app without
          credentials are rejected with MsalEssentials.Unauthorized and the
          expected AADSTS code, and no connection is stored
        - Get-MsalEssentialsToken returns the stored token, and renews it (a
          real token request) when asked to
        - Disconnect-MsalEssentials clears the connection

    Not checked here (only in the unit tests): renewal failures, because a
    real renewal with valid credentials does not fail on demand.

    Token values are compared with -BeTrue on purpose: a failing -Be/-Not -Be
    assertion would print the access token into the console and logs.
#>

BeforeDiscovery {
    $skipTenant = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_TENANT_ID)

    $script:SkipSecretApp = $skipTenant -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_SECRET_CLIENT_ID) -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_SECRET)
    $script:SkipCertificateApp = $skipTenant -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_CERT_CLIENT_ID) -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_CERT_THUMBPRINT)
    $skipNoCredentialsApp = $skipTenant -or [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_NO_CREDENTIALS_CLIENT_ID)

    # One case per app registration and credential type.
    $script:RejectedCredentialCases = @(
        @{ Name = 'a wrong secret';                               ClientIdVariable = 'MSAL_TEST_APP_SECRET_CLIENT_ID';         Credential = 'Secret';      AadstsCode = '7000215'; Skip = $script:SkipSecretApp }
        @{ Name = 'a certificate that is not uploaded';           ClientIdVariable = 'MSAL_TEST_APP_CERT_CLIENT_ID';           Credential = 'Certificate'; AadstsCode = '700027';  Skip = $script:SkipCertificateApp }
        @{ Name = 'a secret for an app without credentials';      ClientIdVariable = 'MSAL_TEST_APP_NO_CREDENTIALS_CLIENT_ID'; Credential = 'Secret';      AadstsCode = '7000215'; Skip = $skipNoCredentialsApp }
        @{ Name = 'a certificate for an app without credentials'; ClientIdVariable = 'MSAL_TEST_APP_NO_CREDENTIALS_CLIENT_ID'; Credential = 'Certificate'; AadstsCode = '700027';  Skip = $skipNoCredentialsApp }
    )

    if ($skipTenant) {
        Write-Host 'Application integration tests skipped: set $env:MSAL_TEST_TENANT_ID and the app variables to run them (see the top of 02-ApplicationSignIn.Tests.ps1).' -ForegroundColor 'Yellow'
    }
}

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:TenantId     = $env:MSAL_TEST_TENANT_ID
    $script:GraphScope   = 'https://graph.microsoft.com/.default'

    $script:SecretClientId      = $env:MSAL_TEST_APP_SECRET_CLIENT_ID
    $script:CertificateClientId = $env:MSAL_TEST_APP_CERT_CLIENT_ID

    if (-not [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_SECRET)) {
        $script:ClientSecret = ConvertTo-SecureString -AsPlainText -Force -String $env:MSAL_TEST_APP_SECRET
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MSAL_TEST_APP_CERT_THUMBPRINT)) {
        $script:Certificate = Get-Item -Path ('Cert:\CurrentUser\My\{0}' -f $env:MSAL_TEST_APP_CERT_THUMBPRINT) -ErrorAction 'Stop'
    }

    # Wrong credentials: a certificate created in memory (never uploaded, so
    # Entra ID cannot know it) and a random value that is no secret of any app.
    $certificateRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=MsalEssentialsWrongCertificate',
        [System.Security.Cryptography.RSA]::Create(2048),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $script:WrongCertificate = $certificateRequest.CreateSelfSigned(
        [System.DateTimeOffset]::UtcNow.AddDays(-1),
        [System.DateTimeOffset]::UtcNow.AddDays(1)
    )
    $script:PublicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:WrongCertificate.RawData)
    $script:WrongSecret       = ConvertTo-SecureString -AsPlainText -Force -String ([guid]::NewGuid().ToString())

    # Runs a script block and returns the error it threw, or $null if it did not throw.
    function global:Get-MsalAppIntegrationError {
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

    # Sends the token to Microsoft Graph and returns the HTTP status code.
    # 200 or 403 means Graph accepted the token (403: the app has no
    # permission for this request), 401 means the token was rejected.
    function global:Get-MsalAppIntegrationGraphStatus {
        param (
            [Parameter(Mandatory)]
            $Connection
        )

        $graphRequest = @{
            Uri         = 'https://graph.microsoft.com/v1.0/users?$top=1'
            Method      = 'GET'
            Headers     = @{ Authorization = $Connection.CreateAuthorizationHeader() }
            ErrorAction = 'Stop'
        }

        try {
            $null = Invoke-RestMethod @graphRequest
            200
        }
        catch {
            [int]$_.Exception.Response.StatusCode
        }
    }

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'
}

AfterAll {
    if (Get-Module -Name $script:ModuleName) {
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    }

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'

    Remove-Item -Path 'Function:\Get-MsalAppIntegrationError', 'Function:\Get-MsalAppIntegrationGraphStatus' -ErrorAction 'SilentlyContinue'

    $script:WrongCertificate.Dispose()
    $script:PublicCertificate.Dispose()
    $script:WrongSecret.Dispose()
    if ($script:ClientSecret) {
        $script:ClientSecret.Dispose()
    }
}

Describe 'MSAL.Essentials application permissions (real tenant)' {
    BeforeEach {
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    }

    Context 'Connect-MsalEssentials -Certificate' -Skip:$script:SkipCertificateApp {
        It 'connects as an application with a token Microsoft Graph accepts' {
            $connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -ErrorAction 'Stop'

            $connection.AuthenticationType |
                Should -Be 'Application'
            $connection.ClientId |
                Should -Be $script:CertificateClientId
            $connection.TenantId |
                Should -Not -BeNullOrEmpty
            $connection.Username |
                Should -BeNullOrEmpty
            $connection.ExpiresOn |
                Should -BeGreaterThan ([System.DateTimeOffset]::UtcNow)
            (-not [string]::IsNullOrEmpty($connection.AccessToken)) |
                Should -BeTrue
            Get-MsalAppIntegrationGraphStatus -Connection $connection |
                Should -BeIn 200, 403
        }

        It 'uses the Microsoft Graph .default scope unless told otherwise' {
            $connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -ErrorAction 'Stop'

            $connection.Scopes |
                Should -Contain $script:GraphScope
        }

        It 'passes a custom scope on' {
            # Microsoft Graph by its application ID: exists in every tenant.
            $customScope = '00000003-0000-0000-c000-000000000000/.default'

            $connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -Scopes $customScope -ErrorAction 'Stop'

            $connection.Scopes |
                Should -Contain $customScope
        }

        It 'rejects a certificate without a private key' {
            $caught = Get-MsalAppIntegrationError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:PublicCertificate -ErrorAction 'Stop' }

            $caught.Exception.Message |
                Should -BeLike '*no private key*'
        }

        It 'does not accept -Certificate together with -ClientSecret' {
            $caught = Get-MsalAppIntegrationError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -ClientSecret $script:WrongSecret -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
        }

        It 'does not accept delegated-only parameters' {
            $caught = Get-MsalAppIntegrationError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -RedirectUri 'http://localhost' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Connect-MsalEssentials -ClientSecret' -Skip:$script:SkipSecretApp {
        It 'connects as an application with a token Microsoft Graph accepts' {
            $connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:SecretClientId -ClientSecret $script:ClientSecret -ErrorAction 'Stop'

            $connection.AuthenticationType |
                Should -Be 'Application'
            $connection.ClientId |
                Should -Be $script:SecretClientId
            $connection.Username |
                Should -BeNullOrEmpty
            (-not [string]::IsNullOrEmpty($connection.AccessToken)) |
                Should -BeTrue
            Get-MsalAppIntegrationGraphStatus -Connection $connection |
                Should -BeIn 200, 403
        }

        It 'requires a SecureString, not a plain string' {
            $caught = Get-MsalAppIntegrationError -ScriptBlock { Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:SecretClientId -ClientSecret 'plain-text' -ErrorAction 'Stop' }

            $caught |
                Should -Not -BeNullOrEmpty
        }
    }

    # -ForEach on the Context (not on the It), so $Skip is known during discovery.
    Context 'Rejected credentials: <Name>' -ForEach $script:RejectedCredentialCases {
        It 'is rejected with MsalEssentials.Unauthorized (AADSTS<AadstsCode>) and stores no connection' -Skip:$Skip {
            $connectParameters = @{
                TenantId    = $script:TenantId
                ClientId    = [System.Environment]::GetEnvironmentVariable($ClientIdVariable)
                ErrorAction = 'Stop'
            }
            if ($Credential -eq 'Certificate') {
                $connectParameters['Certificate'] = $script:WrongCertificate
            }
            else {
                $connectParameters['ClientSecret'] = $script:WrongSecret
            }

            $caught = Get-MsalAppIntegrationError -ScriptBlock { Connect-MsalEssentials @connectParameters }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.Unauthorized*'
            $caught.TargetObject.AadstsCode |
                Should -Be $AadstsCode

            $notConnected = Get-MsalAppIntegrationError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }

    Context 'Get-MsalEssentialsToken with an application connection' -Skip:$script:SkipCertificateApp {
        It 'returns the stored token while it is fresh' {
            $connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -ErrorAction 'Stop'

            $token = Get-MsalEssentialsToken -ErrorAction 'Stop'

            ($token.AccessToken -eq $connection.AccessToken) |
                Should -BeTrue
        }

        It 'requests a new token with the connection''s scopes when asked to renew' {
            # Microsoft Graph by its application ID: exists in every tenant.
            $customScope = '00000003-0000-0000-c000-000000000000/.default'
            $connection  = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -Scopes $customScope -ErrorAction 'Stop'

            # A window longer than the token lifetime forces a real renewal now.
            $token = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'

            ($token.AccessToken -ne $connection.AccessToken) |
                Should -BeTrue
            $token.ExpiresOn |
                Should -BeGreaterOrEqual $connection.ExpiresOn
            $token.Scopes |
                Should -Contain $customScope
            Get-MsalAppIntegrationGraphStatus -Connection $token |
                Should -BeIn 200, 403
        }
    }

    Context 'Disconnect-MsalEssentials with an application connection' -Skip:$script:SkipCertificateApp {
        It 'clears the connection without errors or output' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:CertificateClientId -Certificate $script:Certificate -ErrorAction 'Stop'

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' |
                Should -BeNullOrEmpty

            $notConnected = Get-MsalAppIntegrationError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
