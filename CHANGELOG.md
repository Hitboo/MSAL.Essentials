# Changelog<!-- omit from toc -->

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Table of contents<!-- omit from toc -->

- [\[1.2.0\] - 2026-10-23](#120---2026-10-23)
  - [TL;DR](#tldr)
  - [Changed](#changed)
- [\[1.1.1\] - 2026-10-23](#111---2026-10-23)
  - [Changed](#changed)
- [\[1.1.0\] - 2026-10-20](#110---2026-10-20)
  - [TL;DR](#tldr)
  - [Added](#added)
  - [Fixed](#fixed)
- [\[1.0.0\] - 2026-10-16](#100---2026-10-16)

## [1.2.0] - 2026-10-23

### TL;DR
- The parameter `-ClientID` is now spelled `-ClientId`. PowerShell ignores the letter case, so existing calls keep working.

### Changed

- Parameter `-ClientID` renamed to `-ClientId` (PascalCase, consistent with the `ClientId` property of the connection). Calls with `-ClientID` still work, because PowerShell parameter names are not case-sensitive.

## [1.1.1] - 2026-10-23

### Changed

- Bundled MSAL.NET (`Microsoft.Identity.Client`) updated from 4.90.1 to 4.91.1 in `src/lib` for Windows PowerShell 5.1 (`net472`) and PowerShell 7 (`netstandard2.0`), as proposed by the dependency check (issue #12).
  - The dependencies of both targets are unchanged and still pinned in `dependencies.json`.
  - No changes to the module's commands or parameters.

## [1.1.0] - 2026-10-20

### TL;DR

- New optional parameter `-LoginHintUpn` for `Connect-MsalEssentials` to pre-fill the username in the browser.
- Fix: `Disconnect-MsalEssentials` no longer writes `VoidTaskResult` to the pipeline.
- Unit and integration tests for the login hint.
- Weekly dependency check for the bundled MSAL libraries (workflow and `Test-MsalLibDependencies.ps1`).
- The 1.0.0 entry below now also lists release workflow details that were missing.

### Added

- **Functions**
  - New parameter `LoginHintUpn` on `Connect-MsalEssentials` and `Get-MsalEssentialsDelegatedTokenSystemBrowser`. It pre-fills the username/email field in the browser with a user principal name (UPN).
    - It is only a hint, not a guarantee: the user can still change it or sign in with a different account.
    - Useful for guest sign-ins, where it points to the right account in the target tenant, and to save users from typing their address.
    - With a hint, the sign-in uses the `NoPrompt` behavior: if the browser already has a session for that account, sign-in can complete without asking for credentials. The hint is only shown as pre-filled when the browser has no signed-in session; otherwise Entra ID uses the session (or its account picker) and the hint does not appear.
    - The value must look like a UPN (`name@domain.tld`).
- **Tests**
  - Unit tests: `-LoginHintUpn` is passed on to the sign-in only when given, invalid values (no `@`, no user name, no domain, no domain dot, two `@`, a space, empty, `$null`) are rejected, and `Disconnect-MsalEssentials` writes nothing to the pipeline.
  - Integration tests:
    - Sign-in with a login hint against a real tenant. It runs only when `MSAL_TEST_LOGIN_HINT_UPN` is set (see the header of `tests/3-integration/01-SignIn.Tests.ps1`).
    - A hard-coded hint (`user@hitboo.test`) must not sign in by itself: it ends as `MsalEssentials.Timeout` and stores no connection, which confirms nothing is pre-authenticated.
    - An invalid, empty or `$null` hint is rejected before a browser opens.
- **Build**
  - `build/Test-MsalLibDependencies.ps1` checks the libraries bundled in `src/lib` for known vulnerabilities (NuGet audit, transitive packages included) and for a newer `Microsoft.Identity.Client` release on nuget.org, without changing anything. Updating is still done with `Update-MsalLibDependencies.ps1`.
- **Workflow**
  - `.github/workflows/dependency-check.yml` runs the check above every Monday and on demand. A vulnerability of severity Moderate or higher (or an audit that could not run) fails the run; a newer MSAL.NET opens (and later closes) an issue labeled `msal-update`.

### Fixed

- `Disconnect-MsalEssentials` no longer writes `System.Threading.Tasks.VoidTaskResult` to the pipeline when it removes the cached accounts.

## [1.0.0] - 2026-10-16

### TL;DR

- Initial release with minimal capabilities to get started.
- No application or managed identity auth flows yet.
- Documentation
- **Added Functions**
  - Connect-MsalEssentials
  - Get-MsalEssentialsToken
  - Disconnect-MsalEssential
- **Added Helper functions**
  - ConvertTo-MsalEssentialsConnection
  - Get-MsalEssentialsDelegatedTokenSystemBrowser
- Bundled MSAL libraries + function Update-MsalLibDependencies.ps1
- Pester testfiles
- Release builder and workflow ci

### Added

- **Functions (public)**
  - `Connect-MsalEssentials`: signs in as the current user through the system's default browser (delegated rights) and keeps the connection in module scope for the PowerShell session. Nothing is written to disk.
    - `-PassThru` returns the connection: `AuthenticationType`, `TenantId`, `ClientId`, `Username`, `Scopes`, `ExpiresOn` and `AccessToken`, plus a `CreateAuthorizationHeader()` method. The token is hidden from the default console display.
    - `-RedirectUri` is passed on to the sign-in, so the default and the validation live in one place.
    - Parameter sets are prepared for future app (certificate, token) and managed identity connections.
  - `Get-MsalEssentialsToken`: returns the connection with a valid token. A token that expires within `-RefreshBeforeExpiryMinutes` (default 15) is renewed silently, without opening a browser.
    - It never signs in by itself. Without a connection, or when the token has expired and cannot be renewed silently, it fails and asks you to run `Connect-MsalEssentials`.
    - If renewal fails but the current token is still valid, the current token is returned together with a warning.
  - `Disconnect-MsalEssentials`: clears the accounts and tokens from the MSAL client's cache and removes the stored connection. It shows a hint to remove variables that still hold the token.
- **Helper functions (private)**
  - `Get-MsalEssentialsDelegatedTokenSystemBrowser`: interactive delegated sign-in through the system browser, using a loopback redirect URI (default `http://localhost`).
    - `-TimeoutSeconds` (default 120, range 1 to 3600) stops waiting for a sign-in that never completes.
    - `-RedirectUri` (default `http://localhost`) sets the redirect URI MSAL listens on, for example a fixed port such as `http://localhost:1234`. It must be well-formed and absolute, and it must be registered on the app registration under *Mobile and desktop applications*. Entra ID ignores the port when matching a localhost URI, but the path must match exactly, including letter case. Only loopback addresses work with the system browser.
    - `-ApplicationReference` hands back the MSAL client so the token can be renewed silently later.
  - `ConvertTo-MsalEssentialsConnection`: builds the `MsalEssentials.Connection` object returned by `Connect-MsalEssentials -PassThru` and `Get-MsalEssentialsToken`, so both commands return the same object.
    - The object holds only strings, a string array and a date, so it is safe to print, unlike the full MSAL `AuthenticationResult`.
    - Values are read from the session's current token, so they stay correct after a silent renewal.
    - `AccessToken` is hidden from the default console display but stays a normal property. `Format-List *`, `ConvertTo-Json` and `Export-Clixml` still include it.
- **Error handling for delegated sign-in** (system browser), raised by `Get-MsalEssentialsDelegatedTokenSystemBrowser` and passed through unchanged by `Connect-MsalEssentials`. Errors are terminating errors with a friendly message, a hint for known Entra ID error codes (redirect URI, consent, Conditional Access and others), and a stable `FullyQualifiedErrorId`:
  - `MsalEssentials.Timeout`
  - `MsalEssentials.Cancelled`
  - `MsalEssentials.AppConfiguration`
  - `MsalEssentials.Unauthorized`
  - `MsalEssentials.ConditionalAccess`
  - `MsalEssentials.Authentication`
  - **In most cases a failed sign-in surfaces as `MsalEssentials.Timeout`.** Entra ID shows many errors (for example a redirect URI that is not registered, or a Conditional Access block) on its own page in the browser and does not send them back to PowerShell, so MSAL keeps waiting until the timeout. The timeout message lists the usual causes, but the actual error and its AADSTS code are only visible on the page in the browser. The other categories apply when Entra ID does return the error, for example a declined consent or a claims challenge.
  - `$_.Exception` is still the original MSAL exception and `$_.TargetObject` carries `Category`, `AadstsCode`, `ErrorCode`, `CorrelationId` and `Claims`.
  - The connection commands add `MsalEssentials.NotConnected`, `MsalEssentials.ReconnectRequired`, `MsalEssentials.RenewalNotSupported` and `MsalEssentials.NoToken`.
  - A redirect URI that MSAL rejects as not being a loopback address is reported as `MsalEssentials.AppConfiguration`, with a hint to use a loopback address.
  - The redirect URI hints name the URI that was actually used, so they tell you exactly what to register on the app.
- **Bundled MSAL libraries** in `src/lib` for Windows PowerShell 5.1 (`net472`) and PowerShell 7 (`netstandard2.0`): `Microsoft.Identity.Client` 4.90.1 and its dependencies, with the versions pinned in `dependencies.json`.
  - `build/Update-MsalLibDependencies.ps1` updates the bundled libraries and checks that the references between the DLLs match.
- **Tests** (Pester 6.2.0 or later) and the runner `tests/Start-Test.ps1`:
  - `Start-Test.ps1` makes sure Pester 6.2.0 or later is loaded and supports `-TestsPath`, `-Verbosity` (default `Detailed`) and `-AllEditions` (runs the suite under Windows PowerShell 5.1 and PowerShell 7).
  - A check that the required Pester version is loaded.
  - Library versions: each package in `dependencies.json` is present in `lib` at the pinned version.
  - Module import: files exist, the manifest is valid, the module imports without errors or warnings in the current session and in a fresh process of the same PowerShell edition, and the expected commands are exported.
  - A probe run in a clean process that imports the module twice with `-Force`, builds an MSAL client and starts a cancelled sign-in, to catch missing or mismatched dependencies without opening a browser.
  - Simulated connection tests: `Connect-MsalEssentials`, `Get-MsalEssentialsToken` (including silent renewal) and `Disconnect-MsalEssentials`, with their error cases (not connected, nothing to renew, sign-in failed). These tests **do not sign in**. The sign-in helper is mocked and the MSAL client is replaced by a fake, so they only check the module's own logic: when a token is renewed, which error is raised, and what is kept or cleared. They do not prove that a real sign-in, a real silent renewal or the Entra ID error handling work.
  - Real Entra ID integration tests: `Connect-MsalEssentials`, `Get-MsalEssentialsToken` (including real silent renewal) and `Disconnect-MsalEssentials`, plus real sign-in failure cases for unknown applications and unregistered `http://localhost` redirect URIs. These tests **do sign in and use the network**: they open the browser for a real Microsoft Entra ID sign-in and call Microsoft Graph to verify that the returned and renewed tokens are accepted. They check that a real connection and token are returned, silent renewal works, disconnect clears the connection, and Entra ID authentication errors ultimately surface as `MsalEssentials.Timeout`. They require a configured tenant and are intended to be run interactively, not unattended or in CI.
- **Workflow**
  - `.github/workflows/ci.yml` to run checks and pester on push and pull requests.
  - `.github\workflows\release.yml` to build the git release.
    - _Added to this entry after the release (missing at the time of 1.0.0, nothing changed in 1.1.0):_
      - Tests run as one job per PowerShell edition (Windows PowerShell 5.1 and PowerShell 7). `-AllEditions` from a single PowerShell 7 job made the Windows PowerShell child process inherit the `PSModulePath` of PowerShell 7, which breaks the Pester installation.
      - Job `publish-gallery` publishes the packaged module to the PowerShell Gallery after the GitHub release. It stays switched off until the repository variable `PUBLISH_TO_GALLERY` is `true`, and it runs in the `powershell-gallery` environment, which can require your approval and holds the `PSGALLERY_API_KEY` secret.
- **Build**
  - `build/Build-Module.ps1` create the release folder `output` with all files needed for a new build/release/version.
- **Documentation**
  - General conventions in [`branching-model.md`](/docs/conventions/branching-model.md), [`commit-messages.md`](/docs/conventions/commit-messages.md) and [`naming-conventions.md`](/docs/conventions/naming-conventions.md)
  - Notes and further information in [`Microsoft.Identity.Client-dependency.md`](/docs/notes/Microsoft.Identity.Client-dependency.md) and [`MSAL-TLDR.md`](/docs/notes/MSAL-TLDR.md)
  - Important files
    - [`CONTRIBUTING.md`](/CONTRIBUTING.md)
    - [`CHANGELOG.md`](/CHANGELOG.md)
    - [`LICENSE`](/LICENSE)
    - [`README.md`](/README.md)
    - [`SECURITY.md`](/SECURITY.md)
    - [`THIRD-PARTY-NOTICES.md`](/THIRD-PARTY-NOTICES.md)