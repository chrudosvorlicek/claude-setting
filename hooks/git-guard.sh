#!/usr/bin/env bash
# PreToolUse(Bash) hook: blocks risky git operations before they run.
# Exit 2 = block; the stderr message is shown to Claude so it can change course.
#
#   - commit / merge / cherry-pick / revert directly on a protected branch
#   - push to a protected branch, push --force / -f, push --all / --mirror
#   - --no-verify (skipping the repo's own git hooks)
#   - committing files that look like secrets (.env, keys, certificates)
#   - committing content that looks like secrets (API keys, tokens, private keys, passwords)
#
# Protected branches: GIT_GUARD_PROTECTED (ERE), default "main|master".
# Escape hatch: the user runs the command themselves in a terminal.

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ "$cmd" == *git* ]] || exit 0

PROTECTED="^(${GIT_GUARD_PROTECTED:-main|master})$"

block() {
  printf 'BLOCKED by global git guard (~/.claude hooks): %s\n' "$*" >&2
  printf 'If this is intended, ask the user to run the command themselves.\n' >&2
  exit 2
}

resolve() { local d="${1/#\~/$HOME}"; [[ "$d" == /* ]] || d="$cwd/$d"; printf '%s' "$d"; }

# --- secret detection ---------------------------------------------------------
SECRET_FILE='(^|/)(\.env(\.[^/]+)?|id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|key|p12|pfx|jks|keystore)|credentials\.json|service[-_]account[^/]*\.json|\.netrc|\.pgpass)$'
SECRET_FILE_OK='(^|/)\.env\.(example|sample|template|dist|defaults)$|\.pub$'
SECRET_CONTENT=(
  'AKIA[0-9A-Z]{16}'                                   # AWS access key
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'                 # private keys
  'gh[pousr]_[A-Za-z0-9]{36,}'                         # GitHub tokens
  'github_pat_[A-Za-z0-9_]{50,}'
  'glpat-[A-Za-z0-9_-]{20,}'                           # GitLab
  'xox[baprs]-[A-Za-z0-9-]{10,}'                       # Slack
  'sk-ant-[A-Za-z0-9_-]{20,}'                          # Anthropic
  'sk-(proj-)?[A-Za-z0-9_-]{32,}'                      # OpenAI-style
  'AIza[0-9A-Za-z_-]{35}'                              # Google API key
  '(sk|rk)_live_[0-9A-Za-z]{20,}'                      # Stripe
  '(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]]{8,}["'"'"']'
)

scan_commit() {  # $1 = dir, $2 = 1 if commit -a (include unstaged tracked changes)
  local dir="$1" all="$2" files f hits=""
  files=$(git -C "$dir" diff --cached --name-only 2>/dev/null)
  [[ "$all" == 1 ]] && files+=$'\n'$(git -C "$dir" diff --name-only 2>/dev/null)
  # files a `git add` earlier in the same command line is about to stage (not staged yet when we run)
  (( ${#pending_add[@]} )) && files+=$'\n'$(git -C "$dir" ls-files -m -o --exclude-standard -- "${pending_add[@]}" 2>/dev/null)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" =~ $SECRET_FILE && ! "$f" =~ $SECRET_FILE_OK ]]; then
      hits+="  - $f (secret-like file name)"$'\n'; continue
    fi
    local added
    added=$( { git -C "$dir" diff --cached -U0 -- "$f"; git -C "$dir" diff -U0 -- "$f"
               git -C "$dir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || head -c 1000000 -- "$dir/$f" | sed 's/^/+/'; } 2>/dev/null \
             | grep -E '^\+' | grep -vE '^\+\+\+ ')
    local p
    for p in "${SECRET_CONTENT[@]}"; do
      if grep -qiE -- "$p" <<<"$added"; then hits+="  - $f (content matches: ${p:0:40})"$'\n'; break; fi
    done
  done < <(sort -u <<<"$files")
  [[ -n "$hits" ]] && block $'possible secrets in this commit:\n'"$hits"'Remove them (and add to .gitignore) or confirm with the user that these are false positives.'
}

# --- walk each command segment --------------------------------------------------
dir="$cwd"
pending_add=()
while IFS= read -r seg; do
  read -ra w <<<"$seg"
  (( ${#w[@]} )) || continue
  i=0
  # track `cd DIR` so later segments target the right repo
  if [[ "${w[0]}" == cd && -n "${w[1]:-}" ]]; then dir=$(resolve "${w[1]}"); continue; fi
  while [[ "${w[i]:-}" == *=* || "${w[i]:-}" == sudo || "${w[i]:-}" == command ]]; do ((i++)); done
  [[ "${w[i]:-}" == git ]] || continue
  ((i++))
  gdir="$dir"
  while [[ "${w[i]:-}" == -* ]]; do
    case "${w[i]}" in
      -C) gdir=$(resolve "${w[i+1]}"); ((i+=2)) ;;
      -c) ((i+=2)) ;;
      *)  ((i++)) ;;
    esac
  done
  sub="${w[i]:-}"; args=("${w[@]:i+1}")
  branch=$(git -C "$gdir" rev-parse --abbrev-ref HEAD 2>/dev/null)

  for a in "${args[@]}"; do
    [[ "$a" == --no-verify ]] && block "--no-verify skips the repository's own safety hooks."
  done

  case "$sub" in
    add)
      paths=(); for a in "${args[@]}"; do [[ "$a" == -* ]] || paths+=("$a"); done
      for a in "${args[@]}"; do [[ "$a" == -A || "$a" == --all || "$a" == -u || "$a" == --update ]] && paths=(.); done
      (( ${#paths[@]} )) && pending_add+=("${paths[@]}")
      ;;
    commit)
      [[ "$branch" =~ $PROTECTED ]] && block "direct commit to '$branch'. Create a branch first: git switch -c <feature-name>"
      all=0
      for a in "${args[@]}"; do [[ "$a" == --all || "$a" =~ ^-[a-zA-Z]*a[a-zA-Z]*$ ]] && all=1; done
      scan_commit "$gdir" "$all"
      ;;
    merge|cherry-pick|revert|am)
      ff=0; for a in "${args[@]}"; do [[ "$a" == --ff-only || "$a" == --abort ]] && ff=1; done
      [[ "$branch" =~ $PROTECTED && $ff == 0 ]] && block "'git $sub' would create commits directly on '$branch'. Work on a branch and open a PR."
      ;;
    push)
      pos=()
      for a in "${args[@]}"; do
        case "$a" in
          --force|-f|--force-if-includes) block "force push. Use --force-with-lease on your own feature branch if really needed." ;;
          --all|--mirror) block "push $a pushes every branch, including protected ones." ;;
          -*) ;;
          *) pos+=("$a") ;;
        esac
        [[ "$a" =~ ^-[a-zA-Z]*f[a-zA-Z]*$ ]] && block "force push (-f)."
      done
      # refspecs: anything after the remote; check the destination side
      for r in "${pos[@]:1}"; do
        dst="${r##*:}"; dst="${dst#+}"; dst="${dst#refs/heads/}"
        [[ "$r" == +* ]] && block "force push via +refspec ($r)."
        [[ "$dst" =~ $PROTECTED || "$dst" == HEAD && "$branch" =~ $PROTECTED ]] && block "push to protected branch '$dst'. Push a feature branch and open a PR."
      done
      (( ${#pos[@]} <= 1 )) && [[ "$branch" =~ $PROTECTED ]] && block "push from '$branch' goes straight to the protected branch. Push a feature branch and open a PR."
      ;;
  esac
done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"$cmd")

exit 0
