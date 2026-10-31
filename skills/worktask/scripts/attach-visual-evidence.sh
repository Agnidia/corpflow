#!/usr/bin/env bash
# attach-visual-evidence.sh — embed DV screenshot captures into the PR body and
# the GitHub issue, on a UI-change run (metadata.requires_screenshots=true).
#
# Publishing modes, plus a read-only
# --validate-manifest <path> documented with the others below. The publishing modes'
# exit-0 contract is load-bearing — their stdout is spliced into the PR body — so the
# schema check is a SEPARATE mode with its own exit codes and never alters theirs:
#   --emit pr [--force]
#                 Print a ready-to-insert "## Visual evidence" markdown block to
#                 stdout. The PR-body composer (FN agent / FN PR flow /
#                 conductor-attachments skeleton, and adhoc-visual-evidence.sh for
#                 a PR opened outside a worktask) inserts it between ## Test plan
#                 and ## Merge danger. Empty stdout ⇒ insert nothing (flag false / no
#                 captures). Callers invoke UNCONDITIONALLY; gating lives here.
#                 Idempotent: a second run replays the first run's hosted URLs from
#                 the emission cache instead of re-uploading. --force re-hosts.
#   --post issue  Post ONE marker-deduped `gh issue comment` carrying the same
#                 block. Run by the orchestrator at stage-loop exit (post-FN /
#                 post-push). Non-blocking: operational failures → audit row +
#                 exit 0 (mirrors publish-pl-issue.sh's contract class).
#   --post completion [<pr-ref>]
#                 (AC2) Post-merge completion: resolve every issue the PR closes
#                 via PR-body keywords (Closes|Fixes|Resolves #N, case-insensitive)
#                 ∪ gh closingIssuesReferences, deduped to integers (no untrusted
#                 text in argv). Post ONE completion comment per issue carrying:
#                 1. Work-summary: sourced from .context/complete-summary-<run_index>.md
#                    → state.json facts.goal → PR title+body (sanitised via
#                    sanitise_body; never local paths). 2. Visual-evidence block
#                    (when requires_screenshots=true and captures exist; summary-only
#                    otherwise). Per-issue HTML-marker idempotency
#                    (<!-- completion-summary:<worktask_id>:<run_index>:<issue_n> -->):
#                    a retry never double-posts; partial prior failure re-posts only
#                    missing issues. Each gh failure audits and continues (overall
#                    exit 0 always). Run by orchestrator post-loop after FN merge
#                    ("when the PR closes"). <pr-ref> optional; sources in order:
#                    argument; current branch's PR, else ledger metadata.pr_url
#                    (FN writes it; covers a checkout that is off the PR head
#                    branch after a non-default-base merge). A valid argument
#                    is final; with none, the current-branch PR wins if it
#                    yields at least one issue, else the ledger PR. The argument and the ledger
#                    value must be a PR number or a github.com PR URL naming this
#                    repository; any other value counts as absent. Defers under milestone mode (parent
#                    milestone issue is canonical); audits no_related_issues when no
#                    source yields an issue.
#   --validate-manifest <path>
#                 Read-only schema assertion over the canonical 9-column capture
#                 table. Writes nothing, posts nothing, loads no state. exit 0 valid,
#                 1 schema violation (diagnostic on stdout), 2 manifest not found,
#                 3 no capture rows at all (caller decides whether that is legitimate).
#   --validate-manifest <path> --task-id <ID> [--images-dir <dir>]
#                 Per-task grammar: dv-<ID>-NN-<slug> basenames whose NN equals `#`, image
#                 magic bytes matching the extension, well-formed tool_missing rows, and the
#                 legacy `## <ID>` section when <path> is not screenshots-<ID>.md. Exits as
#                 above plus 4 = only tool_missing rows (prints `tool_missing_only tools=<a,b>`).
#                 Called by hooks/dv-screenshot-gate.sh so the grammar has one owner.
#
# Image hosting (REQ-5, ad7): reuse publish-pl-issue.sh's host-tier degradation
# by sourcing it under PUBLISH_LIB_ONLY=1 — select_host_tier / host_one_asset /
# gist_raw_url_reachable, with every ASSET_* env mock inherited for free. Relative
# .context/ refs are REJECTED (never render in PR/issue bodies; camo can't fetch
# private/internal raw). none-tier emits note line, never broken ![](). Both
# --post modes share the gist privacy posture: ASSET_GIST_PUBLIC is tri-state —
# 1 forces a world-readable gist, 0 forces secret/unlisted, and empty (the
# default) auto-derives from repo visibility, declining --public on a
# PRIVATE/INTERNAL repo where it adds indexing without improving rendering.
# Neither kind preserves screenshot confidentiality (camo fetches anonymously);
# do not capture secrets/tokens/PII, and use
# ASSET_HOST_MODE=none for material that must not leave the org. See
# the `Privacy:` paragraph in publish-pl-issue.sh's header for full rationale.
#
# Idempotency (all three publishing modes):
#   --emit pr:    cached at .context/logs/visual-evidence-pr-<worktask_id>-<run_index>.md,
#                 written on a successful emission and replayed verbatim on any later
#                 run. The --post modes dedupe on a marker they can read back off the
#                 issue; --emit has no such remote to consult, so the cache IS the
#                 marker. Without it a second run re-hosts every asset and orphans the
#                 first set on GitHub. --force bypasses (re-hosts and rewrites cache).
#   --post issue: marked with <!-- visual-evidence:<worktask_id>:<run_index> -->
#   --post completion: marked with <!-- completion-summary:<worktask_id>:<run_index>:<issue_n> -->
# Exact-match grep (no regex breakout); retry never double-posts.
#
# Exit codes: 0 all operational paths (incl. deferred/skipped), 1 catastrophic
# (jq missing / state corrupt — mirrors publish helper), 2 --self-test failure.
#
# Env (injection / test hooks): STATE_FILE, WORKSPACE_ROOT, GH_BIN, DRY_RUN, plus
# every ASSET_* / *_URL_BASE hook honoured by publish-pl-issue.sh (inherited via
# the source-guard). MANIFEST_FILE overrides manifest discovery in self-tests.
# MILESTONE_MODE=1 env override for offline testing.

set -u

# ---------- defaults / env --------------------------------------------------
STATE_FILE="${STATE_FILE:-.context/state.json}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}"
GH_BIN="${GH_BIN:-gh}"
DRY_RUN="${DRY_RUN:-0}"
LOG_DIR="${WORKSPACE_ROOT}/.context/logs"
AUDIT_FILE="$LOG_DIR/audit.jsonl"
MAX_EMBED="${MAX_EMBED:-5}"   # PR/issue embed cap (mirrors capture skill's 5-per-run cap)

# Source publish-pl-issue.sh for tier logic (library mode — returns before main).
_LIB="$(dirname "$0")/publish-pl-issue.sh"

# ---------- audit -----------------------------------------------------------
# Shared ledger reads; the fallback default is an explicit argument, never unified —
# some call sites probe for absence rather than read a value. `[ -r ]` guard as above.
_STATE_READ_LIB="$(dirname "$0")/../../shared/lib/state-read-lib.sh"
if [ ! -r "$_STATE_READ_LIB" ]; then
  printf >&2 'attach-visual-evidence: plugin install broken — state-read-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/state-read-lib.sh disable=SC1091  # sourced from a runtime path; lint runs without -x
. "$_STATE_READ_LIB"

# Shared audit-row appender. `[ -r ]` before the `.`: a bare `.` on a missing file is a
# special-builtin error that exits the shell, bypassing an `if !` guard.
_AUDIT_LIB="$(dirname "$0")/../../shared/lib/audit-lib.sh"
if [ ! -r "$_AUDIT_LIB" ]; then
  printf >&2 'attach-visual-evidence: plugin install broken — audit-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/audit-lib.sh disable=SC1091  # sourced from a runtime path; lint runs without -x
. "$_AUDIT_LIB"

audit_av() {
  # $1=action, $2=result, $3=metadata-json (compact). Never fatal on its own.
  # jq-absent stays a silent no-row rather than the library's degraded row: this
  # emitter has never written one on a jq-less host and nothing downstream expects it.
  command -v jq >/dev/null 2>&1 || return 0
  corpflow_audit_row --file "$AUDIT_FILE" --actor orchestrator \
    --action "$1" --subject "FN${RUN_INDEX:-0}" --result "$2" --task-id unknown --meta "$3"
}

# ---------- state accessors -------------------------------------------------
state_get() { jq -r "$1 // \"\"" "$STATE_FILE" 2>/dev/null || printf ''; }

# Ledger-level requires_screenshots with the same has()-presence semantics as the
# ledger step of the gate's FLAG_JQ: a literal false must survive.
state_requires_screenshots() {
  jq -r 'if (.metadata|type=="object") and (.metadata|has("requires_screenshots"))
         then (.metadata.requires_screenshots|tostring) else "true" end' \
    "$STATE_FILE" 2>/dev/null || echo true
}

# ---------- manifest discovery + parse --------------------------------------
# Manifest path: MANIFEST_FILE override, else
# <root>/.context/images/<worktask_id>/screenshots.md.
manifest_path() {
  if [ -n "${MANIFEST_FILE:-}" ]; then printf '%s' "$MANIFEST_FILE"; return 0; fi
  printf '%s/.context/images/%s/screenshots.md' "$WORKSPACE_ROOT" "$WORKTASK_ID"
}

# Echo manifest capture rows as TSV: NN<TAB>path<TAB>caption<TAB>kind
#   kind ∈ {png, placeholder, oversize}
# A "skip-rationale" manifest (no table rows) yields zero lines.
parse_manifest() {
  local mf="$1"
  [ -f "$mf" ] || return 0
  # Table rows look like: | 01 | slug | dv-DV0-01-slug.png | 187234 | apple | adapter | caption | ts | ref |
  # Header + separator rows are filtered (col1 not two-digit; separator has ---).
  LC_ALL=C awk -F'|' '
    /^[[:space:]]*\|/ {
      # Trim each field.
      for (i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
      num=$2; path=$4; cap=$8
      if (num !~ /^[0-9][0-9]$/) next            # skip header / non-data
      if (path ~ /^-+$/ || path=="") next        # skip separator
      kind="png"
      if (path ~ /\.txt$/) kind="placeholder"
      if ($7 == "cli_fallback" && index(cap, "tool_missing:") == 1) kind="tool_missing"
      printf "%s\t%s\t%s\t%s\n", num, path, cap, kind
    }
  ' "$mf"
  # Out-of-budget (oversize, link-only) rows live under a "§ Out-of-budget" head
  # as bullets "- <path>: <bytes> ..."; surface them as oversize kind.
  LC_ALL=C awk '
    /^##?[[:space:]]+Out-of-budget/ { inblk=1; next }
    /^##?[[:space:]]/ && inblk { inblk=0 }
    inblk && /^[[:space:]]*-[[:space:]]+/ {
      line=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",line)
      p=line; sub(/:.*/,"",p); gsub(/^[[:space:]]+|[[:space:]]+$/,"",p)
      if (p=="" || p ~ /^\(none\)/) next
      printf "99\t%s\t%s\toversize\n", p, "oversize (link-only)"
    }
  ' "$mf"
}

# ---------- mode: --validate-manifest (read-only) ---------------------------
# Schema assertion for hooks/dv-screenshot-gate.sh, living HERE so the 9-column
# grammar has exactly one implementation. A second copy in the gate would recreate
# the duplicated-map drift the artifact-map parity guard exists to police.
#
# Canonical row: | # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |
# with a mandatory two-digit index. A manifest carrying NO capture rows is reported as
# exit 3 rather than judged here: whether that is a skip rationale or dropped evidence
# depends on what sits beside the file, which the caller sees and this parser does not.
#
#   exit 0  structurally valid, at least one canonical capture row
#   exit 1  schema violation (diagnostic on stdout)
#   exit 2  manifest missing or unreadable
#   exit 3  well-formed but carries no capture rows — legitimate only when no captures
#           exist beside it, which the caller (not this parser) is the one that knows
validate_manifest() {
  local mf="$1" bad rows
  if [ -z "$mf" ] || [ ! -f "$mf" ]; then
    printf 'manifest not found: %s\n' "${mf:-<unset>}"
    return 2
  fi

  # Candidate rows are pipe-tables minus the header and the --- separator. Each
  # violation is reported with its line number so the writer can fix the row, not
  # re-author the file.
  bad=$(LC_ALL=C awk -F'|' '
    /^[[:space:]]*\|/ {
      for (i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
      if ($2 == "#" || tolower($2) == "no." ) next          # header
      if ($2 ~ /^:?-+:?$/ || $3 ~ /^:?-+:?$/) next          # separator, incl. alignment rows
      if ($2 == "" && $3 == "") next                        # blank filler
      if (NF - 2 != 9) {
        printf "line %d: %d columns, expected 9\n", NR, NF - 2
        next
      }
      if ($2 !~ /^[0-9][0-9]$/) {
        printf "line %d: index \"%s\" is not a two-digit ordinal\n", NR, $2
        next
      }
      if ($4 == "") { printf "line %d: empty Path column\n", NR }
    }
  ' "$mf")

  if [ -n "$bad" ]; then
    printf 'manifest schema violation(s) in %s:\n%s\n' "$mf" "$bad"
    return 1
  fi

  rows=$(parse_manifest "$mf" | grep -c . || true)
  if [ "$rows" -eq 0 ]; then
    if grep -qE '^[[:space:]]*\|[[:space:]]*[0-9]' "$mf"; then
      printf 'manifest schema violation in %s: table rows present but none matches the canonical schema\n' "$mf"
      return 1
    fi
    # No capture rows at all. Whether that is a legitimate skip-rationale manifest or a
    # silently dropped capture depends on what sits NEXT to the file, which is the caller's
    # knowledge, not the parser's — so report the fact and let the gate apply the policy.
    printf 'manifest %s carries no canonical capture rows\n' "$mf"
    return 3
  fi

  return 0
}

_TASK_ID_RE='^[A-Z]{2}[0-9]+$'

# The rows one task owns: its whole per-task file, or only the legacy `## <ID>` section.
# The id is compared as a string, never spliced into a regex. rc 3 = no such section.
manifest_task_body() {
  local mf="$1" id="$2"
  if [ "$(basename -- "$mf")" = "screenshots-$id.md" ]; then
    cat -- "$mf"
    return 0
  fi
  LC_ALL=C awk -v id="$id" '
    { line = $0; sub(/\r$/, "", line); head = line; sub(/[[:space:]]+$/, "", head) }
    insec && line ~ /^##?[[:space:]]/ { exit }
    insec { print line; next }
    head == "## " id { insec = 1; found = 1 }
    END { exit(found ? 0 : 3) }
  ' "$mf"
}

# Content type from the first 12 bytes: png, jpeg, webp, or nothing.
image_kind() {
  local sig
  sig=$(LC_ALL=C od -An -tx1 -N12 -- "$1" 2>/dev/null | tr -d ' \n') || sig=""
  case "$sig" in
    89504e470d0a1a0a*) printf 'png' ;;
    ffd8ff*) printf 'jpeg' ;;
    52494646????????57454250*) printf 'webp' ;;
  esac
}

# "silicon(absent), magick(absent)" -> "silicon,magick"; rc 1 unless every tool says (absent).
tool_missing_names() {
  local rest="$1" item names="" re='^([A-Za-z0-9._+-]+)\(absent\)$'
  while :; do
    item="${rest%%,*}"
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ $item =~ $re ]] || return 1
    names="${names:+$names,}${BASH_REMATCH[1]}"
    case "$rest" in
      *,*) rest="${rest#*,}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$names"
}

validate_task_manifest() {
  local mf="$1" id="$2" img="$3" body rows bad="" n_img=0 n_tools=0 tools="" names
  local tag f1 f2 f3 f4 slug want kind file us slug_re='^[a-z0-9][a-z0-9-]*$'
  us=$(printf '\037')
  if ! [[ $id =~ $_TASK_ID_RE ]]; then
    printf 'invalid --task-id: %s\n' "$id"
    return 1
  fi
  if [ -z "$mf" ] || [ ! -f "$mf" ]; then
    printf 'manifest not found: %s\n' "${mf:-<unset>}"
    return 2
  fi
  [ -n "$img" ] || img=$(dirname -- "$mf")
  if ! body=$(manifest_task_body "$mf" "$id"); then
    printf 'manifest not found: %s has no ## %s section\n' "$mf" "$id"
    return 2
  fi

  rows=$(printf '%s\n' "$body" | LC_ALL=C awk -F'|' -v us="$us" '
    /^[[:space:]]*\|/ {
      for (i=1;i<=NF;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i) }
      if ($2 == "#" || tolower($2) == "no.") next
      if ($2 ~ /^:?-+:?$/ || $3 ~ /^:?-+:?$/) next
      if ($2 == "" && $3 == "") next
      if (NF - 2 != 9) { printf "ERR%sline %d: %d columns, expected 9\n", us, NR, NF - 2; next }
      if ($2 !~ /^[0-9][0-9]$/) { printf "ERR%sline %d: index \"%s\" is not a two-digit ordinal\n", us, NR, $2; next }
      if ($7 == "cli_fallback" && index($8, "tool_missing:") == 1) {
        printf "TM%s%d%s%s%s%s%s%s\n", us, NR, us, $4, us, $5, us, substr($8, 14); next
      }
      printf "IMG%s%d%s%s%s%s\n", us, NR, us, $2, us, $4
    }')

  while IFS="$us" read -r tag f1 f2 f3 f4; do
    case "$tag" in
      ERR) bad="${bad}${f1}"$'\n' ;;
      TM)
        if [ "$f2" != "—" ] || [ "$f3" != "0" ] || ! names=$(tool_missing_names "$f4"); then
          bad="${bad}line $f1: malformed tool_missing row (Path —, Bytes 0, caption tool_missing: <tool>(absent), ...)"$'\n'
          continue
        fi
        n_tools=$((n_tools + 1))
        tools="${tools:+$tools,}$names"
        ;;
      IMG)
        case "$f3" in
          */* | .* | "")
            bad="${bad}line $f1: name:$f3 is not a basename"$'\n'
            continue
            ;;
          dv-"$id"-[0-9][0-9]-*.png | dv-"$id"-[0-9][0-9]-*.jpg | dv-"$id"-[0-9][0-9]-*.jpeg | dv-"$id"-[0-9][0-9]-*.webp) ;;
          *)
            bad="${bad}line $f1: name:$f3 is not dv-$id-NN-<slug>.<png|jpg|jpeg|webp>"$'\n'
            continue
            ;;
        esac
        want="${f3#dv-"$id"-}"
        slug="${want#??-}"
        slug="${slug%.*}"
        want="${want%%-*}"
        if ! [[ $slug =~ $slug_re ]] || [ "$want" != "$f2" ]; then
          bad="${bad}line $f1: name:$f3 needs a kebab slug and NN equal to # ($f2)"$'\n'
          continue
        fi
        file="$img/$f3"
        if [ -L "$file" ]; then
          bad="${bad}line $f1: symlink:$f3"$'\n'
        elif [ ! -f "$file" ]; then
          bad="${bad}line $f1: missing:$f3"$'\n'
        elif [ ! -s "$file" ]; then
          bad="${bad}line $f1: empty:$f3"$'\n'
        else
          kind=$(image_kind "$file")
          case "$kind:${f3##*.}" in
            png:png | jpeg:jpg | jpeg:jpeg | webp:webp) n_img=$((n_img + 1)) ;;
            *) bad="${bad}line $f1: mime:$f3"$'\n' ;;
          esac
        fi
        ;;
    esac
  done <<EOF
$rows
EOF

  if [ -n "$bad" ]; then
    printf 'manifest violation(s) in %s for %s:\n%s' "$mf" "$id" "$bad"
    return 1
  fi
  [ "$n_img" -gt 0 ] && return 0
  if [ "$n_tools" -gt 0 ]; then
    printf 'tool_missing_only tools=%s\n' "$tools"
    return 4
  fi
  printf 'manifest %s carries no canonical capture rows for %s\n' "$mf" "$id"
  return 3
}

# screenshots-<ID>.md paths in one images dir, ordered by stage code then task number.
task_manifests() {
  local f b id tab
  tab=$(printf '\t')
  for f in "$1"/screenshots-*.md; do
    [ -f "$f" ] || continue
    b="${f##*/}"; id="${b#screenshots-}"; id="${id%.md}"
    [[ $id =~ $_TASK_ID_RE ]] || continue
    printf '%s\t%s\t%s\n' "${id:0:2}" "${id:2}" "$f"
  done | LC_ALL=C sort -t "$tab" -k1,1 -k2,2n | cut -f3-
}

# MANIFEST_FILE pins one file; otherwise every per-task manifest, then the legacy file.
parse_manifests() {
  local mf="$1" f
  if [ -n "${MANIFEST_FILE:-}" ]; then
    parse_manifest "$mf"
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && parse_manifest "$f"
  done <<EOF
$(task_manifests "$(dirname -- "$mf")")
EOF
  parse_manifest "$mf"
}

# ---------- block builder ---------------------------------------------------
# Build the "## Visual evidence" block from a parsed manifest.
#   stdout: the block (may be empty)
#   Heading arrives as $2.
# Hosting decisions go through the sourced select_host_tier/host_one_asset.
# Returns the chosen host tier via the HOST_TIER global (set by select_host_tier).
build_block() {
  local mf="$1" heading="$2"
  local rows; rows=$(parse_manifests "$mf")
  # No capture rows at all → empty emission (skip-rationale manifest / no captures).
  if [ -z "$rows" ]; then
    return 1   # signal "no captures" to caller
  fi

  select_host_tier   # sets HOST_TIER (+ owner/ref for raw)
  # Propagate HOST_TIER past the command-substitution subshell boundary: callers
  # pass a tempfile path via HOST_TIER_FILE and read it back after $() returns.
  [ -n "${HOST_TIER_FILE:-}" ] && printf '%s' "$HOST_TIER" > "$HOST_TIER_FILE"

  local img_dir; img_dir=$(dirname "$mf")
  local out="" embed_count=0 num path cap kind src url bullets=""
  # Counts EMBEDDABLE rows only (kind=png). placeholder/oversize rows are never
  # embedded by design, so counting them would fire the degradation notice on
  # every healthy run and train the operator to ignore it.
  local hostable=0
  # Per-bullet text stays short; the WHY is emitted once below (host_fail_note) so
  # a 5-capture run does not repeat a paragraph five times.
  local HOST_FAIL_HINT="not embeddable; see note below." host_fail=0
  # The embed cap and a hosting failure are different degradations with different
  # remedies, and only the second is fixed by a token. Tracked separately so the reason,
  # the body note and the operator advice can each name the one that actually fired.
  local cap_hit=0
  local host_fail_note
  case "$(repo_visibility 2>/dev/null || printf '')" in
    PRIVATE|INTERNAL)
      host_fail_note="Could not host these inline. On a private/internal repo the raw tier is refused (camo fetches anonymously and would 404) and gists reject binary files, so the working path is GitHub's user-attachments store — install the uploader with \`gh extension install drogers0/gh-image\` and re-run, or drag the files into this body via the web UI. The captures are on disk at the manifest path." ;;
    *)
      host_fail_note="Hosting failed for the captures above; they remain on disk at the manifest path." ;;
  esac

  while IFS="$(printf '\t')" read -r num path cap kind; do
    [ -z "$path" ] && continue
    case "$kind" in
      png)
        hostable=$((hostable+1))
        if [ "$embed_count" -ge "$MAX_EMBED" ]; then
          bullets="${bullets}- ${path} — omitted (embed cap ${MAX_EMBED}); see manifest."$'\n'
          cap_hit=1
          continue
        fi
        # none-tier: never embed an image; list as bullet instead (no broken ![]()).
        if [ "$HOST_TIER" = "none" ]; then
          bullets="${bullets}- ${path} — inline hosting unavailable; see manifest."$'\n'
          continue
        fi
        src="$img_dir/$(basename "$path")"
        if [ ! -f "$src" ]; then
          # Source PNG missing on disk → cannot host; list as bullet, never embed.
          bullets="${bullets}- ${path} — file not found on disk; see manifest."$'\n'
          continue
        fi
        url=$(WORKTASK_ID="$WORKTASK_ID" host_one_asset "$(basename "$path")" "$src" 2>/dev/null || true)
        if [ -z "$url" ]; then
          # Hosting miss for this asset → degrade to bullet (never a broken embed).
          bullets="${bullets}- ${path} — ${HOST_FAIL_HINT}"$'\n'
          host_fail=1
          continue
        fi
        out="${out}![dv-${num} ${cap}](${url})"$'\n'
        embed_count=$((embed_count+1))
        ;;
      placeholder)
        bullets="${bullets}- ${path} — placeholder (tool_missing); see manifest."$'\n'
        ;;
      tool_missing)
        bullets="${bullets}- ${cap} — nothing captured; see manifest."$'\n'
        ;;
      oversize)
        bullets="${bullets}- ${path} — ${cap}; see manifest."$'\n'
        ;;
    esac
  done <<EOF
$rows
EOF

  # Assemble. Always emit heading + manifest ref so the section is never broken.
  printf '%s\n\n' "$heading"
  [ -n "$out" ] && printf '%s' "$out"
  [ -n "$bullets" ] && printf '%s' "$bullets"
  if [ "$HOST_TIER" = "none" ] || { [ -z "$out" ] && [ -z "$bullets" ]; }; then
    # none-tier (or nothing hostable): single note line, zero broken image refs.
    printf 'Screenshots persisted on disk; inline hosting unavailable — see manifest.\n'
  elif [ "$host_fail" = "1" ]; then
    # Explain the degradation once, in terms an operator can act on.
    printf '\n%s\n' "$host_fail_note"
  fi
  # State the cap in the body itself. The per-row bullets already said "omitted", but the
  # summary read as a healthy run: a reader had no way to tell a capped run from one that
  # captured only what is shown.
  if [ "$cap_hit" = "1" ]; then
    # "hosting is healthy" only when no row failed to host; both can fire in one run.
    printf '\nOnly the first %d capture(s) are embedded inline (embed cap %d). The rest are listed above and on disk at the manifest path%s\n' \
      "$MAX_EMBED" "$MAX_EMBED" "$([ "$host_fail" = "1" ] && printf '.' || printf '; hosting is healthy.')"
  fi
  # Manifest reference, deliberately path-free: relative links never resolve in PR/issue
  # bodies, the working-folder path is local and gitignored, and publish-pl-issue.sh's
  # sanitiser would strip a path anyway, leaving "see manifest" naming nothing.
  printf '\nManifest: %s\n' "screenshots.md, in this run's local images folder (not committed)."

  # D4 -- notify when captures exist but did not reach the reader. Emitted from
  # inside build_block on purpose: callers wrap this in $(), which captures stdout
  # only, so stderr and the audit append both still escape. Uses "<" not "== 0" so
  # partial loss (e.g. the MAX_EMBED cap silently dropping the 6th capture) is
  # caught too, not just total failure.
  if [ "$hostable" -gt 0 ] && [ "$embed_count" -lt "$hostable" ]; then
    # The reason used to come from the hosting probe ALONE, so a capped-but-healthy run
    # reported a hosting reason (often `unknown`) on a row nothing was wrong with.
    local reason seen
    if [ "$cap_hit" = "1" ] && [ "$host_fail" = "1" ]; then
      reason="embed_cap+${GH_IMAGE_FAIL_REASON:-unknown}"
    elif [ "$cap_hit" = "1" ]; then
      reason="embed_cap"
    else
      reason="${GH_IMAGE_FAIL_REASON:-unknown}"
    fi
    if [ "$embed_count" -eq 0 ]; then
      seen="no images"
    else
      seen="only $embed_count of $hostable images"
    fi
    printf >&2 'attach-visual-evidence: NOTICE — %d capture(s) on disk, %d embedded (reason=%s).\n' \
      "$hostable" "$embed_count" "$reason"
    # A token fixes hosting; it does not raise the cap. Telling a capped run to supply one
    # sends the operator after a credential that changes nothing.
    if [ "$cap_hit" = "1" ] && [ "$host_fail" != "1" ]; then
      printf >&2 '  Reviewers will see %s. This is the embed cap (%d), not a hosting failure — the remaining captures are on disk and listed in the body; a session token would not change it.\n' \
        "$seen" "$MAX_EMBED"
    else
      printf >&2 '  Reviewers will see %s. Set GH_SESSION_TOKEN to make tier-0 non-interactive.\n' "$seen"
    fi
    audit_av visual_evidence_degraded degraded \
      "$(jq -cn --argjson c "$hostable" --argjson e "$embed_count" \
              --arg r "$reason" --arg t "${HOST_TIER:-unknown}" \
          '{captured:$c, embedded:$e, reason:$r, host_tier:$t}' 2>/dev/null || printf '{}')"
  fi
  return 0
}

# Classify a zero-row outcome. "no_captures" means DV genuinely produced nothing;
# "manifest_unparseable" means a manifest exists AND image files sit beside it, but
# no table row parsed — i.e. the manifest does not follow the canonical schema
#   | NN | slug | path | bytes | platform | adapter | caption | captured | ref |
# (col2 MUST be two digits: `01`, not `1`). That case is a silent-evidence-loss
# trap: the screenshots gate passes on file presence while the attach step no-ops,
# so the PR ships with the evidence missing and nothing says so. Warn loudly and
# audit distinguishably instead of reporting it as "no captures".
manifest_diagnosis() {
  local mf="$1"
  [ -f "$mf" ] || [ -n "$(task_manifests "$(dirname -- "$mf")")" ] || { printf 'no_captures'; return 0; }
  local dir imgs
  dir=$(dirname "$mf")
  imgs=$(find "$dir" -maxdepth 1 -type f \
           \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null | wc -l | tr -d ' ')
  if [ "${imgs:-0}" -gt 0 ]; then
    printf 'manifest_unparseable'
    echo "attach-visual-evidence: WARNING — $mf has $imgs image file(s) beside it but zero parseable table rows." >&2
    echo "attach-visual-evidence: the manifest must use the canonical 9-column schema with a TWO-DIGIT index:" >&2
    echo "attach-visual-evidence:   | # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |" >&2
    echo "attach-visual-evidence:   | 01 | header | dv-DV0-01-header.png | 78683 | apple | apple_sim | after | <ts> | — |" >&2
    echo "attach-visual-evidence: evidence was NOT attached. See skills/dv-screenshot-capture/references/examples/README.md" >&2
    return 0
  fi
  printf 'no_captures'
}

# ---------- mode: --emit pr -------------------------------------------------
# Path of the emission cache for this worktask run.
emit_pr_cache_path() {
  printf '%s/visual-evidence-pr-%s-%s.md' "$LOG_DIR" "$WORKTASK_ID" "$RUN_INDEX"
}

# True when this run already emitted successfully: an `ok` audit row carrying this
# run's dedupe key AND a cache file to replay. Both halves are required — a pruned
# cache must re-host rather than emit nothing, which would drop evidence silently.
emit_pr_already_emitted() {
  local dk="$1" cache="$2"
  [ -s "$cache" ] || return 1
  [ -f "$AUDIT_FILE" ] || return 1
  grep -F "\"dedupe_key\":\"$dk\"" "$AUDIT_FILE" 2>/dev/null \
    | grep -F '"action":"visual_evidence_pr_emitted"' | grep -qF '"result":"ok"'
}

emit_pr() {
  local req; req=$(state_requires_screenshots)
  local dk="$WORKTASK_ID:$RUN_INDEX:visual_evidence:pr"
  local cache; cache=$(emit_pr_cache_path)

  if [ "${FORCE:-0}" != "1" ] && emit_pr_already_emitted "$dk" "$cache"; then
    cat "$cache"
    audit_av "visual_evidence_pr_emitted" "reused" \
      "$(jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" --arg dk "$dk" --arg c "$cache" \
         '{worktask_id:$w, run_index:$r, host_tier:"cache", reason:"already_emitted", cache:$c, dedupe_key:$dk}')"
    return 0
  fi

  if [ "$req" = "false" ]; then
    audit_av "visual_evidence_pr_emitted" "skipped" \
      "$(jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" --arg dk "$dk" \
         '{worktask_id:$w, run_index:$r, captures:0, host_tier:"none", reason:"requires_screenshots_false", dedupe_key:$dk}')"
    return 0   # empty stdout
  fi
  local mf; mf=$(manifest_path)
  local block _tier_tmp _tier; _tier="none"
  _tier_tmp=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ave-tier-pr.$$")
  if block=$(HOST_TIER_FILE="$_tier_tmp" \
             build_block "$mf" "## Visual evidence"); then
    _tier=$(cat "$_tier_tmp" 2>/dev/null || printf 'none'); rm -f "$_tier_tmp"
    printf '%s' "$block"
    mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s' "$block" > "$cache" 2>/dev/null || true
    local caps; caps=$(printf '%s' "$block" | grep -c '^!\[' || true)
    audit_av "visual_evidence_pr_emitted" "ok" \
      "$(jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" --argjson c "${caps:-0}" \
         --arg t "$_tier" --arg dk "$dk" \
         '{worktask_id:$w, run_index:$r, captures:$c, host_tier:$t, reason:"emitted", dedupe_key:$dk}')"
  else
    rm -f "$_tier_tmp"
    # Zero rows → empty emission. Distinguish "nothing captured" from "captures on
    # disk that the manifest failed to describe" (manifest_diagnosis warns on stderr).
    local reason; reason=$(manifest_diagnosis "$mf")
    audit_av "visual_evidence_pr_emitted" "skipped" \
      "$(jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" --arg dk "$dk" --arg reason "$reason" \
         '{worktask_id:$w, run_index:$r, captures:0, host_tier:"none", reason:$reason, dedupe_key:$dk}')"
  fi
  return 0
}

# ---------- mode: --post issue ----------------------------------------------
post_issue() {
  local dk="$WORKTASK_ID:$RUN_INDEX:visual_evidence:issue"
  local marker="<!-- visual-evidence:$WORKTASK_ID:$RUN_INDEX -->"

  # Gate 0: milestone mode → defer (parent milestone issue is canonical).
  if [ "${MILESTONE_MODE:-0}" = "1" ] || \
     { [ -f "$STATE_FILE" ] && [ -n "$(jq -r '.metadata.milestone // empty' "$STATE_FILE" 2>/dev/null)" ]; }; then
    audit_av "visual_evidence_issue_commented" "deferred" \
      "$(_issue_meta 0 none milestone_mode "" "$dk")"
    return 0
  fi

  # Gate 1: flag false → skip, no gh call.
  local req; req=$(state_requires_screenshots)
  if [ "$req" = "false" ]; then
    audit_av "visual_evidence_issue_commented" "skipped" \
      "$(_issue_meta 0 none flag_false "" "$dk")"
    return 0
  fi

  # Gate 2: no issue url → defer (publish deferred / failed at Step 6.5).
  local issue_url; issue_url=$(state_get '.metadata.github_issue_url')
  if [ -z "$issue_url" ]; then
    audit_av "visual_evidence_issue_commented" "deferred" \
      "$(_issue_meta 0 none no_issue_url "" "$dk")"
    return 0
  fi

  # Gate 3: build block; no captures → skip.
  local mf; mf=$(manifest_path)
  local block _tier_tmp _tier; _tier="none"
  _tier_tmp=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ave-tier-issue.$$")
  if ! block=$(HOST_TIER_FILE="$_tier_tmp" \
               build_block "$mf" "## Visual evidence (DV captures, run $RUN_INDEX)"); then
    rm -f "$_tier_tmp"
    audit_av "visual_evidence_issue_commented" "skipped" \
      "$(_issue_meta 0 none no_captures "$issue_url" "$dk")"
    return 0
  fi
  _tier=$(cat "$_tier_tmp" 2>/dev/null || printf 'none'); rm -f "$_tier_tmp"
  local caps; caps=$(printf '%s' "$block" | grep -c '^!\[' || true)

  # Gate 4: idempotency — marker already present on the issue → skip.
  if pl_issue_has_marker "$issue_url" "$marker"; then
    audit_av "visual_evidence_issue_commented" "skipped" \
      "$(_issue_meta "${caps:-0}" "$_tier" already_published "$issue_url" "$dk")"
    return 0
  fi

  # Post a single marker-tagged comment. gh failure → deferred (non-blocking).
  # NOTE: DRY_RUN governs only ASSET hosting (no cp / reachability probe), NOT the
  # gh call — the orchestrator decides live invocation, and self-tests inject a
  # GH_BIN mock, so the comment path is always exercised through $GH_BIN.
  local comment_body
  comment_body="$(printf '%s\n%s' "$marker" "$block")"
  if printf '%s' "$comment_body" | "$GH_BIN" issue comment "$issue_url" --body-file - >/dev/null 2>&1; then
    audit_av "visual_evidence_issue_commented" "ok" \
      "$(_issue_meta "${caps:-0}" "$_tier" commented "$issue_url" "$dk")"
  else
    audit_av "visual_evidence_issue_commented" "deferred" \
      "$(_issue_meta "${caps:-0}" "$_tier" gh_error "$issue_url" "$dk")"
  fi
  return 0
}

# Build the issue audit metadata JSON. $1=captures $2=tier $3=reason $4=url $5=dk
_issue_meta() {
  jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" --argjson c "${1:-0}" \
    --arg t "$2" --arg reason "$3" --arg url "$4" --arg dk "$5" \
    '{worktask_id:$w, run_index:$r, issue_url:$url, captures:$c, host_tier:$t, reason:$reason, dedupe_key:$dk}'
}

# ---------- context bootstrap ----------------------------------------------
load_context() {
  command -v jq >/dev/null 2>&1 || { echo "attach-visual-evidence: jq not found" >&2; exit 1; }
  [ -r "$STATE_FILE" ] || { echo "attach-visual-evidence: state unreadable: $STATE_FILE" >&2; exit 1; }
  jq -e . "$STATE_FILE" >/dev/null 2>&1 || { echo "attach-visual-evidence: state corrupt" >&2; exit 1; }
  WORKTASK_ID=$(corpflow_worktask_id "$STATE_FILE")
  RUN_INDEX=$(corpflow_run_index "$STATE_FILE")
}

# ---------- mode: --post completion (AC2) -----------------------------------
# Post-merge completion summary to every issue the PR closes. Resolves related
# issues (PR-body keywords ∪ closingIssuesReferences, deduped ints), posts one
# marker-deduped comment per issue. Non-blocking: each gh failure → audit row +
# continue; overall exit 0. Marker grammar (EXACT):
#   <!-- completion-summary:<worktask_id>:<run_index>:<issue_n> -->

# Emit the per-issue idempotency marker. $1=issue_n.
_completion_marker() {
  printf '<!-- completion-summary:%s:%s:%s -->' "$WORKTASK_ID" "$RUN_INDEX" "$1"
}

# Resolve related issues for a PR. $1=optional pr-ref (number or URL); empty = the
# checkout's own branch PR (gh resolves it; post_completion adds the ledger
# metadata.pr_url fallback). Output: newline-sep
# sorted-unique INTEGERS on stdout. Empty on no refs / gh failure. Always rc 0,
# never blocks. SECURITY: output is filtered to ^[0-9]+$ so no shell metachar
# from an untrusted PR body can ever reach a downstream gh argv.
resolve_related_issues() {
  local ref="${1:-}"
  local body_json refs_json kw_nums ref_nums
  # Source 1: PR body keywords (Closes|Fixes|Resolves #N, case-insensitive).
  if [ -n "$ref" ]; then
    body_json=$("$GH_BIN" pr view "$ref" --json body --jq '.body' 2>/dev/null || true)
  else
    body_json=$("$GH_BIN" pr view --json body --jq '.body' 2>/dev/null || true)
  fi
  kw_nums=$(printf '%s\n' "$body_json" \
    | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' || true)
  # Source 2: closingIssuesReferences (GitHub's resolved link set).
  if [ -n "$ref" ]; then
    refs_json=$("$GH_BIN" pr view "$ref" --json closingIssuesReferences \
      --jq '.closingIssuesReferences[].number' 2>/dev/null || true)
  else
    refs_json=$("$GH_BIN" pr view --json closingIssuesReferences \
      --jq '.closingIssuesReferences[].number' 2>/dev/null || true)
  fi
  ref_nums=$(printf '%s\n' "$refs_json" | grep -oE '[0-9]+' || true)
  # Union + dedup, integer-only (mandatory security + correctness filter).
  printf '%s\n%s\n' "$kw_nums" "$ref_nums" \
    | grep -E '^[0-9]+$' \
    | sort -un
  return 0
}

# Source the work-summary text for the completion comment (sanitised). First
# available wins: complete-summary-<run_index>.md → state.json facts/goal → PR
# title+body. Reads nothing from untrusted argv; output is sanitised via the
# library sanitise_body so leaked local paths never reach the comment.
_completion_summary_text() {
  local ref="${1:-}"
  local summ_file="$WORKSPACE_ROOT/.context/complete-summary-$RUN_INDEX.md"
  if [ -f "$summ_file" ]; then
    sanitise_body < "$summ_file"
    return 0
  fi
  # Fallback 1: state.json facts.goal (+ facts summary if present).
  local goal
  goal=$(jq -r '.facts.goal // empty' "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$goal" ]; then
    printf '%s' "$goal" | sanitise_body
    return 0
  fi
  # Fallback 2: PR title + body.
  local pr_txt
  if [ -n "$ref" ]; then
    pr_txt=$("$GH_BIN" pr view "$ref" --json title,body \
      --jq '"\(.title)\n\n\(.body)"' 2>/dev/null || true)
  else
    pr_txt=$("$GH_BIN" pr view --json title,body \
      --jq '"\(.title)\n\n\(.body)"' 2>/dev/null || true)
  fi
  printf '%s' "$pr_txt" | sanitise_body
  return 0
}

# Build the completion comment body for one issue. $1=issue_n, $2=optional pr-ref.
# Layout: marker + heading + work-summary [+ visual-evidence block]. The block is
# appended only when requires_screenshots==true AND captures exist (build_block
# returns 0). Summary-only otherwise — NO broken refs, NO note spam. stdout only.
build_completion_body() {
  local issue_n="$1" ref="${2:-}"
  local marker summary req
  marker=$(_completion_marker "$issue_n")
  summary=$(_completion_summary_text "$ref")
  printf '%s\n' "$marker"
  printf '## Worktask completed\n\n'
  [ -n "$summary" ] && printf '%s\n' "$summary"
  # Append the visual-evidence block only when screenshots are on AND captures
  # exist. build_block returns non-zero (no output) when there are no captures.
  req=$(state_requires_screenshots)
  if [ "$req" != "false" ]; then
    local mf block _tier_tmp
    mf=$(manifest_path)
    _tier_tmp=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ave-tier-comp.$$")
    if block=$(HOST_TIER_FILE="$_tier_tmp" \
               build_block "$mf" "## Visual evidence (DV captures, run $RUN_INDEX)"); then
      printf '\n%s' "$block"
    fi
    rm -f "$_tier_tmp"
  fi
  return 0
}

# Build the per-issue completion audit metadata JSON.
#   $1=issue_n $2=result-reason $3=dedupe_key
_completion_meta() {
  jq -cn --arg w "$WORKTASK_ID" --argjson r "$RUN_INDEX" \
    --argjson issue "$1" --arg reason "$2" --arg dk "$3" \
    '{worktask_id:$w, run_index:$r, issue:$issue, reason:$reason, dedupe_key:$dk}'
}

# Syntax gate for a PR ref that reaches a gh argv, whether it came from the
# argument or the ledger: a bare number or a github.com PR URL. Anything else
# (an option-looking string such as --repo=x, shell metachars) counts as absent.
# Which repo a URL names is _pr_ref_is_local's job, not this gate's.
_valid_pr_ref() {
  # [[ =~ ]] anchors on the whole value; grep matches per line, so a multi-line
  # value with one valid line would pass.
  [[ "${1:-}" =~ ^([0-9]+|https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+)$ ]]
}

# A URL ref must name THIS repo: the later `gh issue comment <n>` carries no --repo,
# so a foreign PR's closing refs would land on the same-numbered local issue. A bare
# number is always local. An unresolvable origin fails closed (treated as foreign).
_pr_ref_is_local() {
  local ref="${1:-}" slug origin
  case "$ref" in
    https://*) ;;
    *) return 0 ;;
  esac
  slug=${ref#https://github.com/}; slug=${slug%/pull/*}
  origin=$("$GH_BIN" repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
  [ -n "$origin" ] || return 1
  [ "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" ]
}

# Ledger metadata.pr_url, echoed only when _valid_pr_ref accepts it.
_ledger_pr_ref() {
  local v
  v=$(jq -r '.metadata.pr_url // empty' "$STATE_FILE" 2>/dev/null || true)
  if _valid_pr_ref "$v" && _pr_ref_is_local "$v"; then
    printf '%s' "$v"
  fi
  return 0
}

# Post one completion comment per related issue. $1=optional pr-ref. Non-blocking.
post_completion() {
  local ref="${1:-}"
  local action="completion_summary_commented"

  # Gate 0: milestone mode → defer (parent milestone issue is canonical).
  if [ "${MILESTONE_MODE:-0}" = "1" ] || \
     { [ -f "$STATE_FILE" ] && [ -n "$(jq -r '.metadata.milestone // empty' "$STATE_FILE" 2>/dev/null)" ]; }; then
    audit_av "$action" "deferred" \
      "$(_completion_meta 0 milestone_mode "$WORKTASK_ID:$RUN_INDEX:completion:all")"
    return 0
  fi

  # Gate 1: resolve related issues. Sources in order: the argument, the checkout's
  # branch PR, then the ledger's metadata.pr_url. A valid argument is final; with
  # none, the branch PR wins if it yields at least one issue, else the ledger PR
  # (a long-lived PR that closes nothing must not mask this run's PR). A URL naming
  # another repo counts as absent. Empty → audit no_related_issues, exit 0. After a
  # merge into a non-default base the checkout sits on a branch with no PR, so the ledger ref is
  # the only one that still names it. $ref becomes the effective ref, so the
  # summary fallback reads the same PR the issues came from.
  { _valid_pr_ref "$ref" && _pr_ref_is_local "$ref"; } || ref=""
  local issues; issues=$(resolve_related_issues "$ref")
  if [ -z "$issues" ] && [ -z "$ref" ]; then
    local ledger_ref; ledger_ref=$(_ledger_pr_ref)
    if [ -n "$ledger_ref" ]; then
      issues=$(resolve_related_issues "$ledger_ref")
      [ -n "$issues" ] && ref="$ledger_ref"
    fi
  fi
  if [ -z "$issues" ]; then
    audit_av "$action" "skipped" \
      "$(_completion_meta 0 no_related_issues "$WORKTASK_ID:$RUN_INDEX:completion:none")"
    return 0
  fi

  # One comment per issue. Integers only (resolver-validated). Non-blocking.
  local n marker dk body
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    dk="$WORKTASK_ID:$RUN_INDEX:completion:$n"
    marker=$(_completion_marker "$n")
    # Gate 2: idempotency — per-issue marker already present → skip.
    if pl_issue_has_marker "$n" "$marker"; then
      audit_av "$action" "skipped" "$(_completion_meta "$n" already_published "$dk")"
      continue
    fi
    body=$(build_completion_body "$n" "$ref")
    # Gate 3: post via stdin (--body-file -); never interpolate body into argv.
    if printf '%s' "$body" | "$GH_BIN" issue comment "$n" --body-file - >/dev/null 2>&1; then
      audit_av "$action" "ok" "$(_completion_meta "$n" commented "$dk")"
    else
      audit_av "$action" "deferred" "$(_completion_meta "$n" gh_error "$dk")"
    fi
  done <<EOF
$issues
EOF
  return 0
}

# ---------- entrypoint ------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  # Sourced HERE, not at the top: the harness is test code the production path
  # never runs. `[ -r ]` first, not a bare `.`: sourcing a missing file with the
  # `.` builtin is a special-builtin error that exits the shell immediately,
  # bypassing an `if ! . …` guard entirely.
  SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/attach-visual-evidence-selftest.sh"
  if [ -r "$SELFTEST_LIB_PATH" ]; then
    # shellcheck source=attach-visual-evidence-selftest.sh
    # shellcheck disable=SC1090,SC1091  # path built at runtime; lint runs without -x
    . "$SELFTEST_LIB_PATH"
  else
    printf >&2 'attach-visual-evidence: self-test harness unreachable at %s — plugin install broken\n' \
      "$SELFTEST_LIB_PATH"
    exit 2
  fi
  run_self_tests || exit 2
  exit 0
fi

# Read-only schema check. Handled here, before the tier library and state load, so the
# gate can call it in a tree with no state.json and so nothing about the publishing
# modes' exit-0 contract is reachable from this path.
if [ "${1:-}" = "--validate-manifest" ]; then
  _vm_path="${2:-}"; _vm_task=""; _vm_task_set=0; _vm_img=""
  shift; [ "$#" -gt 0 ] && shift
  # Unknown extras stay ignored so the task-less form keeps its old argv tolerance.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task-id) _vm_task="${2:-}"; _vm_task_set=1 ;;
      --images-dir) _vm_img="${2:-}" ;;
    esac
    shift; [ "$#" -gt 0 ] && shift
  done
  if [ "$_vm_task_set" = "1" ]; then
    validate_task_manifest "$_vm_path" "$_vm_task" "$_vm_img"
    exit $?
  fi
  validate_manifest "$_vm_path"
  exit $?
fi

usage() {
  echo "usage: $0 {--emit pr [--force] | --post issue | --post completion [<pr-ref>] | --validate-manifest <path> | --self-test}" >&2
}

# Argv is validated BEFORE the library/state load so a caller error reports the
# caller error — a missing state.json must not mask a bad or absent mode.
MODE="${1:-}"; TARGET="${2:-}"
FORCE=0
case "$MODE" in
  --emit)
    [ "$TARGET" = "pr" ] || { echo "usage: $0 --emit pr [--force]" >&2; exit 1; }
    case "${3:-}" in
      --force) FORCE=1 ;;
      "") ;;
      *) echo "usage: $0 --emit pr [--force]" >&2; exit 1 ;;
    esac ;;
  --post)
    case "$TARGET" in
      issue|completion) ;;
      *) echo "usage: $0 --post {issue | completion [<pr-ref>]}" >&2; exit 1 ;;
    esac ;;
  *)
    usage
    exit 1 ;;
esac

# Source the tier library (after self-test branch so tests fork fresh processes).
if [ -f "$_LIB" ]; then
  # shellcheck disable=SC1090
  PUBLISH_LIB_ONLY=1 . "$_LIB"
else
  echo "attach-visual-evidence: tier library not found: $_LIB" >&2
  exit 1
fi

load_context

case "$MODE" in
  --emit) emit_pr ;;
  --post)
    case "$TARGET" in
      issue) post_issue ;;
      completion) post_completion "${3:-}" ;;
    esac ;;
esac
exit 0
