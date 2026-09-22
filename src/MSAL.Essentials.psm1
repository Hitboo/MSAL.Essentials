# MSAL.Essentials.psm1

# Load the correct pre-built assemblies for this PowerShell edition.
# PS 7+ (Core) needs the netstandard2.0 build; Windows PowerShell 5.1 (Desktop) needs net472.
$DllFolder = if ($PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net472' }
$LibPath   = Join-Path -Path $PSScriptRoot -ChildPath ('lib\{0}' -f $DllFolder)

# Add-Type cannot unload an assembly from a running session. Re-importing this module
# with -Force would otherwise throw "type already exists" errors on the second run,
# so skip anything that's already loaded.
$LoadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies().GetName().Name

foreach ($dll in Get-ChildItem -Path $LibPath -Filter '*.dll') {
    $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($dll.Name)

    if ($assemblyName -in $LoadedAssemblies) {
        continue
    }

    try {
        Add-Type -Path $dll.FullName
    } catch {
        throw ('Failed to load assembly {0}: {1}' -f $dll.FullName, $_)
    }
}

# Dot-source every function file so it becomes available in this module's scope.
$PublicFunctions  = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public\*.ps1')  -ErrorAction SilentlyContinue)
$PrivateFunctions = @(Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private\*.ps1') -ErrorAction SilentlyContinue)

foreach ($function in @($PublicFunctions + $PrivateFunctions)) {
    try {
        . $function.FullName
    } catch {
        throw ('Failed to import function {0}: {1}' -f $function.FullName, $_)
    }
}

# Only Public/ functions become part of the module's exposed surface;
# Private/ functions stay dot-sourced but internal.
Export-ModuleMember -Function $PublicFunctions.BaseName