#Requires -Version 7
<#
.SYNOPSIS
    Extracts policy assignment parameter values from AzGovViz's JSON output
    and emits one Bicep .bicepparam fragment per MG scope, ready to paste into
    the tenant config repo's parPolicyAssignmentParameterOverrides blocks.

.DESCRIPTION
    Reads per-assignment JSON files written by AzGovVizParallel.ps1 under
    JSON_<root>/Assignments/PolicyAssignments/Mg/**/*.json. Each file is the
    raw ARM response, so properties.parameters is present verbatim.

    For each MG scope that has ALZ-library-matching assignments with populated
    parameters, emits a file override-<mgId>.bicepparam containing a complete
    parPolicyAssignmentParameterOverrides = { ... } assignment.

    Non-library assignments are listed in custom-assignments.txt for operator
    review but are not emitted into the fragments.

    Read-only. Does not touch Azure or any repo file.

.PARAMETER AzGovVizJsonPath
    Path to the JSON_<root> directory produced by AzGovVizParallel.ps1.

.PARAMETER OutputDirectory
    Directory where per-scope fragment files will be written. Created if absent.

.PARAMETER AlzLibraryPath
    Optional path to the ALZ library (*.alz_policy_assignment.json files).
    When supplied, only assignments whose name matches an ALZ-library
    assignment name are emitted into the fragments. Highly recommended —
    without it, custom tenant-specific assignments leak into the output.

.EXAMPLE
    ./Build-OverrideFragments.ps1 `
        -AzGovVizJsonPath ./azgovviz-output/JSON_alz `
        -OutputDirectory ./takeover-fragments `
        -AlzLibraryPath ../templates/core/governance/lib/alz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AzGovVizJsonPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$AlzLibraryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Logging helpers (style mirrors existing scripts in this repo)
# -----------------------------------------------------------------------------
$NoColor = -not $Host.UI.SupportsVirtualTerminal
function Write-Step ($msg) { if ($NoColor) { Write-Host "`n── $msg ──" } else { Write-Host "`n`e[1m── $msg ──`e[0m" } }
function Write-Info ($msg) { if ($NoColor) { Write-Host "[INFO] $msg" }   else { Write-Host "`e[36m[INFO]`e[0m $msg" } }
function Write-Ok   ($msg) { if ($NoColor) { Write-Host "[OK]   $msg" }   else { Write-Host "`e[32m[OK]`e[0m   $msg" } }
function Write-Warn ($msg) { if ($NoColor) { Write-Host "[WARN] $msg" }   else { Write-Host "`e[33m[WARN]`e[0m $msg" } }

# =============================================================================
# Bicep literal emission
# =============================================================================

# A key can be a bare identifier if it matches [A-Za-z_][A-Za-z0-9_]*.
# Assignment names contain dashes, so they almost always get quoted.
function Format-BicepKey ([string]$Key) {
    if ($Key -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $Key }
    return "'{0}'" -f ($Key -replace "'", "\'")
}

# Escape a string for a Bicep single-quoted literal.
# Order matters: backslash first so subsequent escape insertions aren't re-escaped.
function Format-BicepString ([string]$Value) {
    $escaped = $Value `
        -replace '\\', '\\' `
        -replace "'", "\'" `
        -replace "`r", '\r' `
        -replace "`n", '\n' `
        -replace "`t", '\t' `
        -replace '\$\{', '\${'
    return "'{0}'" -f $escaped
}

# Recursive serializer: PSCustomObject / IDictionary / IList / scalar -> Bicep.
# The caller is expected to place the return value inline after `:` or `=` —
# this function never prefixes its first line with indent.
function ConvertTo-BicepLiteral {
    param(
        [object]$Value,
        [int]$IndentLevel = 0
    )
    $indent = '  ' * $IndentLevel
    $indentIn = '  ' * ($IndentLevel + 1)

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }

    if ($Value -is [string]) { return Format-BicepString $Value }

    # Arrays — empty on one line, items multiline.
    if ($Value -is [System.Collections.IList]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('[')
        foreach ($item in $items) {
            $rendered = ConvertTo-BicepLiteral -Value $item -IndentLevel ($IndentLevel + 1)
            [void]$sb.AppendLine("$indentIn$rendered")
        }
        [void]$sb.Append("$indent]")
        return $sb.ToString()
    }

    # Objects — PSCustomObject (from ConvertFrom-Json) or IDictionary (ordered).
    $props = $null
    if ($Value -is [System.Collections.IDictionary]) {
        # Preserve insertion order if it's an OrderedDictionary; otherwise sorted is fine.
        $props = @($Value.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Value = $Value[$_] } })
    }
    elseif ($Value -is [PSCustomObject]) {
        $props = @($Value.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Value = $_.Value } })
    }
    else {
        # Fallback — shouldn't happen with JSON input, but don't crash.
        return Format-BicepString ([string]$Value)
    }

    if ($props.Count -eq 0) { return '{}' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('{')
    foreach ($p in $props) {
        $key = Format-BicepKey $p.Name
        $rendered = ConvertTo-BicepLiteral -Value $p.Value -IndentLevel ($IndentLevel + 1)
        [void]$sb.AppendLine("$indentIn$key`: $rendered")
    }
    [void]$sb.Append("$indent}")
    return $sb.ToString()
}

# =============================================================================
# AzGovViz assignment discovery
# =============================================================================

# Walk JSON_<root>/Assignments/PolicyAssignments/Mg/** and return one record per
# assignment: { MgId; Path; Name; Properties }. The MG ID is pulled from
# properties.scope rather than the containing directory name (directory names
# include the display name and are not authoritative).
function Read-MgScopeAssignments ([string]$JsonRoot) {
    $mgRoot = Join-Path $JsonRoot 'Assignments/PolicyAssignments/Mg'
    if (-not (Test-Path $mgRoot)) {
        Write-Warn "AzGovViz MG-scope assignments directory not found: $mgRoot"
        return @()
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($jsonFile in Get-ChildItem -Path $mgRoot -Recurse -Filter '*.json') {
        try {
            $raw = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warn "Failed to parse $($jsonFile.FullName): $($_.Exception.Message)"
            continue
        }
        if (-not $raw.PSObject.Properties['properties']) { continue }
        $props = $raw.properties

        $scope = if ($props.PSObject.Properties['scope']) { [string]$props.scope } else { '' }
        $mgId = if ($scope -match '/managementGroups/([^/]+)$') { $Matches[1] } else { '' }
        if (-not $mgId) { continue }

        $name = if ($raw.PSObject.Properties['name']) { [string]$raw.name } else { $jsonFile.BaseName }

        [void]$results.Add([PSCustomObject]@{
                MgId       = $mgId
                Path       = $jsonFile.FullName
                Name       = $name
                Properties = $props
            })
    }
    return @($results)
}

# =============================================================================
# ALZ library filter
# =============================================================================

function Read-AlzLibraryAssignmentNames ([string]$LibraryPath) {
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $LibraryPath -or -not (Test-Path $LibraryPath)) { return $names }

    foreach ($file in Get-ChildItem -Path $LibraryPath -Filter '*.alz_policy_assignment.json' -Recurse) {
        try {
            $j = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($j.PSObject.Properties['name']) { [void]$names.Add([string]$j.name) }
        }
        catch {
            Write-Warn "Failed to parse library assignment $($file.Name): $($_.Exception.Message)"
        }
    }
    return $names
}

# =============================================================================
# Fragment emission
# =============================================================================

function New-OverrideFragment {
    param(
        [string]$MgId,
        [object[]]$Assignments
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("// Generated by Build-OverrideFragments.ps1 on $(Get-Date -Format 'o')")
    [void]$sb.AppendLine("// Source: AzGovViz assignment JSONs at MG scope '$MgId'")
    [void]$sb.AppendLine("// Paste into the .bicepparam file that drives the '$MgId' scope,")
    [void]$sb.AppendLine("// replacing the existing parPolicyAssignmentParameterOverrides assignment (if any).")
    [void]$sb.AppendLine('//')
    [void]$sb.AppendLine('// LITERAL values from the brownfield tenant are preserved verbatim. Review before')
    [void]$sb.AppendLine('// committing — some values may be worth converting to local var references')
    [void]$sb.AppendLine('// (e.g. lawResourceId, location, securityEmail) for maintainability.')
    [void]$sb.AppendLine('')
    [void]$sb.Append('param parPolicyAssignmentParameterOverrides = ')

    $outer = [ordered]@{}
    foreach ($a in ($Assignments | Sort-Object Name)) {
        $paramsProp = if ($a.Properties.PSObject.Properties['parameters']) { $a.Properties.parameters } else { $null }
        if (-not $paramsProp) { continue }

        # Skip assignments with no actual parameter values — nothing to override.
        $paramCount = @($paramsProp.PSObject.Properties).Count
        if ($paramCount -eq 0) { continue }

        $outer[$a.Name] = [ordered]@{ parameters = $paramsProp }
    }

    if ($outer.Keys.Count -eq 0) {
        [void]$sb.AppendLine('{}')
        [void]$sb.AppendLine('// (no ALZ-library assignments with parameter values found at this scope)')
        return $sb.ToString()
    }

    [void]$sb.AppendLine((ConvertTo-BicepLiteral -Value $outer -IndentLevel 0))
    return $sb.ToString()
}

# =============================================================================
# Main
# =============================================================================
Write-Host ''
if ($NoColor) { Write-Host 'Build-OverrideFragments' } else { Write-Host "`e[1mBuild-OverrideFragments`e[0m" }
Write-Host '(read-only — inga ändringar görs)'
Write-Host ''

if (-not (Test-Path $AzGovVizJsonPath)) {
    Write-Error "AzGovViz output path not found: $AzGovVizJsonPath"
    exit 1
}
if (-not (Test-Path $OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}

Write-Info "AzGovViz input:  $AzGovVizJsonPath"
Write-Info "Output dir:      $OutputDirectory"
if ($AlzLibraryPath) { Write-Info "ALZ library:     $AlzLibraryPath" }

# -----------------------------------------------------------------------------
# Load ALZ-library assignment names for filtering
# -----------------------------------------------------------------------------
$libNames = Read-AlzLibraryAssignmentNames $AlzLibraryPath
if ($AlzLibraryPath) {
    if ($libNames.Count -eq 0) {
        Write-Warn "ALZ library path was given but zero assignments were loaded — filter will pass everything through."
    }
    else {
        Write-Info "ALZ-library assignments loaded: $($libNames.Count)"
    }
}

# -----------------------------------------------------------------------------
# Walk AzGovViz output
# -----------------------------------------------------------------------------
Write-Step 'Reading AzGovViz MG-scope assignment JSONs'
$allAssignments = Read-MgScopeAssignments -JsonRoot $AzGovVizJsonPath
Write-Info "MG-scope assignments found: $($allAssignments.Count)"

# -----------------------------------------------------------------------------
# Split into ALZ-library vs custom
# -----------------------------------------------------------------------------
$alzAssignments = [System.Collections.Generic.List[object]]::new()
$customAssignments = [System.Collections.Generic.List[object]]::new()
foreach ($a in $allAssignments) {
    if ($libNames.Count -eq 0 -or $libNames.Contains($a.Name)) {
        [void]$alzAssignments.Add($a)
    }
    else {
        [void]$customAssignments.Add($a)
    }
}
Write-Info "ALZ-library matches:  $($alzAssignments.Count)"
Write-Info "Custom assignments:   $($customAssignments.Count)"

# -----------------------------------------------------------------------------
# Emit one fragment per MG scope
# -----------------------------------------------------------------------------
Write-Step 'Emitting Bicep fragments'
$byMg = $alzAssignments | Group-Object MgId
foreach ($grp in $byMg) {
    $fragment = New-OverrideFragment -MgId $grp.Name -Assignments $grp.Group
    $safe = ($grp.Name -replace '[^A-Za-z0-9_-]', '_')
    $outFile = Join-Path $OutputDirectory "override-$safe.bicepparam"
    $fragment | Set-Content -Path $outFile -Encoding utf8
    Write-Ok "  $($grp.Name) — $($grp.Group.Count) assignment(s) → $outFile"
}

# -----------------------------------------------------------------------------
# Custom assignments listed separately for operator review
# -----------------------------------------------------------------------------
if ($customAssignments.Count -gt 0) {
    $customFile = Join-Path $OutputDirectory 'custom-assignments.txt'
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('# Tilldelningar vid MG-scopes som inte finns i ALZ-biblioteket.')
    [void]$lines.Add('# Engine-stacken rör inte dessa vid takeover — de överlever orörda.')
    [void]$lines.Add('# Om du vill att engine ska hantera dem framöver, lägg in dem i')
    [void]$lines.Add("# tenant-repots customerPolicyAssignments. Annars — gör ingenting.")
    [void]$lines.Add('')
    [void]$lines.Add("MgId`tAssignmentName")
    foreach ($a in ($customAssignments | Sort-Object MgId, Name)) {
        [void]$lines.Add("$($a.MgId)`t$($a.Name)")
    }
    $lines | Set-Content -Path $customFile -Encoding utf8
    Write-Info "Custom assignments listed in: $customFile"
}

Write-Host ''
Write-Ok 'Done.'