# Contributing to MSAL.Essentials

Thanks for your interest! This is my first open source project, so I'm still learning, and feedback of any kind is welcome: issues, ideas, code review and pull requests.

## Ways to contribute

- Report a bug or suggest an improvement by opening an issue.
- Review the code, especially anything that touches authentication or tokens.
- Improve the documentation or fix a typo.
- Send a pull request.

**Security problems**: please don't open a public issue. Follow [SECURITY.md](/SECURITY.md) instead.

## Before you start

For anything bigger than a small fix, please open an issue first so we can agree on the approach before you spend time on it. The module is intentionally small; see the Limitations section in the [README](/README.md) for what it does not try to cover.

## Development setup

You need:

- Windows PowerShell 5.1 and PowerShell 7 (the module supports both, and the tests are meant to run on both)
- [Pester](https://pester.dev/) 6.2.0 or later. `tests/Start-Test.ps1` installs it for the current user if it is missing.

Clone the repository and import the module from the source folder:

```powershell
Import-Module .\src\MSAL.Essentials.psd1 -Force
```

## Running the tests

```powershell
# Run the build and unit tests in the current PowerShell edition
.\tests\Start-Test.ps1

# Run them in both Windows PowerShell 5.1 and PowerShell 7
.\tests\Start-Test.ps1 -AllEditions

# Run only one folder
.\tests\Start-Test.ps1 -TestsPath .\tests\2-unit
```

| Folder | What it checks | Needs |
| --- | --- | --- |
| `tests/1-build` | The module files, the bundled libraries and a clean import | nothing |
| `tests/2-unit` | The connection commands with a simulated sign-in | nothing |
| `tests/3-integration` | A real sign-in, token renewal and sign-in failures | a browser and a tenant, run by hand |

The unit tests do **not** sign in. They only check the module's own logic, so they can't prove that a real sign-in works.

The integration tests are interactive. They are skipped unless the environment variable `MSAL_TEST_TENANT_ID` is set; the setup is described at the top of `tests/3-integration/01-SignIn.Tests.ps1`. If you change anything that touches signing in, renewing a token or the error handling, please run them once before you open the pull request and say so in the description.

## Making a change

- Follow the [branching model](/docs/conventions/branching-model.md), the [commit message rules](/docs/conventions/commit-messages.md) and the [naming conventions](/docs/conventions/naming-conventions.md).
- Add or update tests for what you change.
- Update the comment-based help of any command whose parameters or behavior change.
- Add an entry to the [CHANGELOG](/CHANGELOG.md) under the unreleased version, in the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) style.
- Keep pull requests small and focused, and fill in the pull request template.

## Updating the bundled libraries

MSAL.NET and its dependencies are bundled in `src/lib`. Don't copy or edit DLLs by hand. Use the update script instead. This needs the [.NET SDK](https://dot.net) (`dotnet`) and internet access.

```powershell
. .\build\Update-MsalLibDependencies.ps1   # loads the functions
Update-MsalLibDependencies                 # latest stable MSAL.NET; add -WhatIf to preview, -Force to re-fetch the same version
```

Then update [`THIRD-PARTY-NOTICES.md`](/THIRD-PARTY-NOTICES.md) if the set of libraries changed, add a CHANGELOG entry, and run the tests on both PowerShell editions.

## AI-assisted contributions

Parts of this project were written with AI assistance, and I'm open about that. If you used an AI tool to write part of your contribution, please say so in the pull request. You are responsible for the code: read it, understand it and test it before you submit it.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](/LICENSE) that covers this project.
