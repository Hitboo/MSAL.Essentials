<#
    Integration tests: device code sign-in against a real Microsoft Entra ID
    tenant.

    These tests are INTERACTIVE. Two tests show a device code that you have
    to enter on the page from the message (any browser, any device): in the
    first you decline the sign-in, in the second you sign in. Don't run them unattended or in CI. They are skipped unless
    a tenant is configured, like 01-SignIn.Tests.ps1.

    Setup (once per PowerShell session):

        $env:MSAL_TEST_TENANT_ID = '<tenant id or verified domain>'

    Optional:

        # Client (application) ID to sign in with. It needs "Allow public
        # client flows" set to Yes. Defaults to Microsoft Graph Command Line
        # Tools (14d82eec-204b-4c2f-b7e8-296a70dab67e), which allows it.
        $env:MSAL_TEST_CLIENT_ID = '<client id>'

        # The same app registration as in 01-SignIn.Tests.ps1, without
        # http://localhost. It must also have "Allow public client flows"
        # set to No (the default for a new app registration). Enables the
        # "public client flows not allowed" test (AADSTS7000218).
        $env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST = '<client id>'

    Run:

        .\tests\Start-Test.ps1 -TestsPath .\tests\3-integration\05-DeviceCodeSignIn.Tests.ps1

    If your tenant blocks the device code flow with Conditional Access (as
    Microsoft recommends), the sign-in test fails with
    MsalEssentials.ConditionalAccess (AADSTS53003). That is the expected
    behaviour of such a tenant, not a bug in the module.

    What is checked:
        - a device code is shown, and an unanswered code ends as
          MsalEssentials.Timeout after -TimeoutSeconds (no sign-in needed)
        - an app that does not allow public client flows ends as
          MsalEssentials.AppConfiguration (AADSTS7000218)
        - declining the sign-in ("It wasn't me" on the "Are you trying to
          sign in" page) ends as MsalEssentials.Cancelled (AADSTS700171,
          authorization_declined)
        - signing in with the code returns a usable delegated connection and
          a token Microsoft Graph accepts
        - Get-MsalEssentialsToken renews it silently (no new device code)
        - Disconnect-MsalEssentials clears the connection

    Token values are compared with -BeTrue on purpose: a failing -Be/-Not -Be
    assertion would print the access token into the console and logs.
#>

BeforeDiscovery {
    $script:SkipSignIn       = [string]::IsNullOrWhiteSpace($env:MSAL_TEST_TENANT_ID)
    $script:SkipPublicClient = $script:SkipSignIn -or [string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST)

    if ($script:SkipSignIn) {
        Write-Host 'Device code integration tests skipped: set $env:MSAL_TEST_TENANT_ID to run them (see the top of 05-DeviceCodeSignIn.Tests.ps1).' -ForegroundColor 'Yellow'
    }
}

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path

    $script:TenantId = $env:MSAL_TEST_TENANT_ID
    $script:ClientId = if ([string]::IsNullOrWhiteSpace($env:MSAL_TEST_CLIENT_ID)) { '14d82eec-204b-4c2f-b7e8-296a70dab67e' } else { $env:MSAL_TEST_CLIENT_ID }

    # How long each interactive test waits. Short on purpose: the module
    # copies the code to the clipboard, so you only paste it and pick an
    # account that is already signed in in your browser.
    $script:SignInTimeoutSeconds = 30
    $script:WaitNote = 'Sign in with an account of tenant {0} (an InPrivate window keeps the browser from using another signed-in account; an error page there is not sent back, so the test then ends as a timeout). The test waits {1} seconds.' -f $env:MSAL_TEST_TENANT_ID, $script:SignInTimeoutSeconds

    function global:Write-MsalDcTestNote {
        param (
            [Parameter(Mandatory)]
            [ValidateSet('SignIn', 'DoNotSignIn', 'Decline', 'AlwaysFails')]
            [string]$Action,

            [Parameter(Mandatory)]
            [string]$Description
        )

        $color = switch ($Action) {
            'SignIn'      { 'Green' }
            'DoNotSignIn' { 'Yellow' }
            'Decline'     { 'Magenta' }
            'AlwaysFails' { 'Magenta' }
        }
        $instruction = switch ($Action) {
            'SignIn'      { 'ENTER THE CODE BELOW AND SIGN IN' }
            'DoNotSignIn' { 'DO NOT ENTER THE CODE BELOW' }
            'Decline'     { 'ENTER THE CODE BELOW, THEN DECLINE THE SIGN-IN' }
            'AlwaysFails' { 'THIS SIGN-IN ALWAYS FAILS: ENTER THE CODE BELOW AND SIGN IN' }
        }
        $line        = '=' * 72

        Write-Host ''
        Write-Host $line -ForegroundColor $color
        Write-Host ('  DEVICE CODE: {0}' -f $instruction) -ForegroundColor $color
        Write-Host ('  {0}' -f $Description) -ForegroundColor $color
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

    Remove-Item -Path 'Function:\Write-MsalDcTestNote' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials device code sign-in (real tenant)' -Skip:$script:SkipSignIn {
    It 'shows a device code and times out when nobody enters it' {
        Write-MsalDcTestNote -Action 'DoNotSignIn' -Description 'The test waits 7 seconds and passes when the sign-in times out.'

        # -InformationVariable keeps a copy of the host output, which is still
        # shown in the console while the test runs.
        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -Scopes 'User.Read' -TimeoutSeconds 7 -InformationVariable 'deviceCodeOutput' -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $outputText = @($deviceCodeOutput) -join ' '
        $outputText |
            Should -Match 'devicelogin|/device'

        # The "copied" line only appears when the clipboard was checked to hold
        # the code. Some hosts have no usable clipboard, so it is not required,
        # but when it is shown the clipboard must hold the code from the message.
        if ($outputText -like '*The code is copied to the clipboard.*') {
            $clipboardText = (@(Get-Clipboard) -join '').Trim()
            $clipboardText |
                Should -Match '^[A-Z0-9]{6,}$'
            $outputText |
                Should -BeLike ('*{0}*' -f $clipboardText)
        }
        else {
            Write-Host '  (The clipboard was not available in this host, so the code was only shown.)' -ForegroundColor 'Yellow'
        }
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Timeout*'
        $caught.Exception |
            Should -BeOfType ([System.TimeoutException])

        $notConnected = $null
        try {
            $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
        }
        catch {
            $notConnected = $_
        }
        $notConnected.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.NotConnected*'
    }

    It 'reports MsalEssentials.AppConfiguration (AADSTS7000218) for an app without public client flows' -Skip:$script:SkipPublicClient {
        Write-MsalDcTestNote -Action 'AlwaysFails' -Description ('The app does not allow public client flows. If a code is shown, enter it and sign in; Entra ID then rejects the token request. ' + $script:WaitNote)

        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $env:MSAL_TEST_CLIENT_ID_NO_LOCALHOST -UseDeviceCode -Scopes 'User.Read' -TimeoutSeconds $script:SignInTimeoutSeconds -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.AppConfiguration*'
        $caught.TargetObject.AadstsCode |
            Should -Be '7000218'
        $caught.ErrorDetails.Message |
            Should -BeLike '*Allow public client flows*'
    }

    It 'reports MsalEssentials.Cancelled when the sign-in is declined' {
        Write-MsalDcTestNote -Action 'Decline' -Description ('Enter the code and pick your account, then choose "It wasn''t me" when asked whether you are trying to sign in. ' + $script:WaitNote)

        $caught = $null
        try {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -Scopes 'User.Read' -TimeoutSeconds $script:SignInTimeoutSeconds -ErrorAction 'Stop'
        }
        catch {
            $caught = $_
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.Cancelled*'
        $caught.TargetObject.ErrorCode |
            Should -Be 'authorization_declined'
        $caught.Exception |
            Should -BeOfType ([Microsoft.Identity.Client.MsalServiceException])

        $notConnected = $null
        try {
            $null = Get-MsalEssentialsToken -ErrorAction 'Stop'
        }
        catch {
            $notConnected = $_
        }
        $notConnected.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.NotConnected*'
    }

    It 'signs in with a device code and gets a token Microsoft Graph accepts' {
        Write-MsalDcTestNote -Action 'SignIn' -Description ('Open the page in any browser, enter the code and sign in. ' + $script:WaitNote)

        $connection = Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -UseDeviceCode -Scopes 'User.Read' -TimeoutSeconds $script:SignInTimeoutSeconds -PassThru -ErrorAction 'Stop'

        $connection.AuthenticationType |
            Should -Be 'Delegated'
        $connection.Username |
            Should -Not -BeNullOrEmpty
        [string]::IsNullOrEmpty($connection.AccessToken) |
            Should -BeFalse

        $me = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = $connection.CreateAuthorizationHeader() } -ErrorAction 'Stop'
        $me.userPrincipalName |
            Should -Not -BeNullOrEmpty
    }

    It 'renews the token silently without a new device code' {
        $before = Get-MsalEssentialsToken -ErrorAction 'Stop'

        # 1440 minutes: every token "expires soon", so this forces a renewal.
        $output = @(Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop' 6>&1)

        $informationRecords = @($output | Where-Object -FilterScript { $_ -is [System.Management.Automation.InformationRecord] })
        $renewed            = $output | Where-Object -FilterScript { $_ -isnot [System.Management.Automation.InformationRecord] }

        $informationRecords.Count |
            Should -Be 0
        ($renewed.AccessToken -ne $before.AccessToken) |
            Should -BeTrue
    }

    It 'disconnects' {
        Disconnect-MsalEssentials -InformationAction SilentlyContinue

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
}
