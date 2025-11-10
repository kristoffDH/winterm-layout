
param(
    # Allow bare positional argument for layout name (without -Layout)
    [Parameter(Position = 0, Mandatory = $false, HelpMessage = "Logical layout name; loads .\layouts\layout-<name>.json. Ignored when -LayoutJson is provided.")]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        try {
            $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
            $dir = Join-Path $root 'layouts'
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Filter 'layout-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Name -match '^layout-(.+)\.json$') {
                        $name = $matches[1]
                        if ([string]::IsNullOrEmpty($wordToComplete) -or $name -like "$wordToComplete*") {
                            [System.Management.Automation.CompletionResult]::new($name, $name, 'ParameterValue', $name)
                        }
                    }
                }
            }
        } catch {}
    })]
    [string]$Layout = "example",

    [Parameter(Mandatory = $false)]
    [string]$LayoutJson,

    [Parameter(Mandatory = $false)]
    [string]$ProfileName,

    [Parameter(Mandatory = $false)]
    [switch]$ReuseWindow,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# ---------- Utils ----------

function Resolve-WtPath {
    # Try local app path then PATH
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\wt.exe"),
        "wt"
    )
    foreach ($c in $candidates) {
        try {
            $cmd = Get-Command $c -ErrorAction Stop 
            return $cmd.Source
        } catch {
            continue
        }
    }
    throw "wt.exe not found. Install Windows Terminal or add wt to PATH."
}

function Escape-WtArg([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    $escaped = $s -replace '"','\"'
    return '"' + $escaped + '"'
}

function Build-CommandSegmentsJoin([string[]]$segments) {
    return ($segments -join " ; ")
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Layout JSON not found: $path"
    }
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    try {
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid JSON: $path. Error: $($_.Exception.Message)"
    }
}

function Resolve-LayoutPath([string]$name) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $dir  = Join-Path $root 'layouts'
    return Join-Path $dir ("layout-{0}.json" -f $name)
}

function Build-PaneCommand([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return @() }
    $escaped = $cmd -replace '"','`"'
    return @("--", "pwsh -NoExit -Command `"$escaped`"")
}

function Is-MoveFocusStep($p) {
    $valid = @('left','right','up','down','first','previous','nextInOrder','previousInOrder')
    if ($null -eq $p) { return $false }
    if ($p.PSObject.Properties.Match('MoveFocus').Count -eq 0) { return $false }
    $dir = ($p.MoveFocus | Out-String).Trim()
    return ($valid -contains $dir)
}

# ---------- Load JSON ----------

try {
    if ($LayoutJson) {
        $layoutObj = Read-JsonFile -path $LayoutJson
    } elseif ($Layout) {
        $path = Resolve-LayoutPath -name $Layout
        $layoutObj = Read-JsonFile -path $path
    } else {
        throw "Specify -Layout <name> or -LayoutJson <path>."
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

if (-not $layoutObj.tabs) {
    Write-Error "JSON must contain a 'tabs' array."
    exit 1
}

# ---------- Build wt chain ----------

$wt = Resolve-WtPath

# Use a growable list for segments
$segments = [System.Collections.Generic.List[string]]::new()

# Optional window reuse (-w 0)
$prefix = @()
if ($ReuseWindow) { $prefix = @("-w","0") }

foreach ($tab in $layoutObj.tabs) {
    # Resolve profile precedence: pane.Profile > tab.Profile > -ProfileName
    $tabProfile = $null
    if ($tab.PSObject.Properties.Match('Profile').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($tab.Profile)) {
        $tabProfile = [string]$tab.Profile
    } elseif ($ProfileName) {
        $tabProfile = $ProfileName
    }

    # new-tab
    $newTab = @("new-tab")
    if ($tab.TabTitle) { $newTab += @("--title", (Escape-WtArg $tab.TabTitle)) }
    if ($tab.TabColor) { $newTab += @("--tabColor", (Escape-WtArg $tab.TabColor)) }
    if ($tabProfile)   { $newTab += @("--profile", (Escape-WtArg $tabProfile)) }
    if ($tab.Cmd)      { $newTab += (Build-PaneCommand $tab.Cmd) }
    $segments.Add(($newTab -join ' '))

    # pane steps
    if (-not $tab.Panes) { continue }

    foreach ($p in $tab.Panes) {
        if (Is-MoveFocusStep $p) {
            $segments.Add(("move-focus {0}" -f $p.MoveFocus))
            continue
        }

        $split = @("split-pane")

        # Pane-level profile override
        $paneProfile = "PowerShell"

        if ($tab.TabTitle) { $split += @("--title", (Escape-WtArg $tab.TabTitle)) }
        if ($tab.TabColor) { $split += @("--tabColor", (Escape-WtArg $tab.TabColor)) }
        if ($paneProfile)  { $split += @("--profile", (Escape-WtArg $paneProfile)) }

        if ($p.Vertical -eq $true) { $split += "-V" } else { $split += "-H" }
        if ($p.Size) { $split += @("-s", "$($p.Size)") }

        $split += (Build-PaneCommand $p.Cmd)

        $segments.Add(($split -join ' '))
    }
}

# ---------- Launch ----------

$fullArgs = @()
$fullArgs += $prefix
$fullArgs += (Build-CommandSegmentsJoin -segments $segments)

if ($DryRun) {
    Write-Host "wt $($fullArgs -join ' ')"
    exit 0
}

Start-Process $wt -ArgumentList ($fullArgs -join ' ')
