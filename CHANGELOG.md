# Changelog<!-- omit from toc -->

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Table of contents<!-- omit from toc -->

- [\[1.1.0\] -](#110--)
  - [Added](#added)
  - [Fixed](#fixed)
- [\[1.0.0\] - 2026-10-16](#100---2026-10-16)
  - [TL;DR](#tldr)
  - [Added](#added-1)


## [1.1.0] -

### Added

- New parameter `LoginHintUpn` to `Get-MsalEssentialsDelegatedTokenSystemBrowser` and `Connect-MsalEssentials` to pass a user principal name (UPN) to pre-fill the username/email field in the browser.
  - Only as a hint not a guarantee: the user can still change it or sign in with a different account.  
  - This is helpful for guest sign-ins, on the target tenant for a more targeted experience, or to avoid the user having to type their email address.

### Fixed

- Function `Disconnect-MsalEssentials` no longer returns 'System.Threading.Tasks.VoidTaskResult' on Account disposal.

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