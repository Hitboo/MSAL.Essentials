<#
    .SYNOPSIS
        Acquires a delegated token with the device code flow: the user signs
        in on another device by entering a code.

    .DESCRIPTION
        NOT RECOMMENDED. Use the system browser sign-in
        (Get-MsalEssentialsDelegatedTokenSystemBrowser) wherever a browser
        can be opened. The device code flow is included for compatibility,
        for example for a session without a browser (SSH, a server core
        installation, a container).

        Why it is not recommended:
          - Phishing: an attacker can start a device code sign-in and send the
            code to a victim. Whoever enters the code signs in the attacker's
            session, and the code page looks like a normal Microsoft sign-in.
          - Conditional Access: many tenants block the device code flow with
            the "Authentication flows" condition, as Microsoft recommends.
            The sign-in then fails with AADSTS53003.

        MSAL asks Entra ID for a device code, and this function writes the
        message that comes with it to the host, for example "To sign in, use
        a web browser to open the page https://microsoft.com/devicelogin and
        enter the code ABCD1234 to authenticate." MSAL then polls Entra ID
        until the user has signed in, declined, or the code has expired
        (usually after 15 minutes).

        The app registration needs "Allow public client flows" set to Yes
        (Entra admin center > App registrations > your app > Authentication >
        Advanced settings). Otherwise Entra ID answers with AADSTS7000218. No
        redirect URI is needed.

        Errors are thrown as terminating errors with a stable
        FullyQualifiedErrorId and a friendly message, like in
        Get-MsalEssentialsDelegatedTokenSystemBrowser:
            MsalEssentials.Timeout            code expired or -TimeoutSeconds elapsed
            MsalEssentials.Cancelled          sign-in declined or cancelled
            MsalEssentials.AppConfiguration   public client flows off, app not found, invalid scope
            MsalEssentials.Unauthorized       consent missing, user not assigned, not in tenant
            MsalEssentials.ConditionalAccess  device code flow blocked, MFA or other policy requirement
            MsalEssentials.Authentication     any other sign-in failure
        $_.Exception is still the original MSAL exception (except for
        Timeout after -TimeoutSeconds, where it is a TimeoutException
        wrapping it), and $_.TargetObject carries Category, AadstsCode,
        ErrorCode, CorrelationId and Claims for programmatic handling.

    .PARAMETER TenantId
        The directory (tenant) ID or verified domain to authenticate against.

    .PARAMETER ClientId
        The application (client) ID registered in Entra ID.
        Use '14d82eec-204b-4c2f-b7e8-296a70dab67e' for Microsoft Graph Command Line Tools (not recommended for production).

    .PARAMETER Scopes
        The delegated scopes to request. Defaults to Microsoft Graph's
        default scope set.

    .PARAMETER TimeoutSeconds
        How long to wait for the sign-in to complete before giving up.
        Defaults to 300 seconds (5 minutes). Allowed range is 1 to 900
        seconds: 900 seconds (15 minutes) is the usual lifetime of a device
        code, so waiting longer would not help. If the code expires first,
        MSAL stops on its own and the sign-in fails with
        MsalEssentials.Timeout.

    .PARAMETER ApplicationReference
        A [ref] variable that receives the MSAL client application used for
        the sign-in. Keep it to renew the token silently later:
        AcquireTokenSilent needs the same client instance, because the
        refresh token lives in its in-memory cache.

    .EXAMPLE
        Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId $tenantId -ClientId $clientId -Scopes 'User.Read'
        Shows a device code, waits until the user has signed in with it on another device, and returns the token.

    .EXAMPLE
        $publicClientApplication = $null
        $token = Get-MsalEssentialsDelegatedTokenDeviceCode -TenantId $tenantId -ClientId $clientId -ApplicationReference ([ref]$publicClientApplication)
        Returns the token and also stores the MSAL client in $publicClientApplication.

    .LINK
        https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code

    .LINK
        https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-authentication-flows
#>

function Get-MsalEssentialsDelegatedTokenDeviceCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientId,

        [Parameter()]
        [string[]]
        $Scopes = @('https://graph.microsoft.com/.default'),

        [Parameter()]
        # At most the usual lifetime of a device code (expires_in, 15 minutes).
        [ValidateRange(1, 900)]
        [int]
        $TimeoutSeconds = 300,

        [Parameter()]
        [ref]
        $ApplicationReference
    )

    # Cancels the pending sign-in once the timeout elapses, or when the wait
    # is stopped (Ctrl+C). Cancelled and disposed in finally.
    $timeoutSource = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds($TimeoutSeconds))

    try {
        #region Build the MSAL client

        # No redirect URI: the device code flow never returns to this process.
        $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
            $ClientId
        ).WithAuthority(
            ('https://login.microsoftonline.com/{0}' -f $TenantId)
        ).Build()

        #endregion Build the MSAL client

        # Hand the client back to the caller, if asked, so it can renew the
        # token silently later. Only useful to the caller if sign-in succeeds.
        if ($ApplicationReference) {
            $ApplicationReference.Value = $publicClientApplication
        }

        Write-Verbose -Message ('Requesting a device code, waiting up to {0} seconds for the sign-in to complete.' -f $TimeoutSeconds)

        #region Acquire the token with a device code

        # Returns the full MSAL AuthenticationResult. Don't print it to the
        # console (see Get-MsalEssentialsDelegatedTokenSystemBrowser).
        # Wait-MsalEssentialsDeviceCodeTask shows the device code and keeps
        # the wait from deadlocking on a UI thread (WPF, WinForms).
        return Wait-MsalEssentialsDeviceCodeTask -ScriptBlock {
            param ($deviceCodeCallback)

            $publicClientApplication.AcquireTokenWithDeviceCode(
                [string[]]$Scopes,
                $deviceCodeCallback
            ).ExecuteAsync(
                $timeoutSource.Token
            )
        }

        #endregion Acquire the token with a device code
    }
    catch {
        #region exception handling

        # The real MSAL exception can be wrapped (MethodInvocationException,
        # AggregateException), so walk the whole chain and prefer the MSAL
        # exception, then a cancellation, then the innermost exception.
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
        $publicClientHint = 'The app registration does not allow the device code flow. Set "Allow public client flows" to Yes: Entra admin center > App registrations > your app > Authentication > Advanced settings. Or sign in through the browser instead (Connect-MsalEssentials without -UseDeviceCode).'
        $blockedHint      = 'Access was blocked by a Conditional Access policy. Many tenants block the device code flow on purpose (Conditional Access > Conditions > Authentication flows). Sign in through the browser instead (Connect-MsalEssentials without -UseDeviceCode), or ask your administrator which policy applies.'
        $deviceHint       = 'A Conditional Access policy requires a managed, compliant or domain-joined device. With the device code flow, that is the device where the code was entered. Sign in through the browser on a device that meets the policy, or ask your administrator.'
        $mfaHint          = 'A Conditional Access policy requires additional verification. Sign in again and complete the MFA prompt, or ask your administrator which policy applies.'

        # https://learn.microsoft.com/en-us/entra/identity-platform/reference-error-codes
        $knownAadstsErrors = @{
            '7000218' = @{ Category = 'AppConfiguration';  Hint = $publicClientHint }
            '700016'  = @{ Category = 'AppConfiguration';  Hint = 'The application (client) ID was not found in this tenant. Check -ClientId and -TenantId, and that the app is registered or consented in this tenant.' }
            '70011'   = @{ Category = 'AppConfiguration';  Hint = 'A requested scope is not valid. Check -Scopes.' }
            '65001'   = @{ Category = 'Unauthorized';      Hint = 'The user or an administrator has not consented to the requested permissions. Ask an administrator to grant consent for this app.' }
            '65004'   = @{ Category = 'Unauthorized';      Hint = 'The user declined the consent request. Sign in again and accept it, or ask an administrator to grant consent.' }
            '90094'   = @{ Category = 'Unauthorized';      Hint = 'The requested permissions need administrator consent. Ask an administrator to grant consent for this app.' }
            '50105'   = @{ Category = 'Unauthorized';      Hint = 'The signed-in user is not assigned to this application. Ask an administrator to assign the user (assignment required is enabled).' }
            '50020'   = @{ Category = 'Unauthorized';      Hint = 'The signed-in account does not exist in this tenant (for example a guest that was not invited). Sign in with an account from the tenant or invite the guest.' }
            '50034'   = @{ Category = 'Unauthorized';      Hint = 'The user account does not exist in this directory. Check the account and -TenantId.' }
            '53000'   = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '53001'   = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '530003'  = @{ Category = 'ConditionalAccess'; Hint = $deviceHint }
            '53002'   = @{ Category = 'ConditionalAccess'; Hint = 'A Conditional Access policy requires an approved client app. This app is not on the approved list; ask your administrator.' }
            '53003'   = @{ Category = 'ConditionalAccess'; Hint = $blockedHint }
            '53004'   = @{ Category = 'ConditionalAccess'; Hint = 'The user must register for multi-factor authentication first. Complete the MFA registration at https://aka.ms/mfasetup and try again.' }
            '50076'   = @{ Category = 'ConditionalAccess'; Hint = $mfaHint }
            '50079'   = @{ Category = 'ConditionalAccess'; Hint = $mfaHint }
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
            $hint     = 'Open the page from the message on any device, enter the code and sign in before the time runs out. If you need longer, increase -TimeoutSeconds (at most 900 seconds, the usual lifetime of a device code).'
            $exceptionToThrow = [System.TimeoutException]::new($summary, $caughtException)
        }
        elseif ($isCancellation) {
            $category = 'Cancelled'
            $summary  = 'Sign-in was cancelled.'
        }
        elseif ($errorCode -in 'code_expired', 'expired_token') {
            # code_expired: MSAL stopped polling, expired_token: Entra ID said so.
            $category = 'Timeout'
            $summary  = 'The device code expired before the sign-in was completed.'
            $hint     = 'Run Connect-MsalEssentials -UseDeviceCode again and enter the new code within its lifetime (usually 15 minutes).'
        }
        elseif ($errorCode -in 'authorization_declined', 'access_denied') {
            $category = 'Cancelled'
            $summary  = 'Sign-in was declined on the device where the code was entered.'
            $hint     = 'If you did not start this sign-in yourself, someone may have tried to phish you with a device code: decline it and tell your administrator.'
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
        elseif ($errorCode -in 'unauthorized_client', 'consent_required') {
            $category = 'Unauthorized'
            $hint     = 'The app or user is not authorized for this request. Check the app registration, granted permissions and consent.'
        }
        elseif ($errorCode -eq 'interaction_required') {
            $category = 'ConditionalAccess'
            $hint     = 'Further interaction is required (for example MFA, a compliant device or consent). Sign in again; if it keeps failing, sign in through the browser instead or ask your administrator which Conditional Access policy applies.'
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
                ClientId      = $ClientId
            }
        )
        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(($detailLines -join [System.Environment]::NewLine))

        $PSCmdlet.ThrowTerminatingError($errorRecord)
        #endregion exception handling
    }
    finally {
        # Also stops MSAL from polling on when the wait was stopped with Ctrl+C.
        $timeoutSource.Cancel()
        $timeoutSource.Dispose()
    }
}
