<#
    Tests for workload identity federation in the private token helper:
        Get-MsalEssentialsApplicationToken -FederatedToken / -FederatedTokenFile
        MsalEssentials.FederatedTokenFileReader (the assertion delegate)

    No network is used. Wait-MsalEssentialsTask is mocked to return a result
    or throw the exception MSAL would throw; the MSAL client itself is real
    but never sends a request.
#>

BeforeAll {
    $script:ModuleName   = 'MSAL.Essentials'
    $script:ManifestPath = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../src/MSAL.Essentials.psd1')).Path

    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
    Import-Module -Force -Name $script:ManifestPath -ErrorAction 'Stop'

    # Not a real token: only the shape (three parts separated by dots) matters.
    $script:FederatedToken = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl'

    # Runs the helper with Wait-MsalEssentialsTask throwing $Failure, and
    # returns the error record (or $null). -Credential picks the parameter set.
    function script:Get-FederatedTokenError {
        param (
            [Parameter(Mandatory)]
            $Failure,

            [hashtable]$Credential = @{ FederatedToken = $script:FederatedToken }
        )

        InModuleScope -ModuleName $script:ModuleName -Parameters @{ Failure = $Failure; Credential = $Credential } -ScriptBlock {
            param ($Failure, $Credential)

            Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { throw $Failure }.GetNewClosure()

            $caughtError = $null
            try {
                $null = Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' @Credential
            }
            catch {
                $caughtError = $_
            }
            $caughtError
        }
    }
}

AfterAll {
    Get-Module -Name $script:ModuleName |
        Remove-Module -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Get-MsalEssentialsApplicationToken -FederatedToken' {
    It 'returns the result of the wait and hands out the MSAL client' {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ FederatedToken = $script:FederatedToken } -ScriptBlock {
            param ($FederatedToken)

            Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { [pscustomobject]@{ AccessToken = 'wif-token' } }

            $clientApplication = $null
            $result = Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedToken $FederatedToken -ApplicationReference ([ref]$clientApplication)

            $result.AccessToken |
                Should -Be 'wif-token'
            $clientApplication |
                Should -BeOfType 'Microsoft.Identity.Client.IConfidentialClientApplication'
            $clientApplication.Authority |
                Should -BeLike 'https://login.microsoftonline.com/hitboo.test/*'
        }
    }

    It 'rejects an empty token before building a client' {
        InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
            Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { throw 'must not be called' }

            { Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedToken '' } |
                Should -Throw -ErrorId 'ParameterArgumentValidationError*'

            Should -Invoke -CommandName 'Wait-MsalEssentialsTask' -Times 0 -Exactly
        }
    }

    It 'maps <Name> to MsalEssentials.<Category>' -ForEach @(
        @{
            Name     = 'no matching federated credential (AADSTS70021)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_request', 'AADSTS70021: No matching federated identity record found for presented assertion.') }
            Category = 'Unauthorized'
            Hint     = 'No federated credential on the app matches this token.*Federated credentials*'
        }
        @{
            Name     = 'a wrong issuer (AADSTS700211)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS700211: No matching federated identity record found for presented assertion issuer.') }
            Category = 'Unauthorized'
            Hint     = '*matches the issuer*'
        }
        @{
            Name     = 'a wrong audience (AADSTS700212)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS700212: No matching federated identity record found for presented assertion audience.') }
            Category = 'Unauthorized'
            Hint     = '*matches the audience*api://AzureADTokenExchange*'
        }
        @{
            Name     = 'a wrong subject (AADSTS700213)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS700213: No matching federated identity record found for presented assertion subject.') }
            Category = 'Unauthorized'
            Hint     = '*matches the subject*'
        }
        @{
            Name     = 'an expired federated token (AADSTS700024)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS700024: Client assertion is not within its valid time range.') }
            Category = 'Unauthorized'
            Hint     = 'The federated token has expired*'
        }
        @{
            Name     = 'a malformed token (AADSTS50027)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_request', 'AADSTS50027: JWT token is invalid or malformed.') }
            Category = 'Unauthorized'
            Hint     = '*not a valid JWT*'
        }
        @{
            Name     = 'an unknown invalid_client error'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('invalid_client', 'AADSTS99999: Something new went wrong.') }
            Category = 'Unauthorized'
            Hint     = '*federated token and the federated credential*'
        }
        @{
            Name     = 'a Conditional Access block (AADSTS53003)'
            Failure  = @{ Type = 'Microsoft.Identity.Client.MsalServiceException'; Arguments = @('access_denied', 'AADSTS53003: Access has been blocked by Conditional Access policies.') }
            Category = 'ConditionalAccess'
            Hint     = '*Conditional Access policy for workload identities*'
        }
    ) {
        # Built here, not in -ForEach: discovery runs before the module (and MSAL) is loaded.
        $Failure = New-Object -TypeName $Failure.Type -ArgumentList $Failure.Arguments
        $caught  = Get-FederatedTokenError -Failure $Failure

        $caught.FullyQualifiedErrorId |
            Should -BeLike ('MsalEssentials.{0}*' -f $Category)
        $caught.TargetObject.Category |
            Should -Be $Category
        $caught.ErrorDetails.Message |
            Should -BeLike ('Token request failed `[{0}`]*' -f $Category)
        $caught.ErrorDetails.Message |
            Should -BeLike ('*Hint: {0}' -f $Hint)
        $caught.Exception |
            Should -Be $Failure
    }

    It 'keeps the certificate hint for AADSTS700024 with a certificate' {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $certificateRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=MsalEssentialsTest',
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $certificate = $certificateRequest.CreateSelfSigned(
            [System.DateTimeOffset]::UtcNow.AddDays(-1),
            [System.DateTimeOffset]::UtcNow.AddDays(1)
        )

        try {
            $failure = [Microsoft.Identity.Client.MsalServiceException]::new('invalid_client', 'AADSTS700024: Client assertion is not within its valid time range.')
            $caught  = Get-FederatedTokenError -Failure $failure -Credential @{ Certificate = $certificate }

            $caught.ErrorDetails.Message |
                Should -BeLike '*Hint: The certificate assertion is not within its valid time*'
        }
        finally {
            $certificate.Dispose()
            $rsa.Dispose()
        }
    }
}

Describe 'Get-MsalEssentialsApplicationToken -FederatedTokenFile' {
    BeforeEach {
        $script:TokenFile = Join-Path -Path $TestDrive -ChildPath 'azure-identity-token'
        Set-Content -LiteralPath $script:TokenFile -Value $script:FederatedToken -NoNewline
    }

    It 'returns the result of the wait for an existing file' {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ TokenFile = $script:TokenFile } -ScriptBlock {
            param ($TokenFile)

            Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { [pscustomobject]@{ AccessToken = 'wif-file-token' } }

            $clientApplication = $null
            $result = Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedTokenFile $TokenFile -ApplicationReference ([ref]$clientApplication)

            $result.AccessToken |
                Should -Be 'wif-file-token'
            $clientApplication |
                Should -BeOfType 'Microsoft.Identity.Client.IConfidentialClientApplication'
        }
    }

    It 'resolves a relative path against the current location' {
        Push-Location -LiteralPath $TestDrive
        try {
            InModuleScope -ModuleName $script:ModuleName -ScriptBlock {
                Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { [pscustomobject]@{ AccessToken = 'wif-file-token' } }

                (Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedTokenFile 'azure-identity-token').AccessToken |
                    Should -Be 'wif-file-token'
            }
        }
        finally {
            Pop-Location
        }
    }

    It 'fails with MsalEssentials.AppConfiguration when the file does not exist, without a token request' {
        InModuleScope -ModuleName $script:ModuleName -Parameters @{ MissingFile = (Join-Path -Path $TestDrive -ChildPath 'missing-token') } -ScriptBlock {
            param ($MissingFile)

            Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { throw 'must not be called' }

            $caught = $null
            try {
                $null = Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedTokenFile $MissingFile
            }
            catch {
                $caught = $_
            }

            $caught.FullyQualifiedErrorId |
                Should -BeLike 'MsalEssentials.AppConfiguration*'
            $caught.Exception |
                Should -BeOfType 'System.IO.FileNotFoundException'
            $caught.ErrorDetails.Message |
                Should -BeLike '*Hint: Check -FederatedTokenFile*'
            Should -Invoke -CommandName 'Wait-MsalEssentialsTask' -Times 0 -Exactly
        }
    }

    It 'fails with MsalEssentials.AppConfiguration when the file turns out empty at request time' {
        $failure = [System.IO.InvalidDataException]::new('The federated token file is empty: x')
        $caught  = Get-FederatedTokenError -Failure $failure -Credential @{ FederatedTokenFile = $script:TokenFile }

        $caught.FullyQualifiedErrorId |
            Should -BeLike 'MsalEssentials.AppConfiguration*'
        $caught.ErrorDetails.Message |
            Should -BeLike '*empty*Hint: Check -FederatedTokenFile*'
    }

    Context 'MsalEssentials.FederatedTokenFileReader' {
        BeforeAll {
            # The helper compiles the class on first use.
            InModuleScope -ModuleName $script:ModuleName -Parameters @{ TokenFile = (Join-Path -Path $TestDrive -ChildPath 'compile-token') } -ScriptBlock {
                param ($TokenFile)

                Set-Content -LiteralPath $TokenFile -Value 'x.y.z' -NoNewline
                Mock -CommandName 'Wait-MsalEssentialsTask' -MockWith { [pscustomobject]@{ AccessToken = 'compiled' } }
                $null = Get-MsalEssentialsApplicationToken -TenantId 'hitboo.test' -ClientId '11111111-1111-1111-1111-111111111111' -FederatedTokenFile $TokenFile
            }
        }

        It 'reads the file and trims line breaks and spaces' {
            Set-Content -LiteralPath $script:TokenFile -Value ("  {0}`r`n" -f $script:FederatedToken) -NoNewline

            [MsalEssentials.FederatedTokenFileReader]::new($script:TokenFile).Read() |
                Should -BeExactly $script:FederatedToken
        }

        It 'reads the file again on every call, so a rotated token is picked up' {
            $reader = [MsalEssentials.FederatedTokenFileReader]::new($script:TokenFile)

            $reader.Read() |
                Should -BeExactly $script:FederatedToken

            Set-Content -LiteralPath $script:TokenFile -Value 'rotated.token.value' -NoNewline

            $reader.Read() |
                Should -BeExactly 'rotated.token.value'
        }

        It 'throws InvalidDataException for an empty file' {
            Set-Content -LiteralPath $script:TokenFile -Value "  `n" -NoNewline

            $caught = $null
            try {
                $null = [MsalEssentials.FederatedTokenFileReader]::new($script:TokenFile).Read()
            }
            catch {
                $caught = $_
            }

            $caught.Exception.InnerException |
                Should -BeOfType 'System.IO.InvalidDataException'
        }

        It 'binds to Func[string], the delegate type MSAL takes' {
            $reader   = [MsalEssentials.FederatedTokenFileReader]::new($script:TokenFile)
            $delegate = [System.Delegate]::CreateDelegate(
                [System.Func[string]],
                $reader,
                [MsalEssentials.FederatedTokenFileReader].GetMethod('Read')
            )

            $delegate.Invoke() |
                Should -BeExactly $script:FederatedToken
        }
    }
}
