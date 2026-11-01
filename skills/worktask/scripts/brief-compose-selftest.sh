#!/usr/bin/env bash
# brief-compose-selftest.sh — the `--self-test` harness for brief-compose.sh.
#
# SOURCED, never executed: brief-compose.sh loads this file only on the `--self-test`
# path, so the production path never pays for it. Sourcing leaves the caller's helpers
# ($0, plugin_root, etc.) in scope; this file is not standalone.
#
# Contract: defines `self_test`, which owns the exit for this invocation.

self_test() {
  local self_dir SELF td fail=0
  _SELFTEST_PASSED=0
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  SELF="$self_dir/brief-compose.sh"
  td=$(mktemp -d "${TMPDIR:-/tmp}/brief-compose-XXXXXX")
  # shellcheck disable=SC2064  # expand now: $td is local and gone by EXIT time otherwise
  trap "rm -rf '$td'" EXIT

  # extract_section <text> <marker> — the section body between <<<marker>>> and the
  # next <<<...>>> tag or EOF; mirrors cache-lint.sh's own extractor so a self-test
  # assertion reads sections the same way the prefix-lint that checks them does.
  extract_section() {
    local body="$1" marker="$2"
    awk -v m="$marker" '
      $0 == "<<<" m ">>>" { capture = 1; next }
      /^<<<.*>>>$/ && capture { exit }
      capture { print }
    ' <<< "$body"
  }

  check() {
    local label="$1"
    shift
    if "$@"; then
      printf 'ok: %s\n' "$label"
      _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
    else
      printf 'FAIL: %s\n' "$label" >&2
      fail=$((fail + 1))
    fi
  }

  # Invoked indirectly as `check "<label>" str_eq …` — shellcheck cannot trace a command
  # name passed as a plain argument, so each is a false "never invoked" positive.
  # shellcheck disable=SC2329
  str_eq() { [ "$1" = "$2" ]; }
  # shellcheck disable=SC2329
  not_grep() { ! grep -q -- "$1" <<< "$2"; }
  # shellcheck disable=SC2329
  not_grep_i() { ! grep -qi -- "$1" <<< "$2"; }
  # shellcheck disable=SC2329
  has_line() { grep -qF -- "$1" <<< "$2"; }

  # ---- refs: a DV0 fixture — every non-identifier [5] line is a resolvable ref ----
  local d1="$td/ac1"
  mkdir -p "$d1/.context"
  cat > "$d1/.context/planning-0.md" << 'EOF'
## requirements

Fixture requirement text.

## acceptance-criteria

Fixture acceptance text.
EOF
  cat > "$d1/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "agent": "system-developer:bash-developer",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d1",
        "context_refs": ["planning-0.md#requirements"]
      }
    }
  }
}
EOF
  local out1 rc1=0
  out1=$(bash "$SELF" DV0 --state "$d1/.context/state.json" --orch-root "$d1" 2>/dev/null) || rc1=$?
  check "refs: DV0 fixture composes (exit 0)" [ "$rc1" -eq 0 ]

  local sec5 line bad_line="" ref_count=0
  sec5=$(extract_section "$out1" "task-description")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      task_id:* | stage:* | agent:* | model:* | artifact:* | subject:*) continue ;;
      'ref: '*)
        ref_count=$((ref_count + 1))
        # A resolvable ref is shaped one of three ways: "path:N" (file:line),
        # "artifact#anchor", or a plain existing-file path — an empty value is the only
        # shape that is not a fact the brief actually checked.
        case "${line#ref: }" in
          *:[0-9]*)
            case "${line#ref: }" in *'#'*) bad_line="$line" ;; esac
            ;;
          *'#'*) : ;;
          '') bad_line="$line" ;;
          *) : ;;
        esac
        ;;
      *) bad_line="$line" ;;
    esac
  done <<< "$sec5"
  check "refs: every non-identifier [5] line is 'ref: ' + file:line, artifact#anchor or a plain path" [ -z "$bad_line" ]
  check "refs: [5] carries at least one ref" [ "$ref_count" -gt 0 ]

  # Each ref must be proven to RESOLVE, not merely shaped like one: brief-
  # compose.sh's own exit 0 is not evidence, since a guard bug could pass a ref it never
  # actually checked. This re-derives resolution independently, off the fixture's own
  # files, and never calls check_ref_resolves.
  local proot resolve_fail=""
  proot="$(cd "$self_dir/../../.." && pwd -P)"
  while IFS= read -r line; do
    case "$line" in
      'ref: '*)
        local rv="${line#ref: }"
        case "$rv" in
          *'#'*)
            local art="${rv%%#*}" anchor="${rv#*#}" found=0 hl
            local apath="$d1/.context/$art"
            if [ -f "$apath" ]; then
              while IFS= read -r hl; do
                if [ "$hl" = "## $anchor" ]; then
                  found=1
                  break
                fi
              done < "$apath"
            fi
            [ "$found" -eq 1 ] || resolve_fail="${resolve_fail}${rv} "
            ;;
          *:[0-9]*)
            local f="${rv%:*}" ln="${rv##*:}" n
            if [ -f "$proot/$f" ]; then
              n=$(wc -l < "$proot/$f" | tr -d ' ')
              if [ "$ln" -lt 1 ] || [ "$ln" -gt "$n" ]; then resolve_fail="${resolve_fail}${rv} "; fi
            else
              resolve_fail="${resolve_fail}${rv} "
            fi
            ;;
          *)
            # Plain-path shape: resolved by existing plugin-root-relative, under the
            # fixture's own workspace_path, or under its .context dir — the same
            # locations plain_path_exists checks in brief-compose.sh.
            if [ ! -f "$proot/$rv" ] && [ ! -f "$d1/$rv" ] && [ ! -f "$d1/.context/$rv" ]; then
              resolve_fail="${resolve_fail}${rv} "
            fi
            ;;
        esac
        ;;
    esac
  done <<< "$sec5"
  check "refs: every [5] ref independently resolves " [ -z "$resolve_fail" ]

  # ---- canon: [1] is contract-reminder.md's fenced block, byte for byte — the same
  # extraction cache-lint.sh's canonical_contract_block() uses, so a self-test pass here
  # is also a prediction that the prefix-lint's `contract_canon: true` check will pass ----
  local s1 contract_canon
  s1=$(extract_section "$out1" "contract-reminder")
  contract_canon=$(awk '
    $0 == "```text" { infence = 1; next }
    infence && $0 == "```" { exit }
    infence { print }
  ' "$proot/skills/worktask/references/contract-reminder.md")
  check "canon: [1] equals contract-reminder.md's fenced block byte for byte" \
    str_eq "$s1" "$contract_canon"

  # ---- digest: [3] is ledger-digest.sh's grammar — a pointer plus six ordered
  # keys, never the ledger JSON cache-lint.sh's ledger_digest_lint() rejects ----
  local s3 s3_keys want_keys
  s3=$(extract_section "$out1" "state-json")
  s3_keys=$(grep -oE '^[a-z_]+:' <<< "$s3" | sed 's/:$//')
  want_keys=$'ledger\nrun_index\nready\nin_progress\nblocked\nopen_blocking_questions'
  check "digest: [3] first line is the ledger pointer" \
    str_eq "$(head -1 <<< "$s3")" "ledger: .context/state.json"
  check "digest: [3] keys are exactly the six digest keys, in order" \
    str_eq "$s3_keys" "$want_keys"
  check "digest: [3] carries no inlined-JSON brace" not_grep '{' "$s3"
  check "digest: [3] carries no ledger \"tasks\" key" not_grep '"tasks"' "$s3"

  # ---- refs: stage-contracts.md's Required Inputs/Outputs headings ride in [5] as
  # resolvable refs, since [1] carries only the canon block ----
  local req_in_line req_out_line
  req_in_line=$(grep -n -m1 -E '^## Required Inputs \(handoff-protocol\)$' \
    "$proot/skills/shared/stage-contracts.md" | cut -d: -f1)
  req_out_line=$(grep -n -m1 -E '^## Required Outputs \(handoff-protocol\)$' \
    "$proot/skills/shared/stage-contracts.md" | cut -d: -f1)
  check "refs: [5] carries the Required Inputs ref" \
    has_line "ref: skills/shared/stage-contracts.md:${req_in_line}" "$sec5"
  check "refs: [5] carries the Required Outputs ref" \
    has_line "ref: skills/shared/stage-contracts.md:${req_out_line}" "$sec5"

  # ---- refs: context_refs as a JSON-encoded string (state-ledger.md's preferred
  # shape) decodes; the ref is one only context_refs can produce ----
  local d5="$td/ac1b"
  mkdir -p "$d5/.context"
  cp "$d1/.context/planning-0.md" "$d5/.context/planning-0.md"
  cat > "$d5/.context/research-0.md" << 'EOF'
## findings

Fixture findings text.
EOF
  cat > "$d5/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d5",
        "context_refs": "[\"research-0.md#findings\"]"
      }
    }
  }
}
EOF
  local out5 rc5=0
  out5=$(bash "$SELF" DV0 --state "$d5/.context/state.json" --orch-root "$d5" 2>/dev/null) || rc5=$?
  check "refs: context_refs JSON-string shape composes (exit 0)" [ "$rc5" -eq 0 ]
  check "refs: context_refs JSON-string shape decodes its ref" \
    has_line "ref: research-0.md#findings" "$out5"

  # ---- refs: a plain-path context_refs entry (the
  # consultant-return channel) is emitted only when the file exists ----
  local d6="$td/ac1c"
  mkdir -p "$d6/.context/logs"
  cp "$d1/.context/planning-0.md" "$d6/.context/planning-0.md"
  : > "$d6/.context/logs/consultant-return-DR0-x-a1.md"
  cat > "$d6/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d6",
        "context_refs": [
          ".context/logs/consultant-return-DR0-x-a1.md",
          ".context/logs/consultant-return-DR0-y-a1.md"
        ]
      }
    }
  }
}
EOF
  local out6 rc6=0
  out6=$(bash "$SELF" DV0 --state "$d6/.context/state.json" --orch-root "$d6" 2>/dev/null) || rc6=$?
  check "refs: plain-path context_refs fixture composes (exit 0)" [ "$rc6" -eq 0 ]
  check "refs: an existing plain-path context_refs entry is emitted" \
    has_line "ref: .context/logs/consultant-return-DR0-x-a1.md" "$out6"
  check "refs: a missing plain-path context_refs entry is not emitted" \
    not_grep "consultant-return-DR0-y-a1" "$out6"

  # ---- refs: a JSON-string context_refs that is not an array exits 2 ----
  local d10="$td/ac1d"
  mkdir -p "$d10/.context"
  cp "$d1/.context/planning-0.md" "$d10/.context/planning-0.md"
  cat > "$d10/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d10",
        "context_refs": "{\"a\":1}"
      }
    }
  }
}
EOF
  local out10 rc10=0
  out10=$(bash "$SELF" DV0 --state "$d10/.context/state.json" --orch-root "$d10" 2>/dev/null) || rc10=$?
  check "refs: context_refs non-array JSON string exits 2" [ "$rc10" -eq 2 ]
  check "refs: context_refs non-array JSON string prints no stdout" [ -z "$out10" ]

  # ---- refs: PL0-seeded context_refs repeating the plan refs and AR0's decisions ref
  # compose to one ref: line per value, first occurrence kept in place ----
  local d11="$td/ac1e"
  mkdir -p "$d11/.context"
  cp "$d1/.context/planning-0.md" "$d11/.context/planning-0.md"
  printf '## decisions\n\nFixture decision.\n' > "$d11/.context/architecture-0.md"
  printf '## findings\n\nFixture finding.\n' > "$d11/.context/research-0.md"
  cat > "$d11/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "AR0": {"status": "completed", "metadata": {"stage": "AR", "run_index": 0}},
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d11",
        "context_refs": ["planning-0.md#requirements", "research-0.md#findings",
          "planning-0.md#acceptance-criteria", "architecture-0.md#decisions"]
      }
    }
  }
}
EOF
  local out11 rc11=0 refs11
  out11=$(bash "$SELF" DV0 --state "$d11/.context/state.json" --orch-root "$d11" 2>/dev/null) || rc11=$?
  refs11=$(extract_section "$out11" "task-description" | grep '^ref: ' | grep -v 'stage-contracts\|^ref: agents/' || true)
  check "refs: dedup fixture composes (exit 0)" [ "$rc11" -eq 0 ]
  check "refs: no ref: line repeats in the brief" \
    str_eq "" "$(grep '^ref: ' <<< "$out11" | sort | uniq -d)"
  check "refs: first occurrences keep their relative order" \
    str_eq "$(printf 'ref: %s\n' planning-0.md#requirements planning-0.md#acceptance-criteria \
      research-0.md#findings architecture-0.md#decisions)" "$refs11"

  # ---- guard: absolute-path guard — off-root fails closed, on-root passes ----
  local d2="$td/ac2"
  mkdir -p "$d2/.context"
  cp "$d1/.context/planning-0.md" "$d2/.context/planning-0.md"
  cat > "$d2/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "agent": "system-developer:bash-developer",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d2",
        "subject": "touches /opt/elsewhere/x.md outside every allowed root"
      }
    }
  }
}
EOF
  local out2 err2 rc2=0
  err2=$(mktemp)
  out2=$(bash "$SELF" DV0 --state "$d2/.context/state.json" --orch-root "$d2" 2> "$err2") || rc2=$?
  check "guard: an off-root absolute path exits 1" [ "$rc2" -eq 1 ]
  check "guard: an off-root absolute path prints no stdout" [ -z "$out2" ]
  check "guard: an off-root absolute path names itself on stderr" grep -q '^brief-compose: ' "$err2"
  rm -f "$err2"

  local d3="$td/ac2b"
  mkdir -p "$d3/.context"
  cp "$d1/.context/planning-0.md" "$d3/.context/planning-0.md"
  cat > "$d3/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "agent": "system-developer:bash-developer",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d3",
        "subject": "touches $d3/notes/ok.md, which sits under the fixture root"
      }
    }
  }
}
EOF
  local out3 rc3=0
  out3=$(bash "$SELF" DV0 --state "$d3/.context/state.json" --orch-root "$d3" 2>/dev/null) || rc3=$?
  check "guard: a path under WORKSPACE_ROOT passes" [ "$rc3" -eq 0 ]
  check "guard: a passing compose is non-empty" [ -n "$out3" ]

  # ---- guard: /dev/null and slash-command tokens in ledger text are not absolute
  # paths, so neither is flagged off-root ----
  local d7="$td/ac2c"
  mkdir -p "$d7/.context"
  cp "$d1/.context/planning-0.md" "$d7/.context/planning-0.md"
  cat > "$d7/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d7",
        "subject": "redirects to /dev/null, then run /worktask or /corpflow:worktask"
      }
    }
  }
}
EOF
  local out7 rc7=0
  out7=$(bash "$SELF" DV0 --state "$d7/.context/state.json" --orch-root "$d7" 2>/dev/null) || rc7=$?
  check "guard: /dev/null and slash commands in ledger text pass (exit 0)" [ "$rc7" -eq 0 ]
  check "guard: /dev/null and slash commands fixture is non-empty" [ -n "$out7" ]

  # ---- guard: a workspace root containing a space and "@" is masked whole before
  # tokenising, so it is never truncated into a false off-root prefix ----
  local d8="$td/ws dir@x"
  mkdir -p "$d8/.context"
  cp "$d1/.context/planning-0.md" "$d8/.context/planning-0.md"
  cat > "$d8/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d8",
        "subject": "touches $d8/notes/ok.md, under a root with a space and @"
      }
    }
  }
}
EOF
  local out8 rc8=0
  out8=$(bash "$SELF" DV0 --state "$d8/.context/state.json" --orch-root "$d8" 2>/dev/null) || rc8=$?
  check "guard: a root containing a space and @ is not truncated (exit 0)" [ "$rc8" -eq 0 ]
  check "guard: a root containing a space and @ fixture is non-empty" [ -n "$out8" ]

  # ---- guard: a comma boundary and a stripped file:// scheme still surface an
  # off-root path instead of hiding it ----
  local d9a="$td/ac2d"
  mkdir -p "$d9a/.context"
  cp "$d1/.context/planning-0.md" "$d9a/.context/planning-0.md"
  cat > "$d9a/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d9a",
        "subject": "see the list: ,/opt/elsewhere/x.md"
      }
    }
  }
}
EOF
  local out9a rc9a=0
  out9a=$(bash "$SELF" DV0 --state "$d9a/.context/state.json" --orch-root "$d9a" 2>/dev/null) || rc9a=$?
  check "guard: a comma-prefixed off-root path exits 1" [ "$rc9a" -eq 1 ]
  check "guard: a comma-prefixed off-root path prints no stdout" [ -z "$out9a" ]

  local d9b="$td/ac2e"
  mkdir -p "$d9b/.context"
  cp "$d1/.context/planning-0.md" "$d9b/.context/planning-0.md"
  cat > "$d9b/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d9b",
        "subject": "see file:///opt/elsewhere/y.md"
      }
    }
  }
}
EOF
  local out9b rc9b=0
  out9b=$(bash "$SELF" DV0 --state "$d9b/.context/state.json" --orch-root "$d9b" 2>/dev/null) || rc9b=$?
  check "guard: a file:// off-root path exits 1" [ "$rc9b" -eq 1 ]
  check "guard: a file:// off-root path prints no stdout" [ -z "$out9b" ]

  # ---- guard: a parked sibling's blocked_on/preflight-check detail stays in the ledger
  # on disk — [3] is a digest — so its off-root path neither reaches the brief nor fails
  # DV0's compose ----
  local d11="$td/ac4a"
  mkdir -p "$d11/.context"
  cp "$d1/.context/planning-0.md" "$d11/.context/planning-0.md"
  cat > "$d11/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "metadata": {
    "preflight": {
      "version": 1,
      "result": "pass",
      "ran_at": "unknown",
      "platforms": ["systems"],
      "checks": [
        {"id": "xcrun", "kind": "toolchain", "status": "pass", "detail": "found at /opt/homebrew/bin/xcrun"}
      ],
      "tools_absent": []
    }
  },
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d11"
      }
    },
    "DV1": {
      "status": "blocked",
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d11",
        "blocked_on": {
          "kind": "user_action",
          "detail": {
            "request": "Boot the iPhone 16 simulator; capture needs a running device",
            "command": "xcrun simctl boot iPhone-16 --password=hunter2hunter2 /Users/alice/devices.json",
            "verify": "xcrun simctl list devices booted"
          },
          "resume_with": "decision_ref"
        }
      }
    }
  }
}
EOF
  local out11 rc11=0
  out11=$(bash "$SELF" DV0 --state "$d11/.context/state.json" --orch-root "$d11" 2>/dev/null) || rc11=$?
  check "guard: a parked sibling's blocked_on/preflight detail does not fail DV0 (exit 0)" [ "$rc11" -eq 0 ]
  check "guard: a parked sibling's off-root blocked_on path no longer reaches the brief" \
    not_grep "/Users/alice/devices.json" "$out11"

  # ---- guard: "**/x" and "src/*/x" globs are not off-root paths ----
  local d13="$td/ac4c"
  mkdir -p "$d13/.context"
  cp "$d1/.context/planning-0.md" "$d13/.context/planning-0.md"
  cat > "$d13/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d13",
        "subject": "globs **/Package.swift and src/*/x.md"
      }
    }
  }
}
EOF
  local out13 rc13=0
  out13=$(bash "$SELF" DV0 --state "$d13/.context/state.json" --orch-root "$d13" 2>/dev/null) || rc13=$?
  check "guard: glob text passes (exit 0)" [ "$rc13" -eq 0 ]
  check "guard: glob text fixture is non-empty" [ -n "$out13" ]

  # ---- guard: an off-root path inside "*" emphasis is still flagged ----
  local d14="$td/ac4d"
  mkdir -p "$d14/.context"
  cp "$d1/.context/planning-0.md" "$d14/.context/planning-0.md"
  cat > "$d14/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {
        "stage": "DV",
        "model": "opus",
        "run_index": 0,
        "workspace_path": "$d14",
        "subject": "see */opt/elsewhere/z.md* here"
      }
    }
  }
}
EOF
  local out14 rc14=0
  out14=$(bash "$SELF" DV0 --state "$d14/.context/state.json" --orch-root "$d14" 2>/dev/null) || rc14=$?
  check "guard: an emphasis-star off-root path exits 1" [ "$rc14" -eq 1 ]
  check "guard: an emphasis-star off-root path prints no stdout" [ -z "$out14" ]

  # ---- fan-out: a two-stream DV fan-out — refs.dev in ascending task-id order, no override text ----
  local d4="$td/ac3"
  mkdir -p "$d4/.context"
  cp "$d1/.context/planning-0.md" "$d4/.context/planning-0.md"
  cat > "$d4/.context/development-0-service.md" << 'EOF'
---
handoff:
  stage: DV
  verdict: ok
---

## files-changed

fixture body (service)
EOF
  cat > "$d4/.context/development-0-web.md" << 'EOF'
---
handoff:
  stage: DV
  verdict: ok
---

## files-changed

fixture body (web)
EOF
  cat > "$d4/.context/state.json" << EOF
{
  "worktask_id": "brief-compose-selftest",
  "plan_file": ".context/planning-0.md",
  "run_index": 0,
  "tasks": {
    "DV0": {
      "metadata": {"stage": "DV", "model": "opus", "run_index": 0, "stream": "service",
        "artifact": ".context/development-0-service.md", "workspace_path": "$d4"}
    },
    "DV1": {
      "metadata": {"stage": "DV", "model": "opus", "run_index": 0, "stream": "web",
        "artifact": ".context/development-0-web.md", "workspace_path": "$d4"}
    },
    "DR0": {
      "metadata": {"stage": "DR", "agent": "corpflow:technical-lead", "model": "opus",
        "run_index": 0, "workspace_path": "$d4"}
    }
  }
}
EOF
  local out4 rc4=0
  out4=$(bash "$SELF" DR0 --state "$d4/.context/state.json" --orch-root "$d4" 2>/dev/null) || rc4=$?
  check "fan-out: DR0 fixture composes (exit 0)" [ "$rc4" -eq 0 ]

  local dev_refs
  dev_refs=$(grep -E '^ref: development-0-(service|web)\.md#files-changed$' <<< "$out4" || true)
  local want_refs
  want_refs=$(printf 'ref: development-0-service.md#files-changed\nref: development-0-web.md#files-changed')
  check "fan-out: refs.dev is exactly service then web, in that order" str_eq "$dev_refs" "$want_refs"

  check "fan-out: no git-diff override text" not_grep_i "git diff" "$out4"
  check "fan-out: no bare development-0.md" not_grep 'development-0\.md' "$out4"
  check "fan-out: no hand-written anchor list" not_grep "Anchors:" "$out4"

  [ "$fail" -eq 0 ] || { printf 'self-test FAIL (%d passed, %d failed)\n' "$_SELFTEST_PASSED" "$fail" >&2; exit 1; }
  printf 'self-test OK (%d passed, 0 failed)\n' "$_SELFTEST_PASSED"
}
