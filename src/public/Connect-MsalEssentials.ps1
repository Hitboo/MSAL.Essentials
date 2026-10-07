<#
    .SYNOPSIS
        Connects to Microsoft Entra ID and keeps the resulting token for this
        PowerShell session.

    .DESCRIPTION
        Signs in as the current user through the system's default web browser
        (delegated rights) by calling
        Get-MsalEssentialsDelegatedTokenSystemBrowser, then stores the result
        in module scope so other MSAL.Essentials functions can use it.

        Nothing is written to disk. Running Connect-MsalEssentials again
        replaces the stored connection.

        Errors from the sign-in are passed through unchanged, including the
        FullyQualifiedErrorId values (MsalEssentials.Timeout,
        MsalEssentials.ConditionalAccess, ...) and the TargetObject details
        described in Get-MsalEssentialsDelegatedTokenSystemBrowser. This is a
        terminating error for the command, so use -ErrorAction Stop or
        try/catch in scripts to make sure nothing runs after a failed sign-in.

        Currently supported:
            DelegatedSystemBrowser   interactive sign-in as a user (default)

        Planned parameter sets (not implemented yet):
            AppCertificate, AccessToken, ManagedIdentity

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientID
        The application (client) ID registered in Entra ID.

    .PARAMETER Scopes
        The delegated scopes to request. If omitted, the default of
        Get-MsalEssentialsDelegatedTokenSystemBrowser is used.

    .PARAMETER TimeoutSeconds
        How long to wait for the interactive sign-in to complete. If omitted,
        the default of Get-MsalEssentialsDelegatedTokenSystemBrowser is used.

    .PARAMETER PassThru
        Returns the connection as an object with the properties
        AuthenticationType, TenantId, ClientId, Username, Scopes, ExpiresOn
        and AccessToken, plus a CreateAuthorizationHeader() method that
        returns 'Bearer <token>'.

        The access token is a credential. It is hidden from the default
        console display, but Format-List *, ConvertTo-Json, Export-Clixml and
        similar commands will include it. Don't log or share the object.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId
        Opens the default browser for sign-in and stores the connection.

    .EXAMPLE
        Connect-MsalEssentials -TenantId $tenantId -ClientID $clientId -Scopes 'User.Read' -TimeoutSeconds 60 -PassThru
        Requests only User.Read, gives up after 60 seconds, and returns the connection.

    .EXAMPLE
        try {
            $connection = Connect-MsalEssentials -PassThru -TenantId $tenantId -ClientID $clientId -ErrorAction 'Stop'

            $request = @{
                Uri         = 'https://graph.microsoft.com/beta/me'
                Method      = 'GET'
                Headers     = @{ Authorization = $connection.CreateAuthorizationHeader() }
                ContentType = 'application/json'
            }

            $result = Invoke-RestMethod @request
        }
        catch {
            Write-Warning -Message $_.ErrorDetails.Message
        }
#>

function Connect-MsalEssentials {
    [CmdletBinding(DefaultParameterSetName = 'DelegatedSystemBrowser')]
    [OutputType('MsalEssentials.Connection')]
    param (
        # TenantId and ClientID have no parameter set, so they belong to every set.
        # When app / managed identity sets are added, move them into the sets that need them.
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientID,

        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [string[]]
        $Scopes,

        [Parameter(ParameterSetName = 'DelegatedSystemBrowser')]
        [int]
        $TimeoutSeconds,

        [Parameter()]
        [switch]
        $PassThru
    )

    $authenticationResult = $null
    $authenticationType   = $null

    switch ($PSCmdlet.ParameterSetName) {
        'DelegatedSystemBrowser' {
            $tokenParameters = @{
                TenantId = $TenantId
                ClientID = $ClientID
            }

            # Only pass optional parameters that were actually supplied, so the
            # defaults live in one place (the helper function).
            foreach ($optionalParameterName in 'Scopes', 'TimeoutSeconds') {
                if ($PSBoundParameters.ContainsKey($optionalParameterName)) {
                    $tokenParameters[$optionalParameterName] = $PSBoundParameters[$optionalParameterName]
                }
            }

            $authenticationType = 'Delegated'

            # The helper throws a statement-terminating error. Without this
            # try/catch, execution would continue after a failed sign-in and
            # store an empty connection.
            try {
                $authenticationResult = Get-MsalEssentialsDelegatedTokenSystemBrowser @tokenParameters
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }

        # Future parameter sets go here, each setting $authenticationResult and
        # $authenticationType the same way:
        #   'AppCertificate'  -> client credentials with a certificate
        #   'AccessToken'     -> use an access token that was obtained elsewhere
        #   'ManagedIdentity' -> managed identity endpoint
    }

    if (-not $authenticationResult -or [string]::IsNullOrEmpty($authenticationResult.AccessToken)) {
        $noTokenRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('Sign-in completed but no access token was returned.'),
            'MsalEssentials.NoToken',
            [System.Management.Automation.ErrorCategory]::AuthenticationError,
            $null
        )
        $PSCmdlet.ThrowTerminatingError($noTokenRecord)
    }

    $username = if ($authenticationResult.Account) { $authenticationResult.Account.Username } else { $null }

    # Module-scope state. Kept as plain values plus the MSAL result. The raw
    # AuthenticationResult is never returned from this function (see the note
    # in the helper about printing the full AuthenticationResult).
    $script:MsalEssentialsSession = @{
        AuthenticationType   = $authenticationType
        TenantId             = $authenticationResult.TenantId
        ClientId             = $ClientID
        Username             = $username
        Scopes               = @($authenticationResult.Scopes)
        ExpiresOn            = $authenticationResult.ExpiresOn
        AuthenticationResult = $authenticationResult
    }

    Write-Verbose -Message (
        'Connected as {0} ({1}), token expires {2}.' -f
            $(if ($username) { $username } else { 'application' }),
            $authenticationType,
            $authenticationResult.ExpiresOn
    )

    if ($PassThru) {
        # A small object made only of strings, a string array and a date, so it
        # is safe to print, unlike the full MSAL AuthenticationResult.
        $connection = [pscustomobject]@{
            PSTypeName         = 'MsalEssentials.Connection'
            AuthenticationType = $authenticationType
            TenantId           = $authenticationResult.TenantId
            ClientId           = $ClientID
            Username           = $username
            Scopes             = @($authenticationResult.Scopes)
            ExpiresOn          = $authenticationResult.ExpiresOn
            AccessToken        = $authenticationResult.AccessToken
        }

        # Same method name MSAL's AuthenticationResult has, so existing code
        # that calls CreateAuthorizationHeader() keeps working.
        $connection | 
            Add-Member -MemberType 'ScriptMethod' -Name 'CreateAuthorizationHeader' -Value {
                'Bearer {0}' -f $this.AccessToken
            }

        # Keep the token out of the default console display. It is still a
        # normal property, so $connection.AccessToken works.
        $defaultDisplayProperties = [System.Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet',
            [string[]]@('AuthenticationType', 'TenantId', 'ClientId', 'Username', 'Scopes', 'ExpiresOn')
        )
        $standardMembers = [System.Management.Automation.PSMemberSet]::new(
            'PSStandardMembers',
            [System.Management.Automation.PSMemberInfo[]]@($defaultDisplayProperties)
        )
        $connection.PSObject.Members.Add($standardMembers)

        $connection
    }
}