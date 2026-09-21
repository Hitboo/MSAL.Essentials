# MSAL.Essentials <!-- omit from toc -->
Lightweight PowerShell [Microsoft Authentication Library (MSAL)](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview) wrapper.
- Delegated permissions
- Application permissions (certificate or secret)
- Managed Identity

# Table of contents<!-- omit from toc -->
- [Disclaimer](#disclaimer)
  - [This module is NOT supported by Microsoft](#this-module-is-not-supported-by-microsoft)
  - [AI](#ai)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
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
  [Overview of the Microsoft Authentication Library (MSAL) | MS Learn](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview)  
  [Microsoft Authentication Library for .NET](https://learn.microsoft.com/en-us/entra/msal/dotnet/)

## Limitations
This Module only supports minimal ways to get a MSAL token. For more complex tasks I recommend looking into other projects like:
- [PSMSALNet](https://github.com/SCOMnewbie/PSMSALNet/tree/main)
- [powershell-module-entraidaccesstoken](https://github.com/fortytwoservices/powershell-module-entraidaccesstoken/tree/main)

## Install from the PowerShell Gallery
N/A

## How to use it
N/A