# Managed identity sign-in

Signs in as the managed identity of the Azure resource the script runs on (Azure VM, App Service, Azure Functions, Azure Arc-enabled server, ...) and lists users from Microsoft Graph. No tenant, secret, certificate or browser is needed.
The managed identity must be turned on for the resource and needs the Microsoft Graph application permission `User.Read.All`, see [Managed identity](/README.md#managed-identity-sign-in-as-the-azure-resource) and [Grant Microsoft Graph permissions to a managed identity](Grant-ManagedIdentityGraphPermission.md).

A managed identity only exists on its Azure resource. On your own computer the sign-in fails with `MsalEssentials.ManagedIdentityUnavailable`; use [application sign-in](Application-Certificate.md) there instead.

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# Leave empty to use the system-assigned managed identity of this resource.
# For a user-assigned managed identity, enter its client ID (Azure portal > Managed Identities > your identity > Overview).
[string]$UserAssignedClientId = ''
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    $ConnectParameters = @{
        ManagedIdentity = $true
        PassThru        = $true
        ErrorAction     = 'Stop'
    }
    if ($UserAssignedClientId) {
        # With -ClientId the user-assigned managed identity with that client ID is used.
        $ConnectParameters['ClientId'] = $UserAssignedClientId
    }

    # Get an MSAL token for the managed identity. Like application sign-in, it uses one scope that ends with '/.default';
    # 'https://graph.microsoft.com/.default' is the default, so -Scopes can be left out here.
    $MsalEssentialsConnection = Connect-MsalEssentials @ConnectParameters

    # If the request might happen later or takes longer, make sure to have a valid token.
    # Get-MsalEssentialsToken asks the managed identity endpoint for a new token if it expires in less than 5 minutes (the default).
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

Other resources than Microsoft Graph need their own scope and permission, for example Azure Key Vault with `-Scopes 'https://vault.azure.net/.default'` and an Azure role on the vault.

[Back to README](/README.md#how-to-use-it)
