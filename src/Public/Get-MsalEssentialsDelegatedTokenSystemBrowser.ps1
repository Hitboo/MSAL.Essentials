<#
    .SYNOPSIS
        Acquires a delegated token interactively, using the system's default
        web browser for sign-in.

    .DESCRIPTION
        MSAL starts a short-lived local HTTP listener on the loopback
        address, opens the sign-in page in the user's default browser (Edge,
        Chrome, Firefox, whatever is set), and receives the redirect back on
        that listener once sign-in completes. No popup is drawn by this
        process.

        This is the only interactive flow used here that needs nothing
        beyond the core Microsoft.Identity.Client package already shipped in
        lib\. The embedded-webview flow needs the separate
        Microsoft.Identity.Client.Desktop package (WebView2/WinForms), and
        WAM needs Microsoft.Identity.Client.Broker plus further native
        dependencies - both deliberately left out of this module for now.

        Sign-in is abandoned after -TimeoutSeconds. This matters because
        some errors (for example AADSTS50011, a redirect URI that is not
        registered on the app, or a Conditional Access block) are shown on a
        page hosted by Entra ID in the browser and are never sent back to the
        listener. Without a timeout the call would wait forever; with it, the
        failure surfaces as a Timeout error that lists the usual causes.

        Errors are thrown as terminating errors with a stable
        FullyQualifiedErrorId and a friendly message:
            MsalEssentials.Timeout            sign-in not completed in time
            MsalEssentials.Cancelled          sign-in cancelled
            MsalEssentials.AppConfiguration   redirect URI, app not found, invalid scope
            MsalEssentials.Unauthorized       consent missing, user not assigned, not in tenant
            MsalEssentials.ConditionalAccess  MFA, device, location or other policy requirement
            MsalEssentials.Authentication     any other sign-in failure
        $_.Exception is still the original MSAL exception (except for
        Timeout, where it is a TimeoutException wrapping it), and
        $_.TargetObject carries Category, AadstsCode, ErrorCode,
        CorrelationId and Claims for programmatic handling.

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientId
        The application (client) ID registered in Entra ID.
        Use '14d82eec-204b-4c2f-b7e8-296a70dab67e' for Microsoft Graph Command Line Tools (not recommended for production).

    .PARAMETER Scopes
        The delegated scopes to request. Defaults to Microsoft Graph's
        default scope set.

    .PARAMETER TimeoutSeconds
        How long to wait for the interactive sign-in to complete before
        giving up. Defaults to 300 seconds (5 minutes). Allowed range is
        10 to 3600 seconds.

    .EXAMPLE
        Get-MsalEssentialsDelegatedTokenSystemBrowser -TenantId $tenantId -ClientID $clientId -Scopes 'User.Read'
        Opens the default browser for sign-in and returns the resulting token.

    .EXAMPLE
        Get-MsalEssentialsDelegatedTokenSystemBrowser -TenantId $tenantId -ClientID $clientId -TimeoutSeconds 60
        Gives up after 60 seconds if sign-in has not completed.

    .EXAMPLE
        try {
            $token = Get-MsalEssentialsDelegatedTokenSystemBrowser -TenantId $tenantId -ClientID $clientId
        }
        catch {
            if ($_.TargetObject.Category -eq 'ConditionalAccess') { ... }
        }
#>

function Get-MsalEssentialsDelegatedTokenSystemBrowser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientID,

        [Parameter()]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]
        $TimeoutSeconds = 120
    )

    # Cancels the pending sign-in once the timeout elapses. Disposed in finally.
    $timeoutSource = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds($TimeoutSeconds))

    try {
        $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
            $ClientID
        ).WithAuthority(
            ('https://login.microsoftonline.com/{0}' -f $TenantId)
        ).WithDefaultRedirectUri().Build()

        Write-Verbose -Message ('Waiting up to {0} seconds for sign-in to complete in the default browser.' -f $TimeoutSeconds)

        # $false routes sign-in to the system browser via a local loopback
        # listener instead of drawing a popup inside this process - this is
        # the default on .NET, but explicit here since net472's default is
        # embedded, and this function's whole point is to avoid that path.
        $authenticationResult = $publicClientApplication.AcquireTokenInteractive(
            $Scopes
        ).WithUseEmbeddedWebView(
            $false
        ).ExecuteAsync(
            $timeoutSource.Token
        ).GetAwaiter().GetResult()

        # Deliberately not returning $authenticationResult, $authenticationResult.Account,
        # or $authenticationResult.BindingCertificate - even partially, even via
        # Select-Object -ExcludeProperty. PowerShell's console formatter walks an
        # object's full property graph to print it, and these MSAL/.NET types carry
        # deep and/or self-referencing structures (ClaimsPrincipal, TenantProfiles,
        # certificate chain data) that can drive that walk into a genuine
        # StackOverflowException - which crashes the process immediately and cannot
        # be caught by any try/catch, even one wrapping the original call.
        # Excluding a single named property isn't enough, since the remaining
        # properties can still carry the same kind of depth. Every value below is
        # drilled down to an actual string/bool/datetime leaf, never a nested object.
        return $authenticationResult
    }
    catch {
        # PowerShell wraps exceptions thrown by a directly-called .NET method
        # (like GetResult() here) in a MethodInvocationException, so the
        # real MSAL exception (e.g. MsalClientException, MsalServiceException)
        # is one or more levels down in InnerException, not in $_.Exception
        # itself. Walk the whole chain and prefer the MSAL exception, then a
        # cancellation, then the innermost exception.
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
            $caughtException = $exceptionChain |
                Where-Object -FilterScript { $_ -is [System.OperationCanceledException] } |
                Select-Object -First 1
        }

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

        # Known Entra ID error codes -> category and what to do about it.
        # Not exhaustive: anything not listed falls through to the generic
        # handling below and still reports the original message.
        $redirectUriHint = "Add 'http://localhost' (no port) as a redirect URI on the app registration: Entra admin center > App registrations > your app > Authentication > Add a platform > Mobile and desktop applications. MSAL picks a random port at runtime; Entra ignores the port for http://localhost."
        $mfaHint         = 'A Conditional Access policy requires additional verification. Sign in again and complete the MFA prompt, or ask your administrator which policy applies.'
        $deviceHint      = 'A Conditional Access policy requires a managed, compliant or domain-joined device. Run this from a device that meets the policy, or ask your administrator.'

        # https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
        $knownAadstsErrors = @{
            '50011'  = @{ Category = 'AppConfiguration';  Hint = $redirectUriHint }
            '500113' = @{ Category = 'AppConfiguration';  Hint = $redirectUriHint }
            '700016' = @{ Category = 'AppConfiguration';  Hint = 'The application (client) ID was not found in this tenant. Check -ClientID and -TenantId, and that the app is registered or consented in this tenant.' }
            '70011'  = @{ Category = 'AppConfiguration';  Hint = 'A requested scope is not valid. Check -Scopes.' }
            '65001'  = @{ Category = 'Unauthorized';      Hint = 'The user or an administrator has not consented to the requested permissions. Ask an administrator to grant consent for this app.' }
            '65004'  = @{ Category = 'Unauthorized';      Hint = 'The user declined the consent request. Sign in again and accept it, or ask an administrator to grant consent.' }
            '90094'  = @{ Category = 'Unauthorized';      Hint = 'The requested permissions need administrator consent. Ask an administrator to grant consent for this app.' }
            '50105'  = @{ Category = 'Unauthorized';      Hint = 'The signed-in user is not assigned to this application. Ask an administrator to assign the user (assignment required is enabled).' }
            '50020'  = @{ Category = 'Unauthorized';      Hint = 'The signed-in account does not exist in this tenant (for example a guest that was not invited). Sign in with an account from the tenant or invite the guest.' }
            '50034'  = @{ Category = 'Unauthorized';      Hint = 'The user account does not exist in this directory. Check the account and -TenantId.' }
            '53000'  = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '53001'  = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '530003' = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '53002'  = @{ Category = 'ConditionalAccess'; Hint = 'A Conditional Access policy requires an approved client app. This app is not on the approved list; ask your administrator.' }
            '53003'  = @{ Category = 'ConditionalAccess'; Hint = 'Access was blocked by a Conditional Access policy (for example location, device or risk). Ask your administrator which policy applies.' }
            '53004'  = @{ Category = 'ConditionalAccess'; Hint = 'The user must register for multi-factor authentication first. Complete the MFA registration at https://aka.ms/mfasetup and try again.' }
            '50076'  = @{ Category = 'ConditionalAccess'; Hint = $mfaHint }
            '50079'  = @{ Category = 'ConditionalAccess'; Hint = $mfaHint }
        }

        $errorCategoryMap = @{
            Timeout           = [System.Management.Automation.ErrorCategory]::OperationTimeout
            Cancelled         = [System.Management.Automation.ErrorCategory]::OperationStopped
            AppConfiguration  = [System.Management.Automation.ErrorCategory]::InvalidOperation
            Unauthorized      = [System.Management.Automation.ErrorCategory]::PermissionDenied
            ConditionalAccess = [System.Management.Automation.ErrorCategory]::SecurityError
            Authentication    = [System.Management.Automation.ErrorCategory]::AuthenticationError
        }

        $category         = 'Authentication'
        $summary          = ($caughtException.Message -split '\r?\n')[0]
        $hint             = $null
        $exceptionToThrow = $caughtException

        $isCancellation = $caughtException -is [System.OperationCanceledException] -or $errorCode -eq 'authentication_canceled'

        if ($isCancellation -and $timeoutSource.IsCancellationRequested) {
            $category = 'Timeout'
            $summary  = 'Sign-in was not completed within {0} seconds.' -f $TimeoutSeconds
            # Errors that Entra ID shows on its own page in the browser are not
            # sent back to MSAL, so a timeout is how they show up here.
            $hint     = "If the browser showed an error page, that error is displayed by Entra ID and is not returned to PowerShell; fix the cause named there. Common ones: AADSTS50011 (redirect URI not registered) - $redirectUriHint AADSTS53003 / 53000 / 530003 - blocked by a Conditional Access policy. If the browser never opened or you simply need longer, increase -TimeoutSeconds."
            $exceptionToThrow = [System.TimeoutException]::new($summary, $caughtException)
        }
        elseif ($isCancellation) {
            $category = 'Cancelled'
            $summary  = 'Sign-in was cancelled.'
        }
        elseif ($aadstsCode -and $knownAadstsErrors.ContainsKey($aadstsCode)) {
            $category = $knownAadstsErrors[$aadstsCode].Category
            $hint     = $knownAadstsErrors[$aadstsCode].Hint
        }
        elseif ($claims) {
            # A claims challenge means a policy needs a stronger or different
            # authentication than the one that was just performed.
            $category = 'ConditionalAccess'
            $hint     = 'A Conditional Access policy returned a claims challenge: additional authentication (such as MFA or a specific authentication context) is required. Ask your administrator which policy applies.'
        }
        elseif ($errorCode -in 'access_denied', 'unauthorized_client', 'consent_required') {
            $category = 'Unauthorized'
            $hint     = 'The app or user is not authorized for this request. Check the app registration, granted permissions and consent.'
        }
        elseif ($errorCode -eq 'interaction_required') {
            $category = 'ConditionalAccess'
            $hint     = 'Further interaction is required (for example MFA, a compliant device or consent). Sign in again; if it keeps failing, ask your administrator which Conditional Access policy applies.'
        }
        elseif ($isServiceException -and $caughtException.StatusCode -in 401, 403) {
            $category = 'Unauthorized'
            $hint     = 'The service rejected the request as unauthorized. Check the app registration, granted permissions and consent.'
        }

        $detailLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $detailLines.Add(('Sign-in failed [{0}]: {1}' -f $category, $summary))
        if ($hint) {
            $detailLines.Add(('Hint: {0}' -f $hint))
        }

        $technicalDetails = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if ($aadstsCode)     { $technicalDetails.Add(('AADSTS{0}' -f $aadstsCode)) }
        if ($errorCode)      { $technicalDetails.Add(('ErrorCode: {0}' -f $errorCode)) }
        if ($correlationId)  { $technicalDetails.Add(('CorrelationId: {0}' -f $correlationId)) }
        if ($technicalDetails.Count -gt 0) {
            $detailLines.Add(('Details: {0}' -f ($technicalDetails -join ' | ')))
        }

        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exceptionToThrow,
            ('MsalEssentials.{0}' -f $category),
            $errorCategoryMap[$category],
            [pscustomobject]@{
                Category      = $category
                AadstsCode    = $aadstsCode
                ErrorCode     = $errorCode
                CorrelationId = $correlationId
                Claims        = $claims
                TenantId      = $TenantId
                ClientId      = $ClientID
            }
        )
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(($detailLines -join [System.Environment]::NewLine))

        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
    finally {
        $timeoutSource.Dispose()
    }
}