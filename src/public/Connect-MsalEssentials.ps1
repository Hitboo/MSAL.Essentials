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
        terminating error for the command, so use -ErrorAction Stop or
        try/catch in scripts to make sure nothing runs after a failed sign-in.

        Currently supported:
            DelegatedSystemBrowser   interactive sign-in as a user (default)

        Planned parameter sets (not implemented yet):
            AppCertificate, AccessToken, ManagedIdentity

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientID
        The application (client) ID registered in Entra ID.

    .PARAMETER Scopes
        The delegated scopes to request. Defaults to Microsoft Graph's default
        scope set. The same scopes are used when the token is renewed.

    .PARAMETER TimeoutSeconds
        How long to wait for the interactive sign-in to complete. If omitted,
        the default of Get-MsalEssentialsDelegatedTokenSystemBrowser is used.

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
        Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId
        Opens the default browser for sign-in and stores the connection.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId -Scopes 'User.Read' -TimeoutSeconds 60 -PassThru
        Requests only User.Read, gives up after 60 seconds, and returns the connection.

    .EXAMPLE
        try {
            $connection = Connect-MsalEssentials -PassThru -TenantId $tenantId -ClientID $clientId -ErrorAction 'Stop'

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
        # TenantId and ClientID have no parameter set, so they belong to every set.
        # When app / managed identity sets are added, move them into the sets that need them.
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientID,

        # Keep this default in sync with Get-MsalEssentialsDelegatedTokenSystemBrowser.
        # It is needed here because the scopes are stored for silent token renewal.
        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [int]
        $TimeoutSeconds,

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
                ClientID             = $ClientID
                Scopes               = $requestedScopes
                # Receives the MSAL client. Silent renewal needs the same client
                # instance, because the refresh token lives in its in-memory cache.
                ApplicationReference = [ref]$publicClientApplication
            }

            # Only pass the timeout if it was supplied, so its default lives in
            # one place (the helper function).
            if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) {
                $tokenParameters['TimeoutSeconds'] = $TimeoutSeconds
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
        ClientId                = $ClientID
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