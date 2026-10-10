# As a quick TL:DR of MSAL
## Get MSAL / Microsoft.Identity.Client (and dependencies) and load it somehow.
- Nuget download
- `Microsoft.Graph.Authentication` Module
- `Az.Accounts` Module
- ...

## Build the identity client Application:
```powershell
# The directory (tenant) ID or verified domain to authenticate against.
[string]$TenantId = '00000000-0000-0000-0000-000000000000'
# The application (client) ID registered in Entra ID.
[string]$ClientID = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line Tools

$publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
    $ClientID                                              # Target app
).WithAuthority(
    ('https://login.microsoftonline.com/{0}' -f $TenantId) # Target tenant
).WithRedirectUri(
    'http://localhost'                                     # Loopback redirect, required for the system browser
).Build()                                                  # Create the object

#WithDefaultRedirectUri(): it picks a default that depends on the platform.
```

## Run the authentication:
###  As User (delegated rights, interactive)
```powershell
# Permission scopes to request.
# '.default' = all delegated permissions already granted (consented) to the app for this user.
# It does not add new permissions. To request specific ones use e.g. 'User.Read', 'Mail.Read'.
[string[]]$Scopes = @('https://graph.microsoft.com/.default')

# Cancels the pending sign-in once the timeout elapses.
$timeoutSource = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds(60))

try {
    # AcquireTokenInteractive = 'as user, in a browser'
    $authenticationResult = $publicClientApplication.AcquireTokenInteractive(
        $Scopes                         # What rights do we need.
    ).WithUseEmbeddedWebView(
        $false                          # Open the default browser (Edge, Chrome, Firefox, ...) instead of the embedded view.
    ).ExecuteAsync(
        $timeoutSource.Token            # Lets us give up. Without it, a sign-in that never finishes waits forever.
    ).GetAwaiter().GetResult()          # Wait for the async result and return it. Important.
}
finally {
    $timeoutSource.Dispose() # Cleanup
}
```
### Others to be done

## Use the token
```powershell
$Request = @{
    Uri     = 'https://graph.microsoft.com/Beta/me'
    Method  = 'GET'
    Headers = @{
        Authorization = $AuthenticationResult.createAuthorizationHeader()
    }
    ContentType = 'application/json'
}

# Get info about myself via Microsoft Graph
Invoke-RestMethod @Request
```
