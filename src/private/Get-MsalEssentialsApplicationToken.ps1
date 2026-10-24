<#
    .SYNOPSIS
        Gets an access token for the application itself (application
        permissions) with a certificate or a client secret.

    .DESCRIPTION
        Private helper used by Connect-MsalEssentials. Builds an MSAL
        confidential client and requests a token with the client credentials
        flow. No user, no browser and no redirect URI are
        involved. Needs only the Microsoft.Identity.Client assembly to be
        loaded, so it can also be used on its own.

        The token carries the application permissions (app roles) that were
        granted to the app and consented by an administrator.

        Failures are turned into a terminating error with a category, a hint
        and the technical details:

            FullyQualifiedErrorId  MsalEssentials.<Category>
            ErrorDetails.Message   summary, hint and technical details
            TargetObject           Category, AadstsCode, ErrorCode,
                                   CorrelationId, Claims, TenantId, ClientId

        Categories: AppConfiguration, Unauthorized, ConditionalAccess,
        Authentication.

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.
        The client credentials flow needs a specific tenant. 'common',
        'organizations' and 'consumers' do not work.

    .PARAMETER ClientId
        The application (client) ID registered in Entra ID.

    .PARAMETER Certificate
        A certificate with a private key. Its public part must be uploaded on
        the app registration (Certificates & secrets > Certificates).

    .PARAMETER ClientSecret
        The client secret value as a SecureString. It is converted to plain
        text only for the moment MSAL needs it. .NET strings can't be wiped,
        so a copy may stay in memory until garbage collection.

    .PARAMETER Scopes
        Exactly one scope that ends with '/.default', for example
        'https://graph.microsoft.com/.default'. Application permissions are
        granted on the app registration, not requested per call.

    .PARAMETER ApplicationReference
        Receives the MSAL client, so the caller can renew the token later.

    .EXAMPLE
        Get-MsalEssentialsApplicationToken -TenantId $tenantId -ClientId $clientId -Certificate $certificate
        Gets an app-only Microsoft Graph token with a certificate.

    .EXAMPLE
        Get-MsalEssentialsApplicationToken -TenantId $tenantId -ClientId $clientId -ClientSecret $secureSecret -Scopes 'https://vault.azure.net/.default'
        Gets an app-only token for Azure Key Vault with a client secret.
#>

function Get-MsalEssentialsApplicationToken {
    [CmdletBinding(DefaultParameterSetName = 'Certificate')]
    param (
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientId,

        [Parameter(Mandatory, ParameterSetName = 'Certificate')]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]
        $Certificate,

        [Parameter(Mandatory, ParameterSetName = 'Secret')]
        [System.Security.SecureString]
        $ClientSecret,

        [Parameter()]
        [ValidateCount(1, 1)]
        [ValidatePattern('/\.default$')]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        [ref]
        $ApplicationReference
    )

    try {
        #region Build the MSAL client

        $clientBuilder = [Microsoft.Identity.Client.ConfidentialClientApplicationBuilder]::Create(
            $ClientId
        ).WithAuthority(
            ('https://login.microsoftonline.com/{0}' -f $TenantId)
        )

        if ($PSCmdlet.ParameterSetName -eq 'Certificate') {
            $clientBuilder = $clientBuilder.WithCertificate($Certificate)
        }
        else {
            # MSAL only accepts the secret as a string. Keep the plain text
            # only as long as the builder needs it, and wipe the unmanaged copy.
            $secretPointer = [System.IntPtr]::Zero
            try {
                $secretPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($ClientSecret)
                $clientBuilder = $clientBuilder.WithClientSecret(
                    [System.Runtime.InteropServices.Marshal]::PtrToStringUni($secretPointer)
                )
            }
            finally {
                if ($secretPointer -ne [System.IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($secretPointer)
                }
            }
        }

        $confidentialClientApplication = $clientBuilder.Build()

        #endregion Build the MSAL client

        # Hand the client back so the token can be renewed later. MSAL keeps
        # app tokens in its in-memory cache, so the same instance is needed.
        if ($ApplicationReference) {
            $ApplicationReference.Value = $confidentialClientApplication
        }

        Write-Verbose -Message (
            'Requesting an application token for ''{0}'' (tenant ''{1}'', client ''{2}'') with a {3}.' -f
                $Scopes[0],
                $TenantId,
                $ClientId,
                $PSCmdlet.ParameterSetName.ToLowerInvariant()
        )

        # Returns the full MSAL AuthenticationResult. Don't print it to the
        # console: PowerShell's formatter walks its deep, self-referencing
        # properties and can crash the process with a StackOverflowException.
        return $confidentialClientApplication.AcquireTokenForClient(
            [string[]]$Scopes
        ).ExecuteAsync().GetAwaiter().GetResult()
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

        $errorCode     = if ($isMsalException)    { $caughtException.ErrorCode }     else { $null }
        $correlationId = if ($isServiceException) { $caughtException.CorrelationId } else { $null }
        $claims        = if ($isServiceException) { $caughtException.Claims }        else { $null }

        $aadstsCode = $null
        if ($caughtException.Message -match 'AADSTS(?<code>\d+)') {
            $aadstsCode = $Matches['code']
        }

        $publicClientHint = 'The app registration is set up as a public client. Entra admin center > App registrations > your app > Authentication > Settings: set "Allow public client flows" to No.'
        $secretHint       = 'Create a new secret under Certificates & secrets and use its Value (shown only once), not the Secret ID.'

        # https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
        $knownAadstsErrors = @{
            '700016'  = @{ Category = 'AppConfiguration';  Hint = 'The application (client) ID was not found in this tenant. Check -ClientId and -TenantId, and that the app is registered in this tenant.' }
            '90002'   = @{ Category = 'AppConfiguration';  Hint = 'The tenant was not found. Check -TenantId. The client credentials flow needs a tenant ID or domain, not "common" or "organizations".' }
            '900023'  = @{ Category = 'AppConfiguration';  Hint = 'The tenant identifier is not valid. Check -TenantId.' }
            '70011'   = @{ Category = 'AppConfiguration';  Hint = 'The requested scope is not valid. Use the resource with "/.default", for example https://graph.microsoft.com/.default.' }
            '500011'  = @{ Category = 'AppConfiguration';  Hint = 'The resource in -Scopes was not found in this tenant. Check the resource part of the scope.' }
            '700025'  = @{ Category = 'AppConfiguration';  Hint = $publicClientHint }
            '7000218' = @{ Category = 'AppConfiguration';  Hint = $publicClientHint }
            '7000215' = @{ Category = 'Unauthorized';      Hint = ('The client secret is not valid. {0}' -f $secretHint) }
            '7000222' = @{ Category = 'Unauthorized';      Hint = ('The client secret has expired. {0}' -f $secretHint) }
            '700027'  = @{ Category = 'Unauthorized';      Hint = 'The certificate signature was rejected. Upload the public part (.cer) of exactly this certificate on the app registration (Certificates & secrets > Certificates), and check that it has not expired.' }
            '700024'  = @{ Category = 'Unauthorized';      Hint = 'The certificate assertion is not within its valid time. Check the clock of this computer and the validity period of the certificate.' }
            '700023'  = @{ Category = 'Unauthorized';      Hint = 'The certificate does not match the application. Check -ClientId and the certificate uploaded on the app registration.' }
            '53003'   = @{ Category = 'ConditionalAccess'; Hint = 'Access was blocked by a Conditional Access policy for workload identities (for example location). Ask your administrator which policy applies.' }
        }

        $errorCategoryMap = @{
            AppConfiguration  = [System.Management.Automation.ErrorCategory]::InvalidOperation
            Unauthorized      = [System.Management.Automation.ErrorCategory]::PermissionDenied
            ConditionalAccess = [System.Management.Automation.ErrorCategory]::SecurityError
            Authentication    = [System.Management.Automation.ErrorCategory]::AuthenticationError
        }

        $category = 'Authentication'
        $summary  = ($caughtException.Message -split '\r?\n')[0]
        $hint     = $null

        if ($aadstsCode -and $knownAadstsErrors.ContainsKey($aadstsCode)) {
            $category = $knownAadstsErrors[$aadstsCode].Category
            $hint     = $knownAadstsErrors[$aadstsCode].Hint
        }
        elseif ($claims) {
            $category = 'ConditionalAccess'
            $hint     = 'A Conditional Access policy returned a claims challenge. Ask your administrator which policy applies.'
        }
        elseif ($errorCode -in 'invalid_client', 'unauthorized_client', 'access_denied') {
            $category = 'Unauthorized'
            $hint     = 'The app was not accepted. Check the client secret or certificate, and the app registration.'
        }
        elseif ($isServiceException -and $caughtException.StatusCode -in 401, 403) {
            $category = 'Unauthorized'
            $hint     = 'The service rejected the request as unauthorized. Check the app registration, granted permissions and admin consent.'
        }

        $detailLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $detailLines.Add(('Token request failed [{0}]: {1}' -f $category, $summary))
        if ($hint) {
            $detailLines.Add(('Hint: {0}' -f $hint))
        }

        $technicalDetails = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if ($aadstsCode)    { $technicalDetails.Add(('AADSTS{0}' -f $aadstsCode)) }
        if ($errorCode)     { $technicalDetails.Add(('ErrorCode: {0}' -f $errorCode)) }
        if ($correlationId) { $technicalDetails.Add(('CorrelationId: {0}' -f $correlationId)) }
        if ($technicalDetails.Count -gt 0) {
            $detailLines.Add(('Details: {0}' -f ($technicalDetails -join ' | ')))
        }

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $caughtException,
            ('MsalEssentials.{0}' -f $category),
            $errorCategoryMap[$category],
            [pscustomobject]@{
                Category      = $category
                AadstsCode    = $aadstsCode
                ErrorCode     = $errorCode
                CorrelationId = $correlationId
                Claims        = $claims
                TenantId      = $TenantId
                ClientId      = $ClientId
            }
        )
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(($detailLines -join [System.Environment]::NewLine))

        $PSCmdlet.ThrowTerminatingError($errorRecord)
        #endregion exception handling
    }
}
