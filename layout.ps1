
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
    [string]$Layout,

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

function Escape-WtColor([string]$color) {
    if ([string]::IsNullOrEmpty($color)) { 
        return "" 
    }
    return '"' + $color + '"'
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

function Expand-Variables([string]$cmd, [hashtable]$variables, [hashtable]$globalVars) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $cmd }
    
    $expandedCmd = $cmd
    
    if ($variables) {
        foreach ($var in $variables.GetEnumerator()) {
            $pattern = '\$' + [regex]::Escape($var.Key)
            $expandedCmd = $expandedCmd -replace $pattern, $var.Value
        }
    }
    
    if ($globalVars) {
        foreach ($var in $globalVars.GetEnumerator()) {
            $pattern = '\$' + [regex]::Escape($var.Key)
            $expandedCmd = $expandedCmd -replace $pattern, $var.Value
        }
    }
    
    return $expandedCmd
}

function Build-PaneCommand([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return @() }
    
    # 이미 확장된 명령어를 받음
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

function Convert-PSObjectToHashtable($obj) {
    $hashtable = @{}
    if ($obj) {
        $obj.PSObject.Properties | ForEach-Object {
            $hashtable[$_.Name] = $_.Value
        }
    }
    return $hashtable
}

# ---------- Load JSON ----------

try {
    if ($LayoutJson) {
        $layoutObj = Read-JsonFile -path $LayoutJson
    } elseif ($Layout) {
        $path = Resolve-LayoutPath -name $Layout
        $layoutObj = Read-JsonFile -path $path
    } else {
        # Layout이 지정되지 않았으면 사용 가능한 레이아웃 목록 표시
        $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $dir  = Join-Path $root 'layouts'
        
        $layouts = Get-ChildItem -LiteralPath $dir -Filter 'layout-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
        
        if ($layouts.Count -eq 0) {
            Write-Host "사용 가능한 레이아웃이 없습니다." -ForegroundColor Red
            exit 1
        }
        
        Write-Host "`n사용 가능한 레이아웃 목록:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $layouts.Count; $i++) {
            $name = $layouts[$i].BaseName -replace '^layout-', ''
            Write-Host "  $($i + 1). $name" -ForegroundColor Green
        }
        
        $selection = Read-Host "`n레이아웃 번호를 선택하세요 (1-$($layouts.Count))"
        
        if (-not [int]::TryParse($selection, [ref]$null) -or $selection -lt 1 -or $selection -gt $layouts.Count) {
            Write-Host "잘못된 선택입니다." -ForegroundColor Red
            exit 1
        }
        
        $Layout = $layouts[$selection - 1].BaseName -replace '^layout-', ''
        $path = Resolve-LayoutPath -name $Layout
        $layoutObj = Read-JsonFile -path $path
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

# 전역 변수 처리
$globalVars = @{}
if ($layoutObj.PSObject.Properties.Match('Vars').Count -gt 0 -and $layoutObj.Vars) {
    $globalVars = Convert-PSObjectToHashtable -obj $layoutObj.Vars
}

foreach ($tab in $layoutObj.tabs) {
    # Resolve profile precedence: pane.Profile > tab.Profile > -ProfileName
    $tabProfile = $null
    if ($tab.PSObject.Properties.Match('Profile').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($tab.Profile)) {
        $tabProfile = [string]$tab.Profile
    } elseif ($ProfileName) {
        $tabProfile = $ProfileName
    }

    # 탭 수준 변수 처리
    $tabVars = @{}
    if ($tab.PSObject.Properties.Match('Vars').Count -gt 0 -and $tab.Vars) {
        $tabVars = Convert-PSObjectToHashtable -obj $tab.Vars
    }

    # main pane 찾기
    $mainPane = $null
    $otherPanes = @()
    if ($tab.Panes) {
        foreach ($p in $tab.Panes) {
            if (-not (Is-MoveFocusStep $p)) {
                if ($p.PSObject.Properties.Match('main').Count -gt 0 -and $p.main -eq $true) {
                    $mainPane = $p
                } else {
                    $otherPanes += $p
                }
            } else {
                $otherPanes += $p
            }
        }
    }

    # new-tab
    $newTab = @("new-tab")
    if ($tab.TabTitle) { $newTab += @("--title", (Escape-WtArg $tab.TabTitle)) }
    if ($tab.TabColor) { 
        $colorEscaped = Escape-WtColor $tab.TabColor
        $newTab += @("--tabColor", $colorEscaped) 
    }
    if ($tabProfile)   { $newTab += @("--profile", (Escape-WtArg $tabProfile)) }
    
    # main pane이 있으면 해당 커맨드 사용, 없으면 탭의 Cmd 사용
    if ($mainPane) {
        $paneVars = @{}
        if ($mainPane.PSObject.Properties.Match('Vars').Count -gt 0 -and $mainPane.Vars) {
            $paneVars = Convert-PSObjectToHashtable -obj $mainPane.Vars
        }
        $expandedCmd = Expand-Variables -cmd $mainPane.Cmd -variables $paneVars -globalVars $globalVars
        $newTab += (Build-PaneCommand -cmd $expandedCmd)
    } elseif ($tab.Cmd) {
        $expandedCmd = Expand-Variables -cmd $tab.Cmd -variables $tabVars -globalVars $globalVars
        $newTab += (Build-PaneCommand -cmd $expandedCmd)
    }
    
    $segments.Add(($newTab -join ' '))

    # pane steps (main이 아닌 pane들만 처리)
    if (-not $otherPanes) { continue }

    foreach ($p in $otherPanes) {
        if (Is-MoveFocusStep $p) {
            $segments.Add(("move-focus {0}" -f $p.MoveFocus))
            continue
        }

        $split = @("split-pane")

        # Pane-level profile override
        $paneProfile = "PowerShell"

        if ($tab.TabTitle) { $split += @("--title", (Escape-WtArg $tab.TabTitle)) }
        if ($tab.TabColor) { $split += @("--tabColor", (Escape-WtColor $tab.TabColor)) }
        if ($paneProfile)  { $split += @("--profile", (Escape-WtArg $paneProfile)) }

        if ($p.Vertical -eq $true) { $split += "-V" } else { $split += "-H" }
        if ($p.Size) { $split += @("-s", "$($p.Size)") }

        # 팬 변수 처리
        $paneVars = @{}
        if ($p.PSObject.Properties.Match('Vars').Count -gt 0 -and $p.Vars) {
            $paneVars = Convert-PSObjectToHashtable -obj $p.Vars
        }

        $expandedCmd = Expand-Variables -cmd $p.Cmd -variables $paneVars -globalVars $globalVars
        $split += (Build-PaneCommand -cmd $expandedCmd)

        $segments.Add(($split -join ' '))
    }
}

# ---------- Launch ----------

$commandString = Build-CommandSegmentsJoin -segments $segments
if ($prefix) {
    $commandString = ($prefix -join ' ') + " " + $commandString
}

if ($DryRun) {
    Write-Host "wt $commandString"
    exit 0
}

# wt.exe 실행 - cmd.exe를 통해 명령어 실행 (따옴표 보존)
try {
    Write-Host "Launching Windows Terminal with layout: $Layout" -ForegroundColor Cyan
    $cmdLine = "wt.exe $commandString"
    Start-Process cmd.exe -ArgumentList "/c", $cmdLine -WindowStyle Hidden
} catch {
    Write-Error "Failed to launch Windows Terminal: $_"
    exit 1
}
