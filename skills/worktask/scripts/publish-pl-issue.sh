#!/usr/bin/env bash
# publish-pl-issue.sh — auto-publish a sanitised GitHub issue after PL approval.
#
# Invoked by the orchestrator after PL0 (skills/worktask/SKILL.md § PL Issue Publish). NEVER blocks the
# worktask: operational outcomes are audit.jsonl rows (result + reason) and exit 0; only a
# catastrophe (jq missing, audit dir unwritable, state corrupt) exits 1, and --self-test
# failure exits 2. An unreachable sibling folds into those two: publish-pl-issue-lib.sh
# missing is catastrophic, publish-pl-issue-selftest.sh missing is a self-test that cannot
# run. The lib is sourced eagerly (PUBLISH_LIB_ONLY consumers need it); the harness only on
# the --self-test arm, so the publish path never loads test code.
#
# Contracts owned elsewhere, implemented here — read the owner before changing behaviour:
#   - Cross-run dedup, the .context/gh-issue.json anchor, the marker-deduped follow-up
#     comment and milestone-mode: skills/gh-issue-dedup. Env: GH_ISSUE_ANCHOR (anchor path),
#     GH_ISSUE_SEARCH=0 (disable the title search).
#   - plan_file shape boundary (path in state.json, bare basename in task metadata; readers
#     MUST accept either): handoff-protocol.md § plan_file shape boundary. The PLAN_FILE block below
#     tries the value as given, then its basename against the state directory, and names both
#     candidates on the fatal path.
#   - {{asset:<basename>}} placeholder grammar and the .context/designs/-only lookup:
#     pl0-procedure.md § Asset-placeholder grammar. Tokens carry no path, so they survive
#     sanitiser Pass-1 L1; resolve_design_assets() rewrites them to hosted image lines AFTER
#     sanitisation, so no local path ever reaches the issue body.
#
# Sanitiser: two passes (awk line-strip L1-L9, then token-strip with allow-list A1-A5). A
# strip ratio over 50% aborts the publish and persists the body to
# .context/logs/issue-body-<run_index>.aborted.tmp rather than posting a gutted issue.
#
# Asset hosting — tier order, highest first. Each downgrade appends a non-blocking audit row
# under a distinct dedupe-key suffix (:asset_hosting) so it cannot mask the result row, and
# no tier ever emits a broken `![]()`:
#   0. user-attachments — the only tier that satisfies private-repo rendering, binary
#      payloads and no repo commit at once. Needs the `drogers0/gh-image` gh extension for
#      the browser session token; a PAT cannot drive the upload-policy flow (it is
#      web-session-oriented and rejects a Bearer token). Probed with `gh image check-token`.
#   1. raw.githubusercontent.com — REFUSED for a PRIVATE/INTERNAL repo and verified with an
#      anonymous `curl -fsIL` otherwise, because GitHub's camo proxy fetches ANONYMOUSLY: an
#      authenticated `gh api contents` check passes on a URL that renders broken.
#   2. gist — a public-or-secret gist raw URL is anonymously fetchable, so camo renders it
#      even inside a private repo. Render-verified by anonymous HEAD before it is emitted.
#   3. none — Figma URL plus one note line; bullets, never an embed.
#
#   Privacy: NEITHER gist kind preserves confidentiality — both are anonymously readable by
#   URL, which is exactly what makes them render. They differ in DISCOVERABILITY only, so the
#   default is auto (PRIVATE/INTERNAL → secret, PUBLIC/unknown → public). Material that must
#   not leave the org needs ASSET_HOST_MODE=none, not an unlisted URL.
#
#   raw path: the PNG is copied to .worktask-assets/<worktask_id>/<basename> on the worktask
#   branch. The helper does NOT commit or push — no surprising git side effects at Step 6.5 —
#   so it verifies the ref is reachable with `git ls-remote --exit-code origin <ref>` first
#   and degrades when it is not.
#
# Env seams (test/dev injection): STATE_FILE, WORKSPACE_ROOT, GH_BIN, DRY_RUN, GH_TIMEOUT
# (30). Asset hosting: ASSET_HOST_MODE (user-attachments|raw|gist|none, forces a tier and
# bypasses live probes), ASSET_OWNER_REPO, ASSET_REF, ASSET_REPO_VISIBILITY, GIST_RAW_URL_BASE,
# USER_ATTACH_URL_BASE, GIST_VERIFY_FORCE (pass|fail), ASSET_GH_IMAGE (pin tier-0 probe),
# ASSET_UA_ENABLE=1 (offline tier-0 mock), ASSET_GIST_PUBLIC (1 public / 0 secret / unset
# auto).

set -u

# Physical directory of this script, used to resolve the sibling libraries below.
# CDPATH= disables a benign-but-common CDPATH setting that otherwise makes `cd`
# echo an extra line into this very capture; `pwd -P` plus the readlink loop
# follow a symlinked script to its real directory so sibling-library resolution
# cannot be redirected onto an attacker-planted file next to the symlink.
# BASH_SOURCE (not $0) on purpose: attach-visual-evidence.sh SOURCES this file
# with PUBLISH_LIB_ONLY=1, where $0 is that caller, not us.
_resolve_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  while [ -h "$src" ]; do
    dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd -P)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  CDPATH= cd -- "$(dirname -- "$src")" && pwd -P
}
SCRIPT_DIR="$(_resolve_script_dir 2> /dev/null)" || SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"

# ---------- defaults / env --------------------------------------------------
STATE_FILE="${STATE_FILE:-.context/state.json}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-}"
GH_BIN="${GH_BIN:-gh}"
DRY_RUN="${DRY_RUN:-0}"
GH_TIMEOUT="${GH_TIMEOUT:-30}"
# Longer than GH_TIMEOUT on purpose: a COLD `gh image check-token` legitimately
# needs tens of seconds to decrypt the browser cookie store (warm is ~3s).
GH_IMAGE_PROBE_TIMEOUT="${GH_IMAGE_PROBE_TIMEOUT:-90}"
STRICT="${STRICT:-0}"
LOG_DIR="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/logs"
AUDIT_FILE="$LOG_DIR/audit.jsonl"
# Run-independent .context ↔ issue binding. state.json is re-seeded on every fresh
# /worktask (commands/worktask.md § seed), wiping metadata.github_issue_url — so the
# canonical issue reference is persisted HERE instead, surviving run_index increments.
# A second worktask in the same .context/ then comments on the existing issue rather
# than opening a duplicate. See skills/gh-issue-dedup. Sits next to state.json.
# shellcheck disable=SC2034  # read by publish-pl-issue-lib.sh (anchor read/write) at call time
ISSUE_ANCHOR="${GH_ISSUE_ANCHOR:-$(dirname "$STATE_FILE")/gh-issue.json}"
# GitHub-side recovery search when no local anchor resolves (fresh clone / lost
# .context/). Default on; exact-title single-hit only (guarded against false matches).
GH_ISSUE_SEARCH="${GH_ISSUE_SEARCH:-1}"
# Human-readable suffix for the next fatal() diagnostic. Declared here so `set -u`
# is satisfied at every fatal() call; callers set it immediately before failing.
FATAL_DETAIL=""

# ---------- asset-hosting env hooks (Figma image embed) ---------------------
# Roots used to resolve {{asset:<basename>}} tokens and to stage hosted copies.
# Derived from WORKSPACE_ROOT (falls back to CLAUDE_PROJECT_DIR / cwd) so the
# helper works both in-worktree and in self-test sandboxes.
ASSET_ROOT="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}"
ASSET_DESIGNS_DIR="$ASSET_ROOT/.context/designs"     # canonical (and only) Figma asset source
# shellcheck disable=SC2034  # save/restore target of the self-test sandbox; no production reader
ASSET_IMAGES_DIR="$ASSET_ROOT/.context/images"        # DV implementation screenshots — NEVER a Figma {{asset:...}} source
# Test hooks (unset in production → real git/gh probes drive tier selection):
ASSET_HOST_MODE="${ASSET_HOST_MODE:-}"                # user-attachments|raw|gist|none force
ASSET_OWNER_REPO="${ASSET_OWNER_REPO:-}"              # mock "owner/repo"
ASSET_REF="${ASSET_REF:-}"                            # mock <ref>
GIST_RAW_URL_BASE="${GIST_RAW_URL_BASE:-}"            # mock gist raw base
USER_ATTACH_URL_BASE="${USER_ATTACH_URL_BASE:-}"      # mock user-attachments asset base
ASSET_REPO_VISIBILITY="${ASSET_REPO_VISIBILITY:-}"    # mock PUBLIC|PRIVATE|INTERNAL (REQ-1)
# Live opt-in for the user-attachments tier. Currently inert: q1 spike found the
# upload-policy flow needs a browser session cookie, not a gh token (see header).
# This flag now ONLY gates the offline mock path (with USER_ATTACH_URL_BASE) used
# by self-tests. The live tier-0 path is not gated by it — it activates whenever
# `gh image` is installed and authed. Default off (mock disabled).
ASSET_UA_ENABLE="${ASSET_UA_ENABLE:-0}"
# Pin tier-0 availability for deterministic tests: 1 = force available, 0 = force
# unavailable, empty = probe `gh image check-token` live.
ASSET_GH_IMAGE="${ASSET_GH_IMAGE:-}"
# Gist visibility. Tri-state: "1" forces public, "0" forces secret/unlisted, and
# EMPTY (the default) means auto — derived from repo visibility by
# gist_public_effective(): PRIVATE/INTERNAL → secret, everything else → public.
#
# Why auto rather than a flat default-on: both gist kinds are anonymously
# fetchable by URL (camo requires that to render at all), so on a PRIVATE or
# INTERNAL repo `--public` buys NOTHING — it cannot improve rendering, which
# already works — while adding search indexing and a listing on the authoring
# account's public gist profile. That is pure downside exactly where the source
# repo is closed, so auto declines it. On a PUBLIC repo the listing costs
# nothing and public stays the default.
#
# This narrows discoverability only. It does NOT make the bytes confidential —
# see the AC1 privacy posture note in the header. Both paths render-verify
# before emitting a URL (see gist_raw_url_reachable).
ASSET_GIST_PUBLIC="${ASSET_GIST_PUBLIC:-}"
# Offline render-verify test hook for gist_raw_url_reachable. When set to "pass"
# the anonymous HEAD probe is short-circuited to success; "fail" forces failure
# (caller degrades). Empty (production default) → a real anonymous curl HEAD.
GIST_VERIFY_FORCE="${GIST_VERIFY_FORCE:-}"
# Reason recorded by resolve_design_assets() when it degrades below tier-1.
# resolve_design_assets runs in a command substitution (subshell), so it cannot
# set a parent variable — it writes the reason to ASSET_DEGRADED_FILE instead,
# which the parent reads after the substitution returns. Empty file / absent →
# no degradation.
ASSET_DEGRADED_REASON=""
ASSET_DEGRADED_FILE=""

# ---------- CLI flag parsing ------------------------------------------------
# Accept --strict (sets STRICT=1). --self-test handled in entrypoint below.
for _arg in "$@"; do
  case "$_arg" in
    --strict) STRICT=1 ;;
    *) ;;
  esac
done

# ---------- helpers ---------------------------------------------------------
# Bounded execution WITHOUT coreutils. Stock macOS ships neither `timeout` nor
# `gtimeout` and Homebrew coreutils is not a dependency of this plugin, so the
# `command -v gtimeout || command -v timeout` idiom used below silently resolves
# to empty and leaves the call UNBOUNDED on exactly the platform that needs it.
# Prefers a real timeout binary when one exists; otherwise polls at 1s
# granularity. Returns the command's status, or 124 on timeout (GNU convention).
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi
  "$@" &
  local p=$! n=0
  while kill -0 "$p" 2> /dev/null && [ "$n" -lt "$secs" ]; do
    sleep 1; n=$((n + 1))
  done
  if kill -0 "$p" 2> /dev/null; then
    kill -9 "$p" 2> /dev/null || true
    wait "$p" 2> /dev/null || true
    return 124
  fi
  wait "$p" 2> /dev/null
  return $?
}

# Shared ledger reads; the fallback default is an explicit argument, never unified —
# some call sites probe for absence rather than read a value. `[ -r ]` guard as above.
_STATE_READ_LIB="$SCRIPT_DIR/../../shared/lib/state-read-lib.sh"
if [ ! -r "$_STATE_READ_LIB" ]; then
  printf >&2 'publish-pl-issue: plugin install broken — state-read-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/state-read-lib.sh
. "$_STATE_READ_LIB"

# Shared audit-row appender. `[ -r ]` before the `.`: a bare `.` on a missing file is a
# special-builtin error that exits the shell, bypassing an `if !` guard.
_AUDIT_LIB="$SCRIPT_DIR/../../shared/lib/audit-lib.sh"
if [ ! -r "$_AUDIT_LIB" ]; then
  printf >&2 'publish-pl-issue: plugin install broken — audit-lib.sh not found\n'
  exit 2
fi
# shellcheck source=../../shared/lib/audit-lib.sh
. "$_AUDIT_LIB"

audit_row() {
  # $1=result, $2=metadata-json (compact). Always appends one row.
  # Returns non-zero when the row was NOT written — the callers' `|| true` decides what
  # that costs. jq-absent keeps its historical hard refusal rather than the library's
  # degraded row: this emitter's metadata is the only record of what was published.
  command -v jq >/dev/null 2>&1 || return 1
  corpflow_audit_row --file "$AUDIT_FILE" --actor orchestrator \
    --action github_issue_created --subject PL0 --result "$1" \
    --task-id PL0 --meta "$2"
  return "$CORPFLOW_AUDIT_LAST_RC"
}

defer() {
  # $1=reason; appends audit row with result=deferred, exits 0.
  local reason="$1"
  local wid run_index dk
  wid=$(corpflow_worktask_id "$STATE_FILE")
  run_index=$(corpflow_run_index "$STATE_FILE")
  dk="$wid:$run_index:gh_issue"
  audit_row "deferred" "$(jq -cn --arg v "publish-pl-issue.sh" --arg r "$reason" --arg dk "$dk" '{via:$v, reason:$r, dedupe_key:$dk}')" || true
  exit 0
}

fatal() {
  # $1=reason; appends audit row with result=error, exits 1.
  local reason="$1"
  local wid run_index dk
  # The audit row alone is machine-only: an operator watching the orchestrator sees
  # nothing at all when this path fires. Emit the reason (plus any FATAL_DETAIL the
  # caller staged) on stderr before exiting.
  printf >&2 'publish-pl-issue: FATAL %s%s\n' "$reason" "${FATAL_DETAIL:+ — $FATAL_DETAIL}"
  wid=$(corpflow_worktask_id "$STATE_FILE")
  run_index=$(corpflow_run_index "$STATE_FILE")
  dk="$wid:$run_index:gh_issue"
  audit_row "error" "$(jq -cn --arg v "publish-pl-issue.sh" --arg r "$reason" --arg dk "$dk" '{via:$v, reason:$r, dedupe_key:$dk}')" 2>/dev/null || true
  exit 1
}

# ---------- shared helper library -------------------------------------------
# Sanitiser, plan extraction, state/anchor writes, label provisioning. Loaded
# eagerly and BEFORE the PUBLISH_LIB_ONLY return below, because sourcing callers
# (fn-preflight-cmds.sh, attach-visual-evidence.sh) depend on `sanitise_body`.
# Absence is the only failure mode — a same-directory, same-commit sibling that
# is missing means a broken install, which is catastrophic in the same class as
# a missing jq: nothing can be sanitised, so nothing may be published. `[ -r ]`
# first, not a bare `.`: sourcing a missing file with the `.` builtin is a
# special-builtin error that exits the shell immediately, bypassing an
# `if ! . …` guard entirely.
HELPER_LIB_PATH="${SCRIPT_DIR}/publish-pl-issue-lib.sh"
if [ -r "$HELPER_LIB_PATH" ]; then
  # shellcheck source=publish-pl-issue-lib.sh
  # shellcheck disable=SC1090
  . "$HELPER_LIB_PATH"
else
  printf >&2 'publish-pl-issue: helper library unreachable at %s — plugin install broken\n' \
    "$HELPER_LIB_PATH"
  exit 1
fi

# ---------- asset host-and-rewrite (Figma image embed) ----------------------
# Parse "owner/repo" from a git remote URL. Handles both forms:
#   git@github.com:Agnidia/corpflow.git
#   https://github.com/Agnidia/corpflow.git   (and without .git)
# Echoes "owner/repo" on success; empty on no match.
parse_owner_repo() {
  local url="$1" path
  case "$url" in
    git@*:*)        path="${url#*:}" ;;                 # scp-like: host:owner/repo
    ssh://*|https://*|http://*|git://*)
                    path="${url#*://}"                  # strip scheme
                    path="${path#*/}" ;;                # strip host[:port]/
    *)              path="$url" ;;
  esac
  path="${path%.git}"                                   # drop trailing .git
  path="${path%/}"
  # Keep only the last two segments (owner/repo) — tolerates extra path depth.
  printf '%s' "$path" | awk -F'/' 'NF>=2 { printf "%s/%s", $(NF-1), $NF }'
}

# Resolve a {{asset:<basename>}} basename to an on-disk path. {{asset:...}} tokens
# carry Figma design-preview frames, which live ONLY under .context/designs/ (the
# canonical design-reference dir). .context/images/ is reserved for DV implementation
# screenshots and is NEVER a design-asset source — do not fall back to it. Echoes the
# resolved designs/ path, or empty if not found.
resolve_asset_path() {
  local base="$1"
  if [ -f "$ASSET_DESIGNS_DIR/$base" ]; then
    printf '%s' "$ASSET_DESIGNS_DIR/$base"; return 0
  fi
  return 1
}

# Echo the target repo visibility (PUBLIC|PRIVATE|INTERNAL|"" unknown). Honours
# the ASSET_REPO_VISIBILITY mock first (offline self-tests), else probes
# `gh repo view --json visibility`. NON-BLOCKING: any failure echoes empty.
repo_visibility() {
  if [ -n "$ASSET_REPO_VISIBILITY" ]; then
    printf '%s' "$ASSET_REPO_VISIBILITY" | tr '[:lower:]' '[:upper:]'
    return 0
  fi
  command -v "$GH_BIN" >/dev/null 2>&1 || { printf ''; return 0; }
  "$GH_BIN" auth status >/dev/null 2>&1 || { printf ''; return 0; }
  "$GH_BIN" repo view --json visibility --jq '.visibility' 2>/dev/null \
    | tr '[:lower:]' '[:upper:]'
}

# Decide the hosting tier + compute owner/repo + ref. Sets globals:
#   HOST_TIER  ∈ {user-attachments, raw, gist, none}
#   HOST_OWNER_REPO, HOST_REF   (for raw tier)
# Honors ASSET_HOST_MODE override (self-tests); otherwise probes git/gh.
# NON-BLOCKING: any probe failure degrades the tier, never errors.
# Is the `gh image` extension (drogers0/gh-image) usable right now? It uploads to
# GitHub's user-attachments CDN using a browser SESSION token — the flow a PAT
# cannot authenticate — and prints `![base](url)`.
# ASSET_GH_IMAGE pins the answer for deterministic tests: 1 = force available,
# 0 = force unavailable, empty = probe live. The probe is cached because
# check-token does network I/O and select_host_tier can be called per asset.
GH_IMAGE_OK_CACHE=""
# Why the probe result is no longer a bare boolean: "extension absent", "token
# stale" and "probe timed out" are three different operator actions, and
# collapsing them into one "inline hosting unavailable" sentence is what let a
# run ship six captured screenshots as a dead path. Set to
# absent|token_invalid|probe_timeout|ok and surfaced in the body + audit row.
GH_IMAGE_FAIL_REASON=""
gh_image_available() {
  case "${ASSET_GH_IMAGE:-}" in
    1) GH_IMAGE_FAIL_REASON="ok"; return 0 ;;
    0) GH_IMAGE_FAIL_REASON="absent"; return 1 ;;
  esac
  [ -n "$GH_IMAGE_OK_CACHE" ] && { [ "$GH_IMAGE_OK_CACHE" = "1" ] && return 0 || return 1; }
  GH_IMAGE_OK_CACHE=0
  command -v "$GH_BIN" >/dev/null 2>&1 || { GH_IMAGE_FAIL_REASON="absent"; return 1; }
  # check-token is SLOW on a cold cache: it decrypts the browser cookie store and
  # on macOS can block indefinitely on a Keychain prompt when non-interactive
  # (measured >120s cold, 3s warm). Unbounded, it stalls FN and the stall is then
  # misreported as "hosting unavailable". GH_SESSION_TOKEN bypasses the browser
  # entirely and is the supported way to make this fast and non-interactive.
  run_with_timeout "$GH_IMAGE_PROBE_TIMEOUT" "$GH_BIN" image check-token >/dev/null 2>&1
  case "$?" in
    0)   GH_IMAGE_OK_CACHE=1; GH_IMAGE_FAIL_REASON="ok"; return 0 ;;
    124) GH_IMAGE_FAIL_REASON="probe_timeout"; return 1 ;;
    *)   GH_IMAGE_FAIL_REASON="token_invalid"; return 1 ;;
  esac
}

HOST_TIER=""
HOST_OWNER_REPO=""
HOST_REF=""
select_host_tier() {
  HOST_TIER="none"; HOST_OWNER_REPO=""; HOST_REF=""
  # Forced mode (self-tests bypass live probes).
  case "$ASSET_HOST_MODE" in
    user-attachments)
      HOST_TIER="user-attachments"; return 0 ;;
    raw)
      HOST_TIER="raw"
      HOST_OWNER_REPO="${ASSET_OWNER_REPO:-owner/repo}"
      HOST_REF="${ASSET_REF:-main}"
      return 0 ;;
    gist) HOST_TIER="gist"; return 0 ;;
    none) HOST_TIER="none"
          [ -n "$GH_IMAGE_FAIL_REASON" ] || GH_IMAGE_FAIL_REASON="no_host_tier"
          return 0 ;;
    *) ;;  # fall through to live probes
  esac

  # Tier-0 (user-attachments) — now LIVE via the `gh image` extension, which
  # drives the browser-session upload the q1 spike found `gh` itself cannot do.
  # This is the PREFERRED tier and the only one that satisfies all three
  # constraints at once: it works on PRIVATE/INTERNAL repos (GitHub serves the
  # asset from private-user-images.githubusercontent.com with a scoped JWT, so no
  # camo 404), it accepts BINARY files (unlike gists), and it does not commit
  # anything to the repository (unlike raw). Preconditions: the extension is
  # installed AND holds a valid session token.
  #   Mock path: ASSET_UA_ENABLE=1 + USER_ATTACH_URL_BASE (offline self-tests).
  if [ "$ASSET_UA_ENABLE" = "1" ] && [ -n "$USER_ATTACH_URL_BASE" ]; then
    HOST_TIER="user-attachments"; return 0
  fi
  if gh_image_available; then
    HOST_TIER="user-attachments"; return 0
  fi

  # Tier-1 (raw.githubusercontent.com) preconditions: remote parseable AND ref
  # reachable on origin. The helper does NOT push — it only checks. REQ-1: refuse
  # the raw tier for PRIVATE/INTERNAL repos, because GitHub's camo image proxy
  # fetches the URL anonymously and would 404 — emitting a broken image. Those
  # repos degrade to gist/none instead. raw_asset_url_reachable() re-checks at
  # host time (defence in depth); selecting away here avoids the wasted cp.
  local remote owner_repo ref vis
  remote=$(git remote get-url origin 2>/dev/null || true)
  owner_repo=$(parse_owner_repo "$remote")
  ref=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  vis=$(repo_visibility)
  if [ -n "$owner_repo" ] && [ -n "$ref" ] && [ "$ref" != "HEAD" ] \
     && [ "$vis" != "PRIVATE" ] && [ "$vis" != "INTERNAL" ]; then
    if git ls-remote --exit-code origin "$ref" >/dev/null 2>&1; then
      HOST_TIER="raw"; HOST_OWNER_REPO="$owner_repo"; HOST_REF="$ref"
      return 0
    fi
  fi
  # Tier-2 (gist): available iff gh is present + authed. NOTE — this tier CANNOT
  # host images: `gh gist create` rejects binary content ("binary file not
  # supported"), so every PNG/JPG fails the guard in host_one_asset and degrades
  # to a bullet. It was previously documented as the effective primary tier for
  # PRIVATE/INTERNAL repos; that claim was wrong. It remains selectable for text
  # assets. Consequence: on a PRIVATE/INTERNAL repo WITHOUT the `gh image`
  # extension there is no working inline-embed tier (raw refused above, tier-0
  # unavailable, gist binary-blocked) — the visual-evidence block degrades to
  # bullets and inline rendering needs a manual web-UI attach. Installing
  # `drogers0/gh-image` activates tier-0 and removes that limitation. It
  # creates a render-verified gist (visibility per gist_public_effective) whose raw URL
  # camo can fetch anonymously. host_one_asset render-verifies before emitting.
  if command -v "$GH_BIN" >/dev/null 2>&1 && \
     "$GH_BIN" auth status >/dev/null 2>&1; then
    HOST_TIER="gist"; return 0
  fi
  # Tier-3: URL-only note. Only stamp a reason when the gh-image probe did not
  # already set a more specific one (absent/token_invalid/probe_timeout) — that
  # distinction is the whole point of GH_IMAGE_FAIL_REASON.
  HOST_TIER="none"
  [ -n "$GH_IMAGE_FAIL_REASON" ] || GH_IMAGE_FAIL_REASON="no_host_tier"
  return 0
}

# Return success only when a constructed raw.githubusercontent.com URL will
# RENDER inside a GitHub issue — i.e. when GitHub's camo image proxy (which
# fetches the URL ANONYMOUSLY) can retrieve it. REQ-1.
#
# The historical bug: this gate used an AUTHENTICATED `gh api contents` existence
# check, which succeeds for PRIVATE/INTERNAL content the anonymous camo proxy
# CANNOT fetch — a false positive that emitted a dead raw URL (broken image).
#
# New semantics:
#   - PRIVATE/INTERNAL repo  → ALWAYS fail (anonymous fetch would 404; degrade).
#   - PUBLIC repo            → require an anonymous `curl -fsIL` HEAD to succeed
#                              (no auth header — mirrors what camo sees). When
#                              curl is absent, fall back to the authenticated
#                              existence check (best effort; public content the
#                              auth check sees is anonymously fetchable too).
# Any uncertainty degrades away from the raw tier (non-blocking).
raw_asset_url_reachable() {
  # $1=owner/repo $2=ref $3=rel-path $4=raw-url
  local owner_repo="$1" ref="$2" rel="$3" raw_url="$4"
  local vis
  vis=$(repo_visibility)
  # REQ-1: never emit a raw URL for non-public repos — camo can't fetch it.
  if [ "$vis" = "PRIVATE" ] || [ "$vis" = "INTERNAL" ]; then
    return 1
  fi
  # Public (or unknown-visibility public-by-default): approximate the camo proxy's
  # ANONYMOUS fetch. Strip any ambient auth so the HEAD matches what camo sees.
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --max-time 10 -H 'Authorization:' "$raw_url" >/dev/null 2>&1 && return 0
    return 1
  fi
  # No curl: fall back to authenticated existence (best effort; only reached for
  # public/unknown repos, where existence implies anonymous reachability).
  if command -v "$GH_BIN" >/dev/null 2>&1 && "$GH_BIN" auth status >/dev/null 2>&1; then
    "$GH_BIN" api --silent -X GET "repos/$owner_repo/contents/$rel" -f ref="$ref" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Return success only when a gist raw URL will RENDER inside a GitHub issue/PR —
# i.e. when GitHub's camo image proxy (which fetches origins ANONYMOUSLY) can
# retrieve it. AC1/REQ-1: a public-gist raw URL is anonymously fetchable, so it
# renders inside a PRIVATE repo's body (the surrounding repo's privacy does not
# gate camo's outbound fetch of a public origin). Mirrors raw_asset_url_reachable.
#   $1 = gist raw URL
# GIST_VERIFY_FORCE (offline test hook) short-circuits the network probe:
#   pass → return 0 ; fail → return 1.
gist_raw_url_reachable() {
  local url="$1"
  # Offline test hook: bypass the network entirely.
  case "$GIST_VERIFY_FORCE" in
    pass) return 0 ;;
    fail) return 1 ;;
  esac
  # Approximate camo's ANONYMOUS fetch: strip any ambient auth header so the HEAD
  # matches what camo sees AND so a leaked token is never sent to a URL derived
  # from gh output.
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --max-time 10 -H 'Authorization;' "$url" >/dev/null 2>&1 && return 0
    return 1
  fi
  # No curl: optimistic-pass. A gist raw URL (public or unlisted/secret) is
  # anonymously reachable by construction, so without a probe tool we assume it
  # renders rather than dropping a working embed. Document the assumption.
  return 0
}

# Resolve the effective gist visibility: "1" (public) or "0" (secret/unlisted).
# An explicit ASSET_GIST_PUBLIC always wins and short-circuits before any probe,
# so callers that set it need no gh/network access. Empty → auto-derive from
# repo visibility, declining `--public` for closed repos (see the ASSET_GIST_PUBLIC
# note above). Unknown visibility (no gh, unauthed, probe failure) falls back to
# public: that is the historical behaviour, and it keeps the embed rendering.
gist_public_effective() {
  case "${ASSET_GIST_PUBLIC:-}" in
    1) printf '1'; return 0 ;;
    0) printf '0'; return 0 ;;
  esac
  case "$(repo_visibility 2>/dev/null || printf '')" in
    PRIVATE|INTERNAL) printf '0' ;;
    *)                printf '1' ;;
  esac
}

# Host a single PNG and echo its public https URL (or empty on failure).
#   $1 = basename, $2 = on-disk source path
# Uses HOST_TIER/HOST_OWNER_REPO/HOST_REF set by select_host_tier().
host_one_asset() {
  local base="$1" src="$2"
  case "$HOST_TIER" in
    user-attachments)
      # TOP tier: github.com/user-attachments/assets/<uuid>. Live via the
      # `gh image` extension, which supplies the browser SESSION token that the
      # upload-policy flow requires and a PAT cannot provide (the q1 blocker).
      # GitHub rewrites these to private-user-images.githubusercontent.com with a
      # short-lived scoped JWT, so they render for repo members on PRIVATE and
      # INTERNAL repos, accept binaries, and never touch the repository.
      if [ -n "$USER_ATTACH_URL_BASE" ]; then
        # Mirror GIST_RAW_URL_BASE: synthesise the asset URL offline. A real UUID
        # is server-assigned; the mock base stands in for it in tests.
        printf '%s/%s' "${USER_ATTACH_URL_BASE%/}" "$base"; return 0
      fi
      if [ "$DRY_RUN" = "1" ]; then
        # A dry run must not upload, but it also must not claim success for an
        # uploader that isn't there — that is the failure mode that made an
        # earlier dry run report working embeds while the real run emitted
        # bullets. check-token is read-only, so probing it here is side-effect
        # free. Inline (not via gh_image_available) to keep host_one_asset
        # dependency-free for the declare -f subshells in the self-tests.
        "$GH_BIN" image check-token >/dev/null 2>&1 || return 1
        printf 'https://github.com/user-attachments/assets/dry-run-%s' "$base"; return 0
      fi
      # `gh image <file>` prints `![<base>](<url>)` on success. Extract the URL;
      # a missing/!matching line means the upload failed, so degrade rather than
      # emit a broken embed. stderr is dropped: it can echo token diagnostics.
      local giout giurl
      giout=$("$GH_BIN" image "$src" 2>/dev/null) || return 1
      giurl=$(printf '%s' "$giout" \
        | grep -oE 'https://github\.com/user-attachments/assets/[A-Za-z0-9._-]+' | head -1)
      [ -z "$giurl" ] && return 1
      printf '%s' "$giurl"
      return 0 ;;
    raw)
      # Copy the PNG into the tracked assets path on the worktask branch so a
      # later (human-gated) commit ships it. We do NOT git-add/commit/push here.
      local rel=".worktask-assets/${WORKTASK_ID:-task}/$base"
      local dest="$ASSET_ROOT/$rel"
      if [ "$DRY_RUN" != "1" ]; then
        mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
        cp -f "$src" "$dest" 2>/dev/null || return 1
      fi
      local raw_url
      raw_url=$(printf 'https://raw.githubusercontent.com/%s/%s/%s' \
        "$HOST_OWNER_REPO" "$HOST_REF" "$rel")
      # Prevent broken image markdown: only emit tier-1 URLs when the asset is
      # reachable at that ref. Otherwise signal failure so caller degrades.
      if [ "$DRY_RUN" != "1" ] && ! raw_asset_url_reachable "$HOST_OWNER_REPO" "$HOST_REF" "$rel" "$raw_url"; then
        return 1
      fi
      printf '%s' "$raw_url"
      return 0 ;;
    gist)
      # HARD LIMIT: `gh gist create` rejects binary content outright with
      # "binary file not supported" — the gists API takes UTF-8 text only. A
      # PNG/JPG can therefore NEVER be hosted on this tier, on any repo. Detect
      # it here and fail fast so the caller degrades to a bullet with a real
      # reason, instead of burning a network round-trip on a guaranteed failure.
      # Placed ahead of the mock/dry-run short-circuits deliberately: a dry run
      # that reported a working embed for a binary would be lying about the very
      # thing being dry-run. `grep -I` treats binary as non-matching, so this
      # succeeds only for text.
      if ! LC_ALL=C grep -qI . "$src" 2>/dev/null; then
        return 1
      fi
      # Mock-friendly: if GIST_RAW_URL_BASE is set (self-tests), synthesise the
      # raw URL without touching the network. Otherwise upload via gh.
      if [ -n "$GIST_RAW_URL_BASE" ]; then
        printf '%s/%s' "${GIST_RAW_URL_BASE%/}" "$base"; return 0
      fi
      if [ "$DRY_RUN" = "1" ]; then
        printf 'https://gist.githubusercontent.com/dry/run/raw/%s' "$base"; return 0
      fi
      local gout raw raw_url
      # Visibility via gist_public_effective(): explicit ASSET_GIST_PUBLIC wins,
      # else auto-derived from repo visibility (closed repo → secret). Both kinds
      # are anonymously fetchable, so both render — only discoverability differs.
      if [ "$(gist_public_effective)" = "1" ]; then
        gout=$("$GH_BIN" gist create --public "$src" 2>/dev/null) || return 1
      else
        gout=$("$GH_BIN" gist create "$src" 2>/dev/null) || return 1
      fi
      # gh prints the gist web URL; the raw asset URL is web/raw/<base>.
      raw=$(printf '%s' "$gout" | grep -oE 'https://gist\.github\.com/[A-Za-z0-9._/-]+' | head -1)
      [ -z "$raw" ] && return 1
      raw_url=$(printf '%s/raw/%s' "$raw" "$base")
      # REQ-1: render-verify (anonymous HEAD) before emitting; on miss, signal
      # failure so the caller degrades — never emit a non-rendering URL.
      if ! gist_raw_url_reachable "$raw_url"; then
        return 1
      fi
      printf '%s' "$raw_url"
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Rewrite {{asset:<basename>}} tokens in the (already-sanitised) design-preview
# body to hosted `![<basename>](<url>)` lines. Reads body on stdin, writes the
# rewritten body to stdout. Because this runs in a command substitution, it
# records degradation by writing the reason to $ASSET_DEGRADED_FILE (when set)
# rather than to a parent variable — the parent reads the file afterwards. A
# tier-1/tier-2 hosting miss injects exactly one tier-3 note line. NON-BLOCKING.
_flag_degraded() {
  # $1 = reason. Record both in-subshell (for self-test direct calls) and via
  # the file side channel (for the live command-substitution call site).
  ASSET_DEGRADED_REASON="$1"
  [ -n "$ASSET_DEGRADED_FILE" ] && printf '%s' "$1" > "$ASSET_DEGRADED_FILE" 2>/dev/null || true
}
resolve_design_assets() {
  local body; body=$(cat)
  # Fast path: no tokens → return body unchanged (URL-only design-preview).
  if ! printf '%s\n' "$body" | grep -q '{{asset:'; then
    printf '%s' "$body"
    return 0
  fi
  select_host_tier
  # Tier-3 (no hosting): strip every {{asset:...}} token line, append exactly one
  # note line. Preserve all non-token lines (Figma URL + description bullets).
  if [ "$HOST_TIER" = "none" ]; then
    _flag_degraded "image_hosting_unavailable"
    printf '%s\n' "$body" \
      | LC_ALL=C awk '/^[[:space:]]*\{\{asset:[^}]+\}\}[[:space:]]*$/ { next } { print }'
    printf 'Screenshots persisted on disk; inline hosting unavailable — see designs registry.\n'
    return 0
  fi
  # Tier-1/Tier-2: substitute each token with a hosted image line. If a single
  # asset cannot be hosted (missing on disk, host_one_asset fails), drop its
  # token line and flag degradation, but keep going for the rest (best effort).
  local degraded=0 line base src url
  while IFS= read -r line; do
    case "$line" in
      *'{{asset:'*'}}'*)
        # Extract basename between {{asset: and }}.
        base=$(printf '%s' "$line" | sed -n 's/.*{{asset:\([^}]*\)}}.*/\1/p')
        if [ -z "$base" ]; then printf '%s\n' "$line"; continue; fi
        src=$(resolve_asset_path "$base" || true)
        if [ -z "$src" ]; then degraded=1; continue; fi   # no file → drop token
        url=$(host_one_asset "$base" "$src" || true)
        if [ -z "$url" ]; then degraded=1; continue; fi    # host failed → drop
        printf '![%s](%s)\n' "$base" "$url"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done <<EOF
$body
EOF
  if [ "$degraded" = "1" ]; then
    _flag_degraded "image_hosting_unavailable"
    printf 'Screenshots persisted on disk; inline hosting unavailable — see designs registry.\n'
  fi
  return 0
}

# Prefixes $1 with $EXTERNAL_TICKET unless already prefixed (case-insensitive,
# `-`/space/`:` accepted as separator). Shared by TITLE and TITLE_LEGACY so the
# legacy dedup probe carries the same prefix the live title would have.
_apply_ticket_prefix() {
  local t="$1"
  [ -n "$EXTERNAL_TICKET" ] || { printf '%s' "$t"; return 0; }
  local t_lc tkt_lc
  t_lc=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  tkt_lc=$(printf '%s' "$EXTERNAL_TICKET" | tr '[:upper:]' '[:lower:]')
  case "$t_lc" in
    "$tkt_lc" | "$tkt_lc "* | "$tkt_lc:"* | "$tkt_lc-"*) printf '%s' "$t" ;;
    *) printf '%s %s' "$EXTERNAL_TICKET" "$t" ;;
  esac
}

# Library mode: attach-visual-evidence.sh sources this file for the tier logic.
[ "${PUBLISH_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ---------- entrypoint ------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  # Sourced HERE, not at the top: the harness is ~1.1k lines the publish path
  # never runs. `[ -r ]` first, not a bare `.`: sourcing a missing file with the
  # `.` builtin is a special-builtin error that exits the shell immediately,
  # bypassing an `if ! . …` guard entirely.
  SELFTEST_LIB_PATH="${SCRIPT_DIR}/publish-pl-issue-selftest.sh"
  if [ -r "$SELFTEST_LIB_PATH" ]; then
    # shellcheck source=publish-pl-issue-selftest.sh
    # shellcheck disable=SC1090
    . "$SELFTEST_LIB_PATH"
  else
    printf >&2 'publish-pl-issue: self-test harness unreachable at %s — plugin install broken\n' \
      "$SELFTEST_LIB_PATH"
    exit 2
  fi
  run_self_tests || exit 2
  exit 0
fi

# Catastrophic-pre-flight: jq required for audit + state I/O.
command -v jq >/dev/null 2>&1 || { echo "publish-pl-issue: jq not found" >&2; exit 1; }
mkdir -p "$LOG_DIR" 2>/dev/null || fatal "audit_dir_unwritable"
[ -r "$STATE_FILE" ] || fatal "state_corrupt"
jq -e . "$STATE_FILE" >/dev/null 2>&1 || fatal "state_corrupt"

# Pull worktask context.
WORKTASK_ID=$(corpflow_worktask_id "$STATE_FILE")
RUN_INDEX=$(corpflow_run_index "$STATE_FILE")
PLAN_FILE=$(jq -r '.plan_file // ""' "$STATE_FILE")
# Two legal shapes reach this field (see the plan_file shape boundary in the header):
# a workspace-relative path, or a bare basename written from the task-metadata
# convention. Resolve the second against the state file's own directory — the same
# fallback ISSUE_ANCHOR performs above. PLAN_CANDIDATES feeds the fatal diagnostic.
PLAN_CANDIDATES="${PLAN_FILE:-<empty .plan_file>}"
if [ -n "$PLAN_FILE" ] && [ ! -r "$PLAN_FILE" ]; then
  _plan_alt="$(dirname "$STATE_FILE")/$(basename "$PLAN_FILE")"
  PLAN_CANDIDATES="$PLAN_FILE, $_plan_alt"
  [ -r "$_plan_alt" ] && PLAN_FILE="$_plan_alt"
fi
DEDUPE_KEY="$WORKTASK_ID:$RUN_INDEX:gh_issue"

# Strict mode: CLI --strict wins; else read metadata.gh_issue.strict from state.
# Default unchanged: STRICT=0 (non-blocking, preserves fixtures 01-05 behaviour).
if [ "$STRICT" != "1" ] && [ "$STRICT" != "true" ]; then
  STATE_STRICT=$(jq -r '.metadata.gh_issue.strict // false' "$STATE_FILE" 2>/dev/null)
  if [ "$STATE_STRICT" = "true" ]; then STRICT=1; fi
fi

# Guard 1: opt-out via env override, or the flag on this run's PL task (where
# /worktask Step 4 stamps it). The run-level key is read too, so a ledger that sets
# it there still opts out.
NO_GH=$(jq -r --arg pl "PL${RUN_INDEX:-0}" \
  '(.tasks[$pl].metadata.no_gh_issue // .tasks.PL0.metadata.no_gh_issue // .metadata.no_gh_issue // false)' \
  "$STATE_FILE" 2>/dev/null)
if [ "${NO_GH_ISSUE:-${NO_GH}}" = "true" ]; then
  defer "opted_out"
fi

# Guard 2: idempotency + cross-run dedup. Resolve the canonical issue for this
# .context from the run-independent anchor (or the same-run state url). Created in
# THIS run → already published (defer). Created in an EARLIER run → comment on it
# instead of opening a duplicate (COMMENT_MODE, executed at the publish branch once
# the body is built). No local hit → COMMENT_MODE stays 0; a GitHub-side search may
# still recover a lost anchor after the title is built. See skills/gh-issue-dedup.
COMMENT_MODE=0
EXISTING_ISSUE_URL=""
EXISTING_ISSUE_SOURCE=""
if resolve_context_issue_local; then
  if [ "${RESOLVED_ISSUE_CREATED_RUN:-0}" -lt "${RUN_INDEX:-0}" ] 2>/dev/null; then
    COMMENT_MODE=1
    EXISTING_ISSUE_URL="$RESOLVED_ISSUE_URL"
    EXISTING_ISSUE_SOURCE="$RESOLVED_ISSUE_SOURCE"
  else
    defer "already_published"
  fi
fi

# Guard 2.5: milestone-mode — skip GH publish entirely (no create, no comment).
# The parent milestone issue is the canonical record; auto-posting plan-approval
# comments would fragment the review surface. PR linkage (FN stage or manual)
# ties the implementation back to the milestone.
if is_milestone_mode; then
  defer "milestone_mode"
fi

# Guard 3: gh binary present.
command -v "$GH_BIN" >/dev/null 2>&1 || defer "gh_not_installed"

# Guard 4: gh auth.
if [ "$DRY_RUN" != "1" ]; then
  "$GH_BIN" auth status >/dev/null 2>&1 || defer "auth_missing"
fi

# Guard 5: remote present.
if [ "$DRY_RUN" != "1" ]; then
  git remote get-url origin 2>/dev/null | grep -q . || defer "no_remote"
fi

# Plan readable?
[ -r "$PLAN_FILE" ] || {
  FATAL_DETAIL="plan unreadable; tried: $PLAN_CANDIDATES"
  fatal "plan_unreadable"
}

# ---------- extract + sanitise + render -------------------------------------
# Title and Summary resolve through INDEPENDENT chains. They shared one source
# (`facts.goal`) until issue #375: `facts.goal` is OPTIONAL in the handoff protocol —
# written only when the PM agent patches state.json, so orchestrator-inline seeding, a
# hand-authored `.context/`, or a regenerated state leaves it unset — and one empty
# value then corrupted BOTH the title (silently, to the kebab worktask slug) and the
# `## Summary` section (to empty) in the same run.
GOAL_RAW=$(jq -r '.facts.goal // ""' "$STATE_FILE")
FM_TITLE=$(extract_frontmatter_field "$PLAN_FILE" "title")
FM_ISSUE=$(extract_frontmatter_field "$PLAN_FILE" "issue")
PLAN_H1=$(extract_first_h1 "$PLAN_FILE")
SUMMARY_ANCHOR=$(extract_anchor "$PLAN_FILE" "summary")
if [ -z "$(printf '%s' "$SUMMARY_ANCHOR" | tr -d '[:space:]')" ]; then
  SUMMARY_ANCHOR=$(extract_anchor "$PLAN_FILE" "problem")
fi

# Summary body chain: facts.goal → `## summary` → `## problem`. The worktask slug is
# deliberately NOT a rank here — an empty section is honest, a slug posing as prose
# is not.
SUMMARY_RAW="$GOAL_RAW"
if [ -z "$SUMMARY_RAW" ]; then SUMMARY_RAW="$SUMMARY_ANCHOR"; fi

# Title chain, first non-empty wins. TITLE_SOURCE names the winning rank and is
# carried into the audit row so a degraded title is visible rather than silent.
TITLE_SOURCE="facts_goal"
TITLE_RAW="$GOAL_RAW"
if [ -z "$TITLE_RAW" ]; then TITLE_SOURCE="plan_frontmatter_title"; TITLE_RAW="$FM_TITLE"; fi
if [ -z "$TITLE_RAW" ]; then TITLE_SOURCE="plan_h1"; TITLE_RAW="$PLAN_H1"; fi
if [ -z "$TITLE_RAW" ]; then
  TITLE_SOURCE="plan_summary_anchor"
  TITLE_RAW=$(printf '%s\n' "$SUMMARY_ANCHOR" | first_sentence)
fi
if [ -z "$TITLE_RAW" ]; then TITLE_SOURCE="worktask_id"; TITLE_RAW="$WORKTASK_ID"; fi

# AC-2: external-ticket extraction. Match ^[A-Z][A-Z0-9]+-[0-9]+ in the goal first,
# then whichever source won the title, then the plan's frontmatter `issue:`, then
# upper-cased WORKTASK_ID. Every rank feeds the same no-double-prefix guard below.
EXTERNAL_TICKET=$(extract_external_ticket "$GOAL_RAW")
if [ -z "$EXTERNAL_TICKET" ]; then
  EXTERNAL_TICKET=$(extract_external_ticket "$TITLE_RAW")
fi
if [ -z "$EXTERNAL_TICKET" ]; then
  EXTERNAL_TICKET=$(extract_external_ticket "$(printf '%s' "$FM_ISSUE" | tr '[:lower:]' '[:upper:]')")
fi
if [ -z "$EXTERNAL_TICKET" ]; then
  EXTERNAL_TICKET=$(extract_external_ticket "$(printf '%s' "$WORKTASK_ID" | tr '[:lower:]' '[:upper:]')")
fi
if [ -n "$EXTERNAL_TICKET" ]; then
  write_state_external_ticket "$EXTERNAL_TICKET" || true
fi
REQS_RAW=$(extract_anchor "$PLAN_FILE" "requirements")
ACS_RAW=$(extract_anchor "$PLAN_FILE" "acceptance-criteria")
SCOPE_RAW=$(extract_anchor "$PLAN_FILE" "scope")
COMPLEXITY_RAW=$(extract_anchor "$PLAN_FILE" "complexity")
# Optional: design-preview anchor (Figma URL captured at PL). Excluded from
# strip-ratio denominator to avoid skewing the guard with short URL bodies.
DESIGN_RAW=$(extract_anchor "$PLAN_FILE" "design-preview")

SUMMARY_S=$(printf '%s\n' "$SUMMARY_RAW" | sanitise_body)
REQS_S=$(printf '%s\n' "$REQS_RAW" | sanitise_body)
ACS_S=$(printf '%s\n' "$ACS_RAW" | sanitise_body)
SCOPE_S=$(printf '%s\n' "$SCOPE_RAW" | sanitise_body)
COMPLEXITY_S=$(printf '%s\n' "$COMPLEXITY_RAW" | sanitise_body)
DESIGN_S=$(printf '%s\n' "$DESIGN_RAW" | sanitise_body)

# Host-and-rewrite (Figma image embed): resolve {{asset:<basename>}} placeholder
# tokens in the already-sanitised design-preview body to hosted ![alt](url) image
# lines. This runs AFTER sanitise_body (so the image lines never face Pass-1 L1)
# and is fully non-blocking — any hosting failure degrades to a URL-only note.
# When the anchor carries no tokens (URL-only design-preview, e.g. fixture 09),
# resolve_design_assets returns the body unchanged. design-preview is excluded
# from the strip-ratio denominator below (R5), so the rewrite cannot perturb it.
# resolve_design_assets runs in a subshell (command substitution), so it reports
# degradation through ASSET_DEGRADED_FILE rather than a parent variable.
ASSET_DEGRADED_FILE="$LOG_DIR/.asset-degraded.$$"
: > "$ASSET_DEGRADED_FILE" 2>/dev/null || ASSET_DEGRADED_FILE=""
DESIGN_EMBED=$(printf '%s' "$DESIGN_S" | resolve_design_assets)
if [ -n "$ASSET_DEGRADED_FILE" ] && [ -s "$ASSET_DEGRADED_FILE" ]; then
  ASSET_DEGRADED_REASON=$(cat "$ASSET_DEGRADED_FILE" 2>/dev/null || echo "")
fi
[ -n "$ASSET_DEGRADED_FILE" ] && rm -f "$ASSET_DEGRADED_FILE" 2>/dev/null || true

# Strip-ratio check against the four required anchor bodies only.
# (stages anchor is consumed by the orchestrator from the plan file but no
# longer rendered into the published body; design-preview is optional and a
# short URL — both excluded from the denominator on purpose.)
ORIG_TOTAL=$(printf '%s%s%s%s' "$REQS_RAW" "$ACS_RAW" "$SCOPE_RAW" "$COMPLEXITY_RAW" | wc -c)
SAN_TOTAL=$(printf '%s%s%s%s' "$REQS_S" "$ACS_S" "$SCOPE_S" "$COMPLEXITY_S" | wc -c)
# Fallback: when the plan has none of the expected anchor headings, anchor-extracted
# bytes are zero — fall back to whole-file byte length so a near-empty body still
# trips the strip-ratio guard instead of being silently published. Matches the
# --self-test behaviour for fixture 03-mostly-paths.md. (T4 remediation, DV0.1)
if [ "$ORIG_TOTAL" -eq 0 ]; then
  ORIG_TOTAL=$(wc -c < "$PLAN_FILE" 2>/dev/null || echo 0)
  PLAN_SAN=$(sanitise_body < "$PLAN_FILE" 2>/dev/null | wc -c)
  SAN_TOTAL="$PLAN_SAN"
fi
STRIP_PCT=0
if [ "$ORIG_TOTAL" -gt 0 ]; then
  STRIP_PCT=$(( (ORIG_TOTAL - SAN_TOTAL) * 100 / ORIG_TOTAL ))
fi
if [ "$STRIP_PCT" -gt 50 ]; then
  ABORT_TMP="$LOG_DIR/issue-body-${RUN_INDEX}.aborted.tmp"
  {
    printf '%s\n\n' "$SUMMARY_S"
    printf '## Requirements\n%s\n\n' "$REQS_S"
    printf '## Acceptance Criteria\n%s\n\n' "$ACS_S"
    printf '## Scope\n%s\n\n' "$SCOPE_S"
    if [ -n "$(printf '%s' "$DESIGN_EMBED" | tr -d '[:space:]')" ]; then
      printf '## Design Preview\n%s\n\nCompare implementation (DV) and screenshots (QA) against this design.\n\n' "$DESIGN_EMBED"
    fi
    printf '## Complexity\n%s\n' "$COMPLEXITY_S"
  } > "$ABORT_TMP" 2>/dev/null || true
  audit_row "deferred" "$(jq -cn --arg v "publish-pl-issue.sh" --arg r "sanitiser_aborted" --argjson sp "$STRIP_PCT" --arg dk "$DEDUPE_KEY" --arg path "$ABORT_TMP" '{via:$v, reason:$r, strip_ratio:$sp, aborted_body:$path, dedupe_key:$dk}')" || true
  exit 0
fi

# Mode is implicit "create" — milestone mode short-circuited above (Guard 2.5).
MODE="create"

# Complexity-tier label (read from facts.decisions or planning § complexity heading).
# Parenthesised first — "(Critical)" is the shape the templates emit — then the
# bare word, because PM prose legitimately writes "Score: 46 / 50 — Critical
# tier." with no parens. Requiring parens made that miss, and the silent default
# below then labelled a 46/50 critical plan `complexity:moderate` — the amber
# label, on the run's highest-risk issue, with nothing in the audit trail to
# show a match had failed. The bare-word arm is anchored on a word boundary so
# it cannot fire on "critically" or a word inside an unrelated sentence.
TIER=$(printf '%s' "$COMPLEXITY_S" | grep -oiE '\((Low|Medium|Moderate|High|Critical)\)' | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '()')
if [ -z "$TIER" ]; then
  TIER=$(printf '%s' "$COMPLEXITY_S" \
    | grep -oiE '(^|[^[:alnum:]])(Low|Medium|Moderate|High|Critical)([[:space:]]+tier|[^[:alnum:]]|$)' \
    | grep -oiE 'Low|Medium|Moderate|High|Critical' | head -1 | tr '[:upper:]' '[:lower:]')
fi
# A silent default is what made the mislabel invisible. Keep the default — a
# missing label must never block publication — but record that it was applied,
# so the discrepancy is greppable instead of indistinguishable from a real match.
if [ -z "$TIER" ]; then
  TIER="moderate"
  printf 'publish-pl-issue: no complexity tier found in the plan; defaulting to "moderate"\n' >&2
fi

# Render body via heredoc.
BODY_TMP="$LOG_DIR/issue-body-${RUN_INDEX}.tmp"
{
  printf '## Summary\n%s\n\n' "$SUMMARY_S"
  printf '## Requirements\n%s\n\n' "$REQS_S"
  printf '## Acceptance Criteria\n%s\n\n' "$ACS_S"
  printf '## Scope\n%s\n\n' "$SCOPE_S"
  if [ -n "$(printf '%s' "$DESIGN_EMBED" | tr -d '[:space:]')" ]; then
    printf '## Design Preview\n%s\n\nCompare implementation (DV) and screenshots (QA) against this design.\n\n' "$DESIGN_EMBED"
  fi
  printf '## Complexity\n%s\n\n' "$COMPLEXITY_S"
  printf -- '---\n*Plan approved on %s. Tracking continues in worktask run #%s.*\n' "$(date -u +%F)" "$RUN_INDEX"
} > "$BODY_TMP" 2>/dev/null || fatal "audit_dir_unwritable"

# REQ-5: if asset hosting degraded below tier-1, append a non-blocking audit row
# recording the reason. Use a distinct dedupe key suffix so this advisory row
# never masks the canonical github_issue_created outcome during audit dedupe.
# The body already carries the URL-only note; publish is never blocked.
if [ -n "$ASSET_DEGRADED_REASON" ]; then
  audit_row "deferred" "$(jq -cn --arg v "publish-pl-issue.sh" --arg r "$ASSET_DEGRADED_REASON" --arg dk "${DEDUPE_KEY}:asset_hosting" '{via:$v, reason:$r, dedupe_key:$dk}')" || true
fi

# Title (sanitised — TITLE_RAW resolved by the chain above). The head/sanitise/cap
# pipeline applies to every rank of that chain: a multi-line frontmatter value or a
# long H1 is flattened, sanitised, then capped at a word boundary. Sanitising runs
# BEFORE the cap — it can shorten the line, and the cap is what must land at <=100.
TITLE=$(printf '%s' "$TITLE_RAW" | head -1 | sanitise_body | tr -d '\n' | title_cap_word_boundary 100)
[ -z "$TITLE" ] && TITLE="Plan approved: $WORKTASK_ID"

# Legacy fixed-100 form of the same TITLE_RAW, kept only to widen the recovery
# search below to an issue still titled under the pre-word-boundary scheme.
TITLE_LEGACY=$(printf '%s' "$TITLE_RAW" | title_legacy_cut)
[ -z "$TITLE_LEGACY" ] && TITLE_LEGACY="Plan approved: $WORKTASK_ID"

# AC-2: ensure title starts with EXTERNAL_TICKET prefix. Skip if already prefixed
# (avoid double-prefix like "OV-113 OV-113 …"). Compared case-INsensitively and with
# `-` accepted as a separator: the slug-fallback rank yields "ov-164-catalog-…",
# which an exact-case check treats as unprefixed and turns into the reported
# "OV-164 ov-164-catalog-…". Applied to TITLE_LEGACY too, so the recovery probe
# below matches what a prefixed old-scheme issue title would actually look like.
TITLE=$(_apply_ticket_prefix "$TITLE")
TITLE_LEGACY=$(_apply_ticket_prefix "$TITLE_LEGACY")

# Degradation is recorded, not silent: reaching the slug rank means every prose
# source was empty and the published title is a kebab id. Distinct dedupe-key suffix
# so this advisory never masks the canonical github_issue_created outcome. Never
# blocks — a title is not worth failing a worktask over.
if [ "$TITLE_SOURCE" = "worktask_id" ]; then
  audit_row "deferred" "$(jq -cn --arg v "publish-pl-issue.sh" --arg r "title_fallback_worktask_id" \
    --arg ts "$TITLE_SOURCE" --arg dk "${DEDUPE_KEY}:title_source" \
    '{via:$v, reason:$r, title_source:$ts, dedupe_key:$dk}')" || true
fi

# Guard 2 (recovery half): no local anchor resolved → try a GitHub-side search to
# recover a lost .context ↔ issue binding (fresh clone / regenerated state). Needs
# the finalised TITLE. On an exact-title single hit, comment instead of create.
if [ "$COMMENT_MODE" != "1" ] && resolve_context_issue_search; then
  COMMENT_MODE=1
  EXISTING_ISSUE_URL="$RESOLVED_ISSUE_URL"
  EXISTING_ISSUE_SOURCE="$RESOLVED_ISSUE_SOURCE"
fi

# AC-1 + AC-2: build the canonical label list and auto-provision missing ones.
CANONICAL_LABELS="worktask planning-approved complexity:$TIER"
if [ -n "$EXTERNAL_TICKET" ]; then
  CANONICAL_LABELS="$CANONICAL_LABELS ticket:$EXTERNAL_TICKET"
fi
if [ "$DRY_RUN" != "1" ] && [ "$COMMENT_MODE" != "1" ]; then
  # shellcheck disable=SC2086
  ensure_labels $CANONICAL_LABELS
fi

# Filter out dropped labels (those that failed to auto-create) from the
# argument passed to `gh issue create`. Preserve original order.
SURVIVING_LABELS=""
for _l in $CANONICAL_LABELS; do
  _dropped=0
  for _d in $DROPPED_LABELS; do
    [ "$_l" = "$_d" ] && _dropped=1 && break
  done
  if [ "$_dropped" -eq 0 ]; then
    SURVIVING_LABELS="${SURVIVING_LABELS}${SURVIVING_LABELS:+,}${_l}"
  fi
done

# Invoke gh — create a NEW issue, or (cross-run) COMMENT on the existing one.
# Milestone mode skipped above. Comment path: a subsequent worktask in the same
# .context/ appends a marker-deduped plan summary instead of opening a duplicate.
URL=""
GH_OUT=""
if [ "$COMMENT_MODE" = "1" ]; then
  PLAN_MARKER="<!-- worktask-plan:$WORKTASK_ID:$RUN_INDEX -->"
  COMMENT_TMP="$LOG_DIR/issue-comment-${RUN_INDEX}.tmp"
  {
    printf '%s\n' "$PLAN_MARKER"
    printf '## Follow-up worktask — run #%s\n\n' "$RUN_INDEX"
    cat "$BODY_TMP"
  } > "$COMMENT_TMP" 2>/dev/null || fatal "audit_dir_unwritable"
  if [ "$DRY_RUN" = "1" ]; then
    URL="$EXISTING_ISSUE_URL"
    echo "DRY_RUN: $GH_BIN issue comment $EXISTING_ISSUE_URL --body-file $COMMENT_TMP" >&2
  else
    # Idempotency: this run already commented (marker present) → do not double-post.
    if pl_issue_has_marker "$EXISTING_ISSUE_URL" "$PLAN_MARKER"; then
      defer "comment_already_present"
    fi
    if CMT_OUT=$("$GH_BIN" issue comment "$EXISTING_ISSUE_URL" --body-file "$COMMENT_TMP" 2>&1); then
      URL="$EXISTING_ISSUE_URL"
    else
      CMT_REASON=$(classify_gh_failure "$CMT_OUT")
      CMT_FAIL=$(jq -cn --arg v "publish-pl-issue.sh" --arg r "$CMT_REASON" --arg url "$EXISTING_ISSUE_URL" --arg src "$EXISTING_ISSUE_SOURCE" --arg dk "$DEDUPE_KEY" \
        '{via:$v, mode:"comment", reason:$r, url:$url, resolved_via:$src, dedupe_key:$dk}')
      if [ "$STRICT" = "1" ] || [ "$STRICT" = "true" ]; then
        audit_row "failed" "$CMT_FAIL" || true
        exit 1
      fi
      audit_row "deferred" "$CMT_FAIL" || true
      exit 0
    fi
  fi
  # Persist/refresh the run-independent anchor so future runs resolve locally.
  if [ "$EXISTING_ISSUE_SOURCE" = "anchor" ]; then
    bump_anchor_commented "$RUN_INDEX" || true
  else
    write_context_issue "$EXISTING_ISSUE_URL" "${RESOLVED_ISSUE_NUMBER:-$(printf '%s' "$EXISTING_ISSUE_URL" | grep -oE '[0-9]+$')}" || true
  fi
  CMT_META=$(jq -cn --arg v "publish-pl-issue.sh" --arg url "$URL" --arg tier "$TIER" --argjson sp "$STRIP_PCT" --arg src "$EXISTING_ISSUE_SOURCE" --arg dk "$DEDUPE_KEY" \
    '{via:$v, mode:"comment", url:$url, complexity_tier:$tier, sanitiser_stripped_pct:$sp, resolved_via:$src, dedupe_key:$dk}')
  audit_row "ok" "$CMT_META" || true
  printf 'commented_url=%s\n' "$URL"
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  URL="https://github.com/dry/run/issues/0"
  echo "DRY_RUN: $GH_BIN issue create --title \"$TITLE\" --body-file $BODY_TMP --label $SURVIVING_LABELS" >&2
else
  # run_with_timeout, not a bare TIMEOUT_BIN probe: on stock macOS both binaries
  # are absent, so the old `else` arm ran this call completely unbounded.
  GH_OUT=$(run_with_timeout "$GH_TIMEOUT" "$GH_BIN" issue create --title "$TITLE" --body-file "$BODY_TMP" --label "$SURVIVING_LABELS" 2>&1) || true
  URL=$(printf '%s' "$GH_OUT" | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+' | head -1)
  if [ -z "$URL" ]; then
    # AC-3: classify failure mode from gh stderr. If labels were dropped and
    # stderr did not specifically blame a different cause, attribute to
    # label_create_failed (the most likely root cause when DROPPED_LABELS≠"").
    REASON=$(classify_gh_failure "$GH_OUT")
    if [ -n "$DROPPED_LABELS" ] && [ "$REASON" = "gh_api_error" ]; then
      REASON="label_create_failed"
    fi
    FAIL_META=$(jq -cn --arg v "publish-pl-issue.sh" --arg r "$REASON" --arg dk "$DEDUPE_KEY" \
      --arg tkt "${EXTERNAL_TICKET:-}" --arg dropped "${DROPPED_LABELS:-}" \
      '{via:$v, reason:$r, dedupe_key:$dk}
       + (if $tkt == "" then {} else {external_ticket:$tkt} end)
       + (if $dropped == "" then {} else {labels_dropped:($dropped|split(" "))} end)')
    # AC-4: strict mode blocks the worktask on operational failure.
    if [ "$STRICT" = "1" ] || [ "$STRICT" = "true" ]; then
      audit_row "failed" "$FAIL_META" || true
      exit 1
    fi
    audit_row "deferred" "$FAIL_META" || true
    exit 0
  fi
fi

# Persist URL to state.json (atomic). Audit row appended regardless of write success.
write_state_url "$URL" || true
# Persist the run-independent .context/gh-issue.json anchor so a later worktask in
# this .context/ (which re-seeds state.json) resolves this issue and comments on it
# instead of opening a duplicate. Non-fatal; state.json stays the same-run fallback.
write_context_issue "$URL" "$(printf '%s' "$URL" | grep -oE '[0-9]+$')" || true
META_JSON=$(jq -cn --arg v "publish-pl-issue.sh" --arg mode "$MODE" --arg url "$URL" --arg tier "$TIER" --argjson sp "$STRIP_PCT" --arg dk "$DEDUPE_KEY" \
  --arg tkt "${EXTERNAL_TICKET:-}" --arg dropped "${DROPPED_LABELS:-}" \
  '{via:$v, mode:$mode, url:$url, complexity_tier:$tier, sanitiser_stripped_pct:$sp, dedupe_key:$dk}
   + (if $tkt == "" then {} else {external_ticket:$tkt} end)
   + (if $dropped == "" then {} else {labels_dropped:($dropped|split(" "))} end)')
audit_row "ok" "$META_JSON" || true

# Emit single optional line for orchestrator terminal UX.
printf 'published_url=%s\n' "$URL"
exit 0
