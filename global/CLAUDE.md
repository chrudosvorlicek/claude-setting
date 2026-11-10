# Global rules (all projects)

Source: `global/CLAUDE.md` in the claude-setting repo, linked to ~/.claude/CLAUDE.md by its install.sh.
Project CLAUDE.md files add to these; they don't replace them.

## Security

- Never commit secrets: API keys, tokens, passwords, private keys, certificates, `.env` files,
  cloud credential files. Use environment variables or a secret manager; commit only
  `.env.example` with placeholder values.
- When adding a file that holds local config or credentials, add it to `.gitignore` in the same change.
- Never print secret values to the terminal or into files, logs or commit messages. Refer to
  them by variable name.
- Don't read credential stores (`~/.ssh`, `~/.aws`, `.env` files, key files) unless the user asks.
- If you find a secret already committed, stop and tell the user. Rotating it is the fix;
  rewriting history alone is not.

## Git

- Never commit directly to `main` or `master`. Create a branch (`git switch -c <type>/<short-name>`,
  e.g. `feat/login-form`, `fix/null-crash`) and open a pull request.
- Never force-push to shared branches. On your own feature branch, use `--force-with-lease` only.
- Never skip hooks (`--no-verify`) or disable signing to get a commit through; fix the cause.
- Commit or push only when the user asks. Review `git diff --staged` before committing.
- Ask before destructive commands: `git reset --hard`, `git clean`, `git branch -D`,
  rewriting published history.

## Enforcement

A PreToolUse hook (`hooks/git-guard.sh` in claude-setting) blocks the git rules above and scans
staged changes for secrets. If it blocks something that is genuinely intended or a false positive,
explain why to the user and let them run the command themselves. Don't try to work around the hook.
