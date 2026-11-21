# protect-sensitive-files.ps1
# PreToolUse hook for the Edit and Write tools.
# Blocks writes to secrets, private keys, git internals, and lock files.
# Exit 2 blocks the tool call and shows the reason to Claude. Exit 0 allows it.
# Runs on Windows PowerShell 5.1. ASCII only on purpose.

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$path = [string]$data.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }

# Normalise Windows separators so one set of patterns covers both.
$norm = $path -replace '\\', '/'

# Templates and examples are meant to be edited and committed.
if ($norm -match '(?i)\.(example|sample|template)$') { exit 0 }

$Blocked = @(
    @{ Pattern = '(?i)(^|/)\.env(\.[^/]*)?$';                    Reason = 'environment file that usually holds secrets' },
    @{ Pattern = '(?i)\.(pem|key|pfx|p12|kdbx|ppk)$';           Reason = 'private key or credential store' },
    @{ Pattern = '(?i)(^|/)id_(rsa|ed25519|ecdsa|dsa)$';         Reason = 'SSH private key' },
    @{ Pattern = '(?i)(^|/)\.ssh/';                              Reason = 'SSH configuration directory' },
    @{ Pattern = '(?i)(^|/)credentials(\.json)?$';               Reason = 'credentials file' },
    @{ Pattern = '(?i)(^|/)\.git/';                              Reason = 'git internals. Use git commands instead' },
    @{ Pattern = '(?i)(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|poetry\.lock|Cargo\.lock|Gemfile\.lock|composer\.lock)$';
       Reason = 'lock file. Change dependencies with the package manager instead' }
)

foreach ($item in $Blocked) {
    if ($norm -match $item.Pattern) {
        [Console]::Error.WriteLine("BLOCKED by hook: $($item.Reason). File: $path. Ask the user before changing this file.")
        exit 2
    }
}

exit 0
