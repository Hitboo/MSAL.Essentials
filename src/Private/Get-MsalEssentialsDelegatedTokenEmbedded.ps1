<#
    .SYNOPSIS
        Acquires a delegated token interactively, using MSAL's embedded web
        view (a popup window rendering the Microsoft sign-in page inside the
        process, via WebView2 on .NET Framework, or the equivalent control
        on .NET).

    .DESCRIPTION
        Does not use the Windows broker (WAM) or the system browser - the
        sign-in UI is drawn inside a popup owned by this process. This needs
        no extra setup beyond the DLLs already shipped in lib\, unlike WAM
        (Microsoft.Identity.Client.Broker, a separate package with further
        native dependencies) or the system browser flow (needs a reachable
        loopback redirect).

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientId
        The application (client) ID registered in Entra ID.
        Use '14d82eec-204b-4c2f-b7e8-296a70dab67e' for Microsoft Graph Command Line Tools (not recommended for production).

    .PARAMETER Scopes
        The delegated scopes to request. Defaults to Microsoft Graph's
        default scope set.

    .EXAMPLE
        Get-MsalEssentialsDelegatedTokenEmbedded -TenantId $tenantId -ClientID $clientId -Scopes 'User.Read'
        Opens an embedded sign-in popup and returns the resulting token.
#>

function Get-MsalEssentialsDelegatedTokenEmbedded {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientID,

        [Parameter()]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default')
    )

    try {
        $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
            $ClientID
        ).WithAuthority(
            ('https://login.microsoftonline.com/{0}' -f $TenantId)
        ).WithDefaultRedirectUri().Build()

        # Explicit even though $true is already the default on .NET Framework,
        # so this function's behavior doesn't silently change if MSAL's
        # default ever flips, or if this code path gets reused on .NET.
        $authenticationResult = $publicClientApplication.AcquireTokenInteractive(
            $Scopes
        ).WithUseEmbeddedWebView(
            $true
        ).ExecuteAsync().GetAwaiter().GetResult()

        return $authenticationResult
    }
    catch {
        # PowerShell wraps exceptions thrown by a directly-called .NET method
        # (like GetResult() here) in a MethodInvocationException, so the
        # real MSAL exception (e.g. MsalClientException, MsalServiceException)
        # is one or more levels down in InnerException, not in $_.Exception
        # itself. Unwrap it so the caller sees the actual cause.
        $innermostException = $_.Exception
        while ($innermostException.InnerException) {
            $innermostException = $innermostException.InnerException
        }

        throw $innermostException
    }
}