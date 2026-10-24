# Create a certificate for testing

Creates a self-signed certificate for the [certificate example](Application-Certificate.md) and exports its public part for the app registration.
Self-signed certificates are fine for testing. For production, use a certificate from your organization's certificate authority or Azure Key Vault.

Windows only: `New-SelfSignedCertificate` and the `Cert:\` drive are part of Windows PowerShell 5.1 and PowerShell 7 on Windows.

```powershell
#region Settings
# The name shown in the certificate store and on the app registration.
[string]$CertificateSubject = 'CN=MSAL.Essentials test'
# Where to save the public part (.cer) for the upload: your Downloads folder.
[string]$PublicCertificatePath = Join-Path -Path $HOME -ChildPath 'Downloads\MsalEssentialsTest.cer'
#endregion Settings

#region Create the certificate
$certificateParameters = @{
    Subject           = $CertificateSubject
    CertStoreLocation = 'Cert:\CurrentUser\My'      # Current user's personal store, no admin rights needed.
    KeyAlgorithm      = 'RSA'
    KeyLength         = 2048
    KeySpec           = 'Signature'                 # The key is only used to sign the client assertion.
    KeyExportPolicy   = 'NonExportable'             # The private key can't be copied out of the store.
    NotAfter          = (Get-Date).AddYears(1)
}
$Certificate = New-SelfSignedCertificate @certificateParameters

# Export only the public part. This is what you upload; the private key stays in the store.
$null = Export-Certificate -Cert $Certificate -FilePath $PublicCertificatePath

# Use this thumbprint in the certificate example.
$Certificate.Thumbprint
#endregion Create the certificate
```

Then upload the `.cer` file: Microsoft Entra admin center > **App registrations** > your app > **Certificates & secrets** > **Certificates** > **Upload certificate**. Entra ID shows the same thumbprint after the upload.

When the test is over, delete the certificate from the app registration and from the store:

```powershell
Remove-Item -Path ('Cert:\CurrentUser\My\{0}' -f $Certificate.Thumbprint)
```

[Back to README](/README.md#how-to-use-it)
