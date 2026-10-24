# Application sign-in with a certificate

Signs in as the app itself with a certificate and lists users from Microsoft Graph. No browser opens, so this works in unattended scripts.
The app registration needs the public part of the certificate and the application permission `User.Read.All` with admin consent, see [App registration](/README.md#application-permissions-sign-in-as-the-app).
No certificate yet? See [Create a certificate for testing](Create-TestCertificate.md).

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# The directory (tenant) ID or verified domain. 'common' and 'organizations' do not work for application sign-in.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID registered in Entra ID.
[string]$ClientId = '00000000-0000-0000-0000-000000000000'
# The thumbprint of the certificate. The certificate, with its private key, must be in the current user's store.
[string]$CertificateThumbprint = '0000000000000000000000000000000000000000'
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    # Load the certificate with its private key from the store. A PFX file works too:
    # $Certificate = Get-PfxCertificate -FilePath 'C:\certs\app.pfx'
    $Certificate = Get-Item -Path ('Cert:\CurrentUser\My\{0}' -f $CertificateThumbprint) -ErrorAction 'Stop'

    # Get an MSAL token for the app itself. Application permissions always use '<resource>/.default';
    # 'https://graph.microsoft.com/.default' is the default, so -Scopes can be left out here.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -Certificate $Certificate -ErrorAction 'Stop'

    # If the request might happen later or takes longer, make sure to have a valid token.
    # Get-MsalEssentialsToken requests a new token with the same certificate if it expires in less than 5 minutes (the default).
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
    # Clean up once done: clear the connection and remove the variable that holds the token.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection' -ErrorAction 'SilentlyContinue'
}
#endregion Connect to Microsoft Graph via MSAL.Essentials
```

[Back to README](/README.md#how-to-use-it)
