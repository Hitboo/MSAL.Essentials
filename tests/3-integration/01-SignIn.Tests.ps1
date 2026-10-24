<#
    Integration tests: real sign-in against a real Microsoft Entra ID tenant.

    These tests are INTERACTIVE. They open your default browser and you have
    to sign in. Don't run them unattended or in CI. They are skipped unless a
    tenant is configured, so a normal run of the test suite does not open a
    browser.

    Setup (once per PowerShell session):

        $env:MSAL_TEST_TENANT_ID = '<tenant id or verified domain>'

    Optional:

        # Client (application) ID to sign in with. Defaults to
        # Microsoft Graph Command Line Tools (14d82eec-204b-4c2f-b7e8-296a70dab67e).
        $env:MSAL_TEST_CLIENT_ID = '<client id>'

        # An app registration that does NOT have http://localhost as a
        # redirect URI. Enables the "redirect URI not registered" test.
        $env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST = '<client id>'

        # The UPN of the account you sign in with. Enables the "login hint"
        # test, which signs in a second time.
        $env:MSAL_TEST_LOGIN_HINT_UPN = '<user principal name>'

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration

    You sign in once per run (and once per PowerShell edition with
    -AllEditions). Use an account that your Conditional Access policies let
    through from this machine, and one that may consent to User.Read.

    What is checked:
        - sign-in returns a usable connection and a token Microsoft Graph accepts
        - Get-MsalEssentialsToken returns the stored token, and renews it
          (a real silent renewal) when asked to
        - Disconnect-MsalEssentials clears the connection
        - sign-in failures that Entra ID shows in the browser (unknown app,
          unregistered redirect URI) end as MsalEssentials.Timeout

    Token values are compared with -BeTrue on purpose: a failing -Be/-Not -Be
    assertion would print the access token into the console and logs.
#>

BeforeDiscovery {
    $script:SkipSignIn   = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_TENANT_ID)
    $script:SkipRedirect = $script:SkipSignIn -or [string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST)
    $script:SkipLoginHint = $script:SkipSignIn -or [string]::IsNullOrWhiteSpace($env:MSAL_TEST_LOGIN_HINT_UPN)

    if ($script:SkipSignIn) {
        Write-Host 'Integration tests skipped: set $env:MSAL_TEST_TENANT_ID to run them (see the top of 01-SignIn.Tests.ps1).' -ForegroundColor 'Yellow'
    }
}

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path

    $script:TenantId = $env:MSAL_TEST_TENANT_ID
    $script:ClientId = if ([string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID)) { '14d82eec-204b-4c2f-b7e8-296a70dab67e' } else { $env:MSAL_TEST_CLIENT_ID }
    $script:ClientIdWithoutLocalhost = $env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST

    # Every test that opens a browser announces itself with a numbered, framed
    # note, so you can tell which window belongs to which test and check that
    # each one really happened. The total counts the browser windows of the
    # tests that are not skipped.
    $script:BrowserWindowTotal = 3
    if (-not [string]::IsNullOrWhiteSpace($env:MSAL_TEST_LOGIN_HINT_UPN)) { $script:BrowserWindowTotal++ }
    if (-not [string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST)) { $script:BrowserWindowTotal++ }
    $global:MsalTestBrowserWindowCount = 0

    function global:Write-MsalTestBrowserNote {
        param (
            [Parameter(Mandatory)]
            [ValidateSet('SignIn', 'DoNotSignIn', 'AlwaysFails')]
            [string]$Action,

            [Parameter(Mandatory)]
            [string]$Description,

            [Parameter(Mandatory)]
            [string]$Expected,

            [string]$Total
        )

        $global:MsalTestBrowserWindowCount++
        $color = switch ($Action) {
            'SignIn'      { 'Green' }
            'DoNotSignIn' { 'Yellow' }
            'AlwaysFails' { 'Magenta' }
        }
        $instruction = switch ($Action) {
            'SignIn'      { 'SIGN IN' }
            'DoNotSignIn' { 'DO NOT SIGN IN' }
            'AlwaysFails' { 'THIS SIGN-IN ALWAYS FAILS (you may sign in to see the error page)' }
        }
        $line = '=' * 72

        Write-Host ''
        Write-Host $line -ForegroundColor $color
        Write-Host ('  BROWSER WINDOW {0} of {1}: {2}' -f $global:MsalTestBrowserWindowCount, $Total, $instruction) -ForegroundColor $color
        Write-Host ('  {0}' -f $Description) -ForegroundColor $color
        Write-Host ('  Expected: {0}' -f $Expected) -ForegroundColor $color
        Write-Host $line -ForegroundColor $color
        Write-Host ''
    }

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'
}

AfterAll {
    if (Get-Module -Name $script:ModuleName) {
        Disconnect-MsalEssentials -InformationAction SilentlyContinue
    }

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'

    Remove-Item -Path 'Function:\Write-MsalTestBrowserNote' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalTestBrowserWindowCount' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

# Runs first on purpose: the login hint is only pre-filled when the browser has no
# signed-in session. Sign out of / clear the cookies of the browser before this
# test, because the tests after it sign in and leave a session behind.
Describe 'MSAL.Essentials sign-in with a login hint for another account (real tenant)' -Skip:$script:SkipSignIn {
    BeforeEach {
        Disconnect-MsalEssentials -InformationAction SilentlyContinue
    }

    # The hint only pre-fills the username. The account does not exist (or has no
    # session in your browser), so the sign-in must ask for credentials. If it
    # completed without you doing anything, the hint would be skipping the sign-in.
    It 'does not sign in by itself with a login hint (nothing is pre-authenticated)' {
        Write-MsalTestBrowserNote -Total $script:BrowserWindowTotal -Action 'DoNotSignIn' -Description 'Login hint "user@hitboo.test": CLEAR YOUR BROWSER SESSIONS/COOKIES FIRST, then the username is pre-filled. The test waits 7 seconds.' -Expected 'nothing is signed in automatically; the test passes when the sign-in times out.'

        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -LoginHintUpn 'user@hitboo.test' -TimeoutSeconds 7 -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught |
            Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Timeout*'
        $caught.Exception |
            Should -BeOfType ([System.TimeoutException])
    }

    It 'does not store a connection after a timeout with a login hint' {
        $caught = $null
        try {
            $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.NotConnected*'
    }

    # Rejected before a browser opens, so nothing to close or wait for.
    It 'rejects -LoginHintUpn <Name> without opening a browser' -ForEach @(
        @{ Name = 'that is not a UPN'; Value = 'not-a-upn' }
        @{ Name = 'that is empty';     Value = '' }
        @{ Name = 'that is null';      Value = $null }
    ) {
        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -LoginHintUpn $Value -TimeoutSeconds 7 -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught |
            Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'ParameterArgumentValidationError*'
        $caught.Exception.Message |
            Should -Match 'LoginHintUpn'

        $stored = $null
        try {
            $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
        }
        catch {
            $stored = $_
        }
        $stored.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.NotConnected*'
    }
}

Describe 'MSAL.Essentials sign-in (real tenant)' -Skip:$script:SkipSignIn {
    BeforeAll {
        Write-MsalTestBrowserNote -Total $script:BrowserWindowTotal -Action 'SignIn' -Description 'Normal sign-in (no hint). The tests below need this connection.' -Expected 'sign-in completes and the tests below pass.'

        $script:Connection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:ClientId -Scopes 'User.Read' -TimeoutSeconds 30 -ErrorAction 'Stop'
    }

    Context 'Connect-MsalEssentials' {
        It 'returns a connection for the signed-in user' {
            $script:Connection.PSObject.TypeNames |
                Should -Contain 'MsalEssentials.Connection'
            $script:Connection.Username |
                Should -Not -BeNullOrEmpty
            $script:Connection.ClientId |
                Should -Be $script:ClientId
            $script:Connection.AuthenticationType |
                Should -Be 'Delegated'

            $tenantGuid = [guid]::Empty
            [guid]::TryParse($script:Connection.TenantId, [ref]$tenantGuid) |
                Should -BeTrue
        }

        It 'returns a token that has not expired' {
            $script:Connection.AccessToken |
                Should -Not -BeNullOrEmpty
            ($script:Connection.ExpiresOn -gt [System.DateTimeOffset]::UtcNow) |
                Should -BeTrue
        }

        It 'returns a token that Microsoft Graph accepts' {
            $request = @{
                Uri     = 'https://graph.microsoft.com/v1.0/me'
                Method  = 'GET'
                Headers = @{ Authorization = $script:Connection.CreateAuthorizationHeader() }
            }

            $me = Invoke-RestMethod @request

            $me.id |
                Should -Not -BeNullOrEmpty
            $me.userPrincipalName |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-MsalEssentialsToken' {
        It 'returns the stored token while it is not close to expiring' {
            $token = Get-MsalEssentialsToken

            ($token.AccessToken -eq $script:Connection.AccessToken) |
                Should -BeTrue -Because 'a token with plenty of time left is returned as is'
        }

        # The window is widened to 24 hours so the fresh token counts as "close
        # to expiring". If this fails, the silent call returned the cached token:
        # MSAL only renews a token that is expired or within about 5 minutes of
        # expiring, unless a refresh is forced.
        It 'renews the token when it is inside the refresh window' {
            $renewed = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440

            ($renewed.AccessToken -ne $script:Connection.AccessToken) |
                Should -BeTrue -Because 'a renewal must return a new token, not the cached one'
            ($renewed.ExpiresOn -gt [System.DateTimeOffset]::UtcNow) |
                Should -BeTrue
        }

        It 'returns a renewed token that Microsoft Graph accepts' {
            $token = Get-MsalEssentialsToken

            $request = @{
                Uri     = 'https://graph.microsoft.com/v1.0/me'
                Method  = 'GET'
                Headers = @{ Authorization = $token.CreateAuthorizationHeader() }
            }

            (Invoke-RestMethod @request).id |
                Should -Not -BeNullOrEmpty
        }
    }

    # Keep this context last: it ends the connection the contexts above use.
    Context 'Disconnect-MsalEssentials' {
        It 'clears the connection' {
            Disconnect-MsalEssentials -InformationAction SilentlyContinue

            $caught = $null
            try {
                $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
            }
            catch {
                $caught = $_
            }

            $caught |
                Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.NotConnected*'
        }
    }
}

Describe 'MSAL.Essentials sign-in with a login hint (real tenant)' -Skip:$script:SkipLoginHint {
    BeforeAll {
        Write-MsalTestBrowserNote -Total $script:BrowserWindowTotal -Action 'SignIn' -Description ('Login hint "{0}": the username may be pre-filled. Sign in within 7 seconds.' -f $env:MSAL_TEST_LOGIN_HINT_UPN) -Expected 'any successful sign-in passes, the hint is optional. It will SSO if it is the account you already signed in with.'

        $script:HintedConnection = Connect-MsalEssentials -PassThru -TenantId $script:TenantId -ClientId $script:ClientId -Scopes 'User.Read' -LoginHintUpn $env:MSAL_TEST_LOGIN_HINT_UPN -TimeoutSeconds 7 -ErrorAction 'Stop'
    }

    AfterAll {
        Disconnect-MsalEssentials -InformationAction SilentlyContinue
    }

    # The hint is not mandatory: it only makes sign-in easier. The user can pick
    # or type another account, and an existing browser session can sign in
    # another account (SSO), so any successful sign-in passes.
    It 'returns a connection when a login hint is given' {
        $script:HintedConnection.PSObject.TypeNames |
            Should -Contain 'MsalEssentials.Connection'
        $script:HintedConnection.Username |
            Should -Not -BeNullOrEmpty
    }

    It 'returns a token that has not expired' {
        ($script:HintedConnection.ExpiresOn -gt [System.DateTimeOffset]::UtcNow) |
            Should -BeTrue
    }
}

# Entra ID shows these errors on its own page in the browser and never sends
# them back to PowerShell, so they end as a timeout. A browser tab with an
# error page opens during each test; close it afterwards.
Describe 'MSAL.Essentials sign-in failures shown in the browser (real tenant)' -Skip:$script:SkipSignIn {
    BeforeEach {
        Disconnect-MsalEssentials -InformationAction SilentlyContinue
    }

    It 'ends as MsalEssentials.Timeout for an application that does not exist' {
        Write-MsalTestBrowserNote -Total $script:BrowserWindowTotal -Action 'AlwaysFails' -Description 'Unknown application: Entra ID shows the error AADSTS700016 in the browser. Signing in changes nothing.' -Expected 'the test passes after 7 seconds, when the sign-in times out. Nothing is stored.'

        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId ([guid]::NewGuid().ToString()) -TimeoutSeconds 7 -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught |
            Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Timeout*'
        $caught.Exception |
            Should -BeOfType ([System.TimeoutException])
    }

    It 'does not store a connection after a timeout' {
        $caught = $null
        try {
            $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.NotConnected*'
    }

    It 'ends as MsalEssentials.Timeout, with the redirect URI hint, when http://localhost is not registered (AADSTS50011)' -Skip:$script:SkipRedirect {
        Write-MsalTestBrowserNote -Total $script:BrowserWindowTotal -Action 'AlwaysFails' -Description 'Redirect URI not registered: you may be asked to sign in first, then Entra ID shows the error AADSTS50011.' -Expected 'the test passes after 7 seconds, when the sign-in times out, with the redirect URI hint.'

        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientIdWithoutLocalhost -TimeoutSeconds 7 -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught |
            Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Timeout*'
        $caught.ErrorDetails.Message |
            Should -Match 'http://localhost'
    }
}