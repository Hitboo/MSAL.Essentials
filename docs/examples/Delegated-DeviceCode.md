# Delegated sign-in with a device code (not recommended)

Signs in as a user with a device code and reads the signed-in user from Microsoft Graph.
You open the page from the message on any device, enter the code and sign in there.

> [!WARNING]
> **Not recommended. Use the [browser sign-in](Delegated-SystemBrowser.md) wherever you can.**
> The device code flow is only included for compatibility, for sessions that can't open a browser (SSH, a server core installation, a container).
>
> - **Phishing:** device codes are a common phishing method. An attacker starts a sign-in and sends you the code, for example as a "please verify your account" message. Whoever enters the code signs in the attacker's session, and the page looks like a normal Microsoft sign-in. Only enter a code that you requested yourself, a moment ago, in your own session.
> - **Often blocked:** Microsoft recommends blocking the device code flow wherever possible, with the Conditional Access condition *Authentication flows*. In such a tenant the sign-in fails with `MsalEssentials.ConditionalAccess`, usually with `AADSTS53003` (blocked by Conditional Access).
>
> See [Authentication flows in Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-authentication-flows) and [Block authentication flows with Conditional Access policy](https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-authentication-flows).

The app registration needs **Allow public client flows** set to **Yes**, see [App registration](/README.md#device-code-not-recommended). No redirect URI is needed.

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# The directory (tenant) ID or verified domain to authenticate against.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID registered in Entra ID. It needs "Allow public client flows" set to Yes.
[string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools (for testing)
# Permission scopes to request. 'User.Read' is enough for the request below.
[string[]]$Scopes = @('User.Read')
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    # Shows a message with a page and a code. Open the page on any device, enter the code and sign in.
    # The command waits until the sign-in is done, the code expires (usually after 15 minutes) or -TimeoutSeconds (default 300, at most 900) runs out.
    # The token is only kept in memory for this PowerShell session.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -Scopes $Scopes -UseDeviceCode -ErrorAction 'Stop'

    # If the request might happen later or takes longer, make sure to have a valid token.
    # Get-MsalEssentialsToken renews the token silently, like after a browser sign-in: no new device code is needed.
    $MsalEssentialsConnection = Get-MsalEssentialsToken -ErrorAction 'Stop'

    $MicrosoftGraphRequest = @{
        Uri     = 'https://graph.microsoft.com/v1.0/me' # Microsoft Graph endpoint to get info about the signed-in user.
        Method  = 'GET'
        Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() } # Use the MSAL token to authorize the request.
    }

    # Invoke the Microsoft Graph request using the MSAL token.
    $MicrosoftGraphResult = Invoke-RestMethod @MicrosoftGraphRequest
    $MicrosoftGraphResult
}
catch {
    # MsalEssentials.ConditionalAccess (AADSTS53003) usually means the tenant blocks the device code flow.
    Write-Warning -Message $_
}
finally {
    # Clean up once done: clear the connection and remove the variable that holds the token.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection' -ErrorAction 'SilentlyContinue'
}
#endregion Connect to Microsoft Graph via MSAL.Essentials
```

The message comes from Entra ID and looks like this (the page and the wording can differ):

```text
To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code ABCD1234 to authenticate.
```

It is written with `Write-Host`, so it is shown even when `$InformationPreference` is `SilentlyContinue`. Redirect stream 6 (`6>&1`) to capture it.

The code is also copied to the clipboard, followed by the line `The code is copied to the clipboard.`, so you can paste it on the sign-in page. If the clipboard can't be set, only the message is shown. In a remote session (SSH, PowerShell remoting) the code may land on the remote computer's clipboard instead of yours, so type it from the message.

## Sources

- [Microsoft identity platform and the OAuth 2.0 device authorization grant flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Device code flow (MSAL.NET)](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/desktop-mobile/device-code-flow)
- [Authentication flows in Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-authentication-flows)

[Back to README](/README.md#how-to-use-it)
