# run-hook-tests.ps1
# Self-test for the hook in .claude/hooks. Feeds real hook payloads into the
# script exactly the way Claude Code does (JSON on stdin) and checks the exit
# code. Also checks the settings.json wiring, which is the part that silently
# breaks.
#
# Usage (from the repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-hook-tests.ps1
#
# Exit code 0 = all cases passed. Exit code 1 = at least one failed.

$ErrorActionPreference = 'Continue'

$root    = Split-Path -Parent $PSScriptRoot
$hooks   = Join-Path $root '.claude/hooks'
$protect = Join-Path $hooks 'protect-sensitive-files.ps1'

if (-not (Test-Path -LiteralPath $protect)) {
    Write-Host "MISSING HOOK SCRIPT: $protect" -ForegroundColor Red
    exit 1
}

function Invoke-Hook {
    param([string]$Script, [hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    $json | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script 2>$null | Out-Null
    return $LASTEXITCODE
}

function File-Payload([string]$Tool, [string]$FilePath) {
    return @{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = @{ file_path = $FilePath } }
}

$results = New-Object System.Collections.ArrayList
function Check([string]$Name, [int]$Expected, [int]$Actual) {
    $ok = ($Expected -eq $Actual)
    [void]$results.Add([pscustomobject]@{ Name = $Name; Expected = $Expected; Actual = $Actual; Pass = $ok })
}

# ---- Must block (exit 2) ----
$blockCases = @(
    @{ Tool = 'Edit';  Path = 'C:\proj\.env' },
    @{ Tool = 'Write'; Path = 'C:\proj\.env.production' },
    @{ Tool = 'Edit';  Path = 'C:\proj\certs\server.pem' },
    @{ Tool = 'Write'; Path = 'C:\Users\me\.ssh\id_ed25519' },
    @{ Tool = 'Edit';  Path = 'C:\proj\.git\config' },
    @{ Tool = 'Edit';  Path = 'C:\proj\package-lock.json' },
    @{ Tool = 'Write'; Path = 'C:\proj\credentials.json' },
    @{ Tool = 'Edit';  Path = '/home/me/project/.env.local' },
    @{ Tool = 'Write'; Path = 'C:\proj\secrets\api.key' }
)
foreach ($c in $blockCases) {
    Check "block: $($c.Path)" 2 (Invoke-Hook $protect (File-Payload $c.Tool $c.Path))
}

# ---- Must be allowed (exit 0) ----
# These matter as much as the blocks. A rule that blocks legitimate work gets
# the whole hook deleted the first time it gets in your way.
$allowCases = @(
    @{ Tool = 'Write'; Path = 'C:\proj\.env.example' },
    @{ Tool = 'Edit';  Path = 'C:\proj\.env.template' },
    @{ Tool = 'Edit';  Path = 'C:\proj\src\index.ts' },
    @{ Tool = 'Write'; Path = 'C:\proj\README.md' },
    @{ Tool = 'Edit';  Path = 'C:\proj\.github\workflows\ci.yml' },
    @{ Tool = 'Write'; Path = 'C:\proj\id_rsa.pub.txt' },
    @{ Tool = 'Edit';  Path = 'C:\proj\docs\keys.md' }
)
foreach ($c in $allowCases) {
    Check "allow: $($c.Path)" 0 (Invoke-Hook $protect (File-Payload $c.Tool $c.Path))
}

# ---- Degenerate payloads must not block ----
Check 'empty path exits 0'  0 (Invoke-Hook $protect (File-Payload 'Edit' ''))
Check 'garbage stdin exits 0' 0 (@{ nonsense = $true } | ForEach-Object { Invoke-Hook $protect @{ junk = 'x' } })

# ---- Config: the settings.json wiring ----
# A correct script behind a matcher that never routes anything to it is the
# failure mode that looks most like success.
$settingsPath = Join-Path $root '.claude/settings.json'
Check 'config: settings.json exists' 1 ([int](Test-Path -LiteralPath $settingsPath))
$settings = $null
try { $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json } catch { $settings = $null }
Check 'config: settings.json parses' 1 ([int]($null -ne $settings))

if ($null -ne $settings) {
    $group = @($settings.hooks.PreToolUse) | Where-Object { $_.matcher -match 'Edit' } | Select-Object -First 1
    Check 'config: PreToolUse group present' 1 ([int]($null -ne $group))
    Check 'config: matcher covers Write'     1 ([int]($group.matcher -match 'Write'))

    $handlers = @($group.hooks)
    Check 'config: handler present'               1 ([int]($handlers.Count -ge 1))
    Check 'config: handler is type=command'       1 ([int]($handlers[0].type -eq 'command'))
    Check 'config: handler invokes powershell'    1 ([int]($handlers[0].command -match '(?i)powershell'))
    Check 'config: handler uses exec form (args)' 1 ([int](@($handlers[0].args).Count -ge 1))
    Check 'config: handler sets a timeout'        1 ([int]([bool]$handlers[0].timeout))

    $ref = (@($handlers[0].args) | Where-Object { $_ -match '(?i)\.ps1$' } | Select-Object -First 1)
    $rel = ($ref -replace '(?i)\$\{CLAUDE_PROJECT_DIR\}', '').TrimStart('/', '\')
    Check 'config: referenced script exists' 1 ([int](Test-Path -LiteralPath (Join-Path $root $rel)))
}

# ---- Report ----
$results | Format-Table Name, Expected, Actual, Pass -AutoSize | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object { -not $_.Pass })
$total = $results.Count
$passed = $total - $failed.Count
if ($failed.Count -eq 0) {
    Write-Host "ALL $total CASES PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$passed of $total passed. FAILED:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $($_.Name) (expected $($_.Expected), got $($_.Actual))" -ForegroundColor Red }
    exit 1
}
