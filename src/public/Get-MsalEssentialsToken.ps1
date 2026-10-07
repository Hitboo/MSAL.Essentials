<#
    .SYNOPSIS
        Returns the current connection with a valid access token, signing in
        or renewing the token first if needed.

    .DESCRIPTION
        Looks at the connection stored by Connect-MsalEssentials:

        1. No connection yet: signs in with Connect-MsalEssentials. This needs
           -TenantId and -ClientID; without them the function throws an error
           that asks you to run Connect-MsalEssentials first.
        2. Token expires in -RefreshBeforeExpiryMinutes or less (default 15):
           gets a new token silently, without opening a browser, using the
           MSAL client and refresh token kept from the original sign-in.
        3. Otherwise: returns the stored token unchanged.

        If the silent renewal needs user interaction (for example the refresh
        token expired or was revoked, or a Conditional Access policy asks for
        a new sign-in), the function falls back to an interactive sign-in in
        the default browser with the stored tenant, client and scopes.

        The returned object is the same one Connect-MsalEssentials -PassThru
        returns: AuthenticationType, TenantId, ClientId, Username, Scopes,
        ExpiresOn and AccessToken, plus a CreateAuthorizationHeader() method.
        The access token is hidden from the default console display but is
        still a credential: Format-List *, ConvertTo-Json and Export-Clixml
        will show it.

    .PARAMETER RefreshBeforeExpiryMinutes
        Renew the token when it expires within this many minutes. Defaults
        to 15. Use 0 to renew only once the token has expired.

    .PARAMETER TenantId
        Only used when there is no connection yet: the tenant to sign in to.
        Ignored if a connection exists.

    .PARAMETER ClientID
        Only used when there is no connection yet: the application (client)
        ID to sign in with. Ignored if a connection exists.

    .PARAMETER Scopes
        Only used when there is no connection yet: the delegated scopes to
        request. Ignored if a connection exists, which keeps using the scopes
        it was created with.

    .PARAMETER TimeoutSeconds
        Only used when an interactive sign-in is needed: how long to wait for
        it to complete. If omitted, the default of
        Get-MsalEssentialsDelegatedTokenSystemBrowser is used.

    .EXAMPLE
        $connection = Get-MsalEssentialsToken
        Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me' -Headers @{ Authorization = $connection.CreateAuthorizationHeader() }
        Uses the existing connection, renewing the token first if it expires soon.

    .EXAMPLE
        $connection = Get-MsalEssentialsToken -TenantId $tenantId -ClientID $clientId
        Signs in if there is no connection yet, otherwise behaves like the previous example.

    .EXAMPLE
        (Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 30).AccessToken
        Returns only the access token string, renewing it if it expires within 30 minutes.
#>

function Get-MsalEssentialsToken {
    [CmdletBinding()]
    [OutputType('MsalEssentials.Connection')]
    param (
        [Parameter()]
        [ValidateRange(0, 1440)]
        [int]
        $RefreshBeforeExpiryMinutes = 15,

        [Parameter()]
        [string]
        $TenantId,

        [Parameter()]
        [string]
        $ClientID,

        [Parameter()]
        [string[]]
        $Scopes,

        [Parameter()]
        [int]
        $TimeoutSeconds
    )

    $session = Get-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ValueOnly -ErrorAction 'SilentlyContinue'

    # 1. No connection yet: sign in, if we were told where to.
    if (-not $session -or -not $session.AuthenticationResult) {
        if (-not ($TenantId -and $ClientID)) {
            $notConnectedRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Not connected. Run Connect-MsalEssentials first, or pass -TenantId and -ClientID to sign in now.'),
                'MsalEssentials.NotConnected',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )
            $PSCmdlet.ThrowTerminatingError($notConnectedRecord)
        }

        $connectParameters = @{
            TenantId = $TenantId
            ClientID = $ClientID
        }
        foreach ($optionalParameterName in 'Scopes', 'TimeoutSeconds') {
            if ($PSBoundParameters.ContainsKey($optionalParameterName)) {
                $connectParameters[$optionalParameterName] = $PSBoundParameters[$optionalParameterName]
            }
        }

        Write-Verbose -Message 'No connection found, signing in.'

        # Connect-MsalEssentials throws a statement-terminating error; without
        # try/catch this function would carry on with an empty session.
        try {
            Connect-MsalEssentials @connectParameters -ErrorAction Stop
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $session = Get-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ValueOnly
    }

    # 2. Token expires soon: renew it silently.
    $remainingTime = $session.AuthenticationResult.ExpiresOn - [System.DateTimeOffset]::UtcNow

    if ($remainingTime.TotalMinutes -le $RefreshBeforeExpiryMinutes) {
        Write-Verbose -Message ('Token expires in {0:N1} minutes (limit {1}), renewing.' -f $remainingTime.TotalMinutes, $RefreshBeforeExpiryMinutes)

        $interactiveSignInRequired = $false

        switch ($session.AuthenticationType) {
            'Delegated' {
                try {
                    $session.AuthenticationResult = $session.PublicClientApplication.AcquireTokenSilent(
                        [string[]]$session.RequestedScopes,
                        $session.AuthenticationResult.Account
                    ).ExecuteAsync().GetAwaiter().GetResult()
                }
                catch {
                    # PowerShell wraps exceptions from directly-called .NET methods in a
                    # MethodInvocationException, so look through the whole chain.
                    $silentFailure    = $_
                    $currentException = $_.Exception
                    $uiRequired       = $false
                    while ($currentException) {
                        if ($currentException -is [Microsoft.Identity.Client.MsalUiRequiredException]) {
                            $uiRequired = $true
                            break
                        }
                        $currentException = $currentException.InnerException
                    }

                    if ($uiRequired) {
                        Write-Verbose -Message ('Silent renewal needs interaction: {0}' -f $currentException.Message)
                        $interactiveSignInRequired = $true
                    }
                    else {
                        $PSCmdlet.ThrowTerminatingError($silentFailure)
                    }
                }
            }

            # Future authentication types are renewed here, for example:
            #   'AppCertificate'  -> call AcquireTokenForClient again
            #   'ManagedIdentity' -> request a new token from the endpoint
            default {
                $notSupportedRecord = [System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new(('Renewing a "{0}" connection is not supported.' -f $session.AuthenticationType)),
                    'MsalEssentials.RenewalNotSupported',
                    [System.Management.Automation.ErrorCategory]::NotImplemented,
                    $null
                )
                $PSCmdlet.ThrowTerminatingError($notSupportedRecord)
            }
        }

        # 3. Silent renewal is not possible: sign in again with the stored settings.
        if ($interactiveSignInRequired) {
            $connectParameters = @{
                TenantId = $session.TenantId
                ClientID = $session.ClientId
                Scopes   = $session.RequestedScopes
            }
            if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) {
                $connectParameters['TimeoutSeconds'] = $TimeoutSeconds
            }

            try {
                Connect-MsalEssentials @connectParameters -ErrorAction Stop
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $session = Get-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ValueOnly
        }
    }

    ConvertTo-MsalEssentialsConnection -Session $session
}