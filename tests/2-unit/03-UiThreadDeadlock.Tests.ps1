<#
    Behaviour tests for Connect > Disconnect > Connect on a UI thread (WPF,
    WinForms), where the second Connect-MsalEssentials used to freeze, and
    for Wait-MsalEssentialsTask (private), which fixes it.
    3-integration\03-UiThreadDeadlock.Tests.ps1 runs the same sequence
    against a real tenant on a real WPF Dispatcher.

    Why only the second Connect: MSAL's system browser sign-in awaits its
    loopback listener without ConfigureAwait(false), so it captures the UI
    thread's SynchronizationContext and posts its continuation back to it.
    The first sign-in in a process happens to escape this, because it starts
    with an instance discovery request and continues on the thread pool after
    it. MSAL caches that metadata for the whole process, so every later
    sign-in reaches the listener on the UI thread. That thread is blocked in
    GetResult(), so the posted continuation never runs.

    A fake UI context counts what is posted to it and runs it on the thread
    pool, so a regression shows up as a failed assertion instead of a
    hanging test run.

    No browser and no network are used:
        - The Wait-MsalEssentialsTask tests use UiThreadWork, which awaits
          like MSAL does.
        - The real MSAL tests turn instance discovery off (which makes every
          sign-in behave like the second one) and replace the browser with a
          delegate that does nothing. The sign-in is cancelled after a second.
        - The command tests mock the sign-in helper, as in
          01-Connection.Tests.ps1, but hand out an MSAL client whose methods
          return real .NET tasks, so the waits in Get-MsalEssentialsToken and
          Disconnect-MsalEssentials are exercised.
        - The sign-in helper itself can't be run without opening a browser,
          so a source check makes sure it waits through
          Wait-MsalEssentialsTask too.

    Why global: the mock bodies run in the module's scope and cannot see
    variables from this file's scope, but they can see global ones.
    Everything global here starts with MsalUiTest and is removed in AfterAll.
#>

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:SourcePath   = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src')).Path
    $script:ManifestPath = Join-Path -Path $script:SourcePath -ChildPath 'MSAL.Essentials.psd1'
    $script:TenantId     = 'hitboo.test'
    $script:ClientId     = '11111111-1111-1111-1111-111111111111'

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # Add-Type cannot redefine a type, so skip it when the file runs again in the same session.
    # Windows PowerShell 5.1 compiles with C# 5 - keep this source C# 5 compatible.
    if (-not ('MsalEssentialsTest.UiThreadContext' -as [type])) {
        Add-Type -Language 'CSharp' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace MsalEssentialsTest
{
    // Stands in for the Dispatcher of a WPF window. Counts what is posted to
    // it, but runs it on the thread pool so a blocked caller still finishes.
    public class UiThreadContext : SynchronizationContext
    {
        private int _postCount;

        public int PostCount { get { return _postCount; } }

        public override void Post(SendOrPostCallback callback, object state)
        {
            Interlocked.Increment(ref _postCount);
            ThreadPool.QueueUserWorkItem(delegate { callback(state); });
        }
    }

    // Stands in for an MSAL call: awaits without ConfigureAwait(false), so it
    // captures the caller's SynchronizationContext.
    public static class UiThreadWork
    {
        public static async Task<string> GetValueAsync(string value)
        {
            await Task.Delay(50);
            return value;
        }

        public static async Task<string> FailAsync(string message)
        {
            await Task.Delay(50);
            throw new InvalidOperationException(message);
        }
    }

    // Replaces the browser in SystemWebViewOptions.OpenBrowserAsync.
    public static class NoBrowser
    {
        public static Func<Uri, Task> Open = delegate(Uri uri) { return Task.FromResult(0); };
    }

    // Stands in for the MSAL PublicClientApplication. Every method awaits
    // without ConfigureAwait(false), like MSAL's sign-in does, so it posts
    // back to the caller's SynchronizationContext unless that was cleared.
    public class UiThreadClient
    {
        private readonly object _silentResult;

        public UiThreadClient(object silentResult)
        {
            _silentResult   = silentResult;
            Accounts        = new List<object> { "user@hitboo.test" };
            RemovedAccounts = new List<object>();
        }

        public List<object> Accounts { get; private set; }
        public List<object> RemovedAccounts { get; private set; }
        public int SilentCallCount { get; private set; }

        public UiThreadSilentRequest AcquireTokenSilent(string[] scopes, object account)
        {
            SilentCallCount++;
            return new UiThreadSilentRequest(_silentResult);
        }

        public async Task<IEnumerable<object>> GetAccountsAsync()
        {
            await Task.Delay(20);
            return Accounts.ToArray();
        }

        public async Task RemoveAsync(object account)
        {
            await Task.Delay(20);
            RemovedAccounts.Add(account);
        }
    }

    public class UiThreadSilentRequest
    {
        private readonly object _result;

        public UiThreadSilentRequest(object result)
        {
            _result = result;
        }

        public UiThreadSilentRequest WithForceRefresh(bool forceRefresh)
        {
            return this;
        }

        public async Task<object> ExecuteAsync()
        {
            await Task.Delay(20);
            return _result;
        }
    }
}
'@
    }

    # A fake MSAL AuthenticationResult with only what the module reads.
    function global:New-MsalUiTestAuthResult {
        param (
            [string]$AccessToken
        )

        [pscustomobject]@{
            AccessToken = $AccessToken
            ExpiresOn   = [System.DateTimeOffset]::UtcNow.AddMinutes(60)
            TenantId    = '00000000-0000-0000-0000-000000000001'
            Scopes      = [string[]]@('User.Read')
            Account     = [pscustomobject]@{ Username = 'user@hitboo.test' }
        }
    }

    # Starts a real MSAL system browser sign-in that opens no browser and
    # needs no network, and is cancelled after a second. Returns its task.
    function global:Start-MsalUiTestNoBrowserSignIn {
        $publicClientApplication = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create(
            '11111111-1111-1111-1111-111111111111'
        ).WithAuthority(
            'https://login.microsoftonline.com/organizations'
        ).WithRedirectUri(
            'http://localhost'
        ).WithInstanceDiscovery(
            $false # no network; makes every sign-in behave like the second one in a process
        ).Build()

        $webViewOptions = [Microsoft.Identity.Client.SystemWebViewOptions]::new()
        $webViewOptions.OpenBrowserAsync = [MsalEssentialsTest.NoBrowser]::Open

        # Not disposed: the token must stay usable until the task is cancelled.
        $timeoutSource = [System.Threading.CancellationTokenSource]::new([System.TimeSpan]::FromSeconds(1))

        return $publicClientApplication.AcquireTokenInteractive(
            [string[]]@('User.Read')
        ).WithUseEmbeddedWebView(
            $false
        ).WithSystemWebViewOptions(
            $webViewOptions
        ).ExecuteAsync(
            $timeoutSource.Token
        )
    }
}

AfterAll {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'

    Remove-Item -Path 'Function:\New-MsalUiTestAuthResult', 'Function:\Start-MsalUiTestNoBrowserSignIn' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Name 'MsalUiTest' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'MSAL.Essentials on a UI thread' {
    BeforeEach {
        $script:UiContext = [MsalEssentialsTest.UiThreadContext]::new()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($script:UiContext)
    }

    AfterEach {
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)
    }

    Context 'Wait-MsalEssentialsTask' {
        It 'test setup: a plain GetResult() posts back to the UI context' {
            # Proves the fake context detects the problem, so the tests below mean something.
            $null = [MsalEssentialsTest.UiThreadWork]::GetValueAsync('value').GetAwaiter().GetResult()

            $script:UiContext.PostCount |
                Should -BeGreaterThan 0
        }

        It 'returns the result of the task' {
            $result = InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::GetValueAsync('token') }
            }

            $result |
                Should -Be 'token'
        }

        It 'posts nothing to the UI context' {
            $null = InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::GetValueAsync('token') }
            }

            $script:UiContext.PostCount |
                Should -Be 0
        }

        It 'restores the UI context afterwards' {
            $null = InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::GetValueAsync('token') }
            }

            [System.Threading.SynchronizationContext]::Current |
                Should -Be $script:UiContext
        }

        It 'leaves no context when there was none (console host)' {
            [System.Threading.SynchronizationContext]::SetSynchronizationContext($null)

            $null = InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::GetValueAsync('token') }
            }

            [System.Threading.SynchronizationContext]::Current |
                Should -BeNullOrEmpty
        }

        It 'throws when the task fails, with the original exception in the chain' {
            # The sign-in helpers walk InnerException to find the MSAL exception,
            # so it must still be reachable through the PowerShell wrapper.
            $caughtError = $null
            try {
                InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                    Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::FailAsync('sign-in failed') }
                }
            }
            catch {
                $caughtError = $_
            }

            $exceptionChain   = New-Object -TypeName 'System.Collections.Generic.List[System.Exception]'
            $currentException = $caughtError.Exception
            while ($currentException) {
                $exceptionChain.Add($currentException)
                $currentException = $currentException.InnerException
            }

            $exceptionChain |
                Where-Object -FilterScript { $_ -is [System.InvalidOperationException] -and $_.Message -eq 'sign-in failed' } |
                Should -Not -BeNullOrEmpty
        }

        It 'restores the UI context when the task fails' {
            try {
                InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                    Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::FailAsync('sign-in failed') }
                }
            }
            catch {
                # Expected; only the context matters here.
            }

            [System.Threading.SynchronizationContext]::Current |
                Should -Be $script:UiContext
        }

        It 'sees variables of the caller inside the script block' {
            # The call sites pass script blocks such as { $tokenRequest.ExecuteAsync() }.
            $result = InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                $expectedValue = 'from-caller'
                Wait-MsalEssentialsTask -ScriptBlock { [MsalEssentialsTest.UiThreadWork]::GetValueAsync($expectedValue) }
            }

            $result |
                Should -Be 'from-caller'
        }
    }

    Context 'Real MSAL sign-in (no browser, no network)' {
        It 'test setup: a plain GetResult() posts the sign-in back to the UI thread (the deadlock cause)' {
            # Proves that MSAL really does this, so the test below means something.
            # The sign-in is cancelled, which is expected; only the posts matter.
            try {
                $null = (Start-MsalUiTestNoBrowserSignIn).GetAwaiter().GetResult()
            }
            catch {
                # Expected: cancelled after a second.
            }

            $script:UiContext.PostCount |
                Should -BeGreaterThan 0
        }

        It 'Wait-MsalEssentialsTask keeps the sign-in off the UI thread' {
            try {
                InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                    $null = Wait-MsalEssentialsTask -ScriptBlock { Start-MsalUiTestNoBrowserSignIn }
                }
            }
            catch {
                # Only a cancellation is expected here. Anything else, such as
                # a missing Wait-MsalEssentialsTask, fails the test.
                $_.Exception.ToString() |
                    Should -Match 'OperationCanceledException|authentication_canceled'
            }

            $script:UiContext.PostCount |
                Should -Be 0
        }
    }

    Context 'Connect > Disconnect > Connect (simulated MSAL client)' {
        BeforeEach {
            InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Remove-Variable -Name 'MsalEssentialsSession' -Scope 'Script' -ErrorAction 'SilentlyContinue'
            }

            # A new client for every sign-in, like the real helper builds one.
            $global:MsalUiTest = @{
                Clients = [System.Collections.Generic.List[object]]::new()
            }

            Mock -ModuleName $script:ModuleName -CommandName 'Get-MsalEssentialsDelegatedTokenSystemBrowser' -MockWith {
                $client = [MsalEssentialsTest.UiThreadClient]::new((New-MsalUiTestAuthResult -AccessToken 'renewed-access-token'))
                $global:MsalUiTest.Clients.Add($client)

                if ($ApplicationReference) {
                    $ApplicationReference.Value = $client
                }

                New-MsalUiTestAuthResult -AccessToken ('access-token-{0}' -f $global:MsalUiTest.Clients.Count)
            }
        }

        It 'runs the whole sequence without posting to the UI thread' {
            $connectParameters = @{
                TenantId = $script:TenantId
                ClientId = $script:ClientId
            }

            foreach ($round in 1, 2) {
                Connect-MsalEssentials @connectParameters -ErrorAction 'Stop'
                # 1440 minutes forces a silent renewal through the client.
                $null = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'
                Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'Stop'
            }

            $script:UiContext.PostCount |
                Should -Be 0
        }

        It 'signs in, renews and removes the account in both rounds' {
            $connectParameters = @{
                TenantId = $script:TenantId
                ClientId = $script:ClientId
            }

            $accessTokens = foreach ($round in 1, 2) {
                Connect-MsalEssentials @connectParameters -ErrorAction 'Stop'
                (Get-MsalEssentialsToken -ErrorAction 'Stop').AccessToken
                (Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop').AccessToken
                Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'Stop'
            }

            $accessTokens |
                Should -Be @('access-token-1', 'renewed-access-token', 'access-token-2', 'renewed-access-token')

            $global:MsalUiTest.Clients |
                ForEach-Object -Process {
                    $_.SilentCallCount |
                        Should -Be 1
                    $_.RemovedAccounts |
                        Should -Be @('user@hitboo.test')
                }
        }

        It 'restores the UI context after each command' {
            Connect-MsalEssentials -TenantId $script:TenantId -ClientId $script:ClientId -ErrorAction 'Stop'
            $null = Get-MsalEssentialsToken -RefreshBeforeExpiryMinutes 1440 -ErrorAction 'Stop'

            [System.Threading.SynchronizationContext]::Current |
                Should -Be $script:UiContext

            Disconnect-MsalEssentials -InformationAction 'SilentlyContinue' -ErrorAction 'Stop'

            [System.Threading.SynchronizationContext]::Current |
                Should -Be $script:UiContext
        }
    }

    Context 'Source' {
        It 'waits on MSAL tasks only through Wait-MsalEssentialsTask' {
            # A direct GetAwaiter() in any other function would block a UI
            # thread again. This also covers the interactive sign-in in
            # Get-MsalEssentialsDelegatedTokenSystemBrowser, which the tests
            # above can't run without opening a browser.
            $directWaits = Get-ChildItem -Path $script:SourcePath -Filter '*.ps1' -Recurse |
                Where-Object -FilterScript { $_.BaseName -ne 'Wait-MsalEssentialsTask' } |
                ForEach-Object -Process {
                    $fileName = $_.Name
                    $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                    $syntaxTree.FindAll({
                        param ($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                            $node.Member.Value -eq 'GetAwaiter'
                    }, $true) |
                        ForEach-Object -Process { '{0}:{1}' -f $fileName, $_.Extent.StartLineNumber }
                }

            $directWaits |
                Should -BeNullOrEmpty
        }
    }
}
