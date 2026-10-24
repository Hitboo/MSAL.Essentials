# MSAL.Essentials <!-- omit from toc -->

[![CI](https://github.com/Hitboo/MSAL.Essentials/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/Hitboo/MSAL.Essentials/actions/workflows/ci.yml)

Lightweight PowerShell [Microsoft Authentication Library (MSAL)](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview) wrapper.

- Delegated permissions (sign in as a user through the system browser)
- Application permissions (sign in as the app itself with a certificate or a client secret)
- Managed Identity **not implemented yet**

> [!NOTE]
> **👋 First open source project**  
> This is my first open source project and my first time building a PowerShell module.
> It is also my first time using [Pester](https://pester.dev/) for testing, and I'm experimenting
> with LLM-assisted development along the way. Expect rough edges.  
> **Feedback is very welcome**: issues, suggestions, code review and PRs are all appreciated.

## Table of contents<!-- omit from toc -->

- [Disclaimer](#disclaimer)
  - [This module is NOT supported by Microsoft](#this-module-is-not-supported-by-microsoft)
  - [AI](#ai)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Dependencies](#dependencies)
  - [Limitations](#limitations)
  - [Install](#install)
    - [PowerShell Gallery](#powershell-gallery)
    - [Import it from a copy of this repository](#import-it-from-a-copy-of-this-repository)
  - [App registration](#app-registration)
  - [How to use it](#how-to-use-it)
  - [Commands](#commands)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

## Disclaimer

### This module is NOT supported by Microsoft

Please use higher level APIs which are officially supported:

- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/get-started?view=graph-powershell-1.0)
- [Azure PowerShell SDK](https://learn.microsoft.com/powershell/azure/new-azureps-module-az?view=azps-10.0.0)
  
### AI

Parts of this module were written with AI assistance (LLM-generated / "vibe coded"). Review the code before using it in production, especially anything touching authentication or credential handling.

I want to be as transparent as possible about this. AI is used as an assisting tool, not to write everything for me — I still review the code myself and test it before use.

## Getting started

### Prerequisites

- Windows PowerShell 5.1 (with .NET Framework 4.7.2 or later) or PowerShell 7.x
- An app registration in Microsoft Entra ID (see [App registration](#app-registration)). For a quick test you can use the Microsoft Graph Command Line Tools app.
- Basic knowledge of MSAL is recommended.  
  Some sources I used:
  - [Overview of the Microsoft Authentication Library (MSAL) | MS Learn](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview)
  - [Microsoft Authentication Library for .NET](https://learn.microsoft.com/en-us/entra/msal/dotnet/)
  - [No Passwords, No Problem: Secure Azure Authentication with MSAL & PowerShell - Ben Reader - PSC](https://youtu.be/UgdhicrPn9c?si=Ult04oswPESN4sTX)

### Dependencies

This module bundles [Microsoft.Identity.Client](https://www.nuget.org/packages/Microsoft.Identity.Client) (MSAL.NET) as its underlying token-acquisition library, together with the assemblies it depends on (for example `Microsoft.IdentityModel.Abstractions` and `System.Text.Json`).

The bundled libraries, their exact versions and their SHA-256 hashes are listed in [`src/lib/dependencies.json`](src/lib/dependencies.json). Their licenses are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Since Microsoft.Identity.Client targets different .NET runtimes for PowerShell 5.1 (Desktop) vs PowerShell 7.x (Core), the binaries are bundled per-runtime under `src/lib/` and the correct set is loaded automatically at import time based on `$PSEdition` — no manual step required.

### Limitations

This Module only supports minimal ways to get a MSAL token. For more complex tasks I recommend looking into other projects like:

- [PSMSALNet](https://github.com/SCOMnewbie/PSMSALNet/tree/main)
- [powershell-module-entraidaccesstoken](https://github.com/fortytwoservices/powershell-module-entraidaccesstoken/tree/main)

Also good to know:

- Only the interactive sign-in through the system browser is implemented. The embedded web view and the Windows broker (WAM) are not included.
- The module compiles a small C# helper when it is imported, so it does not support PowerShell's Constrained Language Mode.
- It is tested on Windows with Windows PowerShell 5.1 and PowerShell 7. Linux and macOS are not tested.
- Tokens are only kept in memory for the current PowerShell session. Nothing is written to disk.
- Most failed sign-ins show up as a timeout. See [Troubleshooting](#troubleshooting).

### Install

#### PowerShell Gallery

```powershell
Install-Module -Name 'MSAL.Essentials' -Scope CurrentUser
Import-Module -Name 'MSAL.Essentials'
```

#### Import it from a copy of this repository

```powershell
git clone https://github.com/Hitboo/MSAL.Essentials.git
Import-Module -Name '.\MSAL.Essentials\src\MSAL.Essentials.psd1'
```

If you download the repository as a ZIP file instead of cloning it, Windows marks the files as downloaded from the internet, and PowerShell may refuse to run them. Unblock them after extracting:

```powershell
Get-ChildItem -Path '.\MSAL.Essentials' -Recurse | Unblock-File
```

### App registration

#### Delegated permissions (sign in as a user)

The sign-in opens your default browser and receives the answer on a local `http://localhost` address. The app registration needs that redirect URI:

1. Open the Microsoft Entra admin center, then **App registrations**, your app and **Authentication**.
2. Choose **Add a platform**, then **Mobile and desktop applications**.
3. Add the redirect URI `http://localhost` (without a port). Entra ID ignores the port for localhost addresses.
4. Under **API permissions**, add the delegated permissions you need.

For testing you can use the **Microsoft Graph Command Line Tools** app (client ID `14d82eec-204b-4c2f-b7e8-296a70dab67e`). It works out of the box, but it belongs to Microsoft, you can't change it, and it is not recommended for production.

To use another loopback address, for example a fixed port, pass `-RedirectUri 'http://localhost:1234'` to `Connect-MsalEssentials` and register the same URI. Only loopback addresses work with the system browser.

#### Application permissions (sign in as the app)

The app signs in as itself with a certificate or a client secret. No browser and no redirect URI are needed. The app registration needs a credential and application permissions:

1. Open the Microsoft Entra admin center, then **App registrations**, your app and **Certificates & secrets**.
2. Add a credential:
   - **Certificates**: upload the public part (`.cer`) of a certificate whose private key you keep (recommended). See [Create a certificate for testing](docs/examples/Create-TestCertificate.md).
   - **Client secrets**: create a secret and copy its **Value** right away. Entra ID shows it only once. The **Secret ID** does not work.
3. Under **API permissions**, add the **application** permissions you need (not delegated ones) and choose **Grant admin consent**. Without consent a token is issued, but it has no roles and Microsoft Graph answers with `403`.
4. Under **Authentication**, keep **Allow public client flows** set to **No**. Otherwise Entra ID rejects the certificate or secret.

A certificate is the safer choice for production, because a secret is a shared password that can leak. Application permissions always use one scope that ends with `/.default`, for example `https://graph.microsoft.com/.default` (the default).

### How to use it

Every example is a complete script: connect, call Microsoft Graph, clean up.

| Example | Sign in as | Use it for |
| --- | --- | --- |
| [Delegated sign-in through the browser](docs/examples/Delegated-SystemBrowser.md) | the current user | interactive scripts that act on behalf of a user |
| [Application sign-in with a certificate](docs/examples/Application-Certificate.md) | the app itself | unattended scripts and automation (recommended) |
| [Application sign-in with a client secret](docs/examples/Application-ClientSecret.md) | the app itself | quick tests, or where a certificate is not possible |
| [Create a certificate for testing](docs/examples/Create-TestCertificate.md) | (setup) | a self-signed certificate for the certificate example |

### Commands

| Command | What it does |
| --- | --- |
| `Connect-MsalEssentials` | Signs in as the current user through the default browser, or as the app itself with `-Certificate` or `-ClientSecret`, and keeps the connection in memory. `-PassThru` returns it, including the access token. |
| `Get-MsalEssentialsToken` | Returns the connection with a valid token and renews it when it expires soon. It never starts an interactive sign-in. |
| `Disconnect-MsalEssentials` | Clears the connection and the MSAL token cache. |

Parameters and examples: `Get-Help Connect-MsalEssentials -Full`.

## Troubleshooting

**The sign-in times out (`MsalEssentials.Timeout`).** Entra ID shows many errors on its own page in the browser and does not send them back to PowerShell. Examples are a redirect URI that is not registered (`AADSTS50011`) or a Conditional Access block. PowerShell only sees that the sign-in never finished. Look at the page in the browser to find the real error and its code. You can also wait longer with `-TimeoutSeconds` (default 120).

Other errors come with a stable error ID in `$_.FullyQualifiedErrorId`. Details such as the error code and the correlation ID are in `$_.TargetObject`:

| Error ID | Meaning |
|---|---|
| `MsalEssentials.AppConfiguration` | Redirect URI, app not found, invalid scope or tenant, or the app is set up as a public client (application permissions). |
| `MsalEssentials.Unauthorized` | Consent is missing, the user is not assigned, the account is not in the tenant, or the client secret or certificate was rejected. |
| `MsalEssentials.ConditionalAccess` | A policy asks for MFA, a compliant device or another condition. |
| `MsalEssentials.Cancelled` | The sign-in was cancelled. |
| `MsalEssentials.NotConnected` | There is no connection yet. Run `Connect-MsalEssentials`. |
| `MsalEssentials.ReconnectRequired` | The token expired and can't be renewed silently. Run `Connect-MsalEssentials` again. |

Add `-Verbose` to see what the module is doing.

## Security

- The module keeps tokens in memory only. It never writes them to disk.
- `Connect-MsalEssentials -PassThru` and `Get-MsalEssentialsToken` return the access token. Treat it like a password: don't log it, print it or share it. It is hidden from the default console display, but `Format-List *`, `ConvertTo-Json` and similar commands show it.
- When you are done, run `Disconnect-MsalEssentials` and remove the variables that hold the token. An access token that was already issued stays valid until it expires.
- Found a security problem? Please follow [SECURITY.md](SECURITY.md) and don't open a public issue.

## Contributing

Contributions and feedback are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Changes are listed in the [CHANGELOG](CHANGELOG.md).

## License

[MIT](LICENSE). The bundled third-party libraries have their own licenses, see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
