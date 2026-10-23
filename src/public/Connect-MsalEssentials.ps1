<#
    .SYNOPSIS
        Connects to Microsoft Entra ID and keeps the resulting token for this
        PowerShell session.

    .DESCRIPTION
        Signs in as the current user through the system's default web browser
        (delegated rights) by calling
        Get-MsalEssentialsDelegatedTokenSystemBrowser, then stores the result
        and the MSAL client in module scope so Get-MsalEssentialsToken can
        renew the token silently later.

        Nothing is written to disk. Running Connect-MsalEssentials again
        replaces the stored connection. Re-importing the module (Import-Module
        -Force) also clears it.

        Errors from the sign-in are passed through unchanged, including the
        FullyQualifiedErrorId values (MsalEssentials.Timeout,
        MsalEssentials.ConditionalAccess, ...) and the TargetObject details
        described in Get-MsalEssentialsDelegatedTokenSystemBrowser. This is a
        terminating error for the command, so use -ErrorAction 'Stop' or
        try/catch in scripts to make sure nothing runs after a failed sign-in.

        Currently supported:
            DelegatedSystemBrowser   interactive sign-in as a user (default)

        Planned parameter sets (not implemented yet):
            AppCertificate, AccessToken, ManagedIdentity

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientId
        The application (client) ID registered in Entra ID.

    .PARAMETER Scopes
        The delegated scopes to request. Defaults to Microsoft Graph's default
        scope set. The same scopes are used when the token is renewed.

    .PARAMETER TimeoutSeconds
        How long to wait for the interactive sign-in to complete. If omitted,
        the default of Get-MsalEssentialsDelegatedTokenSystemBrowser is used.

    .PARAMETER RedirectUri
        The redirect URI MSAL listens on. Defaults to 'http://localhost'.

        It must be registered on the app registration (Entra admin center >
        App registrations > your app > Authentication > Add a platform >
        Mobile and desktop applications).

        Entra ID ignores the port when it matches a localhost redirect URI, so
        registering 'http://localhost' also covers 'http://localhost:1234'.
        Do not register several localhost URIs that differ only by port. The
        path is matched and is case-sensitive: 'http://localhost/MyApp' must
        be registered exactly like that. Use different paths to tell several
        localhost registrations apart.

        The system browser flow needs a loopback address, because MSAL listens
        on it. MSAL's documentation only describes 'http://localhost' and
        'http://localhost:<port>'. A path, '127.0.0.1' (recommended by Entra
        over 'localhost', but it can only be added through the app manifest)
        and 'https://localhost' are valid on the Entra side but are not
        described in MSAL's documentation, so test them first. '[::1]' is not
        supported by Entra ID. Addresses that are not loopback are rejected by
        MSAL with an "Only loopback redirect uri is supported" error and need
        a different sign-in flow, such as the embedded web view or WAM, which
        this module does not include.

    .PARAMETER LoginHintUpn
        A user principal name (UPN) to pre-fill the username/email field in the
        browser. It is only a hint, not a guarantee: the user can still change
        it or sign in with a different account.
        Useful for guest sign-ins, where it points to the right account in the
        target tenant, and to save users from typing their address.
        When a hint is given, the prompt behavior is set to NoPrompt, so Entra
        ID decides based on the hint and the browser cookies. If the browser
        already has a session for that account, sign-in can complete without
        asking for credentials. The hint is only shown as pre-filled when the
        browser has no signed-in session; otherwise Entra ID uses the session
        (or its account picker) and the hint does not appear.

    .PARAMETER PassThru
        Returns the connection as an object with the properties
        AuthenticationType, TenantId, ClientId, Username, Scopes, ExpiresOn
        and AccessToken, plus a CreateAuthorizationHeader() method that
        returns 'Bearer <token>'. This is the same object
        Get-MsalEssentialsToken returns.

        The access token is a credential. It is hidden from the default
        console display, but Format-List *, ConvertTo-Json, Export-Clixml and
        similar commands will include it. Don't log or share the object.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientId $clientId
        Opens the default browser for sign-in and stores the connection.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientId $clientId -LoginHintUpn 'user@hitboo.test'
        Opens the default browser for sign-in with a pre-filled username and stores the connection.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientId $clientId -Scopes 'User.Read' -TimeoutSeconds 60 -PassThru
        Requests only User.Read, gives up after 60 seconds, and returns the connection.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientId $clientId -RedirectUri 'http://localhost:1234'
        Listens on the fixed port 1234. 'http://localhost:1234' must be registered on the app.

    .EXAMPLE
        try {
            $connection = Connect-MsalEssentials -PassThru -TenantId $tenantId -ClientId $clientId -ErrorAction 'Stop'

            $request = @{
                Uri         = 'https://graph.microsoft.com/beta/me'
                Method      = 'GET'
                Headers     = @{ Authorization = $connection.CreateAuthorizationHeader() }
                ContentType = 'application/json'
            }

            $result = Invoke-RestMethod @request
        }
        catch {
            Write-Warning -Message $_.ErrorDetails.Message
        }
#>

function Connect-MsalEssentials {
    [CmdletBinding(DefaultParameterSetName = 'DelegatedSystemBrowser')]
    [OutputType('MsalEssentials.Connection')]
    param (
        # TenantId and ClientId have no parameter set, so they belong to every set.
        # When app / managed identity sets are added, move them into the sets that need them.
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientId,

        # Keep this default in sync with Get-MsalEssentialsDelegatedTokenSystemBrowser.
        # It is needed here because the scopes are stored for silent token renewal.
        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        # No default and no validation here: these live in the helper function.
        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [int]
        $TimeoutSeconds,

        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [string]
        $RedirectUri,

        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [string]
        $LoginHintUpn,

        [Parameter()]
        [switch]
        $PassThru
    )

    $authenticationResult    = $null
    $authenticationType      = $null
    $publicClientApplication = $null
    $requestedScopes         = $null

    switch ($PSCmdlet.ParameterSetName) {
        'DelegatedSystemBrowser' {
            $requestedScopes = [string[]]@($Scopes)

            $tokenParameters = @{
                TenantId             = $TenantId
                ClientId             = $ClientId
                Scopes               = $requestedScopes
                # Receives the MSAL client. Silent renewal needs the same client
                # instance, because the refresh token lives in its in-memory cache.
                ApplicationReference = [ref]$publicClientApplication
            }

            # Only pass optional parameters that were actually supplied, so
            # their defaults live in one place (the helper function).
            foreach ($optionalParameterName in 'TimeoutSeconds', 'RedirectUri', 'LoginHintUpn') {
                if ($PSBoundParameters.ContainsKey($optionalParameterName)) {
                    $tokenParameters[$optionalParameterName] = $PSBoundParameters[$optionalParameterName]
                }
            }

            $authenticationType = 'Delegated'

            # The helper throws a statement-terminating error. Without this
            # try/catch, execution would continue after a failed sign-in and
            # store an empty connection.
            try {
                $authenticationResult = Get-MsalEssentialsDelegatedTokenSystemBrowser @tokenParameters
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }

        # Future parameter sets go here, each setting $authenticationResult,
        # $authenticationType and $requestedScopes the same way:
        #   'AppCertificate'  -> client credentials with a certificate
        #   'AccessToken'     -> use an access token that was obtained elsewhere
        #   'ManagedIdentity' -> managed identity endpoint
    }

    if (-not $authenticationResult -or [string]::IsNullOrEmpty($authenticationResult.AccessToken)) {
        $noTokenRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('Sign-in completed but no access token was returned.'),
            'MsalEssentials.NoToken',
            [System.Management.Automation.ErrorCategory]::AuthenticationError,
            $null
        )
        $PSCmdlet.ThrowTerminatingError($noTokenRecord)
    }

    # Module-scope state. Only the values that cannot be derived are stored;
    # username, scopes and expiry are read from AuthenticationResult, so they
    # stay correct after a silent renewal replaces it. The raw
    # AuthenticationResult is never returned from this function (see the note
    # in the helper about printing the full AuthenticationResult).
    $script:MsalEssentialsSession = @{
        AuthenticationType      = $authenticationType
        TenantId                = $TenantId # as supplied, reused if a new sign-in is needed
        ClientId                = $ClientId
        RequestedScopes         = $requestedScopes
        PublicClientApplication = $publicClientApplication
        AuthenticationResult    = $authenticationResult
    }

    $username = if ($authenticationResult.Account) { $authenticationResult.Account.Username } else { $null }

    Write-Verbose -Message (
        'Connected as {0} ({1}), token expires {2}.' -f
            $(if ($username) { $username } else { 'application' }),
            $authenticationType,
            $authenticationResult.ExpiresOn
    )

    if ($PassThru) {
        ConvertTo-MsalEssentialsConnection -Session $script:MsalEssentialsSession
    }
}