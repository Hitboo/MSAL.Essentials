<#
    .SYNOPSIS
        Builds the MsalEssentials.Connection object from the stored session.

    .DESCRIPTION
        Private helper used by Connect-MsalEssentials and
        Get-MsalEssentialsToken so both return the same object.

        The object is made only of strings, a string array and a date, so it
        is safe to print, unlike the full MSAL AuthenticationResult. All values
        are read from the session's current AuthenticationResult, so they are
        never stale after a silent token refresh.

        AccessToken is a credential. It is hidden from the default console
        display, but Format-List *, ConvertTo-Json, Export-Clixml and similar
        commands will include it.

    .PARAMETER Session
        The module session hashtable ($script:MsalEssentialsSession).
#>

function ConvertTo-MsalEssentialsConnection {
    [CmdletBinding()]
    [OutputType('MsalEssentials.Connection')]
    param (
        [Parameter(Mandatory)]
        [hashtable]
        $Session
    )

    $authenticationResult = $Session.AuthenticationResult
    $username             = if ($authenticationResult.Account) { $authenticationResult.Account.Username } else { $null }

    $connection = [pscustomobject]@{
        PSTypeName         = 'MsalEssentials.Connection'
        AuthenticationType = $Session.AuthenticationType
        TenantId           = $authenticationResult.TenantId
        ClientId           = $Session.ClientId
        Username           = $username
        Scopes             = @($authenticationResult.Scopes)
        ExpiresOn          = $authenticationResult.ExpiresOn
        AccessToken        = $authenticationResult.AccessToken
    }

    # Same method name MSAL's AuthenticationResult has, so existing code
    # that calls CreateAuthorizationHeader() keeps working.
    $connection | Add-Member -MemberType 'ScriptMethod' -Name 'CreateAuthorizationHeader' -Value {
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