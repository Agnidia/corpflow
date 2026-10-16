#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/doc-option-check.sh, the DC option gate.
# Every fixture is a throwaway git tree, because evidence is git's cached plus untracked,
# not-ignored file list, not the raw disk.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/doc-option-check.sh"
CONTRACTS="skills/shared/stage-contracts.md"

setup() {
  WD="$(mk_tmpworkdir)"
  T="$WD/tree"
}

tree_with() { # <path:content>...
  local args=() spec
  for spec in "$@"; do args+=(--file "$spec"); done
  mk_git_fixture --dir "$T" "${args[@]}" > /dev/null
}

check() {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" "$@"
}

# --- env vars ----------------------------------------------------------------

@test "undefined env var: exit 1, one JSON line naming kind, name, reason, doc and line" {
  tree_with 'docs/setup.md:# Setup\n\nSet `API_BIND` before start.\n'
  check --tree "$T" "$T/docs/setup.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.check == "option-exists" and .kind == "env" and .name == "API_BIND"
    and .reason == "undefined" and .doc == "docs/setup.md" and .line == 3' <<< "$output"
}

@test "stderr cites <doc>:<line>: <kind> <name> <reason> per finding" {
  tree_with 'docs/setup.md:# Setup\n\nSet `API_BIND` before start.\n'
  check --tree "$T" "$T/docs/setup.md"
  assert_failure 1
  [ "$stderr" = "docs/setup.md:3: env API_BIND undefined" ]
}

@test "defined env var: a staged script reading it makes the doc clean" {
  tree_with 'docs/setup.md:Set `API_BIND` before start.\n' \
    'bin/serve.sh:#!/bin/sh\nexec server --bind "$API_BIND"\n'
  check --tree "$T" "$T/docs/setup.md"
  assert_success
  assert_output ""
}

@test "defined env var: an in-tree markdown file outside the <doc> set is evidence" {
  tree_with 'docs/setup.md:Set `API_BIND` before start.\n' \
    'docs/reference.md:| API_BIND | listen address |\n'
  check --tree "$T" "$T/docs/setup.md"
  assert_success
  assert_output ""
}

@test "the docs under check are not evidence for each other" {
  tree_with 'docs/a.md:Set `API_BIND`.\n' 'docs/b.md:Also `API_BIND`.\n'
  check --tree "$T" "$T/docs/a.md" "$T/docs/b.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 2 ]
  jq -se 'map(.doc) == ["docs/a.md", "docs/b.md"]' <<< "$output"
}

@test "defined env var: an untracked, not-ignored script reading it makes the doc clean" {
  tree_with 'docs/setup.md:Set `API_BIND` before start.\n'
  mkdir -p "$T/app"
  printf '#!/bin/sh\nexec server --bind "$API_BIND"\n' > "$T/app/serve.sh"
  [ -z "$(git -C "$T" ls-files -- app/serve.sh)" ]
  check --tree "$T" "$T/docs/setup.md"
  assert_success
  assert_output ""
}

@test "an ignored file is not evidence" {
  tree_with 'docs/setup.md:Set `API_BIND`.\n' '.gitignore:build-out/\n'
  mkdir -p "$T/build-out"
  printf 'API_BIND=1\n' > "$T/build-out/env.sh"
  check --tree "$T" "$T/docs/setup.md"
  assert_failure 1
  jq -e '.name == "API_BIND"' <<< "$output"
}

@test "a definition only under .context/ is not evidence" {
  tree_with 'docs/setup.md:Set `API_BIND`.\n'
  mkdir -p "$T/.context"
  printf 'API_BIND=1\n' > "$T/.context/notes.md"
  # -f: a host-wide gitignore commonly lists .context, and the case needs it tracked.
  git -C "$T" add -f -- .context/notes.md
  [ -n "$(git -C "$T" ls-files -- .context/notes.md)" ]
  check --tree "$T" "$T/docs/setup.md"
  assert_failure 1
}

@test "a longer token containing the name is not evidence" {
  tree_with 'docs/setup.md:Set `API_BIND`.\n' 'bin/serve.sh:echo "$API_BIND_PORT"\n'
  check --tree "$T" "$T/docs/setup.md"
  assert_failure 1
}

@test "\$NAME and \${NAME} forms in a fenced block are extracted" {
  tree_with 'docs/run.md:```bash\necho "$DB_URL"\necho "${X}"\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  jq -se 'map(.name) == ["DB_URL", "X"] and map(.line) == [2, 3]' <<< "$output"
}

@test "a NAME assigned or exported inside the same fenced block is local, skipped" {
  tree_with 'docs/run.md:```bash\necho "$LOCAL_A"\nLOCAL_A=1\nexport LOCAL_B\necho "${LOCAL_B}"\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_success
  assert_output ""
}

@test "an assignment in one fenced block does not make a later block's reference local" {
  tree_with 'docs/run.md:```bash\nLOCAL_A=1\n```\n\n```bash\necho "$LOCAL_A"\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  jq -e '.name == "LOCAL_A" and .line == 6' <<< "$output"
}

@test "built-in host names are allowed without evidence" {
  tree_with 'docs/run.md:Uses `$HOME`, `$PATH`, `$PWD`, `$SHELL`, `$TMPDIR` and `$USER`.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_success
}

@test "a bare backticked word without an underscore is not an env var" {
  tree_with 'docs/run.md:Pass `JSON` or `TODO` here.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_success
}

# --- flags -------------------------------------------------------------------

@test "a flag on an untracked, not-ignored tree script is checked" {
  tree_with 'docs/run.md:Run `bash tools/new.sh --bogus-flag` or `tools/new.sh --real-flag`.\n'
  mkdir -p "$T/tools"
  printf 'case "$1" in --real-flag) ;; esac\n' > "$T/tools/new.sh"
  [ -z "$(git -C "$T" ls-files -- tools/new.sh)" ]
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.kind == "flag" and .name == "--bogus-flag" and .reason == "undefined"' <<< "$output"
}

@test "a flag on a staged script that no file defines is a finding" {
  tree_with 'scripts/run.sh:case "$1" in --real-flag) ;; esac\n' \
    'docs/run.md:Run `bash scripts/run.sh --bogus-flag`.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  jq -e '.check == "option-exists" and .kind == "flag" and .name == "--bogus-flag"
    and .reason == "undefined"' <<< "$output"
}

@test "a flag the staged script defines passes" {
  tree_with 'scripts/run.sh:case "$1" in --real-flag) ;; esac\n' \
    'docs/run.md:Run `./scripts/run.sh --real-flag`.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_success
  assert_output ""
}

@test "flags of an external command are skipped" {
  tree_with 'docs/run.md:Never `git commit --no-verify`.\n\n```bash\ngit push --force-with-lease\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_success
  assert_output ""
}

@test "a span with no command word checks its flag" {
  tree_with 'docs/run.md:Pass `--bogus-flag` to it.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  jq -e '.name == "--bogus-flag"' <<< "$output"
}

@test "a backslash continuation keeps the tree script as the flag's command word" {
  tree_with 'scripts/run.sh:echo --real-flag\n' \
    'docs/run.md:```bash\n./scripts/run.sh \\\n  --bogus-flag\ngit log \\\n  --oneline-ish\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.name == "--bogus-flag" and .line == 3' <<< "$output"
}

@test "a pipeline segment takes its own command word" {
  tree_with 'scripts/run.sh:echo --real-flag\n' \
    'docs/run.md:```bash\n./scripts/run.sh --real-flag | grep --color-mode\ngit log | ./scripts/run.sh --bogus-flag\n```\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.name == "--bogus-flag" and .line == 3' <<< "$output"
}

@test "a longer defined flag is not evidence for its prefix" {
  tree_with 'scripts/run.sh:echo --tree-root\n' 'docs/run.md:Pass `--tree`.\n'
  check --tree "$T" "$T/docs/run.md"
  assert_failure 1
}

# --- assigned-tree paths -----------------------------------------------------

@test "an absolute link outside the tree is outside" {
  tree_with 'docs/a.md:See [hosts](/etc/hosts).\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  jq -e '.check == "assigned-tree" and .kind == "path" and .name == "/etc/hosts"
    and .reason == "outside" and .line == 1' <<< "$output"
}

@test "a relative ../ escape out of the tree is outside" {
  tree_with 'docs/a.md:See [x](../../escape.md).\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  jq -e '.reason == "outside" and .name == "../../escape.md"' <<< "$output"
}

@test "an in-tree link or backticked path to an absent file is missing" {
  tree_with 'docs/a.md:See [x](gone.md) and `docs/also-gone.md`.\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  jq -se 'map(.reason) == ["missing", "missing"]
    and (map(.name) | sort) == ["docs/also-gone.md", "gone.md"]' <<< "$output"
}

@test "existing in-tree files and directories pass, fragment stripped" {
  tree_with 'docs/a.md:See [b](b.md#usage), [up](../README.md) and `scripts/`.\n' \
    'docs/b.md:# b\n' 'README.md:# r\n' 'scripts/run.sh:echo\n'
  check --tree "$T" "$T/docs/a.md"
  assert_success
  assert_output ""
}

@test "schemes, mailto: and fragment-only links are skipped" {
  tree_with 'docs/a.md:[w](https://example.com/x) [m](mailto:a@b.c) [f](#top) `https://example.com/y`\n'
  check --tree "$T" "$T/docs/a.md"
  assert_success
}

@test "backticked tokens with placeholders, globs or whitespace are not paths" {
  tree_with 'docs/a.md:`skills/<name>/x` `tests/*.bats` `a/{b,c}` `$HOME/y` `git diff a/b` `.context/state.json`\n'
  check --tree "$T" "$T/docs/a.md"
  assert_success
}

@test "backticked git refs, slugs, hosts, ellipses and regex fragments are not paths" {
  tree_with 'docs/a.md:`origin/develop` `refs/heads/x` `Agnidia/corpflow` `github.com/Agnidia/x` `skills/...` `(a)/b` `^docs/[a-z]+` `a|b/c`\n'
  check --tree "$T" "$T/docs/a.md"
  assert_success
  assert_output ""
}

@test "a missing in-tree path is still a finding next to the skipped tokens" {
  tree_with 'docs/a.md:`origin/develop` `docs/gone.md` `docs/gonedir` `Agnidia/corpflow`\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [[ "$output" == *'"name":"docs/gone.md"'* && "$output" == *'"name":"docs/gonedir"'* ]]
}

@test "a JSON-hostile path token is escaped, not emitted raw" {
  # mk_git_fixture writes through printf %b, which turns this \\ into one backslash.
  tree_with 'docs/a.md:See `docs/a"b\\c/d.md`.\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  run jq -r '.name' <<< "$output"
  assert_output 'docs/a"b\c/d.md'
}

# --- trees, allow-list, exit codes ---------------------------------------------

@test "two trees: a name defined only in the second passes" {
  local T2="$WD/second"
  tree_with 'docs/a.md:Set `API_BIND`.\n'
  mk_git_fixture --dir "$T2" --file 'bin/serve.sh:echo "$API_BIND"\n' > /dev/null
  check --tree "$T" --tree "$T2" "$T/docs/a.md"
  assert_success
  assert_output ""
}

@test "--allow suppresses a host-provided env var and flag" {
  tree_with 'docs/a.md:Set `GITHUB_TOKEN` and pass `--print`.\n'
  check --tree "$T" --allow GITHUB_TOKEN --allow --print "$T/docs/a.md"
  assert_success
  assert_output ""
}

# --- --allow-path ------------------------------------------------------------

@test "--allow-path exempts an exact runtime path; another missing path is still one finding" {
  tree_with 'README.md:Saves under `./.tictactoe/`.\n'
  check --tree "$T" --allow-path .tictactoe "$T/README.md"
  assert_success
  assert_output ""
  printf 'Saves under `./.tictactoe/`.\nSee `docs/gone.md`.\n' > "$T/README.md"
  check --tree "$T" --allow-path .tictactoe "$T/README.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '.name == "docs/gone.md" and .reason == "missing"' <<< "$output"
}

@test "--allow-path exempts a descendant and normalizes ./ and a trailing /" {
  tree_with 'README.md:See `var/cache/run.db` and [log](var/log/a.txt).\n'
  check --tree "$T" --allow-path ./var/ "$T/README.md"
  assert_success
  assert_output ""
}

@test "--allow-path is a path prefix by segment, not by string" {
  tree_with 'README.md:See `variant/x.md`.\n'
  check --tree "$T" --allow-path var "$T/README.md"
  assert_failure 1
  jq -e '.name == "variant/x.md"' <<< "$output"
}

@test "--allow-path never suppresses an outside finding, an env var or a flag" {
  tree_with 'docs/a.md:See [x](/etc/hosts), set `API_BIND`, pass `--print`.\n'
  check --tree "$T" --allow-path etc --allow-path API_BIND --allow-path print "$T/docs/a.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" == *'"reason":"outside"'* && "$output" == *'"name":"API_BIND"'* && "$output" == *'"name":"--print"'* ]]
}

@test "--allow-path validates the normalized value: .//x is absolute and exits 2" {
  tree_with 'docs/a.md:x\n'
  check --tree "$T" --allow-path .//x "$T/docs/a.md"
  assert_failure 2
  [[ "$stderr" == *"must be tree-relative: .//x"* ]]
}

@test "--allow-path canonicalizes inner // and /./, so a//b and a/./b match a/b" {
  tree_with 'README.md:See `a/b/run.db`.\n'
  local v
  for v in a//b a/./b a/.//b/. ; do
    check --tree "$T" --allow-path "$v" "$T/README.md"
    assert_success
    assert_output ""
  done
}

@test "--allow-path rejects a broad value with exit 2" {
  tree_with 'docs/a.md:x\n'
  local v
  for v in '' . ./ /abs a/../b ..; do
    check --tree "$T" --allow-path "$v" "$T/docs/a.md"
    assert_failure 2
  done
  check --tree "$T" --allow-path
  assert_failure 2
}

@test "a missing git-ignored path keeps its finding and gets the runtime hint on stderr" {
  tree_with '.gitignore:.tictactoe/\n' 'README.md:Saves under `./.tictactoe/`.\n'
  check --tree "$T" "$T/README.md"
  assert_failure 1
  [ "${#lines[@]}" -eq 1 ]
  jq -e '. == {"check":"assigned-tree","kind":"path","name":"./.tictactoe/","doc":"README.md","line":1,"reason":"missing"}' <<< "$output"
  [[ "$stderr" == *"README.md:1: path ./.tictactoe/ is git-ignored; if the code creates it at runtime, re-run with --allow-path .tictactoe"* ]]
}

@test "a missing path that is not ignored gets no runtime hint" {
  tree_with 'README.md:See `docs/gone.md`.\n'
  check --tree "$T" "$T/README.md"
  assert_failure 1
  [[ "$stderr" != *"git-ignored"* ]]
}

@test "an unresolvable tree exits 3 with empty stdout" {
  tree_with 'docs/a.md:x\n'
  check --tree "$WD/no-such-dir" "$T/docs/a.md"
  assert_failure 3
  assert_output ""
}

@test "a directory that is not a git work tree exits 3" {
  local plain="$WD/plain"
  mkdir -p "$plain"
  tree_with 'docs/a.md:x\n'
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" --tree "$plain" "$T/docs/a.md"
  assert_failure 3
}

@test "an unreadable doc exits 3 before any finding is printed" {
  tree_with 'docs/a.md:Set `API_BIND`.\n'
  check --tree "$T" "$T/docs/a.md" "$T/docs/absent.md"
  assert_failure 3
  assert_output ""
}

@test "usage errors exit 2" {
  tree_with 'docs/a.md:x\n'
  check --tree "$T"
  assert_failure 2
  check --tree
  assert_failure 2
  check --bogus "$T/docs/a.md"
  assert_failure 2
}

@test "-h prints the header and exits 0" {
  run bash "$PLUGIN_ROOT/$SCRIPT" -h
  assert_success
  assert_output --partial "doc-option-check.sh"
  assert_output --partial "--tree"
}

@test "no --tree: state.json .metadata.workspace_path names the tree" {
  tree_with 'docs/a.md:Set `API_BIND`.\n'
  mkdir -p "$WD/ctx"
  jq -n --arg p "$T" '{metadata: {workspace_path: $p}}' > "$WD/ctx/state.json"
  run --separate-stderr env CONTEXT_DIR="$WD/ctx" bash "$PLUGIN_ROOT/$SCRIPT" "$T/docs/a.md"
  assert_failure 1
  jq -e '.doc == "docs/a.md"' <<< "$output"
}

@test "no --tree and no workspace_path: \$WORKSPACE_ROOT names the tree" {
  tree_with 'docs/a.md:ok\n'
  mkdir -p "$T/.context"
  run --separate-stderr env WORKSPACE_ROOT="$T" bash "$PLUGIN_ROOT/$SCRIPT" "$T/docs/a.md"
  assert_success
}

@test "no --tree resolvable at all exits 3" {
  tree_with 'docs/a.md:ok\n'
  mkdir -p "$WD/empty-ctx"
  run --separate-stderr env CONTEXT_DIR="$WD/empty-ctx" bash "$PLUGIN_ROOT/$SCRIPT" "$T/docs/a.md"
  assert_failure 3
  assert_output ""
}

# --- output shape and safety ---------------------------------------------------

@test "every stdout line is one JSON object in document order" {
  tree_with 'docs/a.md:`ONE_X`\n[x](/etc/hosts)\n`--bogus-flag`\n'
  check --tree "$T" "$T/docs/a.md"
  assert_failure 1
  local l
  for l in "${lines[@]}"; do
    [ "$(jq -c . <<< "$l" | wc -l | tr -d ' ')" = 1 ] || fail "not one JSON object: $l"
  done
  jq -se 'map(.line) == [1, 2, 3] and map(.kind) == ["env", "path", "flag"]' <<< "$output"
}

@test "doc text is never executed" {
  tree_with 'docs/a.md:Run `$(touch PWNED_A)` or [x](<$(touch PWNED_B)>).\n\n```bash\n$(touch PWNED_C)\n`touch PWNED_D`\n```\n'
  cd "$WD"
  check --tree "$T" "$T/docs/a.md"
  [ "$status" -le 1 ]
  [ ! -e "$WD/PWNED_A" ] && [ ! -e "$WD/PWNED_B" ] && [ ! -e "$WD/PWNED_C" ] && [ ! -e "$WD/PWNED_D" ]
  [ ! -e "$T/PWNED_A" ] && [ ! -e "$T/PWNED_B" ] && [ ! -e "$T/PWNED_C" ] && [ ! -e "$T/PWNED_D" ]
}

@test "the F-8 fixture yields the exact finding the DC contract example quotes" {
  local example n=1
  example="$(grep -oE 'finding: "[^"]+"' "$PLUGIN_ROOT/$CONTRACTS" | head -1 | sed 's/^finding: "//; s/"$//')"
  [ "$example" = "README.md:42: env API_BIND undefined" ]
  : > "$WD/readme"
  while [ "$n" -lt 42 ]; do printf 'filler\n' >> "$WD/readme"; n=$((n + 1)); done
  printf 'Set `API_BIND` to the listen address.\n' >> "$WD/readme"
  tree_with "README.md:$(cat "$WD/readme")\n"
  check --tree "$T" "$T/README.md"
  assert_failure 1
  [ "$stderr" = "$example" ]
  jq -e '.doc + ":" + (.line | tostring) == "README.md:42"' <<< "$output"
}

@test "--self-test reaches ALL PASS" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "S1: undefined env var is a finding: ok"
  assert_output --partial "S5: unresolved tree exits 3: ok"
  assert_output --partial "self-test: ALL PASS"
  assert_output --regexp 'ALL PASS \([1-9][0-9]* passed, 0 failed\)'
}
