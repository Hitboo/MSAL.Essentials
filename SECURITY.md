# Security policy

MSAL.Essentials handles access tokens, so security reports are taken seriously.

## Supported versions

Only the latest released version receives security fixes. While the module is on 1.x, please update to the newest release before reporting.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub: open the [Security tab](../../security), go to **Advisories** and choose **Report a vulnerability**.

If you can't see that button, open a public issue titled "Security contact request" **without any details about the problem**. I'll get in touch with you privately from there.

Please include:

- the module version and your PowerShell edition and version (`$PSVersionTable`)
- what you found, the steps to reproduce it, and what an attacker could do with it
- a suggested fix, if you have one

Do **not** include real access tokens, client secrets, certificates or private tenant data in a report. Redact them.

## What to expect

This is a hobby project that I maintain in my spare time, so everything is best effort:

- I aim to acknowledge a report within 7 days.
- I'll tell you whether I can reproduce it and how I plan to handle it.
- Once a fix is released, I'll publish a security advisory and credit you if you want to be named.

## Scope

In scope:

- how the module stores, returns and clears tokens (`Connect-MsalEssentials`, `Get-MsalEssentialsToken`, `Disconnect-MsalEssentials`)
- error handling that could expose sensitive data
- how the bundled libraries are loaded

Out of scope:

- vulnerabilities in MSAL.NET or the other bundled .NET libraries themselves. Report those to Microsoft through the [Microsoft Security Response Center](https://msrc.microsoft.com/). Please also tell me, so I can update the bundled version.
- vulnerabilities in Microsoft Entra ID or Microsoft Graph
- issues that need a machine or account that is already compromised
- tokens that you store or share yourself

## Handling tokens safely

- The module keeps tokens in memory only. It never writes them to disk.
- `Connect-MsalEssentials -PassThru` and `Get-MsalEssentialsToken` return the access token. Treat it like a password: don't log it, print it or share it.
- When you are done, run `Disconnect-MsalEssentials` and remove any variables that hold the token. The command can't clear variables you created.
- An access token that has already been issued stays valid until it expires. Disconnecting does not revoke it.

## Bundled libraries

The module bundles MSAL.NET and its dependencies in `src/lib`. Their versions are pinned in [`src/lib/dependencies.json`](src/lib/dependencies.json), and the licenses are listed in [THIRD-PARTY-NOTICES.md](/THIRD-PARTY-NOTICES.md). They are updated with `build/Update-MsalLibDependencies.ps1`, and notable updates are listed in the [CHANGELOG](/CHANGELOG.md).
