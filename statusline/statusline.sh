#!/usr/bin/env bash
# Claude Code status line:
#   model │ cwd │ context bar (stretches to terminal width) pct used/window │ session tokens + cost │ compact hint
#
# Env overrides:
#   SL_WARN=35  SL_HIGH=70  SL_CRIT=85   thresholds, percent of context window (green below SL_WARN)
#   SL_WIDTH=<cols>                      force line width if terminal width detection fails
#   SL_MARGIN=4                          columns kept free at the right edge
# Debug: SL_DEBUG=1 saves the last stdin JSON to /tmp/statusline-input.json

export LC_ALL=C.UTF-8          # so ${#var} counts characters, not bytes
input=$(cat)
[[ -n "${SL_DEBUG:-}" ]] && printf '%s' "$input" >/tmp/statusline-input.json

WARN=${SL_WARN:-35} HIGH=${SL_HIGH:-70} CRIT=${SL_CRIT:-85} MARGIN=${SL_MARGIN:-4}

# One jq pass: fields separated by \x1f (non-whitespace, so empty fields survive read)
IFS=$'\x1f' read -r model dir transcript win used pct tin tout cost < <(
  jq -r '[
    (.model.display_name // .model.id // "?"),
    (.workspace.current_dir // .cwd // ""),
    (.transcript_path // ""),
    (.context_window.context_window_size // ""),
    (.context_window.current_usage
       | if . then (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
         else "" end),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // ""),
    (.context_window.total_output_tokens // ""),
    (.cost.total_cost_usd // "")
  ] | map(tostring) | join("\u001f")' <<<"$input"
)

# Fallback: read context size from the last main-thread assistant message in the transcript
if [[ -z "$used" && -f "$transcript" ]]; then
  used=$(tail -n 400 "$transcript" | jq -rs '
    map(select(.type == "assistant" and (.isSidechain | not) and .message.usage)) | last
    | .message.usage | if . then (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) else "" end
  ' 2>/dev/null)
fi

# Window size fallback: 1M models carry [1m] in their id/name, otherwise 200k
if [[ -z "$win" ]]; then
  [[ "$input" == *"[1m]"* ]] && win=1000000 || win=200000
fi

# Terminal width: explicit override, then the controlling tty, then $COLUMNS, then 120
cols=${SL_WIDTH:-}
[[ -z "$cols" ]] && cols=$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
[[ -z "$cols" || "$cols" -le 0 ]] && cols=${COLUMNS:-}
[[ -z "$cols" || "$cols" -le 0 ]] && cols=$(tput cols 2>/dev/null)
[[ -z "$cols" || "$cols" -le 0 ]] && cols=120

fmt() {  # 1234 -> 1k, 1234567 -> 1.2M
  awk -v n="${1:-0}" 'BEGIN{
    if (n >= 1e6) printf "%.1fM", n/1e6; else if (n >= 1e3) printf "%.0fk", n/1e3; else printf "%d", n }'
}

R=$'\e[0m' DIM=$'\e[2m' BOLD=$'\e[1m'
GREEN=$'\e[32m' YELLOW=$'\e[33m' ORANGE=$'\e[38;5;208m' RED=$'\e[31m' CYAN=$'\e[36m'
SEP=" ${DIM}│${R} "

# --- build segments; the bar is inserted last, sized to the space left over ---
cwd=${dir/#$HOME/\~}
left="${BOLD}${model}${R}${SEP}${CYAN}${cwd}${R}${SEP}"

ctx="" col=$DIM hint=""
if [[ -n "$used" ]]; then
  [[ -z "$pct" ]] && pct=$(( used * 100 / win ))
  pct=${pct%.*}
  if   (( pct >= CRIT )); then col=$RED    hint="${RED}${BOLD}⚠ /compact now${R}"
  elif (( pct >= HIGH )); then col=$ORANGE hint="${ORANGE}/compact soon${R}"
  elif (( pct >= WARN )); then col=$YELLOW hint="${YELLOW}compact at next stopping point${R}"
  else                         col=$GREEN
  fi
  ctx=" ${col}${pct}%${R} ${DIM}$(fmt "$used")/$(fmt "$win")${R}"
else
  ctx=" ${DIM}ctx –${R}"
fi

right=""
tok=""
[[ -n "$tin" ]]  && tok+="↑$(fmt "$tin") "
[[ -n "$tout" ]] && tok+="↓$(fmt "$tout") "
[[ -n "$cost" ]] && tok+=$(printf '$%.2f' "$cost")
[[ -n "$tok" ]]  && right+="${SEP}${tok% }"
[[ -n "$hint" ]] && right+="${SEP}${hint}"

strip() { sed $'s/\e\\[[0-9;]*m//g' <<<"$1"; }
plain=$(strip "$left$ctx$right")
barw=$(( cols - MARGIN - ${#plain} ))
(( barw < 10 )) && barw=10

filled=$(( ${pct:-0} * barw / 100 )); (( filled > barw )) && filled=$barw
printf -v on  '%*s' "$filled" '';            on=${on// /█}
printf -v off '%*s' $(( barw - filled )) ''; off=${off// /░}

# marker at the "good" threshold so you can see how far past it you are
mark=$(( WARN * barw / 100 ))
if (( mark > filled && mark < barw )); then
  off_a=${off:0:$(( mark - filled ))}; off_b=${off:$(( mark - filled + 1 ))}
  off="${off_a}${DIM}┊${R}${DIM}${off_b}"
fi

printf '%s\n' "${left}${col}${on}${R}${DIM}${off}${R}${ctx}${right}"
