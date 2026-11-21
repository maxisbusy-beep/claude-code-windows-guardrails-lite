# Claude Code file-protection hook for Windows

A single PowerShell `PreToolUse` hook that stops Claude Code from editing your `.env` files, private keys, `.git/` internals and lock files — plus a 28-case self-test that proves it works on your machine before you rely on it.

MIT licensed. No dependencies. No network calls. Runs on the Windows PowerShell 5.1 that ships with Windows 11.

```powershell
git clone https://github.com/maxisbusy-beep/claude-code-windows-guardrails-lite
cd claude-code-windows-guardrails-lite
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-hook-tests.ps1
```

Expected last line: `ALL 28 CASES PASSED`.

## Why this exists

Most Claude Code hook examples in circulation are written for bash. On Windows they tend to fail **without saying anything**: the hook never fires, or it runs under a shell that can't execute it, and Claude carries on exactly as if nothing were configured. You find out when something gets overwritten.

Three traps worth knowing about, whether or not you use this repo.

### Trap 1: `"matcher": "Bash"` does not cover the PowerShell tool

On Windows, Claude Code can run commands through a **separate PowerShell tool**, not only the Bash tool. A `PreToolUse` hook matched on `Bash` never sees those calls — so every rule you wrote for `Remove-Item -Recurse`, `rd /s`, `del` or `format C:` is unreachable while looking perfectly correct in your config.

The matcher has to be `Bash|PowerShell`.

I shipped this bug. The hook script had patterns for all four of those commands, every one of them tested and passing, sitting behind a matcher that could never deliver a PowerShell call to them. The tests passed because they invoked the script directly. Nothing tested the wiring.

### Trap 2: exec form beats shell form

Shell form — one long `command` string — goes through a shell (Git Bash on Windows, or PowerShell when Git Bash isn't installed), so you inherit a dependency and you're relying on quoting to survive a project path with a space in it.

Exec form passes each argument separately, with no shell quoting at all:

```json
{
  "type": "command",
  "command": "powershell.exe",
  "args": [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    "${CLAUDE_PROJECT_DIR}/.claude/hooks/protect-sensitive-files.ps1"
  ],
  "timeout": 15
}
```

`${CLAUDE_PROJECT_DIR}` is substituted into each `args` element before launch, so `C:\My Projects\thing` cannot split into two arguments. That is what this repo ships.

### Trap 3: exit codes, and the fail-open default

A `PreToolUse` hook speaks in exit codes:

| Exit | Meaning |
|---|---|
| `2` | **Block.** Your stderr becomes the message Claude sees. |
| `0` | No verdict. Normal permission flow continues — note that `0` does *not* approve the call. |
| anything else | Non-blocking error. **The action goes ahead.** |

That last row is the trap. A PowerShell script that throws an unhandled exception exits with something that isn't 0 or 2, and the dangerous operation **proceeds**. Your safety hook fails open.

So wrap everything and decide deliberately. This repo's hook catches a malformed payload and exits 0 — which means it fails *open*, by choice, because a broken hook that freezes your session is worse. That is a real trade-off with no free answer; the point is choosing it on purpose rather than discovering it later.

## Install into your own project

Copy `.claude/hooks/protect-sensitive-files.ps1` into your project's `.claude/hooks/`, then merge the `hooks` block from `.claude/settings.json` into your own. Open Claude Code in the project and type `/hooks` — you should see the `Edit|Write|NotebookEdit` entry listed.

To confirm it actually fires, ask Claude to edit a `.env` file. You should see `BLOCKED by hook:` and no write.

## What it blocks

| Pattern | Why |
|---|---|
| `.env`, `.env.*` | environment files that usually hold secrets |
| `*.pem`, `*.key`, `*.pfx`, `*.p12`, `*.kdbx`, `*.ppk` | private keys and credential stores |
| `id_rsa`, `id_ed25519`, `id_ecdsa`, `id_dsa` | SSH private keys |
| anything under `.ssh/` | SSH configuration |
| `credentials`, `credentials.json` | credentials files |
| anything under `.git/` | git internals — use git commands |
| `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `poetry.lock`, `Cargo.lock`, `Gemfile.lock`, `composer.lock` | lock files — change deps with the package manager |

Explicitly allowed: anything ending `.example`, `.sample` or `.template`. Those are meant to be edited and committed.

## Testing your own hooks

The payload arrives on **stdin as JSON**, which means you can test a hook with no agent involved:

```powershell
'{"tool_name":"Edit","tool_input":{"file_path":"C:\\proj\\.env"}}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File .\.claude\hooks\protect-sensitive-files.ps1
"exit=$LASTEXITCODE"   # expect 2
```

Two things most test suites miss, and both are in `tests/run-hook-tests.ps1`:

- **Test the allows, not just the blocks.** A rule that blocks `.env.example` or `docs/keys.md` is worse than no rule, because the first time it gets in your way you'll delete the whole file and then you have nothing.
- **Test the wiring, not just the script.** Read your own `settings.json` in the suite and assert properties of it: that the matcher covers what you think, that every referenced script exists, that every handler sets a timeout. That's Trap 1 again, and it's the one case that would have caught my bug.

## What this does not do

- It is not a sandbox. A determined command gets around path patterns — writing the file from a shell command, for instance, which this hook does not see.
- It only covers `Edit`, `Write` and `NotebookEdit`. A Bash command like `echo x > .env` is not caught here. For that you need a command hook as well.
- It does not run on macOS or Linux as shipped. It's PowerShell. Porting it is not hard, but it isn't done here.

## The full pack

This repo is one hook. The paid pack adds the other two and the tooling around them:

- **`block-dangerous-commands.ps1`** — force push, hard reset, `git clean -f`, `rm -rf` on home or root, pipe-to-shell, drive formats, `DROP DATABASE`, `chmod -R 777`. Matched on `Bash|PowerShell`, per Trap 1.
- **`audit-log.ps1`** — one JSON line per `Bash`, `PowerShell`, `Edit` or `Write` call to `.claude/logs/audit.jsonl`, with secrets redacted.
- Two subagents (a read-only `reviewer` that cannot edit files, and a `test-runner` that won't weaken tests to make them pass), two skills (`/safe-commit`, which never pushes, and `/hook-check`), a Windows `CLAUDE.md` template, an installer that backs up anything it replaces, and a **65-case** self-test — 12 of whose cases check the `settings.json` wiring, for exactly the reason in Trap 1.

$29, one-time: **https://maxibee4.gumroad.com/l/claude-code-windows-guardrails**

Everything described in this README works without buying anything.

## License

MIT. See [LICENSE](LICENSE).
