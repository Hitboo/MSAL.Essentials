# Entra ID auth types: which one to use, and where

A beginner's note for MSAL.Essentials. It explains the main ways to authenticate with Microsoft Entra ID and where to use each one. **All sources are official Microsoft documentation on Microsoft Learn.**

---

## First, a few words you need

- **Microsoft Entra ID** (formerly Azure AD) is the identity service. It issues **tokens**.
- **Token**: a short-lived proof of "who you are" that you send to an API (Microsoft Graph, Azure Resource Manager, your own API). Getting a token is the whole point of MSAL.
- **MSAL** (Microsoft Authentication Library) talks to Entra ID for you and caches tokens ([MSAL overview](https://learn.microsoft.com/entra/identity-platform/msal-overview)). It doesn't decide *who* you are. You choose that with one of the auth types below.
- **Public vs confidential client.** A desktop app or script that a person runs is a *public client*: it can't keep a secret safe. A service or automation that can hold a credential is a *confidential client* ([Public and confidential client apps](https://learn.microsoft.com/entra/identity-platform/msal-client-applications)).

Every token is issued to one of two kinds of identity:

| | Who signs in | Typical use |
|---|---|---|
| **Delegated** (a user) | A person, with their own permissions | Tools a human runs at their desk |
| **App-only** (a workload) | An app or script, with its own permissions | Automation, scheduled jobs, pipelines, services |

### Abbreviations used in this note

| Abbreviation | Stands for | What it means here |
|---|---|---|
| **AAD / Azure AD** | Azure Active Directory | The old name of Microsoft Entra ID. Still appears in some IDs and URIs, such as `Microsoft.AAD.BrokerPlugin`. |
| **AADSTS…** | Azure AD Security Token Service | Prefix of Entra sign-in error codes, for example AADSTS70021. |
| **AD FS** | Active Directory Federation Services | Microsoft's on-premises sign-in server. Some companies use it instead of signing in directly against Entra ID. |
| **API** | Application Programming Interface | A service your code calls, such as Microsoft Graph. |
| **AWS / GCP** | Amazon Web Services / Google Cloud Platform | Other cloud providers. |
| **B2C** | Business-to-Consumer | Azure AD B2C, an Entra variant for customer-facing apps. |
| **CA** | Certificate Authority | A trusted issuer of certificates. Not to be confused with Conditional Access, which this note always writes out in full. |
| **ID** | Identity / identifier | As in "Entra ID" (the service) or "client ID" (your app's unique ID). |
| **JWT** | JSON Web Token (pronounced "jot") | The format of Entra tokens: a signed, Base64-encoded JSON document with claims such as who the token is for. |
| **MFA** | Multi-Factor Authentication | Signing in with more than a password, such as an Authenticator app prompt. |
| **MI** | Managed Identity | See section 2. |
| **MSAL** | Microsoft Authentication Library | The library this project wraps. **MSAL.NET** is its .NET version. |
| **OIDC** | OpenID Connect | The standard sign-in protocol on top of OAuth 2.0. Platforms like GitHub use it to give jobs their own identity tokens. |
| **PKCE** | Proof Key for Code Exchange (pronounced "pixie") | An extra check in the browser sign-in flow, so a stolen authorization code can't be used. |
| **RBAC** | Role-Based Access Control | Azure's permission system: you assign a role (such as Reader) on a scope (such as a resource group). |
| **ROPC** | Resource Owner Password Credentials | A flow where the app sends a username and password directly. Microsoft recommends against it. |
| **SDK** | Software Development Kit | A library for a platform, such as the Azure SDK. |
| **SPIFFE** | Secure Production Identity Framework for Everyone | An open standard for workload identities. |
| **SSH** | Secure Shell | A remote terminal connection, often without a browser. |
| **SSO** | Single Sign-On | Sign in once and other apps reuse that sign-in. |
| **UI** | User Interface | The visible window or app. |
| **URI** | Uniform Resource Identifier | An address, such as a redirect URI that Entra sends the user back to after sign-in. |
| **VM** | Virtual Machine | A virtual server, for example in Azure. |
| **WAM** | Web Account Manager | The Windows sign-in broker. See section 5. |

---

## The options at a glance

The table sorts the options by **where your code runs**. The emojis are a rough rating: 😑 works but is a chore, 🙂 good, 🤩 best.

| Workload in Azure (or another cloud) | Workload online "somewhere else" | Workload local / interactive |
|---|---|---|
| Service principals 😑 | Service principals 😑 | Service principals 😑 |
| Managed identities 🙂 | Managed identities 🙂 (via Azure Arc) | Interactive auth 🙂 |
| | Workload identity federation 🤩 | WAM broker 🤩 |

**The idea:** service principals work everywhere, but you have to manage a secret or certificate. Each column has a better option that removes that secret.

### Quick decision guide

1. **Is a person at the keyboard?** Use **interactive auth**. On Windows, consider the **WAM broker** later.
2. **Is the code running on an Azure resource** (VM, Function, App Service and so on)? Use a **managed identity**.
3. **Is it on a non-Azure server you control?** Onboard the server to **Azure Arc** and use its managed identity.
4. **Is it on a platform that issues its own identity tokens** (GitHub Actions, Azure DevOps, Kubernetes, AWS, GCP)? Use **workload identity federation**.
5. **None of the above?** Use a **service principal with a certificate**, not a client secret.

---

## 1. Service principals (client secret or certificate) 😑

**What it is.** You register an **app** in Entra ID. Its identity inside your tenant is a **service principal** ([Apps & service principals](https://learn.microsoft.com/entra/identity-platform/app-objects-and-service-principals)). Your script proves it *is* that app and gets a token using the **client credentials flow**. The proof can be one of three things: a client secret, a JWT signed with a certificate, or a token from an external identity provider (that last one is federation, section 3) ([client credentials flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow)).

**Where to use it.** Anywhere, which is why it's in all three columns. Use it when nothing better fits. For example, it's useful for **local development** of code that runs with a managed identity in Azure, because a managed identity only exists on its Azure resource ([Managed identities overview](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)).

**Why only 😑.** You own the credential: you store it, rotate it before it expires, and keep it from leaking. Whoever has the credential *is* your app.

**Things to know.**
- Microsoft recommends a **certificate over a client secret** before you go to production. Self-signed certificates are for testing only. In production, use a CA-signed certificate stored in Key Vault ([Add and manage app credentials](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials)).
- The scope must be `<resource>/.default`, for example `https://graph.microsoft.com/.default`. You can ask for one resource per request, and this flow returns no refresh token ([client credentials flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow)).
- For most apps, choose **"single tenant only"** when you register ([Register an app](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app)).

**Set it up.**
1. [Register an app](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app)
2. [Add a certificate (or a secret)](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials)
3. Grant it **application** permissions (for Graph) or an Azure RBAC role.

**In MSAL.Essentials:** already done.

---

## 2. Managed identities 🙂

**What it is.** An identity that **Azure creates and manages for a resource**. There's no secret for you to handle. It comes in two types ([Managed identities overview](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)):
- **System-assigned**: tied to one resource and deleted with it.
- **User-assigned**: a standalone identity you can attach to several resources. Microsoft calls this "the recommended managed identity type for Microsoft services".

Under the hood it's a special kind of service principal that you can't modify directly ([Apps & service principals](https://learn.microsoft.com/entra/identity-platform/app-objects-and-service-principals)).

**Where to use it.**
- **In Azure:** VMs, Functions, App Service, Automation and many more ([services that support MI](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-status)).
- **"Somewhere else," via Azure Arc.** An on-premises or other-cloud server onboarded to Arc gets a managed identity. On Arc servers it is **system-assigned only**. Getting a token there works differently: a local endpoint (`localhost:40342`) first sends back a challenge pointing to a secret file, and you resend the request with that file's contents. You need local admin rights (Windows: Administrators or "Hybrid Agent Extension Applications"; Linux: the `himds` group) ([MI on Arc-enabled servers](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication)).

**Things to know.**
- **Your laptop has no managed identity.** It only exists on supported hosts ([MI with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/advanced/managed-identity)), so local testing needs another method, such as a service principal or interactive sign-in.
- After you create it, **grant it permissions**: an Azure RBAC role, or *application* permissions for Graph. App-only tokens carry application permissions, not delegated ones ([client credentials flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow)).
- In MSAL.NET, managed identity needs version **4.54.0 or later** (`ManagedIdentityApplicationBuilder`). Azure Arc is a supported host, and managed identity tokens are cached in memory only. Microsoft suggests the Azure SDK for Azure resources and MSAL for Graph or your own APIs ([Managed identity with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/advanced/managed-identity)).

**Set it up.**
- **Virtual machines:** [Configure managed identities on Azure VMs](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities). Covers system- and user-assigned, with portal, Azure CLI (`az vm identity assign`) and PowerShell (`Update-AzVM -IdentityType SystemAssigned`) steps.
- **App Service and Azure Functions:** [Use managed identities for App Service and Azure Functions](https://learn.microsoft.com/azure/app-service/overview-managed-identity). One page covers both. In the portal, go to **Settings > Identity** and turn on *System assigned*, or add a *User assigned* identity.
  - Functions extra: [Configure connections in Azure Functions](https://learn.microsoft.com/azure/azure-functions/manage-connections) explains how bindings and triggers use the identity, for example `AzureWebJobsStorage__credential=managedidentity`.
  - App Service calling Graph, end to end: [Access Microsoft Graph as the app](https://learn.microsoft.com/azure/app-service/scenario-secure-app-access-microsoft-graph-as-app). It includes the PowerShell for granting Graph app permissions (`New-MgServicePrincipalAppRoleAssignment`).
- **Other services:** see the [supported services list](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-status).
- [Use it on an Arc server](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication)
- [Managed identity with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/advanced/managed-identity)

---

## 3. Workload identity federation 🤩

**What it is.** You add a **federated identity credential** to an app registration (or a user-assigned managed identity). It says: *"trust tokens from this issuer, for this exact subject."* At run time, the platform gives your job its own signed token. You exchange that token with Entra ID for an access token. **No secret is stored anywhere** ([Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)).

**Where to use it.** Microsoft lists Kubernetes, GitHub Actions, Azure DevOps service connections, Google Cloud, AWS, SPIFFE, and Azure compute that has a user-assigned managed identity ([overview](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)).

**Things to know (this is where people get stuck).**
- **The issuer, subject and audience must match exactly.** No wildcards. A mismatched subject "fails without error" ([create trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust), [considerations](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations)).
- The audience is normally `api://AzureADTokenExchange` ([create trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust)).
- GitHub subjects look like `repo:<org/repo>:environment:<name>`, `repo:<org/repo>:ref:<ref>` or `repo:<org/repo>:pull-request` ([create trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust)). The workflow needs `permissions: id-token: write` ([GitHub Actions OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)).
- New credentials can take a moment to propagate (error AADSTS70021), so add retry logic. You can have at most **20** federated credentials per app or identity ([considerations](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations), [create trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust)).

**In MSAL terms:** it's the client credentials flow with a **client assertion** (the external token) instead of a secret. In MSAL.NET that's `WithClientAssertion(...)`, and **you** cache the external token ([MSAL.NET workload identity federation](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/workload-identity-federation)).

**Set it up.**
1. [Concept overview](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)
2. [Add the federated credential](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust)
3. [GitHub Actions walkthrough](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
4. [Limits and gotchas](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations)

---

## 4. Interactive auth 🙂

**What it is.** A **person** signs in, usually in a browser window, with MFA and Conditional Access applied. The token acts **as that user** (delegated). The app is a public client and can't hold secrets ([Public and confidential clients](https://learn.microsoft.com/entra/identity-platform/msal-client-applications)).

There are two common variants:
- **Authorization code with PKCE**: opens a browser. This is the default to use.
- **Device code**: shows a code you enter on another device. It's useful for headless or SSH sessions. The code expires after 15 minutes by default ([device code flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-device-code)).

**Don't use** ROPC (sending a username and password directly) or the implicit flow. Microsoft recommends against both ([MSAL flows](https://learn.microsoft.com/entra/identity-platform/msal-authentication-flows)).

**Where to use it.** Tools a human runs. It isn't for unattended automation, because nobody is there to sign in.

**Set it up.**
- [Configure a desktop app registration](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-app-configuration). Redirect URIs: `http://localhost` for the system browser, or `https://login.microsoftonline.com/common/oauth2/nativeclient` for an embedded browser.
- [Acquire tokens interactively (MSAL.NET)](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/acquiring-tokens-interactively)

**In MSAL.Essentials:** already done, including the UI-thread deadlock fix.

---

## 5. WAM broker 🤩

**What it is.** **Web Account Manager** is a Windows component that MSAL can hand the sign-in to instead of opening a browser. Microsoft calls brokers "the recommended approach" over browsers ([Acquiring tokens interactively](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/acquiring-tokens-interactively)). What you get:
- **Single sign-on** with the account signed in to Windows (`PublicClientApplication.OperatingSystemAccount`) ([WAM with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam)).

**Documented limits** ([WAM with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam), [Acquire a token with WAM](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-acquire-token-wam)):
- Entra ID only. B2C and AD FS fall back to a browser, and so do macOS, Linux and older Windows.
- It must run in an **interactive user session**. A Windows service, Task Scheduler (unless it runs as the logged-in user) or **`runas`** "will result in errors by design."
- To switch accounts, Microsoft suggests calling `AcquireTokenInteractive` again.

**⚠️ Our own caveat.** In this project, WAM has been unreliable when the account you want **isn't the Windows user who is signed in**, for example a separate admin account. The docs don't document this exactly. What they do say fits it: silent SSO targets the current Windows account, and `runas` is unsupported by design. So make WAM **opt-in**, with a **fallback to the normal browser flow**.

**Practical notes.**
- You need MSAL.NET **4.52.0 or later** plus the `Microsoft.Identity.Client.Broker` package ([WAM with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam)).
- In the app registration, add the redirect URI `ms-appx-web://Microsoft.AAD.BrokerPlugin/{client_id}` under "Mobile and desktop applications" ([Acquire a token with WAM](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-acquire-token-wam)).

---

## Cheat sheet

| Auth type | Who it is | Secret to manage? | Use it when… | In the repo |
|---|---|---|---|---|
| Service principal (cert/secret) | App | **Yes** | Nothing better fits, or local dev | ✅ Done |
| Managed identity | Azure resource or Arc server | No | Code runs in Azure or on an Arc server | Not yet |
| Workload identity federation | App, trusted via an external issuer | No | GitHub Actions, Azure DevOps, Kubernetes, other clouds | Not yet |
| Interactive | User | No | A human runs the tool | ✅ Done |
| WAM broker | User (Windows account) | No | Windows desktop, SSO with the Windows account | Not yet |

## Sources

**Microsoft Learn**
- [MSAL overview](https://learn.microsoft.com/entra/identity-platform/msal-overview) · [Flows supported by MSAL](https://learn.microsoft.com/entra/identity-platform/msal-authentication-flows) · [Public and confidential clients](https://learn.microsoft.com/entra/identity-platform/msal-client-applications)
- [Register an app](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app) · [App credentials](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials) · [Client credentials flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow) · [Apps & service principals](https://learn.microsoft.com/entra/identity-platform/app-objects-and-service-principals)
- [Managed identities overview](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview) · [Supported services](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identities-status) · [MI on a VM](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-configure-managed-identities) · [MI for App Service & Functions](https://learn.microsoft.com/azure/app-service/overview-managed-identity) · [Functions connections](https://learn.microsoft.com/azure/azure-functions/manage-connections) · [App Service to Graph as the app](https://learn.microsoft.com/azure/app-service/scenario-secure-app-access-microsoft-graph-as-app) · [MI with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/advanced/managed-identity) · [MI on Arc servers](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication)
- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation) · [Create trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust) · [Considerations](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations) · [GitHub Actions OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect) · [Federation in MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/workload-identity-federation)
- [Desktop app configuration](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-app-configuration) · [Interactive tokens (MSAL.NET)](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/acquiring-tokens-interactively) · [Device code flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-device-code)
- [WAM with MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam) · [Acquire a token with WAM](https://learn.microsoft.com/entra/identity-platform/scenario-desktop-acquire-token-wam)
