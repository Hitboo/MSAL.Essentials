<#
    .SYNOPSIS
        Gets an access token for the managed identity of the Azure resource
        this code runs on (system-assigned or user-assigned).

    .DESCRIPTION
        Private helper used by Connect-MsalEssentials. Builds an MSAL managed
        identity client and requests a token from the managed identity
        endpoint of the host. No tenant, no secret, no certificate, no
        browser and no redirect URI are involved: the host (Azure VM, App
        Service, Azure Functions, Azure Arc, ...) proves who it is. Needs only
        the Microsoft.Identity.Client assembly to be loaded, so it can also be
        used on its own.

        MSAL detects the endpoint itself (IMDS on a VM, the IDENTITY_ENDPOINT
        environment variable on App Service and Functions, the Arc agent on
        an Arc-enabled server, ...). On a computer without a managed identity,
        such as a laptop, the request fails with
        MsalEssentials.ManagedIdentityUnavailable.

        The token carries the permissions granted to the managed identity:
        Azure RBAC roles, or application permissions (app roles) for APIs
        such as Microsoft Graph.

        Failures are turned into a terminating error with a category, a hint
        and the technical details:

            FullyQualifiedErrorId  MsalEssentials.<Category>
            ErrorDetails.Message   summary, hint and technical details
            TargetObject           Category, ErrorCode, StatusCode,
                                   ManagedIdentitySource, ClientId

        Categories: ManagedIdentityUnavailable, AppConfiguration,
        Unauthorized, Authentication.

    .PARAMETER ClientId
        The client ID of a user-assigned managed identity. Omit it to use the
        system-assigned managed identity of the resource.

        Find it in the Azure portal > Managed Identities > your identity >
        Overview > Client ID. The identity must be assigned to the resource
        this code runs on.

    .PARAMETER Scopes
        Exactly one scope that ends with '/.default', for example
        'https://graph.microsoft.com/.default'. MSAL sends only the resource
        part (without '/.default') to the endpoint.

    .PARAMETER ApplicationReference
        Receives the MSAL client, so the caller can renew the token later.

    .EXAMPLE
        Get-MsalEssentialsManagedIdentityToken
        Gets a Microsoft Graph token for the system-assigned managed identity.

    .EXAMPLE
        Get-MsalEssentialsManagedIdentityToken -ClientId $userAssignedClientId -Scopes 'https://vault.azure.net/.default'
        Gets an Azure Key Vault token for a user-assigned managed identity.
#>

function Get-MsalEssentialsManagedIdentityToken {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ClientId,

        [Parameter()]
        [ValidateCount(1, 1)]
        [ValidatePattern('/\.default$')]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        [ref]
        $ApplicationReference
    )

    $identityDescription = if ($ClientId) { 'user-assigned managed identity ''{0}''' -f $ClientId } else { 'system-assigned managed identity' }

    try {
        #region Build the MSAL client

        $managedIdentityId = if ($ClientId) {
            [Microsoft.Identity.Client.AppConfig.ManagedIdentityId]::WithUserAssignedClientId($ClientId)
        }
        else {
            [Microsoft.Identity.Client.AppConfig.ManagedIdentityId]::SystemAssigned
        }

        $managedIdentityApplication = [Microsoft.Identity.Client.ManagedIdentityApplicationBuilder]::Create(
            $managedIdentityId
        ).Build()

        #endregion Build the MSAL client

        # Hand the client back so the token can be renewed later. MSAL keeps
        # managed identity tokens in its in-memory cache, so the same
        # instance is needed.
        if ($ApplicationReference) {
            $ApplicationReference.Value = $managedIdentityApplication
        }

        Write-Verbose -Message ('Requesting a token for ''{0}'' with the {1}.' -f $Scopes[0], $identityDescription)

        # Returns the full MSAL AuthenticationResult. Don't print it to the
        # console: PowerShell's formatter walks its deep, self-referencing
        # properties and can crash the process with a StackOverflowException.
        # Wait-MsalEssentialsTask keeps the wait from deadlocking on a UI thread (WPF, WinForms).
        return Wait-MsalEssentialsTask -ScriptBlock {
            # MSAL takes a resource here, not a scope, and removes a trailing
            # '/.default' itself, so the scope can be passed on unchanged.
            $managedIdentityApplication.AcquireTokenForManagedIdentity(
                $Scopes[0]
            ).ExecuteAsync()
        }
    }
    catch {
        #region exception handling

        # PowerShell wraps exceptions from directly-called .NET methods, so
        # walk the chain and prefer the MSAL exception.
        $exceptionChain   = New-Object -TypeName 'System.Collections.Generic.List[System.Exception]'
        $currentException = $_.Exception
        while ($currentException) {
            $exceptionChain.Add($currentException)
            $currentException = $currentException.InnerException
        }

        $caughtException = $exceptionChain |
            Where-Object -FilterScript { $_ -is [Microsoft.Identity.Client.MsalException] } |
            Select-Object -First 1

        if (-not $caughtException) {
            $caughtException = $exceptionChain[$exceptionChain.Count - 1]
        }

        Write-Verbose -Message ('{0}: {1}' -f $caughtException.GetType().FullName, $caughtException.Message)

        $isMsalException    = $caughtException -is [Microsoft.Identity.Client.MsalException]
        $isServiceException = $caughtException -is [Microsoft.Identity.Client.MsalServiceException]

        $errorCode  = if ($isMsalException)    { $caughtException.ErrorCode }  else { $null }
        $statusCode = if ($isServiceException -and $caughtException.StatusCode) { $caughtException.StatusCode } else { $null }

        # For IMDS (Azure VMs) MSAL leaves StatusCode at 0 and only writes the
        # HTTP status into the message, for example "Status: BadRequest".
        if (-not $statusCode -and $caughtException.Message -match '(?m)^Status:\s*(?<status>[A-Za-z]+)\s*$') {
            $parsedStatus = $Matches['status'] -as [System.Net.HttpStatusCode]
            if ($null -ne $parsedStatus) {
                $statusCode = [int]$parsedStatus
            }
        }

        # MSAL names the endpoint it used (Imds, AppService, AzureArc, ...),
        # which tells the user where to look.
        $managedIdentitySource = $null
        if ($isMsalException -and $caughtException.AdditionalExceptionData -and
            $caughtException.AdditionalExceptionData.ContainsKey('ManagedIdentitySource')) {
            $managedIdentitySource = $caughtException.AdditionalExceptionData['ManagedIdentitySource']
        }

        $unavailableHint = 'No managed identity endpoint was reachable. Managed identities only exist on Azure resources (VM, App Service, Functions, Azure Arc, ...). Run this on such a resource and turn its managed identity on, or use -Certificate or -ClientSecret on other computers.'

        $category = 'Authentication'
        $summary  = ($caughtException.Message -split '\r?\n')[0]
        $hint     = $null

        if ($errorCode -in 'managed_identity_unreachable_network', 'managed_identity_all_sources_unavailable') {
            $category = 'ManagedIdentityUnavailable'
            $hint     = $unavailableHint
        }
        elseif ($statusCode -eq 400 -and $ClientId) {
            # IMDS ("Identity not found") and App Service answer 400 when the
            # requested identity is not assigned to the resource.
            $category = 'AppConfiguration'
            $hint     = 'The user-assigned managed identity was not found on this resource. Check -ClientId (the Client ID of the identity, not its Object ID) and that the identity is assigned to this resource (Settings > Identity > User assigned).'
        }
        elseif ($statusCode -eq 400) {
            $category = 'AppConfiguration'
            $hint     = 'The managed identity endpoint rejected the request. Check that the system-assigned identity is turned on (Settings > Identity > System assigned) and that the resource in -Scopes is valid.'
        }
        elseif ($statusCode -in 401, 403) {
            $category = 'Unauthorized'
            $hint     = 'The managed identity endpoint rejected the request as unauthorized. On Azure Arc, the account running this needs local admin rights (Windows: Administrators or "Hybrid Agent Extension Applications"; Linux: the himds group).'
        }

        $errorCategoryMap = @{
            ManagedIdentityUnavailable = [System.Management.Automation.ErrorCategory]::ResourceUnavailable
            AppConfiguration           = [System.Management.Automation.ErrorCategory]::InvalidOperation
            Unauthorized               = [System.Management.Automation.ErrorCategory]::PermissionDenied
            Authentication             = [System.Management.Automation.ErrorCategory]::AuthenticationError
        }

        $detailLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $detailLines.Add(('Token request for the {0} failed [{1}]: {2}' -f $identityDescription, $category, $summary))
        if ($hint) {
            $detailLines.Add(('Hint: {0}' -f $hint))
        }

        $technicalDetails = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if ($errorCode)             { $technicalDetails.Add(('ErrorCode: {0}' -f $errorCode)) }
        if ($statusCode)            { $technicalDetails.Add(('StatusCode: {0}' -f $statusCode)) }
        if ($managedIdentitySource) { $technicalDetails.Add(('Source: {0}' -f $managedIdentitySource)) }
        if ($technicalDetails.Count -gt 0) {
            $detailLines.Add(('Details: {0}' -f ($technicalDetails -join ' | ')))
        }

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $caughtException,
            ('MsalEssentials.{0}' -f $category),
            $errorCategoryMap[$category],
            [pscustomobject]@{
                Category              = $category
                ErrorCode             = $errorCode
                StatusCode            = $statusCode
                ManagedIdentitySource = $managedIdentitySource
                ClientId              = $ClientId
            }
        )
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(($detailLines -join [System.Environment]::NewLine))

        $PSCmdlet.ThrowTerminatingError($errorRecord)
        #endregion exception handling
    }
}
