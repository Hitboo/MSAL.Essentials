# Application sign-in with workload identity federation

Signs in as the app itself with a token that another platform issued to the running job, and lists users from Microsoft Graph. No secret or certificate is stored anywhere: Entra ID trusts the platform's token because a **federated credential** on the app registration says so ([Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)).

The app registration needs the application permission `User.Read.All` with admin consent, see [App registration](/README.md#application-permissions-sign-in-as-the-app), and a federated credential for the job (below).

## Add the federated credential

Entra admin center > **App registrations** > your app > **Certificates & secrets** > **Federated credentials** > **Add credential** ([Configure an app to trust an external identity provider](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust)).

| Field | GitHub Actions | Kubernetes (Azure Workload Identity) |
|---|---|---|
| Scenario | **GitHub Actions deploying Azure resources** | **Kubernetes accessing Azure resources** |
| Issuer | `https://token.actions.githubusercontent.com` (filled in) | the OIDC issuer URL of your cluster |
| Subject | built from organization, repository and entity, for example `repo:<org>/<repo>:ref:refs/heads/main` or `repo:<org>/<repo>:environment:<name>` | `system:serviceaccount:<namespace>:<service account>` |
| Audience | `api://AzureADTokenExchange` | `api://AzureADTokenExchange` |

Issuer, subject and audience must match the token **exactly**, without wildcards. A new credential can take a few minutes to become active; until then the sign-in fails with `AADSTS70021` ([Considerations](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations)). An app can have at most 20 federated credentials.

## GitHub Actions

The job asks GitHub for its OIDC token and passes it to `Connect-MsalEssentials -FederatedToken`. The workflow needs `permissions: id-token: write`, otherwise GitHub doesn't provide the token request variables ([Use GitHub Actions to connect to Azure](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)). Store the tenant and client ID as repository variables or secrets; they are not credentials.

```yaml
name: Graph report

on:
  workflow_dispatch:

permissions:
  id-token: write # lets the job request its OIDC token
  contents: read

jobs:
  report:
    runs-on: windows-latest
    environment: production # must match the subject of the federated credential, if you use an environment
    steps:
      - uses: actions/checkout@v4
      - name: List users
        shell: pwsh
        env:
          TENANT_ID: ${{ vars.ENTRA_TENANT_ID }}
          CLIENT_ID: ${{ vars.ENTRA_CLIENT_ID }}
        run: ./scripts/Get-GraphUsers.ps1
```

`scripts/Get-GraphUsers.ps1`:

```powershell
Install-Module -Name 'MSAL.Essentials' -Scope 'CurrentUser' -Force
Import-Module -Name 'MSAL.Essentials'

#region Settings
# From the workflow's env: block. 'common' and 'organizations' do not work for application sign-in.
[string]$TenantId = $env:TENANT_ID
# The application (client) ID of the app registration that has the federated credential.
[string]$ClientId = $env:CLIENT_ID
#endregion Settings

#region Connect to Microsoft Graph via MSAL.Essentials
try {
    # Ask GitHub for this job's OIDC token, with the audience that Entra ID expects.
    # Both variables only exist when the workflow has 'permissions: id-token: write'.
    $OidcRequest = @{
        Uri     = '{0}&audience={1}' -f $env:ACTIONS_ID_TOKEN_REQUEST_URL, [uri]::EscapeDataString('api://AzureADTokenExchange')
        Headers = @{ Authorization = 'Bearer {0}' -f $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN }
    }
    $FederatedToken = (Invoke-RestMethod @OidcRequest -ErrorAction 'Stop').value

    # Exchange it for an MSAL token for the app itself. Application permissions always use '<resource>/.default';
    # 'https://graph.microsoft.com/.default' is the default, so -Scopes can be left out here.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $TenantId -ClientId $ClientId -FederatedToken $FederatedToken -ErrorAction 'Stop'

    # The GitHub token is short-lived and is used as it is for renewal. In a long job, get a new
    # GitHub token and connect again instead of relying on Get-MsalEssentialsToken to renew.

    $MicrosoftGraphRequest = @{
        Uri     = 'https://graph.microsoft.com/v1.0/users?$top=5&$select=displayName,userPrincipalName' # Needs the application permission User.Read.All.
        Method  = 'GET'
        Headers = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() } # Use the MSAL token to authorize the request.
    }

    # Invoke the Microsoft Graph request using the MSAL token.
    $MicrosoftGraphResult = Invoke-RestMethod @MicrosoftGraphRequest
    $MicrosoftGraphResult.value | Format-Table -Property 'displayName', 'userPrincipalName'
}
catch {
    # Fail the job instead of only warning.
    Write-Error -Message $_ -ErrorAction 'Continue'
    exit 1
}
finally {
    # Clean up once done: clear the connection and remove the variables that hold tokens.
    Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalEssentialsConnection', 'FederatedToken' -ErrorAction 'SilentlyContinue'
}
#endregion Connect to Microsoft Graph via MSAL.Essentials
```

## Kubernetes (token file)

With Azure Workload Identity, the pod gets a token file that the cluster replaces before it expires, and its path in `AZURE_FEDERATED_TOKEN_FILE` ([Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)). `-FederatedTokenFile` reads the file again for every new token, so `Get-MsalEssentialsToken` keeps renewing the connection:

```powershell
$MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $env:AZURE_TENANT_ID -ClientId $env:AZURE_CLIENT_ID -FederatedTokenFile $env:AZURE_FEDERATED_TOKEN_FILE -ErrorAction 'Stop'

# Later: renews with the current content of the token file if the token expires in less than 5 minutes.
$MsalEssentialsConnection = Get-MsalEssentialsToken -ErrorAction 'Stop'
```

The same works on any platform that writes its token to a file. Pods usually run Linux, where the module is not tested yet (see [Limitations](/README.md#limitations)).

## When it fails

| Error | Meaning |
|---|---|
| `AADSTS700211`, `AADSTS700212`, `AADSTS700213` | No federated credential matches the issuer, audience or subject of the token. Compare them character by character. |
| `AADSTS70021` | No federated credential matches the token at all, or a new one is not active yet. Wait a few minutes and try again. |
| `AADSTS700024` | The platform token has expired. Get a new one and connect again. |
| `MsalEssentials.AppConfiguration` with `-FederatedTokenFile` | The token file is missing, unreadable or empty. |

The error message of `Connect-MsalEssentials` includes a hint for each of these.

[Back to README](/README.md#how-to-use-it)
