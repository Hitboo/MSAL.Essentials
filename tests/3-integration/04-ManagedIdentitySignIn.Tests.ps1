<#
    Integration tests: managed identity sign-in on a real Azure resource. The
    same checks as the unit tests in
    tests/2-unit/04-ManagedIdentityConnection.Tests.ps1, with real tokens.

    These tests only work ON an Azure resource that has a managed identity
    (an Azure VM is the simplest, see below). On any other computer they are
    skipped, because the variables are not set there.

    These tests are NOT interactive. No browser opens. Each part is skipped
    unless its variable is set.

    Setup (once per PowerShell session, on the Azure resource):

        # The VM has its system-assigned identity turned on
        # (VM > Security > Identity > System assigned > On).
        $env:MSAL_TEST_MI_SYSTEM_ASSIGNED = '1'

        # A user-assigned identity is assigned to the VM
        # (VM > Security > Identity > User assigned > Add).
        # Its Client ID (Managed Identities > your identity > Overview).
        $env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID = '<client id>'

    The identities need no role assignments and no API permissions. The token
    is checked against Azure Resource Manager, which lists the subscriptions
    the identity can see (an empty list without roles) instead of rejecting
    the call.

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration

    What is checked:
        - system- and user-assigned sign-in return a ManagedIdentity
          connection with the expected properties and a token Azure Resource
          Manager accepts
        - the user-assigned token belongs to that identity (appid claim)
        - a client ID that is not assigned to the resource is rejected with
          MsalEssentials.AppConfiguration, and no connection is stored
        - Get-MsalEssentialsToken returns the stored token, and renews it (a
          real token request) when asked to
        - Disconnect-MsalEssentials clears the connection

    Not checked here (only in the unit tests): renewal failures, and the
    error on a computer without a managed identity.

    Token values are compared with -BeTrue on purpose: a failing -Be/-Not -Be
    assertion would print the access token into the console and logs.
#>

BeforeDiscovery {
    $script:SkipSystemAssigned = $env:MSAL_TEST_MI_SYSTEM_ASSIGNED -ne '1'
    $script:SkipUserAssigned   = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID)
    $script:SkipAny            = $script:SkipSystemAssigned -and $script:SkipUserAssigned

    if ($script:SkipAny) {
        Write-Host 'Managed identity integration tests skipped: run them on an Azure resource with a managed identity and set the variables at the top of 04-ManagedIdentitySignIn.Tests.ps1.' -ForegroundColor 'Yellow'
    }
}

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:ArmScope     = 'https://management.azure.com/.default'

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
}

AfterAll {
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'SilentlyContinue'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Managed identity sign-in on an Azure resource' -Skip:$script:SkipAny {
    AfterEach {
        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    }

    Context 'System-assigned identity' -Skip:$script:SkipSystemAssigned {
        It 'returns a ManagedIdentity connection that Azure Resource Manager accepts' {
            $connection = Connect-MsalEssentials -ManagedIdentity -Scopes $script:ArmScope -PassThru -ErrorAction 'Stop'

            $connection.AuthenticationType |
                Should -Be 'ManagedIdentity'
            $connection.ClientId |
                Should -BeNullOrEmpty
            $connection.TenantId |
                Should -BeNullOrEmpty
            $connection.Username |
                Should -BeNullOrEmpty
            ($connection.ExpiresOn -gt [System.DateTimeOffset]::UtcNow) |
                Should -BeTrue
            (Test-ArmAccepts -Connection $connection) |
                Should -BeTrue
        }

        It 'returns the stored token, and a new one when asked to renew' {
            $connection = Connect-MsalEssentials -ManagedIdentity -Scopes $script:ArmScope -PassThru -ErrorAction 'Stop'

            $stored = Get-MsalEssentialsToken -ErrorAction 'Stop'
            ($stored.AccessToken -eq $connection.AccessToken) |
                Should -BeTrue

            # A window as long as a day forces a real token request.
            $renewed = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'
            (Test-ArmAccepts -Connection $renewed) |
                Should -BeTrue
        }
    }

    Context 'User-assigned identity' -Skip:$script:SkipUserAssigned {
        It 'returns a token for exactly that identity' {
            $clientId   = $env:MSAL_TEST_MI_USER_ASSIGNED_CLIENT_ID
            $connection = Connect-MsalEssentials -ManagedIdentity -ClientId $clientId -Scopes $script:ArmScope -PassThru -ErrorAction 'Stop'

            $connection.AuthenticationType |
                Should -Be 'ManagedIdentity'
            $connection.ClientId |
                Should -Be $clientId
            (Get-TokenClaim -AccessToken $connection.AccessToken).appid |
                Should -Be $clientId
            (Test-ArmAccepts -Connection $connection) |
                Should -BeTrue
        }

        It 'rejects a client ID that is not assigned to this resource with MsalEssentials.AppConfiguration' {
            $caught = Get-TestError -ScriptBlock {
                Connect-MsalEssentials -ManagedIdentity -ClientId ([guid]::NewGuid().ToString()) -Scopes $script:ArmScope -ErrorAction 'Stop'
            }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.AppConfiguration*'
            $caught.TargetObject.StatusCode |
                Should -Be 400
            $caught.TargetObject.ManagedIdentitySource |
                Should -Be 'Imds'
            $caught.ErrorDetails.Message |
                Should -BeLike '*Hint:*'

            $notConnected = Get-TestError -ScriptBlock { Get-MsalEssentialsToken -ErrorAction 'Stop' }
            $notConnected.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}
