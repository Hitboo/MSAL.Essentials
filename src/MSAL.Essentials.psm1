# MSAL.Essentials.psm1

# Load the correct pre-built assemblies for this PowerShell edition.
# PS 7+ (Core) needs the netstandard2.0 build; Windows PowerShell 5.1 (Desktop) needs net472.
$DllFolder = if ($PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net472' }
$LibPath   = Join-Path -Path $PSScriptRoot -ChildPath ('lib\{0}' -f $DllFolder)

# Windows PowerShell (and, less often, pwsh) hosts have no app.config with
# assembly binding redirects, so the CLR requires an EXACT assembly version
# match by default. The DLLs under lib\ are a NuGet-resolved graph, and it's
# normal for one package's compiled reference (e.g. System.Text.Json wanting
# System.Memory 4.0.1.1) to not exactly match the version NuGet actually
# resolved for the whole graph (e.g. System.Memory 4.0.1.2). Both files are
# already shipped in lib\ - this handler only redirects a version-mismatched
# lookup to the file that's already there. It never downloads or fetches
# anything; it is a pure offline fallback and only runs when the CLR's
# normal loading has already failed.
$script:MsalEssentialsAssemblyResolveHandler = [System.ResolveEventHandler] {
    param($resolveSender, $resolveArgs)

    $requestedAssemblyName = [System.Reflection.AssemblyName]::new($resolveArgs.Name)
    $candidateDllPath = Join-Path -Path $LibPath -ChildPath ('{0}.dll' -f $requestedAssemblyName.Name)

    if (Test-Path -Path $candidateDllPath) {
        return [System.Reflection.Assembly]::LoadFrom($candidateDllPath)
    }

    return $null
}

[System.AppDomain]::CurrentDomain.add_AssemblyResolve($script:MsalEssentialsAssemblyResolveHandler)

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