# Grant Microsoft Graph permissions to a managed identity

Gives a managed identity the Microsoft Graph application permission `User.Read.All`, so the [managed identity example](ManagedIdentity.md) can list users.
A managed identity has no app registration, so the Azure portal has no **API permissions** page for it. The permission is granted as an app role assignment on the identity's service principal through the Microsoft Graph API ([Grant an appRoleAssignment for a service principal](https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignedto?view=graph-rest-1.0)).

This script uses MSAL.Essentials itself: you sign in as an administrator through the browser, then the script calls Microsoft Graph.

- **Who can run it:** granting Microsoft Graph application permissions needs the **Privileged Role Administrator** role (the least privileged role for Microsoft Graph app roles).
- **Delegated permissions:** `Application.Read.All` and `AppRoleAssignment.ReadWrite.All`. The Microsoft Graph Command Line Tools app asks for consent on the first sign-in.
- **Where to find the object ID:**
  - System-assigned: Azure portal > your resource (for example the VM) > **Identity** > **System assigned** > **Object (principal) ID**.
  - User-assigned: Azure portal > **Managed Identities** > your identity > **Overview** > **Object (principal) ID**. This is not the client ID.

Run it on your own computer, not on the Azure resource.

```powershell
# Install the module first, see "Install" in the README.
Import-Module -Name 'MSAL.Essentials'

#region Settings
# The directory (tenant) ID or verified domain.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID used to sign in as the administrator.
[string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools
# The object (principal) ID of the managed identity, see above.
[string]$ManagedIdentityObjectId = '00000000-0000-0000-0000-000000000000'
# The Microsoft Graph application permission to grant.
[string]$PermissionName = 'User.Read.All'
#endregion Settings

#region Grant the permission via MSAL.Essentials
try {
    # Sign in as an administrator through the browser with the permissions needed to read and assign app roles.
    $connectParameters = @{
        TenantId    = $TenantId
        ClientId    = $ClientId
        Scopes      = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All')
        PassThru    = $true
        ErrorAction = 'Stop'
    }
    $MsalEssentialsConnection = Connect-MsalEssentials @connectParameters
    $Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() }

    # The service principal of the managed identity. This also checks that the object ID is right.
    $managedIdentityRequest = @{
        Uri     = 'https://graph.microsoft.com/v1.0/servicePrincipals/{0}?$select=id,displayName' -f $ManagedIdentityObjectId
        Method  = 'GET'
        Headers = $Headers
    }
    $ManagedIdentity = Invoke-RestMethod @managedIdentityRequest

    # The service principal of Microsoft Graph in your tenant. Its app ID is the same in every tenant.
    $graphRequest = @{
        Uri     = "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id,appRoles"
        Method  = 'GET'
        Headers = $Headers
    }
    $MicrosoftGraph = Invoke-RestMethod @graphRequest

    # The application permission is an app role of Microsoft Graph with this name.
    $AppRole = $MicrosoftGraph.appRoles | Where-Object -FilterScript {
        $_.value -eq $PermissionName -and $_.allowedMemberTypes -contains 'Application'
    }
    if (-not $AppRole) {
        throw ('Microsoft Graph has no application permission named {0}.' -f $PermissionName)
    }

    # Skip the grant if the managed identity already has the permission.
    $assignmentsRequest = @{
        Uri     = 'https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignments' -f $ManagedIdentity.id
        Method  = 'GET'
        Headers = $Headers
    }
    $existingAssignment = (Invoke-RestMethod @assignmentsRequest).value | Where-Object -FilterScript {
        $_.resourceId -eq $MicrosoftGraph.id -and $_.appRoleId -eq $AppRole.id
    }

    if ($existingAssignment) {
        $Status = 'Already granted'
        $Assignment = $existingAssignment
    }
    else {
        # Assign the app role: who gets it (principalId), whose role it is (resourceId) and which role (appRoleId).
        $grantRequest = @{
            Uri         = 'https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignedTo' -f $MicrosoftGraph.id
            Method      = 'POST'
            Headers     = $Headers
            ContentType = 'application/json'
            Body        = @{
                principalId = $ManagedIdentity.id
                resourceId  = $MicrosoftGraph.id
                appRoleId   = $AppRole.id
            } | ConvertTo-Json
        }
        $Status = 'Granted'
        $Assignment = Invoke-RestMethod @grantRequest
    }

    # Keep the assignment ID and the Microsoft Graph service principal ID: you need both to remove the permission again.
    [pscustomobject]@{
        ManagedIdentity                  = $ManagedIdentity.displayName
        Permission                       = $PermissionName
        Status                           = $Status
        AssignmentId                     = $Assignment.id
        MicrosoftGraphServicePrincipalId = $MicrosoftGraph.id
    }
}
catch {
    Write-Warning -Message $_
}
finally {
    # Clean up once done: clear the connection and remove the variables that hold the token.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection', 'Headers' -ErrorAction 'SilentlyContinue'
}
#endregion Grant the permission via MSAL.Essentials
```

The new permission can take a while to show up in the managed identity's token. The managed identity back end caches tokens per resource for around 24 hours, and a token can't be renewed early, so it can take several hours ([Managed identity best practices](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations)).

To check the permissions later, list them in the Microsoft Entra admin center: **Enterprise applications**, set the filter **Application type** to **Managed Identities**, open the identity and choose **Permissions**.

To take the permission away again, sign in the same way and delete the assignment with the two IDs from the output ([Delete appRoleAssignedTo](https://learn.microsoft.com/graph/api/serviceprincipal-delete-approleassignedto?view=graph-rest-1.0)):

```powershell
$MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -Scopes 'AppRoleAssignment.ReadWrite.All' -ErrorAction 'Stop'
$removeRequest = @{
    Uri     = 'https://graph.microsoft.com/v1.0/servicePrincipals/{0}/appRoleAssignedTo/{1}' -f '<MicrosoftGraphServicePrincipalId>', '<AssignmentId>'
    Method  = 'DELETE'
    Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() }
}
Invoke-RestMethod @removeRequest
Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
Remove-Variable -Name 'MsalEssentialsConnection'
```

Permissions for Azure resources, such as a role on a Key Vault or a storage account, are Azure role assignments instead. Those can be granted in the portal under **Access control (IAM)** of the resource.

[Back to README](/README.md#how-to-use-it)
