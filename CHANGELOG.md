# Changelog<!-- omit from toc -->

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Table of contents<!-- omit from toc -->

- [\[0.1.0\] - 2026-10-08](#010---2026-10-08)
  - [TL;DR](#tldr)
  - [Added](#added)

## [0.1.0] - 2026-10-08

### TL;DR

- Initial release with minimal capabilities to get started.
- No application or managed identity auth flows yet.
- **Added Functions**
  - Connect-MsalEssentials
  - Get-MsalEssentialsToken
  - Disconnect-MsalEssential
- **Added Helper functions**
  - ConvertTo-MsalEssentialsConnection
  - Get-MsalEssentialsDelegatedTokenSystemBrowser
- Bundled MSAL libraries + function Update-MsalLibDependencies.ps1
- Pester testfiles

### Added

- **Functions (public)**
  - `Connect-MsalEssentials`: signs in as the current user through the system's default browser (delegated rights) and keeps the connection in module scope for the PowerShell session. Nothing is written to disk.
    - `-PassThru` returns the connection: `AuthenticationType`, `TenantId`, `ClientId`, `Username`, `Scopes`, `ExpiresOn` and `AccessToken`, plus a `CreateAuthorizationHeader()` method. The token is hidden from the default console display.
    - Parameter sets are prepared for future app (certificate, token) and managed identity connections.
  - `Get-MsalEssentialsToken`: returns the connection with a valid token. A token that expires within `-RefreshBeforeExpiryMinutes` (default 15) is renewed silently, without opening a browser.
    - It never signs in by itself. Without a connection, or when the token has expired and cannot be renewed silently, it fails and asks you to run `Connect-MsalEssentials`.
    - If renewal fails but the current token is still valid, the current token is returned together with a warning.
  - `Disconnect-MsalEssentials`: clears the accounts and tokens from the MSAL client's cache and removes the stored connection. It shows a hint to remove variables that still hold the token.
- **Helper functions (private)**
  - `Get-MsalEssentialsDelegatedTokenSystemBrowser`: interactive delegated sign-in through the system browser, using the loopback redirect URI `http://localhost`.
    - `-TimeoutSeconds` (default 120, range 1 to 3600) stops waiting for a sign-in that never completes.
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
- **Bundled MSAL libraries** in `src/lib` for Windows PowerShell 5.1 (`net472`) and PowerShell 7 (`netstandard2.0`): `Microsoft.Identity.Client` 4.90.1 and its dependencies, with the versions pinned in `dependencies.json`.
  - `build/Update-MsalLibDependencies.ps1` updates the bundled libraries and checks that the references between the DLLs match.
- **Tests** (Pester 6.2.0 or later) and the runner `tests/Start-Test.ps1`:
  - `Start-Test.ps1` makes sure Pester 6.2.0 or later is loaded and supports `-TestsPath`, `-Verbosity` (default `Detailed`) and `-AllEditions` (runs the suite under Windows PowerShell 5.1 and PowerShell 7).
  - A check that the required Pester version is loaded.
  - Library versions: each package in `dependencies.json` is present in `lib` at the pinned version.
  - Module import: files exist, the manifest is valid, the module imports without errors or warnings in the current session and in a fresh process of the same PowerShell edition, and the expected commands are exported.
  - A probe run in a clean process that imports the module twice with `-Force`, builds an MSAL client and starts a cancelled sign-in, to catch missing or mismatched dependencies without opening a browser.
