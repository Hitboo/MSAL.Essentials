# Delegated sign-in through the browser

Signs in as the current user through the default browser and reads the signed-in user from Microsoft Graph.
The app registration needs the redirect URI `http://localhost`, see [App registration](/README.md#delegated-permissions-sign-in-as-a-user).

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# The directory (tenant) ID or verified domain to authenticate against.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID registered in Entra ID.
[string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools (for testing)
# Permission scopes to request. 'User.Read' is enough for the request below.
# 'https://graph.microsoft.com/.default' returns all delegated permissions that are already granted to the app.
[string[]]$Scopes = @('User.Read')
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    # Get an MSAL token via the interactive system browser. The token is only kept in memory for this PowerShell session.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -Scopes $Scopes -ErrorAction 'Stop'

    # If the request might happen later or takes longer, make sure to have a valid token.
    # Get-MsalEssentialsToken tries to get a new token silently if it expires in less than 5 minutes (the default).
    $MsalEssentialsConnection = Get-MsalEssentialsToken -ErrorAction 'Stop'

    $MicrosoftGraphRequest = @{
        Uri     = 'https://graph.microsoft.com/beta/me' # Microsoft Graph endpoint to get info about the signed-in user.
        Method  = 'GET'
        Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() } # Use the MSAL token to authorize the request.
    }

    # Invoke the Microsoft Graph request using the MSAL token.
    $MicrosoftGraphResult = Invoke-RestMethod @MicrosoftGraphRequest
    $MicrosoftGraphResult
}
catch {
    Write-Warning -Message $_
}
finally {
    # Clean up once done: clear the connection and remove the variable that holds the token.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection' -ErrorAction 'SilentlyContinue'
}
#endregion Connect to Microsoft Graph via MSAL.Essentials
```

[Back to README](/README.md#how-to-use-it)
