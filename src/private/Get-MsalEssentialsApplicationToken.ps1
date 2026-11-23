<#
    .SYNOPSIS
        Gets an access token for the application itself (application
        permissions) with a certificate, a client secret or a federated
        token (workload identity federation).

    .DESCRIPTION
        Private helper used by Connect-MsalEssentials. Builds an MSAL
        confidential client and requests a token with the client credentials
        flow. No user, no browser and no redirect URI are
        involved. Needs only the Microsoft.Identity.Client assembly to be
        loaded, so it can also be used on its own.

        The token carries the application permissions (app roles) that were
        granted to the app and consented by an administrator.

        Workload identity federation: instead of a secret or certificate, the
        app proves who it is with a token that another identity provider
        issued to the running job (GitHub Actions, Azure DevOps, Kubernetes,
        another cloud, ...). Entra ID accepts it when a federated identity
        credential on the app registration trusts exactly that issuer,
        subject and audience. MSAL sends it as the client assertion. Pass the
        token itself (-FederatedToken) or the path of a file that holds it
        (-FederatedTokenFile). The file is read again whenever MSAL needs a
        new token, so a platform that rotates the file (Kubernetes) keeps
        renewal working. A token passed as a string expires on its own
        schedule, and renewal then fails until the caller connects again
        with a new one.

        Failures are turned into a terminating error with a category, a hint
        and the technical details:

            FullyQualifiedErrorId  MsalEssentials.<Category>
            ErrorDetails.Message   summary, hint and technical details
            TargetObject           Category, AadstsCode, ErrorCode,
                                   CorrelationId, Claims, TenantId, ClientId

        Categories: AppConfiguration, Unauthorized, ConditionalAccess,
        Authentication.

    .LINK
        https://learn.microsoft.com/entra/workload-id/workload-identity-federation

    .LINK
        https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/workload-identity-federation

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

    .PARAMETER FederatedToken
        The token (a JWT) that the platform issued to the running job, for
        example the OIDC token of a GitHub Actions job. Its audience is
        usually 'api://AzureADTokenExchange'. It is sent as the client
        assertion as it is, so renewal fails once it has expired.

    .PARAMETER FederatedTokenFile
        The path of a file that holds the federated token, for example the
        file in AZURE_FEDERATED_TOKEN_FILE on Kubernetes (Azure Workload
        Identity). A relative path is resolved against the current location
        once, when the client is built. The file is read again (and trimmed)
        every time MSAL requests a token, so a rotated file is picked up.

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

    .EXAMPLE
        Get-MsalEssentialsApplicationToken -TenantId $tenantId -ClientId $clientId -FederatedToken $oidcToken
        Gets an app-only Microsoft Graph token with a token from another identity provider (workload identity federation).

    .EXAMPLE
        Get-MsalEssentialsApplicationToken -TenantId $tenantId -ClientId $clientId -FederatedTokenFile $env:AZURE_FEDERATED_TOKEN_FILE
        Gets an app-only Microsoft Graph token with the federated token file of a Kubernetes pod.
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

        [Parameter(Mandatory, ParameterSetName = 'FederatedToken')]
        [ValidateNotNullOrEmpty()]
        [string]
        $FederatedToken,

        [Parameter(Mandatory, ParameterSetName = 'FederatedTokenFile')]
        [ValidateNotNullOrEmpty()]
        [string]
        $FederatedTokenFile,

        [Parameter()]
        [ValidateCount(1, 1)]
        [ValidatePattern('/\.default$')]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        [ref]
        $ApplicationReference
    )

    # Resolved once, so a later Set-Location can't point renewal at another
    # file. Checked inside the try below, so a missing file gets the same
    # error handling as a failed token request.
    $federatedTokenPath = $null
    if ($PSCmdlet.ParameterSetName -eq 'FederatedTokenFile') {
        $federatedTokenPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FederatedTokenFile)
    }

    $credentialDescription = @{
        Certificate        = 'certificate'
        Secret             = 'secret'
        FederatedToken     = 'federated token'
        FederatedTokenFile = 'federated token file'
    }[$PSCmdlet.ParameterSetName]

    try {
        #region Build the MSAL client

        $clientBuilder = [Microsoft.Identity.Client.ConfidentialClientApplicationBuilder]::Create(
            $ClientId
        ).WithAuthority(
            ('https://login.microsoftonline.com/{0}' -f $TenantId)
        )

        switch ($PSCmdlet.ParameterSetName) {
            'Certificate' {
                $clientBuilder = $clientBuilder.WithCertificate($Certificate)
            }

            'FederatedToken' {
                # MSAL sends this string as the client assertion on every request.
                $clientBuilder = $clientBuilder.WithClientAssertion($FederatedToken)
            }

            'FederatedTokenFile' {
                if (-not (Test-Path -LiteralPath $federatedTokenPath -PathType 'Leaf')) {
                    throw [System.IO.FileNotFoundException]::new(
                        ('The federated token file was not found: {0}' -f $federatedTokenPath),
                        $federatedTokenPath
                    )
                }

                if (-not ('MsalEssentials.FederatedTokenFileReader' -as [type])) {
                    # MSAL calls the assertion delegate whenever it requests a
                    # token, possibly on a thread pool thread. A PowerShell script
                    # block can't run there (no runspace), so the delegate is a
                    # small compiled C# method. Windows PowerShell 5.1 compiles
                    # with C# 5 - keep this source C# 5 compatible.
                    Add-Type -Language 'CSharp' -TypeDefinition @'
using System;
using System.IO;

namespace MsalEssentials
{
    public sealed class FederatedTokenFileReader
    {
        private readonly string _path;

        public FederatedTokenFileReader(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                throw new ArgumentNullException("path");
            }
            _path = path;
        }

        public string Path { get { return _path; } }

        // Read on every call: platforms such as Kubernetes replace the file
        // before the token in it expires.
        public string Read()
        {
            string token = File.ReadAllText(_path).Trim();
            if (token.Length == 0)
            {
                throw new InvalidDataException("The federated token file is empty: " + _path);
            }
            return token;
        }
    }
}
'@
                }

                $tokenFileReader   = [MsalEssentials.FederatedTokenFileReader]::new($federatedTokenPath)
                $assertionDelegate = [System.Delegate]::CreateDelegate(
                    [System.Func[string]],
                    $tokenFileReader,
                    [MsalEssentials.FederatedTokenFileReader].GetMethod('Read')
                )
                $clientBuilder = $clientBuilder.WithClientAssertion([System.Func[string]]$assertionDelegate)
            }

            'Secret' {
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

            default {
                throw ('Unknown parameter set: {0}' -f $PSCmdlet.ParameterSetName)
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
                $credentialDescription
        )

        # Returns the full MSAL AuthenticationResult. Don't print it to the
        # console: PowerShell's formatter walks its deep, self-referencing
        # properties and can crash the process with a StackOverflowException.
        # Wait-MsalEssentialsTask keeps the wait from deadlocking on a UI thread (WPF, WinForms).
        return Wait-MsalEssentialsTask -ScriptBlock {
            $confidentialClientApplication.AcquireTokenForClient(
                [string[]]$Scopes
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

        $errorCode     = if ($isMsalException)    { $caughtException.ErrorCode }     else { $null }
        $correlationId = if ($isServiceException) { $caughtException.CorrelationId } else { $null }
        $claims        = if ($isServiceException) { $caughtException.Claims }        else { $null }

        $aadstsCode = $null
        if ($caughtException.Message -match 'AADSTS(?<code>\d+)') {
            $aadstsCode = $Matches['code']
        }

        $publicClientHint = 'The app registration is set up as a public client. Entra admin center > App registrations > your app > Authentication > Settings: set "Allow public client flows" to No.'
        $secretHint       = 'Create a new secret under Certificates & secrets and use its Value (shown only once), not the Secret ID.'
        $federationHint   = 'Entra admin center > App registrations > your app > Certificates & secrets > Federated credentials: issuer, subject and audience (usually api://AzureADTokenExchange) must match the token exactly, without wildcards. A new credential can take a few minutes to become active.'
        $isFederated      = $PSCmdlet.ParameterSetName -in 'FederatedToken', 'FederatedTokenFile'

        # The same code means an expired client assertion for every credential
        # type, but the fix differs.
        $assertionTimeHint = if ($isFederated) {
            'The federated token has expired or is not valid yet. Tokens from GitHub, Azure DevOps and similar platforms are short-lived: get a new one and connect again, or use -FederatedTokenFile where the platform keeps the file up to date.'
        }
        else {
            'The certificate assertion is not within its valid time. Check the clock of this computer and the validity period of the certificate.'
        }

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
            '700024'  = @{ Category = 'Unauthorized';      Hint = $assertionTimeHint }
            '70021'   = @{ Category = 'Unauthorized';      Hint = ('No federated credential on the app matches this token. {0}' -f $federationHint) }
            '700211'  = @{ Category = 'Unauthorized';      Hint = ('No federated credential on the app matches the issuer of this token. {0}' -f $federationHint) }
            '700212'  = @{ Category = 'Unauthorized';      Hint = ('No federated credential on the app matches the audience of this token. {0}' -f $federationHint) }
            '700213'  = @{ Category = 'Unauthorized';      Hint = ('No federated credential on the app matches the subject of this token. {0}' -f $federationHint) }
            '50027'   = @{ Category = 'Unauthorized';      Hint = 'The token is not a valid JWT. Pass the raw token from the platform (three parts separated by dots), not a JSON response or a file path.' }
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
        elseif ($PSCmdlet.ParameterSetName -eq 'FederatedTokenFile' -and -not $isMsalException) {
            # Missing, unreadable or empty token file: nothing reached Entra ID.
            $category = 'AppConfiguration'
            $hint     = 'Check -FederatedTokenFile: the file must exist, be readable by this process and contain the token.'
        }
        elseif ($claims) {
            $category = 'ConditionalAccess'
            $hint     = 'A Conditional Access policy returned a claims challenge. Ask your administrator which policy applies.'
        }
        elseif ($errorCode -in 'invalid_client', 'unauthorized_client', 'access_denied') {
            $category = 'Unauthorized'
            $hint     = if ($isFederated) {
                ('The app was not accepted. Check the federated token and the federated credential. {0}' -f $federationHint)
            }
            else {
                'The app was not accepted. Check the client secret or certificate, and the app registration.'
            }
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
