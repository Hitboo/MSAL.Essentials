<#
    Tests Get-MsalEssentialsManagedIdentityToken with the real MSAL library
    against a simulated managed identity endpoint on this computer.

    MSAL picks the App Service managed identity source when the environment
    variables IDENTITY_ENDPOINT and IDENTITY_HEADER are set. This file sets
    them to a small HTTP listener on localhost, which answers like the App
    Service endpoint does (documented in "Use managed identities for App
    Service and Azure Functions", REST endpoint reference):

        GET <IDENTITY_ENDPOINT>?api-version=2019-08-01&resource=<resource>[&client_id=<id>]
        X-IDENTITY-HEADER: <IDENTITY_HEADER>

    The same listener also answers like IMDS (the endpoint on Azure VMs) on
    /metadata/identity/oauth2/token. MSAL sends IMDS requests there when
    AZURE_POD_IDENTITY_AUTHORITY_HOST points to it and IDENTITY_ENDPOINT is
    not set. IMDS errors look different to MSAL: it reports StatusCode 0
    and puts the HTTP status into the message.

    So this covers what the mocks in 04-ManagedIdentityConnection.Tests.ps1
    can't: that the MSAL calls are right, that system- and user-assigned
    identities send the right request, and how MSAL errors are mapped. It
    does not prove that a real Azure resource accepts the request; that is
    what tests/3-integration is for.

    Only loopback (localhost) traffic is used. The variables are restored in
    AfterAll.

    MSAL keeps managed identity tokens in a cache shared by the whole
    process, so each test asks for its own resource. Otherwise a later test
    would get a cached token without a request.
#>

BeforeAll {
    $script:ModuleName           = 'MSAL.Essentials'
    $script:ManifestPath         = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path
    $script:IdentityHeader       = 'msal-essentials-test-header'
    $script:UserAssignedClientId = '44444444-4444-4444-4444-444444444444'
    $script:UnknownClientId      = '55555555-5555-5555-5555-555555555555'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # Each test gets its own resource (see the note above about MSAL's cache).
    function script:New-TestScope {
        'https://msal-essentials-{0}.test/.default' -f [guid]::NewGuid().ToString('N')
    }

    #region Simulated App Service managed identity endpoint

    # A free port on localhost.
    $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $tcpListener.Start()
    $script:Port = $tcpListener.LocalEndpoint.Port
    $tcpListener.Stop()

    $script:Requests     = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    $script:HttpListener = [System.Net.HttpListener]::new()
    $script:HttpListener.Prefixes.Add(('http://localhost:{0}/' -f $script:Port))
    $script:HttpListener.Start()

    # The listener runs in its own runspace so it can answer while MSAL waits.
    $script:ListenerShell = [powershell]::Create()
    $null = $script:ListenerShell.AddScript({
            param ($Listener, $Requests, $IdentityHeader, $UnknownClientId)

            while ($Listener.IsListening) {
                try {
                    $context = $Listener.GetContext()
                }
                catch {
                    break # the listener was stopped
                }

                $query    = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
                $resource = $query['resource']
                $clientId = $query['client_id']

                $isImds = $context.Request.Url.AbsolutePath -eq '/metadata/identity/oauth2/token'

                $Requests.Enqueue(@{
                        Path       = $context.Request.Url.AbsolutePath
                        ApiVersion = $query['api-version']
                        Resource   = $resource
                        ClientId   = $clientId
                        Header     = $context.Request.Headers['X-IDENTITY-HEADER']
                    })

                if ($isImds -and $context.Request.Headers['Metadata'] -ne 'true') {
                    $status = 400
                    $body   = '{"error":"invalid_request","error_description":"Required metadata header not specified"}'
                }
                elseif ($isImds -and $clientId -eq $UnknownClientId) {
                    # What IMDS on an Azure VM answers when the identity is not assigned.
                    $status = 400
                    $body   = '{"error":"invalid_request","error_description":"Identity not found"}'
                }
                elseif (-not $isImds -and $context.Request.Headers['X-IDENTITY-HEADER'] -ne $IdentityHeader) {
                    $status = 401
                    $body   = '{"statusCode":401,"message":"Missing or wrong X-IDENTITY-HEADER."}'
                }
                elseif ($clientId -eq $UnknownClientId) {
                    # What App Service answers when the identity is not assigned.
                    $status = 400
                    $body   = '{"statusCode":400,"message":"Unable to load the proper Managed Identity.","correlationId":"00000000-0000-0000-0000-000000000099"}'
                }
                else {
                    $status    = 200
                    $expiresOn = [System.DateTimeOffset]::UtcNow.AddHours(24).ToUnixTimeSeconds()
                    $body      = '{{"access_token":"simulated-mi-token-for-{0}","expires_on":"{1}","resource":"{2}","token_type":"Bearer","client_id":"{3}"}}' -f
                        $(if ($clientId) { $clientId } else { 'system' }),
                        $expiresOn,
                        $resource,
                        $(if ($clientId) { $clientId } else { '00000000-0000-0000-0000-000000000000' })
                }

                $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $context.Response.StatusCode      = $status
                $context.Response.ContentType     = 'application/json'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
        }).AddArgument($script:HttpListener).AddArgument($script:Requests).AddArgument($script:IdentityHeader).AddArgument($script:UnknownClientId)

    # System.Web.HttpUtility is not loaded by default in Windows PowerShell.
    Add-Type -AssemblyName 'System.Web'
    $script:ListenerHandle = $script:ListenerShell.BeginInvoke()

    #endregion Simulated App Service managed identity endpoint

    $script:PreviousEnvironment = @{
        IDENTITY_ENDPOINT                 = $env:IDENTITY_ENDPOINT
        IDENTITY_HEADER                   = $env:IDENTITY_HEADER
        AZURE_POD_IDENTITY_AUTHORITY_HOST = $env:AZURE_POD_IDENTITY_AUTHORITY_HOST
    }
    $env:IDENTITY_ENDPOINT = 'http://localhost:{0}/msi/token' -f $script:Port
    $env:IDENTITY_HEADER   = $script:IdentityHeader

    function script:Get-LastRequest {
        $request = $null
        $last    = $null
        while ($script:Requests.TryDequeue([ref]$request)) {
            $last = $request
        }
        $last
    }

    function script:Get-TestError {
        param ([scriptblock]$ScriptBlock)

        $caughtError = $null
        try {
            $null = & $ScriptBlock
        }
        catch {
            $caughtError = $_
        }
        $caughtError
    }
}

AfterAll {
    foreach ($name in $script:PreviousEnvironment.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $script:PreviousEnvironment[$name])
    }

    if ($script:HttpListener) {
        $script:HttpListener.Stop()
        $script:HttpListener.Close()
    }
    if ($script:ListenerShell) {
        $script:ListenerShell.Dispose()
    }

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Get-MsalEssentialsManagedIdentityToken against a simulated endpoint' {
    BeforeEach {
        $null = Get-LastRequest # drop requests from earlier tests
    }

    It 'gets a token for the system-assigned identity' {
        $scope = New-TestScope

        $result = InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope } -ScriptBlock {
            Get-MsalEssentialsManagedIdentityToken -Scopes $Scope
        }
        $request = Get-LastRequest

        $result.AccessToken |
            Should -Be 'simulated-mi-token-for-system'
        $request.ClientId |
            Should -BeNullOrEmpty
        $request.Header |
            Should -Be $script:IdentityHeader
    }

    It 'sends the resource without /.default' {
        $scope = New-TestScope

        $null = InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope } -ScriptBlock {
            Get-MsalEssentialsManagedIdentityToken -Scopes $Scope
        }

        (Get-LastRequest).Resource |
            Should -Be ($scope -replace '/\.default$', '')
    }

    It 'gets a token for a user-assigned identity by its client ID' {
        $scope = New-TestScope

        $result = InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope; ClientId = $script:UserAssignedClientId } -ScriptBlock {
            Get-MsalEssentialsManagedIdentityToken -ClientId $ClientId -Scopes $Scope
        }

        $result.AccessToken |
            Should -Be ('simulated-mi-token-for-{0}' -f $script:UserAssignedClientId)
        (Get-LastRequest).ClientId |
            Should -Be $script:UserAssignedClientId
    }

    It 'hands the MSAL client back for renewal' {
        $scope = New-TestScope

        $client = InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope } -ScriptBlock {
            $managedIdentityClient = $null
            $null = Get-MsalEssentialsManagedIdentityToken -Scopes $Scope -ApplicationReference ([ref]$managedIdentityClient)
            $managedIdentityClient
        }

        $client |
            Should -BeOfType 'Microsoft.Identity.Client.IManagedIdentityApplication'
    }

    It 'rejects <Name> before any request is sent' -ForEach @(
        @{ Name = 'a scope without /.default'; Scopes = @('https://graph.microsoft.com') }
        @{ Name = 'more than one scope';       Scopes = @('https://graph.microsoft.com/.default', 'https://vault.azure.net/.default') }
    ) {
        $caught = Get-TestError -ScriptBlock {
            InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scopes = $Scopes } -ScriptBlock {
                Get-MsalEssentialsManagedIdentityToken -Scopes $Scopes -ErrorAction 'Stop'
            }
        }

        $caught |
            Should -Not -BeNullOrEmpty
        Get-LastRequest |
            Should -BeNullOrEmpty
    }

    It 'maps an identity that is not assigned to MsalEssentials.AppConfiguration' {
        $scope = New-TestScope

        $caught = Get-TestError -ScriptBlock {
            InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope; ClientId = $script:UnknownClientId } -ScriptBlock {
                Get-MsalEssentialsManagedIdentityToken -ClientId $ClientId -Scopes $Scope -ErrorAction 'Stop'
            }
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.AppConfiguration*'
        $caught.TargetObject.StatusCode |
            Should -Be 400
        $caught.TargetObject.ManagedIdentitySource |
            Should -Be 'AppService'
        $caught.TargetObject.ClientId |
            Should -Be $script:UnknownClientId
        $caught.ErrorDetails.Message |
            Should -BeLike '*Client ID of the identity*'
    }

    It 'maps "Identity not found" from IMDS (Azure VM) to MsalEssentials.AppConfiguration' {
        $scope = New-TestScope

        # Switch MSAL from the App Service source to IMDS on the same listener.
        Remove-Item -Path 'Env:\IDENTITY_ENDPOINT', 'Env:\IDENTITY_HEADER'
        $env:AZURE_POD_IDENTITY_AUTHORITY_HOST = 'http://localhost:{0}' -f $script:Port
        try {
            $caught = Get-TestError -ScriptBlock {
                InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope; ClientId = $script:UnknownClientId } -ScriptBlock {
                    Get-MsalEssentialsManagedIdentityToken -ClientId $ClientId -Scopes $Scope -ErrorAction 'Stop'
                }
            }
        }
        finally {
            Remove-Item -Path 'Env:\AZURE_POD_IDENTITY_AUTHORITY_HOST'
            $env:IDENTITY_ENDPOINT = 'http://localhost:{0}/msi/token' -f $script:Port
            $env:IDENTITY_HEADER   = $script:IdentityHeader
        }
        $request = Get-LastRequest

        $request.Path |
            Should -Be '/metadata/identity/oauth2/token' -Because 'the request must go to the simulated IMDS'
        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.AppConfiguration*'
        $caught.TargetObject.StatusCode |
            Should -Be 400 -Because 'the status is read from the message, MSAL reports 0 for IMDS'
        $caught.TargetObject.ManagedIdentitySource |
            Should -Be 'Imds'
    }

    It 'maps an unreachable endpoint to MsalEssentials.ManagedIdentityUnavailable' {
        $scope = New-TestScope

        # Port 1 on localhost is not listening, so the connection is refused
        # at once, like a computer without a managed identity endpoint.
        $env:IDENTITY_ENDPOINT = 'http://localhost:1/msi/token'
        try {
            $caught = Get-TestError -ScriptBlock {
                InModuleScope -ModuleName $script:ModuleName -Parameters @{ Scope = $scope } -ScriptBlock {
                    Get-MsalEssentialsManagedIdentityToken -Scopes $Scope -ErrorAction 'Stop'
                }
            }
        }
        finally {
            $env:IDENTITY_ENDPOINT = 'http://localhost:{0}/msi/token' -f $script:Port
        }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.ManagedIdentityUnavailable*'
        $caught.TargetObject.ErrorCode |
            Should -Be 'managed_identity_unreachable_network'
        $caught.ErrorDetails.Message |
            Should -BeLike '*Hint:*Azure resources*'
    }

    It 'connects and renews end to end through Connect-MsalEssentials and Get-MsalEssentialsToken' {
        $scope = New-TestScope

        $connection = Connect-MsalEssentials -ManagedIdentity -ClientId $script:UserAssignedClientId -Scopes $scope -PassThru
        $null = Get-LastRequest

        $renewed = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 # inside the window, so it renews
        $renewalRequest = Get-LastRequest

        $connection.AuthenticationType |
            Should -Be 'ManagedIdentity'
        $connection.ClientId |
            Should -Be $script:UserAssignedClientId
        $connection.TenantId |
            Should -BeNullOrEmpty
        $renewed.AccessToken |
            Should -Not -BeNullOrEmpty
        $renewalRequest |
            Should -Not -BeNullOrEmpty -Because 'renewal must ask the endpoint again instead of using the MSAL cache'
        $renewalRequest.ClientId |
            Should -Be $script:UserAssignedClientId

        Disconnect-MsalEssentials -InformationAction 'SilentlyContinue'
    }
}
