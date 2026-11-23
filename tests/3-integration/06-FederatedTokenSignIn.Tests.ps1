<#
    Integration tests: workload identity federation against a real tenant.
    The same checks as the unit tests in
    tests/2-unit/08-FederatedTokenConnection.Tests.ps1, with real tokens.

    The federated token comes from the user-assigned managed identity of an
    Azure VM, so no GitHub workflow or Kubernetes cluster is needed: an app
    registration can trust a managed identity like any other issuer. Run
    these tests ON that VM (the same one as for
    04-ManagedIdentitySignIn.Tests.ps1). On any other computer they are
    skipped, because the variables are not set there.

    These tests are NOT interactive. No browser opens.

    Setup (once, in the tenant of the VM):

        1. Entra admin center > App registrations > New registration
           (single tenant, no redirect URI, no secret).
        2. That app > Certificates & secrets > Federated credentials >
           Add credential > scenario "Managed Identity" > select the
           user-assigned identity of the VM. Issuer, subject (the
           identity's object ID) and audience (api://AzureADTokenExchange)
           are filled in.
        The app needs no API permissions and no role assignments: the
        token is checked against Azure Resource Manager, which lists the
        subscriptions the app can see (an empty list without roles).

    Setup (once per PowerShell session, on the VM):

        # The user-assigned identity that issues the federated token
        # (Managed Identities > your identity > Overview > Client ID).
        $env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID = '<client id of the identity>'

        # The app registration with the federated credential.
        $env:MSAL_TEST_WIF_TENANT_ID = '<tenant id>'
        $env:MSAL_TEST_WIF_CLIENT_ID = '<application (client) id of the app>'

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration\06-FederatedTokenSignIn.Tests.ps1

    What is checked:
        - -FederatedToken returns an Application connection for exactly that
          app (appid claim) with a token Azure Resource Manager accepts
        - -FederatedTokenFile does the same, and Get-MsalEssentialsToken
          renews it with a real token request (which reads the file again)
        - a token with the wrong audience (the identity's token for Azure
          Resource Manager) is rejected with MsalEssentials.Unauthorized and
          a federated credential hint, and no connection is stored
        - a missing token file fails with MsalEssentials.AppConfiguration
          before any request
        - Disconnect-MsalEssentials clears the connection

    Not checked here (only in the unit tests): an expired federated token
    (AADSTS700024) and an empty token file.

    Token values are compared with -BeTrue on purpose: a failing -Be/-Not -Be
    assertion would print the access token into the console and logs.
#>

BeforeDiscovery {
    $script:Skip = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID) -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_WIF_TENANT_ID) -or
        [string]::IsNullOrWhiteSpace($env:MSAL_TEST_WIF_CLIENT_ID)

    if ($script:Skip) {
        Write-Host 'Workload identity federation integration tests skipped: run them on the Azure VM and set the variables at the top of 06-FederatedTokenSignIn.Tests.ps1.' -ForegroundColor 'Yellow'
    }
}

BeforeAll {
    $script:ModuleName    = 'MSAL.Essentials'
    $script:ManifestPath  = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:ArmScope      = 'https://management.azure.com/.default'
    $script:ExchangeScope = 'api://AzureADTokenExchange/.default'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # Reads the claims of an access token (no signature check, tests only).
    function script:Get-TokenClaim {
        param ([string]$AccessToken)

        $payload = $AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
    }

    function script:Test-ArmAccepts {
        param ($Connection)

        $request = @{
            Uri         = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
            Method      = 'GET'
            Headers     = @{ Authorization = $Connection.CreateAuthorizationHeader() }
            ErrorAction = 'Stop'
        }
        $null = Invoke-RestMethod @request
        $true
    }

    function script:Get-TestError {
        param ([scriptblock]$ScriptBlock)

        $caughtError = $null
        try {
            $null = & $ScriptBlock
        }
        catch {
            $caughtError = $_
        }
        $caughtError
    }

    # Gets a token of the VM's user-assigned identity, by default the
    # federated token (audience api://AzureADTokenExchange). Connecting as
    # the identity replaces the stored connection, so this runs before the
    # app connects, and disconnects again.
    function script:Get-ManagedIdentityToken {
        param ([string]$Scope = $script:ExchangeScope)

        try {
            $identityConnection = Connect-MsalEssentials -ManagedIdentity -ClientId $env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID -Scopes $Scope -PassThru -ErrorAction 'Stop'
            $identityConnection.AccessToken
        }
        finally {
            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
        }
    }

    $script:WifParameters = @{
        TenantId    = $env:MSAL_TEST_WIF_TENANT_ID
        ClientId    = $env:MSAL_TEST_WIF_CLIENT_ID
        Scopes      = $script:ArmScope
        ErrorAction = 'Stop'
    }
}

AfterAll {
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'SilentlyContinue'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Workload identity federation with a managed identity as issuer' -Skip:$script:Skip {
    AfterEach {
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    }

    Context 'Connect-MsalEssentials -FederatedToken' {
        It 'returns an Application connection for the app that Azure Resource Manager accepts' {
            $federatedToken = Get-ManagedIdentityToken

            $connection = Connect-MsalEssentials @script:WifParameters -FederatedToken $federatedToken -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            $connection.ClientId |
                Should -Be $env:MSAL_TEST_WIF_CLIENT_ID
            $connection.Username |
                Should -BeNullOrEmpty
            # The token belongs to the app, not to the identity that issued the federated token.
            (Get-TokenClaim -AccessToken $connection.AccessToken).appid |
                Should -Be $env:MSAL_TEST_WIF_CLIENT_ID
            (Test-ArmAccepts -Connection $connection) |
                Should -BeTrue
        }

        It 'rejects a token with the wrong audience with MsalEssentials.Unauthorized and stores no connection' {
            # The identity's token for Azure Resource Manager: signed by Entra ID,
            # but not issued for api://AzureADTokenExchange.
            $wrongToken = Get-ManagedIdentityToken -Scope $script:ArmScope

            $caught = Get-TestError -ScriptBlock { Connect-MsalEssentials @script:WifParameters -FederatedToken $wrongToken }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.Unauthorized*'
            # Which part Entra ID reports first (issuer, audience or the whole
            # record) is up to Entra ID, so accept any of them.
            $caught.TargetObject.AadstsCode |
                Should -BeIn @('70021', '700211', '700212', '700213')
            $caught.ErrorDetails.Message |
                Should -BeLike '*Hint: No federated credential*'

            $notConnected = Get-TestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }

    Context 'Connect-MsalEssentials -FederatedTokenFile' {
        BeforeAll {
            $script:TokenFile = Join-Path -Path $TestDrive -ChildPath 'federated-token'
        }

        It 'returns a connection, and renews it by reading the file again' {
            Set-Content -LiteralPath $script:TokenFile -Value (Get-ManagedIdentityToken) -NoNewline

            $connection = Connect-MsalEssentials @script:WifParameters -FederatedTokenFile $script:TokenFile -PassThru

            $connection.AuthenticationType |
                Should -Be 'Application'
            (Test-ArmAccepts -Connection $connection) |
                Should -BeTrue

            # A window as long as a day forces a real token request, for which
            # MSAL reads the file again. (Rotating the file content can't be
            # shown here: MSAL caches managed identity tokens process-wide, so
            # a second identity token would be the same.)
            $renewed = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'
            (Test-ArmAccepts -Connection $renewed) |
                Should -BeTrue
        }

        It 'fails with MsalEssentials.AppConfiguration when the file does not exist' {
            $missingFile = Join-Path -Path $TestDrive -ChildPath 'missing-token'

            $caught = Get-TestError -ScriptBlock { Connect-MsalEssentials @script:WifParameters -FederatedTokenFile $missingFile }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.AppConfiguration*'
            $caught.ErrorDetails.Message |
                Should -BeLike '*Hint: Check -FederatedTokenFile*'
        }
    }

    Context 'Disconnect-MsalEssentials' {
        It 'clears a federated connection' {
            $federatedToken = Get-ManagedIdentityToken
            Connect-MsalEssentials @script:WifParameters -FederatedToken $federatedToken

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'

            $notConnected = Get-TestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
