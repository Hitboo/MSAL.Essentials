param(
    [Parameter(Mandatory)]
    [string]
    $LibFolderPath
)

$ErrorActionPreference = 'Stop'
$mismatches = New-Object -TypeName 'System.Collections.Generic.List[string]'

$dllFiles = Get-ChildItem -Path $LibFolderPath -Filter '*.dll'
$loadedAssembliesByName = @{}

foreach ($dllFile in $dllFiles) {
    try {
        $assembly = [System.Reflection.Assembly]::LoadFrom($dllFile.FullName)
        $loadedAssembliesByName[$assembly.GetName().Name] = $assembly.GetName().Version
    }
    catch {
        $mismatches.Add("Could not load $($dllFile.Name): $_")
    }
}

foreach ($dllFile in $dllFiles) {
    try {
        $assembly = [System.Reflection.Assembly]::LoadFrom($dllFile.FullName)
    }
    catch {
        continue
    }

    foreach ($referencedName in $assembly.GetReferencedAssemblies()) {
        if ($loadedAssembliesByName.ContainsKey($referencedName.Name)) {
            $actualVersion = $loadedAssembliesByName[$referencedName.Name]
            if ($actualVersion -ne $referencedName.Version) {
                $mismatches.Add("$($dllFile.Name) references $($referencedName.Name) $($referencedName.Version), but $actualVersion is present")
            }
        }
    }
}

[pscustomobject]@{ Mismatches = @($mismatches) } | ConvertTo-Json -Compress