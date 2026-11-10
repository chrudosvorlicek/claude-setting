# claude-setting

My shared Claude Code setup: global rules, safety hooks and tools that apply to every project.
One repo, installed into `~/.claude` with one command.

## Install

Requires `bash`, `jq`, `git`.

```bash
git clone <this-repo> ~/claude-setting    # any location works
cd ~/claude-setting
./install.sh --dry-run               # preview
./install.sh                         # install / update (safe to re-run)
```

Then open `/hooks` in Claude Code once, or restart it, so hook changes are loaded.

`./install.sh --uninstall` removes everything this repo added and leaves your own settings alone.

## What gets installed

| Repo path | Installed as | How |
|---|---|---|
| `global/CLAUDE.md` | `~/.claude/CLAUDE.md` | symlink |
| `global/settings.json` | merged into `~/.claude/settings.json` | jq merge, `@REPO@` → repo path |
| `skills/*`, `agents/*`, `commands/*` | `~/.claude/<same dir>/<name>` | symlink per item (folders created when needed) |

`settings.json` is merged rather than linked because Claude Code writes to it itself (theme,
`/config`, approvals). The merge keeps your own keys, merges permission lists, and adds hooks
only if their command isn't there already. Every run that changes something saves a timestamped
`*.bak.<timestamp>` backup first.

Edits to the symlinked files apply immediately. Edits to `global/settings.json` need `./install.sh`.

## Contents

### Status line (`statusline/statusline.sh`)

```
Opus 5.5 │ ~/web/project │ █████████░░░░┊░░░░░░░░░░░░░░ 30% 62k/200k │ ↑1.2M ↓46k $0.42
```

Model, working directory, a context-usage bar that fills the terminal width, session tokens and
cost, plus a compact hint:

| Context used | Colour | Hint |
|---|---|---|
| < 35% | green | (none; `┊` marks the 35% point) |
| 35% | yellow | compact at next stopping point |
| 70% | orange | /compact soon |
| 85% | red | ⚠ /compact now |

Env overrides: `SL_WARN`, `SL_HIGH`, `SL_CRIT` (thresholds), `SL_WIDTH` (force width),
`SL_MARGIN` (right margin), `SL_DEBUG=1` (dump input JSON to `/tmp/statusline-input.json`).

### Git guard (`hooks/git-guard.sh`)

PreToolUse hook on Bash. Blocks:

- commit / merge / cherry-pick / revert directly on `main` or `master` (`merge --ff-only` allowed)
- push to `main`/`master`, including a plain `git push` from them
- `push --force`, `-f`, `+refspec`, `--all`, `--mirror` (`--force-with-lease` on feature branches is allowed)
- `--no-verify`
- commits with secret-like files (`.env*`, `*.pem`, `*.key`, SSH keys, `credentials.json`, …;
  `.env.example` etc. allowed) or secret-like content (AWS / GitHub / GitLab / Slack / Anthropic /
  OpenAI / Google / Stripe keys, private keys, quoted passwords and tokens)

Protected branches: `GIT_GUARD_PROTECTED` (regex, default `main|master`).
It's a guardrail, not a sandbox: commands hidden in scripts or `sh -c` aren't parsed. Use
server-side branch protection for real enforcement.

### Permissions (`global/settings.json`)

- **Deny reading:** `.env` variants, `*.pem`, `*.key`, SSH keys, `~/.ssh`, `~/.aws`, gh and Claude credentials
- **Ask first:** `git reset --hard`, `git clean`, `git branch -D`, `git filter-branch`, `git filter-repo`, `rm -rf`

### Global rules (`global/CLAUDE.md`)

Security and git conventions Claude follows in every project: no secrets in git or output,
branches + PRs instead of commits to main, no force-push or hook skipping, commit only when asked,
ask before destructive commands, no `cd` for one-off operations (absolute paths, `git -C`, subshells).

## Adding things

- **Rule:** edit `global/CLAUDE.md` (live immediately).
- **Setting / permission / hook:** edit `global/settings.json`, use `@REPO@` for paths into this repo, run `./install.sh`.
- **Skill / agent / command:** add it under `skills/<name>/`, `agents/<name>.md` or `commands/<name>.md`, run `./install.sh`.
