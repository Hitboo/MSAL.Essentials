# MSAL.Essentials.psm1

# Load the correct pre-built assemblies for this PowerShell edition.
# PS 7+ (Core) needs the netstandard2.0 build; Windows PowerShell 5.1 (Desktop) needs net472.
$DllFolder = if ($PSEdition -eq 'Core') { 'netstandard2.0' } else { 'net472' }
$LibPath   = Join-Path -Path $PSScriptRoot -ChildPath ('lib\{0}' -f $DllFolder)

# ---------------------------------------------------------------------------
# Dependency resolver
#
# Only the entry-point assemblies are loaded explicitly (below). Everything
# else in lib\ (System.Memory, System.Text.Json, ...) is resolved on demand
# by a handler that runs ONLY when the runtime can't bind the assembly itself:
#
#   Desktop (5.1): AppDomain.AssemblyResolve. Windows PowerShell has no binding
#     redirects, so exact assembly versions rarely line up (see the warnings
#     from Update-MsalLibDependencies). The handler ignores the requested
#     version, prefers an assembly with that name that is ALREADY loaded
#     (e.g. from Az/Graph modules, avoiding duplicate copies), and otherwise
#     loads the file from lib\net472.
#
#   Core (7+): AssemblyLoadContext.Default.Resolving. Fires only if the default
#     context can't find the assembly, so anything the .NET shared framework
#     already provides (System.Text.Json, System.Memory, ...) always wins over
#     the copies in lib\netstandard2.0.
#
# This is compiled C# rather than a scriptblock on purpose: the runtime can
# raise these events on threads that have no PowerShell runspace, which would
# crash a scriptblock handler.
# ---------------------------------------------------------------------------
if (-not ('MsalEssentials.AssemblyResolver' -as [type])) {
    if ($PSEdition -eq 'Core') {
        $resolverSource = @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;

namespace MsalEssentials
{
    public static class AssemblyResolver
    {
        private static string _libPath;
        private static Func<AssemblyLoadContext, AssemblyName, Assembly> _handler;

        public static void Register(string libPath)
        {
            _libPath = libPath;
            if (_handler != null) { return; }
            _handler = Resolve;
            AssemblyLoadContext.Default.Resolving += _handler;
        }

        public static void Unregister()
        {
            if (_handler == null) { return; }
            AssemblyLoadContext.Default.Resolving -= _handler;
            _handler = null;
        }

        private static Assembly Resolve(AssemblyLoadContext context, AssemblyName name)
        {
            string candidate = Path.Combine(_libPath, name.Name + ".dll");
            if (File.Exists(candidate)) { return context.LoadFromAssemblyPath(candidate); }
            return null;
        }
    }
}
'@
    }
    else {
        # Windows PowerShell 5.1 compiles with C# 5 - keep this source C# 5 compatible.
        $resolverSource = @'
using System;
using System.IO;
using System.Reflection;

namespace MsalEssentials
{
    public static class AssemblyResolver
    {
        private static string _libPath;
        private static ResolveEventHandler _handler;

        public static void Register(string libPath)
        {
            _libPath = libPath;
            if (_handler != null) { return; }
            _handler = new ResolveEventHandler(Resolve);
            AppDomain.CurrentDomain.AssemblyResolve += _handler;
        }

        public static void Unregister()
        {
            if (_handler == null) { return; }
            AppDomain.CurrentDomain.AssemblyResolve -= _handler;
            _handler = null;
        }

        private static Assembly Resolve(object sender, ResolveEventArgs args)
        {
            string simpleName = new AssemblyName(args.Name).Name;

            if (simpleName.EndsWith(".resources", StringComparison.OrdinalIgnoreCase)) { return null; }

            // Prefer a copy that is already loaded in this session.
            foreach (Assembly loaded in AppDomain.CurrentDomain.GetAssemblies())
            {
                if (string.Equals(loaded.GetName().Name, simpleName, StringComparison.OrdinalIgnoreCase))
                {
                    return loaded;
                }
            }

            string candidate = Path.Combine(_libPath, simpleName + ".dll");
            if (File.Exists(candidate)) { return Assembly.LoadFrom(candidate); }
            return null;
        }
    }
}
'@
    }

    Add-Type -TypeDefinition $resolverSource -Language 'CSharp'
}

[MsalEssentials.AssemblyResolver]::Register($LibPath)

# Stop the handler from outliving the module (Remove-Module / Import-Module -Force).
$ExecutionContext.SessionState.Module.OnRemove = {
    [MsalEssentials.AssemblyResolver]::Unregister()
}

# ---------------------------------------------------------------------------
# Entry-point assemblies
#
# Everything else is pulled in lazily by the resolver above. Add-Type cannot
# unload an assembly, so skip anything already loaded (re-import with -Force,
# or another module that ships the same assembly) - but warn if the loaded
# copy is a different version than the one this module was built against.
# ---------------------------------------------------------------------------
$EntryAssemblies = @(
    'Microsoft.IdentityModel.Abstractions'
    'Microsoft.Identity.Client'
)

foreach ($assemblyName in $EntryAssemblies) {
    $dllPath = Join-Path -Path $LibPath -ChildPath ('{0}.dll' -f $assemblyName)

    if (-not (Test-Path -Path $dllPath)) {
        throw ('Required assembly not found: {0}. Run build\Update-MsalLibDependencies.ps1.' -f $dllPath)
    }

    $alreadyLoaded = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object -FilterScript { $_.GetName().Name -eq $assemblyName } |
        Select-Object -First 1

    if ($alreadyLoaded) {
        $expectedVersion = [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version
        $loadedVersion   = $alreadyLoaded.GetName().Version

        if ($loadedVersion -ne $expectedVersion) {
            Write-Warning ('{0} {1} is already loaded in this session (from {2}); this module was built against {3}.' -f $assemblyName, $loadedVersion, $alreadyLoaded.Location, $expectedVersion)
        }
        continue
    }

    try {
        Add-Type -Path $dllPath
    } catch {
        throw ('Failed to load assembly {0}: {1}' -f $dllPath, $_)
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