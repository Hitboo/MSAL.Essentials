<#
    .SYNOPSIS
        Clears the connection stored by Connect-MsalEssentials.

    .DESCRIPTION
        Removes the accounts and tokens from the MSAL client's in-memory token
        cache, then removes the stored connection from module scope. After
        this, Get-MsalEssentialsToken fails with MsalEssentials.NotConnected
        until Connect-MsalEssentials is run again.

        If there is no connection, nothing happens and no error is raised.

        What this command cannot clear:

        - Variables in your own session that hold the token. Connect-
          MsalEssentials -PassThru and Get-MsalEssentialsToken return the
          access token, so anything you assigned it to still contains it:
          for example $connection, or a request hashtable such as
          $request.Headers.Authorization built from
          $connection.CreateAuthorizationHeader(). Remove them yourself,
          for example:
              Remove-Variable -Name connection, request
          or set them to $null. Closing the PowerShell session removes
          everything. .NET strings can't be securely wiped, so dropping the
          references is the most that can be done.
        - The browser session. Entra ID keeps sign-in cookies in the browser,
          so the next Connect-MsalEssentials may sign in without a prompt.
          Sign out in the browser (https://login.microsoftonline.com/logout.srf)
          if you need to prevent that.
        - A token that was already issued. It stays valid until it expires
          (about an hour by default) and can't be revoked from the client.
          An administrator can invalidate refresh tokens, for example with
          Revoke-MgUserSignInSession.

        When a connection was cleared, a hint about the token variables is
        shown. Use -InformationAction SilentlyContinue to hide it.

    .EXAMPLE
        Disconnect-MsalEssentials
        Clears the connection and shows the hint about token variables.

    .EXAMPLE
        $connection = Get-MsalEssentialsToken
        # ... use $connection.CreateAuthorizationHeader() ...
        Disconnect-MsalEssentials
        Remove-Variable -Name connection
        Clears the connection, then removes the variable that held the token.

    .EXAMPLE
        Disconnect-MsalEssentials -InformationAction SilentlyContinue
        Clears the connection without showing the hint.
#>

function Disconnect-MsalEssentials {
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    $session = Get-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ValueOnly -ErrorAction 'SilentlyContinue'

    if (-not $session) {
        Write-Verbose -Message 'Not connected, nothing to disconnect.'
        return
    }

    # Remove the accounts (and with them the cached tokens) from the MSAL
    # client. The client is dropped below anyway; this clears the cache now
    # instead of waiting for garbage collection. A failure here must not
    # stop the session from being cleared.
    # Only delegated connections have accounts. An application connection has
    # no user account to remove; dropping its client clears its token cache.
    if ($session.AuthenticationType -eq 'Delegated' -and $session.ClientApplication) {
        try {
            $accounts = $session.ClientApplication.GetAccountsAsync().GetAwaiter().GetResult()
            foreach ($account in $accounts) {
                # Discard the VoidTaskResult that RemoveAsync returns, so it isn't written to the pipeline.
                $null = $session.ClientApplication.RemoveAsync($account).GetAwaiter().GetResult()
            }
        }
        catch {
            $innermostException = $_.Exception
            while ($innermostException.InnerException) {
                $innermostException = $innermostException.InnerException
            }
            Write-Warning -Message ('Could not clear the MSAL token cache: {0}' -f $innermostException.Message)
        }
    }

    Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'

    Write-Verbose -Message 'Connection cleared.'

    # Show the hint by default, but let the caller hide it with
    # -InformationAction (which sets $InformationPreference in this scope).
    if (-not $PSBoundParameters.ContainsKey('InformationAction')) {
        $InformationPreference = 'Continue'
    }

    Write-Information -MessageData (
        'MSAL.Essentials disconnected. Variables that hold the token (for example the result of Connect-MsalEssentials -PassThru or ' +
        'Get-MsalEssentialsToken, or a request header built from it) are not cleared by this command. ' +
        'Remove them yourself, for example: Remove-Variable -Name connection'
    )
}