#!/usr/bin/env bash
# @description  CLI fallback adapter for dv-screenshot-capture.
#               Default for platform="all"/meta-work AND the universal final fallback
#               for every other adapter (silicon → magick → loud failure).
#               Applies redaction grep before piping diff to any image tool.
#
# @arg  --worktask-id <id>           state.json worktask_id (required)
# @arg  --task-id <TASK_ID>          DV task id naming the evidence stream (required)
# @arg  --slug <kebab>               kebab-case slug ≤40 chars (required)
# @arg  --base-ref <ref>             git base ref (default: origin/master)
# @arg  --platform <platform>        platform value recorded in manifest row
# @arg  --run-index <N>              run_index from state.json (default: 0)
# @arg  --files <path-to-filelist>   newline-separated file list to diff (optional)
# @arg  --self-test                  run built-in fixture tests; no network/git required
#
# @exitcode 0  success — path to produced file printed to stdout
# @exitcode 1  hard error (bad args, no .context resolved, ledger disagrees with the ids)
# @exitcode 2  tool_missing — no image tool on PATH; no image is written. When silicon, magick
#              and convert are all absent, a tool_missing row is upserted into
#              <ctx>/images/<id>/screenshots-<TASK_ID>.md. Exit 2 also means a broken install,
#              so consumers key on stdout error=tool_missing, never the bare code.
# @exitcode 3  render_failed — a tool was present but produced no usable PNG
#
# Contract (uniform adapter shape):
#   Prints one line to stdout:
#     path=<file>  bytes=<N>  ok=<true|false>  error=<null|tool_missing|render_failed>
#
# Minimum shell: Bash 4.x (uses [[ ]], local, command -v; macOS ships Bash 3.2 —
# call via `bash <path>` from Homebrew Bash 5 if features require it).

set -Eeuo pipefail
shopt -s inherit_errexit 2> /dev/null || true
IFS=$'\n\t'
trap 'printf >&2 "error: %s:%d: exit %d\n" "${BASH_SOURCE[0]}" "$LINENO" "$?"' ERR

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
WORKTASK_ID=""
TASK_ID=""
SLUG=""
BASE_REF="origin/master"
PLATFORM="all"
RUN_INDEX="0"
FILES_PATH=""
SELF_TEST=0

usage() {
  cat >&2 << 'EOF'
usage: cli-fallback.sh
  --worktask-id <id>        worktask_id from state.json (required)
  --task-id <TASK_ID>       DV task id, e.g. DV0 (required)
  --slug <kebab>            kebab-case slug ≤40 chars (required)
  [--base-ref <ref>]        git base ref (default: origin/master)
  [--platform <platform>]   platform label for manifest (default: all)
  [--run-index <N>]         run_index from state.json (default: 0)
  [--files <path>]          newline-separated file list to scope diff (optional)
  [--self-test]             run built-in self-tests; exits 0 on pass
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktask-id)
      WORKTASK_ID="${2:-}"
      shift 2
      ;;
    --task-id)
      TASK_ID="${2:-}"
      shift 2
      ;;
    --slug)
      SLUG="${2:-}"
      shift 2
      ;;
    --base-ref)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --platform)
      PLATFORM="${2:-}"
      shift 2
      ;;
    --run-index)
      RUN_INDEX="${2:-}"
      shift 2
      ;;
    --files)
      FILES_PATH="${2:-}"
      shift 2
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h | --help) usage ;;
    *)
      printf >&2 'error: unknown flag %s\n' "$1"
      usage
      ;;
  esac
done

# Task ids name the evidence stream and sit inside file names, so the grammar has no glob characters.
_task_id_ok() {
  local re='^[A-Z]{2}[0-9]+$'
  [[ $1 =~ $re ]]
}

# Ids that become path segments or manifest cells: no `/`, `|`, whitespace or leading dot.
_field_ok() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  [[ $1 =~ $re ]]
}

# Next NN for one task: 1 + the highest NN on disk (incl. oversize/) or in its manifest.
# The max, not a count, so a deleted capture never recycles a number; 10# keeps 08 and 09 decimal.
_next_nn() {
  local dir="$1" task="$2" max=0 f nn
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f="${f##*/}"
    nn="${f#dv-"$task"-}"
    nn="${nn%%-*}"
    if [ "$((10#$nn))" -gt "$max" ]; then
      max="$((10#$nn))"
    fi
  done << EOF
$(find "$dir" "$dir/oversize" -maxdepth 1 -type f -name "dv-$task-[0-9][0-9]-*" 2> /dev/null || true)
$(LC_ALL=C awk -F'|' -v t="$task" '/^[[:space:]]*\|/ { gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[0-9][0-9]$/) print "dv-" t "-" $2 "-row" }' "$dir/screenshots-$task.md" 2> /dev/null || true)
EOF
  if [ "$max" -ge 99 ]; then
    return 1
  fi
  printf '%02d\n' "$((max + 1))"
}

# Replaces (or appends) this slug's tool_missing row in the task manifest through a temp file in
# the same directory and a rename, so a reader never sees a half-written table.
_TM_TMP=""
_upsert_tool_missing_row() { # <manifest> <nn> <slug> <platform> <tools> <worktask> <task> <run-index>
  local mf="$1" nn="$2" slug="$3" platform="$4" tools="$5" wid="$6" task="$7" run="$8" old="" row
  if [ -d "$mf" ] || [ -L "$mf" ]; then
    return 1
  fi
  if [ -f "$mf" ]; then
    old=$(LC_ALL=C awk -F'|' -v s="$slug" '
      /^[[:space:]]*\|/ {
        for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        if ($3 == s && $7 == "cli_fallback" && index($8, "tool_missing:") == 1) { print $2; exit }
      }' "$mf" 2> /dev/null || true)
  fi
  if [ -n "$old" ]; then
    nn="$old"
  fi
  row="| $nn | $slug | — | 0 | $platform | cli_fallback | tool_missing: $tools | $(date -u +%Y-%m-%dT%H:%M:%SZ) | — |"
  _TM_TMP=$(mktemp "$(dirname -- "$mf")/.screenshots-$task.md.XXXXXX") || return 1
  if [ -f "$mf" ]; then
    LC_ALL=C awk -v s="$slug" -v row="$row" '
      /^[[:space:]]*\|/ {
        n = split($0, f, "|")
        for (i = 1; i <= n; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", f[i])
        intable = 1
        if (f[3] == s && f[7] == "cli_fallback" && index(f[8], "tool_missing:") == 1) next
        print
        next
      }
      intable && !done { print row; done = 1 }
      { print }
      END {
        if (done) exit
        if (!intable) {
          print ""
          print "| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |"
          print "|---|------|------|-------|----------|---------|---------|----------|------------|"
        }
        print row
      }' "$mf" > "$_TM_TMP" || return 1
  else
    {
      printf '# Screenshots — %s / %s\n\n> Run index: %s.\n\n' "$wid" "$task" "$run"
      printf '| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |\n'
      printf '|---|------|------|-------|----------|---------|---------|----------|------------|\n'
      printf '%s\n' "$row"
    } > "$_TM_TMP" || return 1
  fi
  chmod 644 "$_TM_TMP" || return 1
  mv -f -- "$_TM_TMP" "$mf" || return 1
  _TM_TMP=""
}

# ---------------------------------------------------------------------------
# --self-test: no git, no network, no external deps beyond bash + printf
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" -eq 1 ]]; then
  PASS=0
  FAIL=0

  _ok() {
    printf 'PASS: %s\n' "$1"
    ((PASS++)) || true
  }
  _fail() {
    printf 'FAIL: %s\n' "$1"
    ((FAIL++)) || true
  }

  # --- Test 1: portable stat idiom works on a known file
  T1_FILE="${BASH_SOURCE[0]}"
  T1_BYTES=$(stat -f%z "$T1_FILE" 2> /dev/null || stat -c%s "$T1_FILE" 2> /dev/null || echo 0)
  if [[ "$T1_BYTES" -gt 0 ]]; then
    _ok "portable stat returns non-zero for this script"
  else
    _fail "portable stat returned 0 for ${T1_FILE}"
  fi

  # --- Test 2: redaction pattern detection
  TMPDIR_TEST=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_TEST"' EXIT
  FAKE_DIFF="${TMPDIR_TEST}/fake.diff"
  printf 'password = "supersecret123"\n' > "$FAKE_DIFF"
  if grep -qE '(password|secret|token|api_key|private_key)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}' "$FAKE_DIFF"; then
    _ok "redaction pattern fires on fake secret"
  else
    _fail "redaction pattern missed fake secret"
  fi

  # --- Test 3: safe diff (no secret) does NOT match redaction pattern
  SAFE_DIFF="${TMPDIR_TEST}/safe.diff"
  printf '+func foo() { return 42 }\n' > "$SAFE_DIFF"
  if ! grep -qE '(password|secret|token|api_key|private_key)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}' "$SAFE_DIFF"; then
    _ok "redaction pattern leaves safe diff alone"
  else
    _fail "redaction pattern false-positive on safe diff"
  fi

  # --- Test 4: the floor writes no placeholder and reports the right reason
  T4_DIR="${TMPDIR_TEST}/images/self-test-wt"
  mkdir -p "$T4_DIR"
  T4_PNG="${T4_DIR}/dv-01-self-test.png"
  _floor_reason() { [[ "$1" -eq 1 ]] && printf 'render_failed' || printf 'tool_missing'; }
  if [[ "$(_floor_reason 1)" == "render_failed" ]] && [[ "$(_floor_reason 0)" == "tool_missing" ]]; then
    _ok "floor reason distinguishes a failed render from an absent tool"
  else
    _fail "floor reason mapping wrong"
  fi
  T4_LINE=$(printf 'path=%s bytes=0 ok=false error=%s\n' "$T4_PNG" "$(_floor_reason 0)")
  if [[ "$T4_LINE" =~ ^path=[^[:space:]]+\ bytes=[0-9]+\ ok=(true|false)\ error=(null|tool_missing|render_failed)$ ]] \
    && [[ ! -e "${T4_DIR}/dv-01-self-test.txt" ]]; then
    _ok "floor emits the adapter contract line and writes no .txt placeholder"
  else
    _fail "floor contract line malformed or a .txt placeholder was written"
  fi

  # --- Test 4b: the tool-state string reports each tool individually
  _t4_state() { [[ "$2" -eq 1 ]] && printf '%s' "$1" || printf '%s(absent)' "$1"; }
  if [[ "$(_t4_state silicon 1), $(_t4_state magick 0)" == "silicon, magick(absent)" ]]; then
    _ok "tools-checked string distinguishes present from absent tools"
  else
    _fail "tools-checked string does not distinguish presence"
  fi

  # --- Test 5: NN is per task
  printf 'x' > "${T4_DIR}/dv-DV0-01-foo.png"
  printf 'x' > "${T4_DIR}/dv-DV0-02-bar.png"
  printf 'x' > "${T4_DIR}/dv-DV1-09-other.png"
  NN=$(_next_nn "$T4_DIR" DV0)
  if [[ "$NN" == "03" ]]; then
    _ok "NN is per task (DV0 01,02 → 03; DV1 ignored)"
  else
    _fail "NN wrong: expected 03, got ${NN}"
  fi

  # --- Test 6: tool_missing upsert keeps one row per slug and the other rows intact
  T6_MF="${T4_DIR}/screenshots-DV0.md"
  _upsert_tool_missing_row "$T6_MF" 01 diff backend "silicon(absent)" wt DV0 0
  printf '| 02 | home | dv-DV0-02-home.png | 9 | web | web/playwright | home | t | — |\n' >> "$T6_MF"
  _upsert_tool_missing_row "$T6_MF" 05 diff backend "silicon(absent), magick(absent)" wt DV0 0
  if [[ "$(grep -c 'tool_missing:' "$T6_MF")" == "1" ]] \
    && grep -q '^| 01 | diff | — | 0 | backend | cli_fallback | tool_missing: silicon(absent), magick(absent) |' "$T6_MF" \
    && grep -q 'dv-DV0-02-home.png' "$T6_MF" \
    && [[ -z "$(find "$T4_DIR" -name '.screenshots-*' 2> /dev/null)" ]]; then
    _ok "tool_missing upsert replaces its row by slug, keeps its NN and leaves no temp file"
  else
    _fail "tool_missing upsert wrong: $(tr '\n' '~' < "$T6_MF")"
  fi

  printf '\nself-test: %d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Required arg validation
# ---------------------------------------------------------------------------
[[ -z "$WORKTASK_ID" ]] && {
  printf >&2 'error: --worktask-id required\n'
  usage
}
[[ -z "$TASK_ID" ]] && {
  printf >&2 'error: --task-id required\n'
  usage
}
[[ -z "$SLUG" ]] && {
  printf >&2 'error: --slug required\n'
  usage
}

if ! _task_id_ok "$TASK_ID"; then
  printf >&2 'error: --task-id must match ^[A-Z]{2}[0-9]+$ (got: %s)\n' "$TASK_ID"
  exit 1
fi
if ! _field_ok "$WORKTASK_ID" || ! _field_ok "$PLATFORM"; then
  printf >&2 'error: --worktask-id and --platform must match ^[A-Za-z0-9][A-Za-z0-9._-]*$\n'
  exit 1
fi
if [[ ! "$RUN_INDEX" =~ ^[0-9]+$ ]]; then
  printf >&2 'error: --run-index must be a non-negative integer (got: %s)\n' "$RUN_INDEX"
  exit 1
fi
# Slug safety: kebab-case, ≤40 chars, no injection
if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
  printf >&2 'error: --slug must be kebab-case ≤40 chars (got: %s)\n' "$SLUG"
  exit 1
fi

# Shared audit-row appender — one key order, one symlink refusal for every audit.jsonl.
# Fails closed: a missing library is a broken install, not a runtime condition.
_AUDIT_LIB="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../shared/lib" 2> /dev/null && pwd -P)/audit-lib.sh"
if [ ! -r "$_AUDIT_LIB" ]; then
  printf >&2 'cli-fallback: plugin install broken — audit-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/audit-lib.sh
. "$_AUDIT_LIB"

_STATE_READ_LIB="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../../shared/lib" 2> /dev/null && pwd -P)/state-read-lib.sh"
if [ ! -r "$_STATE_READ_LIB" ]; then
  printf >&2 'cli-fallback: plugin install broken — state-read-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/state-read-lib.sh
. "$_STATE_READ_LIB"

# A ledger for another worktask refuses the write, so a worktree capture never lands in the
# main checkout; without a ledger only an explicit CONTEXT_DIR may capture.
_CTX_RC=0
CTX_DIR=$(trap - ERR; corpflow_context_dir) || _CTX_RC=$?
if [ "$_CTX_RC" -eq 2 ]; then
  printf >&2 'cli-fallback: root resolver unreachable\n'
  exit 2
elif [ "$_CTX_RC" -ne 0 ]; then
  printf >&2 'cli-fallback: no .context resolved; set WORKSPACE_ROOT or run inside a worktask\n'
  exit 1
fi
if [ -f "$CTX_DIR/state.json" ]; then
  if [ "$(corpflow_worktask_id "$CTX_DIR/state.json" "")" != "$WORKTASK_ID" ]; then
    printf >&2 'cli-fallback: --worktask-id %s does not match %s\n' "$WORKTASK_ID" "$CTX_DIR/state.json"
    exit 1
  fi
  if [ "$(jq -r --arg t "$TASK_ID" '(.tasks|type) == "object" and (.tasks|has($t))' "$CTX_DIR/state.json" 2> /dev/null || true)" != "true" ]; then
    printf >&2 'cli-fallback: task %s is not in %s\n' "$TASK_ID" "$CTX_DIR/state.json"
    exit 1
  fi
elif [ -z "${CONTEXT_DIR:-}" ] || [ "$CTX_DIR" != "$CONTEXT_DIR" ]; then
  printf >&2 'cli-fallback: no ledger at %s; set CONTEXT_DIR to capture outside a worktask\n' "$CTX_DIR"
  exit 1
fi

IMAGES_DIR="${CTX_DIR}/images/${WORKTASK_ID}"
LOGS_DIR="${CTX_DIR}/logs"
AUDIT_LOG="${LOGS_DIR}/audit.jsonl"
mkdir -p "$IMAGES_DIR" "$LOGS_DIR"

if ! NN=$(trap - ERR; _next_nn "$IMAGES_DIR" "$TASK_ID"); then
  printf >&2 'cli-fallback: task %s already has capture 99\n' "$TASK_ID"
  exit 1
fi
OUTPUT_PNG="${IMAGES_DIR}/dv-${TASK_ID}-${NN}-${SLUG}.png"

# audit <action> <result> <metadata-json> — binds this adapter's actor and subject onto
# the shared appender.
audit() {
  corpflow_audit_row --file "$AUDIT_LOG" --actor "cli-fallback-adapter" \
    --action "$1" --subject "${WORKTASK_ID}/${SLUG}" --task-id "${TASK_ID:-unknown}" --result "$2" --meta "${3:-}"
}

# ---------------------------------------------------------------------------
# Build file-scope arg array for git diff
# ---------------------------------------------------------------------------
# FILES_PATH is a path to a newline-delimited file list; if absent, no filter.
declare -a DIFF_FILES=()
if [[ -n "$FILES_PATH" ]] && [[ -f "$FILES_PATH" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    DIFF_FILES+=("$line")
  done < "$FILES_PATH"
fi

# ---------------------------------------------------------------------------
# Redaction check — scan diff for secret patterns before any rendering
# (follows logging-conventions § Bash Pattern; see SKILL.md § Redaction)
# If triggered, fall back to file-tree capture instead of full diff.
# ---------------------------------------------------------------------------
_diff_args=("${BASE_REF}...HEAD")
if [[ "${#DIFF_FILES[@]}" -gt 0 ]]; then
  _diff_args+=("--" "${DIFF_FILES[@]}")
fi

REDACTED=0
if git rev-parse --git-dir > /dev/null 2>&1; then
  # shellcheck disable=SC2086  # intentional — _diff_args is an array
  if git diff "${_diff_args[@]}" 2> /dev/null \
    | grep -qE '(password|secret|token|api_key|private_key)[[:space:]]*[=:][[:space:]]*["'"'"'][^"'"'"']{8,}'; then
    printf >&2 'warn: potential secret detected in diff; falling back to file-tree capture\n'
    REDACTED=1
  fi
fi

# ---------------------------------------------------------------------------
# Tool availability checks (guard-first so --self-test never needs them)
# ---------------------------------------------------------------------------
HAS_SILICON=0
HAS_MAGICK=0
command -v silicon > /dev/null 2>&1 && HAS_SILICON=1
command -v magick > /dev/null 2>&1 && HAS_MAGICK=1
# Older ImageMagick 6.x uses `convert` instead of `magick`
HAS_CONVERT=0
command -v convert > /dev/null 2>&1 && HAS_CONVERT=1

# Set to 1 once an image tool has actually been invoked. The floor needs this to
# tell a render failure (tool present, output unusable) from a genuine absence of
# every tool — the two have different operator remedies.
RENDER_ATTEMPTED=0

# ---------------------------------------------------------------------------
# Step 1 — silicon (preferred): annotated diff PNG
# ---------------------------------------------------------------------------
if [[ "$HAS_SILICON" -eq 1 ]] && git rev-parse --git-dir > /dev/null 2>&1; then
  RENDER_ATTEMPTED=1
  if [[ "$REDACTED" -eq 1 ]]; then
    # Secret detected — render file-tree only
    RENDER_OK=0
    set +e
    git diff --name-only "${BASE_REF}...HEAD" 2> /dev/null \
      | head -200 \
      | silicon --language text --output "$OUTPUT_PNG" \
        --theme Dracula --no-line-number \
        --pad-horiz 20 --pad-vert 20
    RENDER_OK=$?
    set -e
  else
    RENDER_OK=0
    set +e
    git diff "${_diff_args[@]}" 2> /dev/null \
      | head -200 \
      | silicon \
        --language diff \
        --theme Dracula \
        --no-line-number \
        --pad-horiz 20 \
        --pad-vert 20 \
        --output "$OUTPUT_PNG"
    RENDER_OK=$?
    set -e
  fi

  if [[ "$RENDER_OK" -eq 0 ]] && [[ -f "$OUTPUT_PNG" ]]; then
    BYTES=$(stat -f%z "$OUTPUT_PNG" 2> /dev/null || stat -c%s "$OUTPUT_PNG" 2> /dev/null || echo 0)
    audit screenshot_captured ok "$(
      jq -nc \
        --arg slug "$SLUG" \
        --arg path "$OUTPUT_PNG" \
        --argjson bytes "$BYTES" \
        --arg platform "$PLATFORM" \
        --arg adapter "cli_fallback/silicon" \
        '{slug:$slug,path:$path,bytes:$bytes,platform:$platform,adapter:$adapter}' \
        2> /dev/null || printf '{}'
    )" 2> /dev/null || true
    printf 'path=%s bytes=%d ok=true error=null\n' "$OUTPUT_PNG" "$BYTES"
    exit 0
  fi
  printf >&2 'warn: silicon render failed; trying magick\n'
fi

# ---------------------------------------------------------------------------
# Step 2 — magick/convert: text-card PNG from first 60 diff lines
# ---------------------------------------------------------------------------
MAGICK_CMD=""
if [[ "$HAS_MAGICK" -eq 1 ]]; then
  MAGICK_CMD="magick"
elif [[ "$HAS_CONVERT" -eq 1 ]]; then
  MAGICK_CMD="convert"
fi

if [[ -n "$MAGICK_CMD" ]] && git rev-parse --git-dir > /dev/null 2>&1; then
  RENDER_ATTEMPTED=1
  if [[ "$REDACTED" -eq 1 ]]; then
    DIFF_CONTENT="[redacted: secret pattern detected]\n\nFiles changed:\n$(git diff --name-only "${BASE_REF}...HEAD" 2> /dev/null | head -60 || true)"
  else
    DIFF_CONTENT=$(git diff "${_diff_args[@]}" 2> /dev/null | head -60 || true)
  fi

  # Order: readable font FILE, then the registry name Courier, then no -font.
  # A FILE needs no type registry, so it is tried first. A registry hit is weaker:
  # IM6 type-ghostscript.xml lists Courier even when its gsfonts glyph file is not
  # installed. A build without fontconfig (stock Homebrew IM7) has an empty registry,
  # where `-font Courier` fails. With neither, a registry-backed build uses its default.
  # CLI_FALLBACK_FONT_FILES (colon-separated) replaces the built-in candidate list.
  MAGICK_FONT_ARGS=()
  _font_candidates=()
  if [[ -n "${CLI_FALLBACK_FONT_FILES+set}" ]]; then
    IFS=: read -r -a _font_candidates <<< "$CLI_FALLBACK_FONT_FILES"
  else
    _font_candidates=(/System/Library/Fonts/Menlo.ttc /System/Library/Fonts/Courier.ttc
      /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
      /usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf
      /usr/share/fonts/dejavu/DejaVuSansMono.ttf /usr/share/fonts/TTF/DejaVuSansMono.ttf)
  fi
  for _font in ${_font_candidates[@]+"${_font_candidates[@]}"}; do
    if [[ -n "$_font" ]] && [[ -f "$_font" ]] && [[ -r "$_font" ]]; then
      MAGICK_FONT_ARGS=(-font "$_font")
      break
    fi
  done
  if [[ "${#MAGICK_FONT_ARGS[@]}" -eq 0 ]]; then
    _font_list=$("$MAGICK_CMD" -list font 2> /dev/null || true)
    if grep -qE '^[[:space:]]*Font: Courier$' <<< "$_font_list"; then
      MAGICK_FONT_ARGS=(-font Courier)
    fi
  fi

  RENDER_OK=0
  set +e
  # ${a[@]+...}: an empty array under `set -u` is an unbound-variable error on Bash 3.2.
  "$MAGICK_CMD" \
    -background white \
    -fill black \
    ${MAGICK_FONT_ARGS[@]+"${MAGICK_FONT_ARGS[@]}"} \
    -pointsize 13 \
    -size 1200x800 \
    "caption:${SLUG}\n\n${DIFF_CONTENT}" \
    "$OUTPUT_PNG"
  RENDER_OK=$?
  set -e

  if [[ "$RENDER_OK" -eq 0 ]] && [[ -f "$OUTPUT_PNG" ]]; then
    BYTES=$(stat -f%z "$OUTPUT_PNG" 2> /dev/null || stat -c%s "$OUTPUT_PNG" 2> /dev/null || echo 0)
    audit screenshot_captured ok "$(
      jq -nc \
        --arg slug "$SLUG" \
        --arg path "$OUTPUT_PNG" \
        --argjson bytes "$BYTES" \
        --arg platform "$PLATFORM" \
        --arg adapter "cli_fallback/magick" \
        '{slug:$slug,path:$path,bytes:$bytes,platform:$platform,adapter:$adapter}' \
        2> /dev/null || printf '{}'
    )" 2> /dev/null || true
    printf 'path=%s bytes=%d ok=true error=null\n' "$OUTPUT_PNG" "$BYTES"
    exit 0
  fi
  printf >&2 'warn: magick render failed\n'
fi

# ---------------------------------------------------------------------------
# Step 3 — floor: fail loudly. No placeholder file is written; a .txt satisfies an
# existence check while proving nothing, and downstream evidence attachment would
# classify it as a captured artifact.
# ---------------------------------------------------------------------------
_tool_state() { # name present-flag -> "name" | "name(absent)"
  [[ "$2" -eq 1 ]] && printf '%s' "$1" || printf '%s(absent)' "$1"
}
TOOLS_CHECKED="$(_tool_state silicon "$HAS_SILICON"), $(_tool_state magick "$HAS_MAGICK"), $(_tool_state convert "$HAS_CONVERT")"

if [[ "$RENDER_ATTEMPTED" -eq 1 ]]; then
  FAIL_REASON="render_failed"
  FAIL_DETAIL="an image tool was present but produced no usable PNG"
  FAIL_EXIT=3
else
  FAIL_REASON="tool_missing"
  FAIL_DETAIL="no image tool available on PATH (or not a git repository)"
  FAIL_EXIT=2
fi

audit screenshot_capture_failed fail "$(
  jq -nc \
    --arg tools_checked "$TOOLS_CHECKED" \
    --arg slug "$SLUG" \
    --arg path "$OUTPUT_PNG" \
    --arg platform "$PLATFORM" \
    --arg reason "$FAIL_REASON" \
    '{tools_checked:$tools_checked,slug:$slug,path:$path,platform:$platform,reason:$reason}' \
    2> /dev/null || printf '{}'
)" 2> /dev/null || true

# Only a genuine absence of every tool is a tool_missing row; "tools present but not a git
# repository" also exits 2 and must not be recorded as an accepted skip candidate.
if [[ "$FAIL_EXIT" -eq 2 ]] && [[ $((HAS_SILICON + HAS_MAGICK + HAS_CONVERT)) -eq 0 ]]; then
  trap '[[ -z "${_TM_TMP:-}" ]] || rm -f "$_TM_TMP"' EXIT
  if ! _upsert_tool_missing_row "${IMAGES_DIR}/screenshots-${TASK_ID}.md" "$NN" "$SLUG" "$PLATFORM" \
    "$TOOLS_CHECKED" "$WORKTASK_ID" "$TASK_ID" "$RUN_INDEX"; then
    printf >&2 'warn: could not record the tool_missing row in %s\n' "${IMAGES_DIR}/screenshots-${TASK_ID}.md"
  fi
fi

printf >&2 'error: capture failed (%s): %s; tools checked: %s\n' \
  "$FAIL_REASON" "$FAIL_DETAIL" "$TOOLS_CHECKED"
printf 'path=%s bytes=0 ok=false error=%s\n' "$OUTPUT_PNG" "$FAIL_REASON"
exit "$FAIL_EXIT"
