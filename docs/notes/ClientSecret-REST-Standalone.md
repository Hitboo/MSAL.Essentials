# Client secret without MSAL (standalone REST example)

The client credentials flow with a secret is a single POST to the Entra ID token endpoint. No MSAL needed.
The module still uses MSAL for this (consistency with the certificate flow, caching, error handling), this is only to show what happens on the wire.
The app needs the application permission `User.Read.All` (or similar) with admin consent.

```powershell
# The directory (tenant) ID or verified domain. 'common' does not work for client credentials.
[string]$TenantId = '00000000-0000-0000-0000-000000000000'
# The application (client) ID registered in Entra ID.
[string]$ClientId = '00000000-0000-0000-0000-000000000000'
# The client secret Value (not the Secret ID), read without leaving it in the console history.
[securestring]$ClientSecret = Read-Host -Prompt 'Client secret' -AsSecureString

$tokenRequest = @{
    Method = 'POST'
    Uri    = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/token' -f $TenantId
    Body   = @{
        client_id     = $ClientId
        client_secret = [System.Net.NetworkCredential]::new('', $ClientSecret).Password # plain text only for the request
        scope         = 'https://graph.microsoft.com/.default'                          # application permissions are always '.default'
        grant_type    = 'client_credentials'
    }
}
$tokenResponse = Invoke-RestMethod @tokenRequest

$graphRequest = @{
    Method  = 'GET'
    Uri     = 'https://graph.microsoft.com/beta/users'
    Headers = @{ Authorization = 'Bearer {0}' -f $tokenResponse.access_token }
}
$users = Invoke-RestMethod @graphRequest
$users.value |
    Select-Object -Property 'displayName', 'userPrincipalName'
```
