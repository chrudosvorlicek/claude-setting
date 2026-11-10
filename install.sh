#!/usr/bin/env bash
# Install claude-setting into ~/.claude (idempotent; safe to re-run after pulling changes).
#
#   ./install.sh              install / update
#   ./install.sh --dry-run    show what would change, touch nothing
#   ./install.sh --uninstall  remove everything this repo added
#
# What it does:
#   - links ~/.claude/CLAUDE.md -> global/CLAUDE.md
#   - links each item in skills/, agents/, commands/ into ~/.claude/<same dir>/
#   - merges global/settings.json into ~/.claude/settings.json (@REPO@ = this folder);
#     your own settings are kept, arrays are merged, hooks are de-duplicated by command
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
FRAGMENT="$REPO/global/settings.json"
LINK_DIRS=(skills agents commands)
TS=$(date +%Y%m%d-%H%M%S)

MODE=install
case "${1:-}" in
  "") ;;
  --dry-run)   MODE=dry ;;
  --uninstall) MODE=uninstall ;;
  -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
esac

say()  { printf '  %s\n' "$*"; }
run()  { if [[ $MODE == dry ]]; then say "[dry-run] $*"; else "$@"; fi; }
need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need jq

[[ "$REPO" == *"|"* ]] && { echo "repo path must not contain '|'" >&2; exit 1; }
mkdir -p "$CLAUDE_DIR"
chmod +x "$REPO"/hooks/*.sh "$REPO"/statusline/*.sh 2>/dev/null || true

# --- symlinks -----------------------------------------------------------------
link() {  # link <target> <link-path>
  local target="$1" path="$2"
  if [[ -L "$path" && "$(readlink -f "$path")" == "$(readlink -f "$target")" ]]; then
    say "ok      ${path/#$HOME/\~}"; return
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    say "backup  ${path/#$HOME/\~} -> ${path/#$HOME/\~}.bak.$TS"
    run mv "$path" "$path.bak.$TS"
  fi
  say "link    ${path/#$HOME/\~} -> ${target/#$REPO/<repo>}"
  run mkdir -p "$(dirname "$path")"
  run ln -s "$target" "$path"
}

unlink_ours() {  # remove link only if it points into this repo
  local path="$1"
  if [[ -L "$path" && "$(readlink -f "$path")" == "$REPO"/* ]]; then
    say "remove  ${path/#$HOME/\~}"; rm "$path"
  fi
}

# --- settings merge -------------------------------------------------------------
frag=$(sed "s|@REPO@|$REPO|g" "$FRAGMENT")
current='{}'
[[ -f "$SETTINGS" ]] && current=$(cat "$SETTINGS")
jq -e . >/dev/null <<<"$current" || { echo "$SETTINGS is not valid JSON; fix it first" >&2; exit 1; }

MERGE='
$F[0] as $F
| (if $F.statusLine then .statusLine = $F.statusLine else . end)
| .permissions.deny = (((.permissions.deny // []) + ($F.permissions.deny // [])) | unique)
| .permissions.ask  = (((.permissions.ask  // []) + ($F.permissions.ask  // [])) | unique)
| .hooks = ((.hooks // {}) as $h
    | reduce (($F.hooks // {}) | to_entries[]) as $e ($h;
        .[$e.key] = ((.[$e.key] // []) as $cur
          | [$cur[].hooks[]?.command] as $have
          | $cur + [ $e.value[] | select(any(.hooks[]; .command as $c | ($have | any(. == $c)) | not)) ])))
'
UNMERGE='
$F[0] as $F
| (if ((.statusLine.command // "") | startswith($repo)) then del(.statusLine) else . end)
| (if .permissions.deny then .permissions.deny -= ($F.permissions.deny // []) else . end)
| (if .permissions.ask  then .permissions.ask  -= ($F.permissions.ask  // []) else . end)
| (if .hooks then .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; (.command // "") | startswith($repo)) | not)))
                            | with_entries(select(.value | length > 0))) else . end)
| (if .permissions then .permissions |= with_entries(select((.value | type) != "array" or (.value | length > 0))) else . end)
| (if .permissions == {} then del(.permissions) else . end)
| (if .hooks == {} then del(.hooks) else . end)
'

write_settings() {  # write_settings <jq-program>
  local new
  new=$(jq --slurpfile F <(printf '%s' "$frag") --arg repo "$REPO" "$1" <<<"$current")
  if [[ "$(jq -S . <<<"$new")" == "$(jq -S . <<<"$current")" ]]; then
    say "ok      ${SETTINGS/#$HOME/\~} (no changes)"; return
  fi
  say "update  ${SETTINGS/#$HOME/\~}"
  diff <(jq -S . <<<"$current") <(jq -S . <<<"$new") | sed 's/^/          /' || true
  if [[ $MODE != dry ]]; then
    [[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$TS"
    printf '%s\n' "$new" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi
}

# --- run ----------------------------------------------------------------------------
echo "claude-setting: $MODE  (repo: $REPO, target: $CLAUDE_DIR)"

if [[ $MODE == uninstall ]]; then
  unlink_ours "$CLAUDE_DIR/CLAUDE.md"
  for d in "${LINK_DIRS[@]}"; do
    for p in "$CLAUDE_DIR/$d"/*; do [[ -L "$p" ]] && unlink_ours "$p"; done
  done
  write_settings "$UNMERGE"
  echo "done. Backups of your previous files are kept as *.bak.<timestamp>."
  exit 0
fi

link "$REPO/global/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
for d in "${LINK_DIRS[@]}"; do
  [[ -d "$REPO/$d" ]] || continue
  for item in "$REPO/$d"/*; do
    [[ -e "$item" ]] || continue
    [[ "$(basename "$item")" == .gitkeep ]] && continue
    link "$item" "$CLAUDE_DIR/$d/$(basename "$item")"
  done
done
write_settings "$MERGE"

[[ $MODE == dry ]] && { echo "dry run, nothing changed."; exit 0; }
echo "done. Open /hooks or restart Claude Code to load hook changes."
