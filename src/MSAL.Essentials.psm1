# MSAL.Essentials.psm1

$Public  = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public\*.ps1')  -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private\*.ps1') -ErrorAction SilentlyContinue)

foreach ($import in @($Public + $Private)) {
    try {
        . $import.FullName
    }
    catch {
        throw ('Failed to import function {0}: {1}' -f $import.FullName, $_)
    }
}

Export-ModuleMember -Function $Public.BaseName