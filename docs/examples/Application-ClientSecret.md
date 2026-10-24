# Application sign-in with a client secret

Signs in as the app itself with a client secret and lists users from Microsoft Graph. No browser opens.
The app registration needs a client secret and the application permission `User.Read.All` with admin consent, see [App registration](/README.md#application-permissions-sign-in-as-the-app).
A secret is a shared password that can leak. Prefer [a certificate](Application-Certificate.md) for production.

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# The directory (tenant) ID or verified domain. 'common' and 'organizations' do not work for application sign-in.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID registered in Entra ID.
[string]$ClientId = '00000000-0000-0000-0000-000000000000'
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    # The secret's Value (not the Secret ID) as a SecureString. Read-Host keeps it out of the script and the console history.
    # From a secret store instead: $ClientSecret = Get-Secret -Name 'MsalEssentialsApp' (Microsoft.PowerShell.SecretManagement)
    $ClientSecret = Read-Host -Prompt 'Client secret' -AsSecureString

    # Get an MSAL token for the app itself. Application permissions always use '<resource>/.default';
    # 'https://graph.microsoft.com/.default' is the default, so -Scopes can be left out here.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -ErrorAction 'Stop'

    # If the request might happen later or takes longer, make sure to have a valid token.
    # Get-MsalEssentialsToken requests a new token with the same secret if it expires in less than 5 minutes (the default).
    $MsalEssentialsConnection = Get-MsalEssentialsToken -ErrorAction 'Stop'

    $MicrosoftGraphRequest = @{
        Uri     = 'https://graph.microsoft.com/v1.0/users?$top=5&$select=displayName,userPrincipalName' # Needs the application permission User.Read.All.
        Method  = 'GET'
        Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() } # Use the MSAL token to authorize the request.
    }

    # Invoke the Microsoft Graph request using the MSAL token.
    $MicrosoftGraphResult = Invoke-RestMethod @MicrosoftGraphRequest
    $MicrosoftGraphResult.value
}
catch {
    Write-Warning -Message $_
}
finally {
    # Clean up once done: clear the connection and remove the variables that hold the token and the secret.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection', 'ClientSecret' -ErrorAction 'SilentlyContinue'
}
#endregion Connect to Microsoft Graph via MSAL.Essentials
```

[Back to README](/README.md#how-to-use-it)
