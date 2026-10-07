# MSAL.Essentials <!-- omit from toc -->
Lightweight PowerShell [Microsoft Authentication Library (MSAL)](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview) wrapper.
- Delegated permissions
- Application permissions (certificate or secret)
- Managed Identity

> [!NOTE]
> **👋 First open source project**  
> This is my first open source project and my first time building a PowerShell module.
> It is also my first time using [Pester](https://pester.dev/) for testing, and I'm experimenting
> with LLM-assisted development along the way. Expect rough edges.  
> **Feedback is very welcome**: issues, suggestions, code review and PRs are all appreciated.

# Table of contents<!-- omit from toc -->
- [Disclaimer](#disclaimer)
  - [This module is NOT supported by Microsoft](#this-module-is-not-supported-by-microsoft)
  - [AI](#ai)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Dependencies](#dependencies)
  - [Limitations](#limitations)
  - [Install from the PowerShell Gallery](#install-from-the-powershell-gallery)
  - [How to use it](#how-to-use-it)

<hr>

# Disclaimer

## This module is NOT supported by Microsoft
Please use higher level APIs which are officially supported: 
 -  [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/get-started?view=graph-powershell-1.0)
 -  [Azure PowerShell SDK](https://learn.microsoft.com/powershell/azure/new-azureps-module-az?view=azps-10.0.0)
  
## AI
Parts of this module were written with AI assistance (LLM-generated / "vibe coded"). Review the code before using it in production, especially anything touching authentication or credential handling.

I want to be as transparent as possible about this. AI is used as an assisting tool, not to write everything for me — I still review the code myself and test it before use.

# Getting started

## Prerequisites
-  PowerShell 5.1 or 7.x
- Basic knowledge of MSAL is recommended.  
  Some sources I used:
  - [Overview of the Microsoft Authentication Library (MSAL) | MS Learn](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview)
  - [Microsoft Authentication Library for .NET](https://learn.microsoft.com/en-us/entra/msal/dotnet/)
  - [No Passwords, No Problem: Secure Azure Authentication with MSAL & PowerShell - Ben Reader - PSC](https://youtu.be/UgdhicrPn9c?si=Ult04oswPESN4sTX)

## Dependencies
This module bundles [Microsoft.Identity.Client](https://www.nuget.org/packages/Microsoft.Identity.Client) (MSAL.NET) as its underlying token-acquisition library, along with its required dependency assemblies.
- Microsoft.Identity.Client -> Core
- Microsoft.IdentityModel.Abstractions -> Core dependency

Since Microsoft.Identity.Client targets different .NET runtimes for PowerShell 5.1 (Desktop) vs PowerShell 7.x (Core), the binaries are bundled per-runtime under `src/lib/` and the correct set is loaded automatically at import time based on `$PSEdition` — no manual step required.

## Limitations
This Module only supports minimal ways to get a MSAL token. For more complex tasks I recommend looking into other projects like:
- [PSMSALNet](https://github.com/SCOMnewbie/PSMSALNet/tree/main)
- [powershell-module-entraidaccesstoken](https://github.com/fortytwoservices/powershell-module-entraidaccesstoken/tree/main)

## Install from the PowerShell Gallery
N/A

## How to use it
```powershell
#Requires -Modules @{ ModuleName='MSAL.Essentials'; ModuleVersion='0.1.0' } 
#region settings
# The directory (tenant) ID or verified domain to authenticate against.
[string]$TenantId = 'EXAMPLE.onmicrosoft.com'
# The application (client) ID registered in Entra ID.
[string]$ClientID = '14d82eec-204b-4c2f-b7e8-296a70dab67e' # Microsoft Graph Command Line # Permission scopes to request.
#endregion settings

#region connect to Microsoft Graph via MSAL.Essentials
try {
    # Get MSAL token via interactive system browser. The token is cached in memory for the duration of the PowerShell session.
    $MsalEssentialsConnection = Connect-MsalEssentials -PassThru -TenantId $tenantId -ClientID $clientId -ErrorAction 'Stop'

    $MicrosoftGraphRequest = @{
        Uri         = 'https://graph.microsoft.com/beta/me' # Microsoft Graph endpoint to get info about the signed-in user.
        Method      = 'GET'
        Headers     = @{ Authorization = $MsalEssentialsConnection.CreateAuthorizationHeader() } # Use the MSAL token to authorize the request.
        ContentType = 'application/json'
    }

    # Invoke Microsoft Graph request using the MSAL token.
    $MicrosoftGraphResult = Invoke-RestMethod @MicrosoftGraphRequest
    $microsoftGraphResult
}
catch {
    Write-Warning -Message $_.ErrorDetails.Message
}
#endregion connect to Microsoft Graph via MSAL.Essentials
```