<#
    .SYNOPSIS
        Imports MSAL.Essentials (twice, to exercise -Force re-import) and
        starts a cancelled connection attempt, to prove the module's
        dependency loading works end to end without opening a browser.

        Run in a clean child process by Lib.Version.Tests.ps1, one process
        per PowerShell edition, and its JSON output is read back by the test.

    .PARAMETER ModuleManifestPath
        Path to MSAL.Essentials.psd1 for the edition under test.
#>
param(
    [Parameter(Mandatory)]
    [string]$ModuleManifestPath
)

$ErrorActionPreference = 'Stop'

try {
    # Goes through the real module manifest - the same entry point any
    # script using this module would use - so this exercises the actual
    # AssemblyResolve handler and dependency loading the module ships with,
    # rather than a copy of that logic maintained separately in the test.
    Import-Module -Name $ModuleManifestPath -Force

    # Add-Type cannot unload an assembly from a running session, so a second
    # -Force import in the same process is the scenario the module's own
    # "skip already-loaded assemblies" guard exists for. Importing a second
    # time here proves that guard actually works, instead of the module
    # only ever being exercised with a single, first-time import.
    Import-Module -Name $ModuleManifestPath -Force

    $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
        '00000000-0000-0000-0000-000000000000'
    ).WithAuthority(
        'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000'
    ).WithRedirectUri(
        'http://localhost'
    ).Build()

    # An already-cancelled token makes MSAL abort the connection attempt as
    # early as possible, before it opens a browser/webview, while still
    # forcing it to build the PKCE challenge and the request pipeline - the
    # same code paths that touch System.Memory, System.Buffers,
    # System.Text.Json, etc. This is not a real login attempt and should
    # never require user interaction.
    $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new()
    $cancellationTokenSource.Cancel()
    $scopes = [string[]]@('User.Read')

    try {
        $publicClientApplication.AcquireTokenInteractive($scopes).ExecuteAsync($cancellationTokenSource.Token).GetAwaiter().GetResult()
    } 
    catch {
        # PowerShell wraps exceptions from direct .NET method calls in a
        # MethodInvocationException, so the real exception has to be found
        # by walking InnerException rather than by a typed catch clause.
        $innermostException = $_.Exception
        while ($innermostException.InnerException) {
            $innermostException = $innermostException.InnerException
        }

        if ($innermostException -isnot [System.OperationCanceledException]) {
            throw $innermostException
        }
        # else: expected - we cancelled on purpose. Reaching this point
        # proves the connection attempt got into MSAL's pipeline without a
        # missing- or mismatched-assembly error.
    }

    [pscustomobject]@{
        Success      = $true
        ClientId     = $publicClientApplication.AppConfig.ClientId
        ErrorMessage = $null
    } | ConvertTo-Json -Compress
}
catch {
    $messages         = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $currentException = $_.Exception

    while ($currentException) {
        $messages.Add($currentException.Message)

        if ($currentException -is [System.Reflection.ReflectionTypeLoadException]) {
            foreach ($loaderException in $currentException.LoaderExceptions) {
                if ($loaderException) { $messages.Add(('LoaderException: {0}' -f $loaderException.Message)) }
            }
        }

        $currentException = $currentException.InnerException
    }

    [pscustomobject]@{
        Success      = $false
        ClientId     = $null
        ErrorMessage = (($messages | Select-Object -Unique) -join ' -> ')
    } | ConvertTo-Json -Compress
}