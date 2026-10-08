<#
    .SYNOPSIS
        Returns the current connection with a valid access token, renewing the
        token silently if it expires soon.

    .DESCRIPTION
        Looks at the connection stored by Connect-MsalEssentials:

        1. Token expires in more than -RefreshBeforeExpiryMinutes (default 15):
           returns the stored token unchanged.
        2. Token expires in -RefreshBeforeExpiryMinutes or less: gets a new
           token silently, without opening a browser, using the MSAL client
           and refresh token kept from the original sign-in.

        This function never signs in. It does not open a browser, and it does
        not take a tenant, client or credentials. Signing in is the job of
        Connect-MsalEssentials, whatever the authentication method. If this
        function cannot return a valid token it fails with a terminating
        error that tells you to run Connect-MsalEssentials again:

            MsalEssentials.NotConnected        no connection exists yet
            MsalEssentials.ReconnectRequired   the token expired and silent
                                               renewal needs a new sign-in
                                               (refresh token expired or
                                               revoked, Conditional Access
                                               asks for a new sign-in, ...)
            MsalEssentials.RenewalNotSupported the connection type cannot be
                                               renewed by this function yet
            (any other error from a failed silent renewal is passed through
            unchanged)

        If renewal fails but the current token has not expired yet, the
        current token is still returned and a warning explains why renewal
        failed. The next call tries to renew again.

        The returned object is the same one Connect-MsalEssentials -PassThru
        returns: AuthenticationType, TenantId, ClientId, Username, Scopes,
        ExpiresOn and AccessToken, plus a CreateAuthorizationHeader() method.
        The access token is hidden from the default console display but is
        still a credential: Format-List *, ConvertTo-Json and Export-Clixml
        will show it.

    .PARAMETER RefreshBeforeExpiryMinutes
        Renew the token when it expires within this many minutes. Defaults
        to 15. Use 0 to renew only once the token has expired.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId
        $connection = Get-MsalEssentialsToken
        Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = $connection.CreateAuthorizationHeader() }
        Signs in once, then gets the token before each request; it is renewed silently when it expires soon.

    .EXAMPLE
        (Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 30).AccessToken
        Returns only the access token string, renewing it if it expires within 30 minutes.

    .EXAMPLE
        try {
            $connection = Get-MsalEssentialsToken -ErrorAction Stop
        }
        catch {
            Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId -ErrorAction Stop
            $connection = Get-MsalEssentialsToken -ErrorAction Stop
        }
        Lets the caller decide how to sign in again when there is no usable token.
#>

function Get-MsalEssentialsToken {
    [CmdletBinding()]
    [OutputType('MsalEssentials.Connection')]
    param (
        [Parameter()]
        [ValidateRange(0, 1440)]
        [int]
        $RefreshBeforeExpiryMinutes = 15
    )

    $session = Get-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ValueOnly -ErrorAction 'SilentlyContinue'

    if (-not $session -or -not $session.AuthenticationResult) {
        $notConnectedRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('Not connected. Run Connect-MsalEssentials first.'),
            'MsalEssentials.NotConnected',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null
        )
        $PSCmdlet.ThrowTerminatingError($notConnectedRecord)
    }

    $remainingTime = $session.AuthenticationResult.ExpiresOn - [System.DateTimeOffset]::UtcNow

    if ($remainingTime.TotalMinutes -le $RefreshBeforeExpiryMinutes) {
        Write-Verbose -Message ('Token expires in {0:N1} minutes (limit {1}), renewing silently.' -f $remainingTime.TotalMinutes, $RefreshBeforeExpiryMinutes)

        $renewalError = $null

        switch ($session.AuthenticationType) {
            'Delegated' {
                try {
                    # AcquireTokenSilent needs the scopes and the account from the original sign-in, which are stored in the session. 
                    $session.AuthenticationResult = $session.PublicClientApplication.AcquireTokenSilent(
                        [string[]]$session.RequestedScopes,
                        $session.AuthenticationResult.Account
                    ).WithForceRefresh(
                        $true 
                        # ForceRefresh is needed to get a new token. 
                        # Otherwise MSAL only returns a token if the expiration is less than 5 minutes away, which is not enough for this function.
                        # See https://learn.microsoft.com/en-us/dotnet/api/microsoft.identity.client.clientapplicationbase.acquiretokensilent?view=msal-dotnet-latest#remarks
                    ).ExecuteAsync().GetAwaiter().GetResult()
                }
                catch {
                    $renewalError = $_
                }
            }

            # Future authentication types are renewed here, for example:
            #   'AppCertificate'  -> call AcquireTokenForClient again
            #   'ManagedIdentity' -> request a new token from the endpoint
            # Renewal must never start an interactive sign-in.
            default {
                $renewalError = [System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new(('Renewing a "{0}" connection is not supported.' -f $session.AuthenticationType)),
                    'MsalEssentials.RenewalNotSupported',
                    [System.Management.Automation.ErrorCategory]::NotImplemented,
                    $null
                )
            }
        }

        if ($renewalError) {
            # PowerShell wraps exceptions from directly-called .NET methods in a
            # MethodInvocationException, so look through the whole chain for the
            # MSAL exception that says a new sign-in is needed.
            $uiRequiredException = $null
            $innermostException  = $renewalError.Exception
            $currentException    = $renewalError.Exception
            while ($currentException) {
                if (-not $uiRequiredException -and $currentException -is [Microsoft.Identity.Client.MsalUiRequiredException]) {
                    $uiRequiredException = $currentException
                }
                $innermostException = $currentException
                $currentException   = $currentException.InnerException
            }

            $reasonException = if ($uiRequiredException) { $uiRequiredException } else { $innermostException }
            $reason          = ($reasonException.Message -split '\r?\n')[0]

            if ($remainingTime.TotalSeconds -gt 0) {
                # The current token still works, so keep the caller going.
                Write-Warning -Message (
                    'The access token could not be renewed and expires in {0:N1} minutes (reason: {1}). Run Connect-MsalEssentials to sign in again.' -f
                        $remainingTime.TotalMinutes,
                        $reason
                )
            }
            elseif ($uiRequiredException) {
                $reconnectRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        ('The access token has expired and could not be renewed silently (reason: {0}). Run Connect-MsalEssentials to sign in again.' -f $reason),
                        $uiRequiredException
                    ),
                    'MsalEssentials.ReconnectRequired',
                    [System.Management.Automation.ErrorCategory]::AuthenticationError,
                    $null
                )
                $PSCmdlet.ThrowTerminatingError($reconnectRecord)
            }
            else {
                $PSCmdlet.ThrowTerminatingError($renewalError)
            }
        }
    }

    ConvertTo-MsalEssentialsConnection -Session $session
}