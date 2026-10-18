#!/usr/bin/env bash
# @description doc-option-check.sh — documented-option and assigned-tree check (DC gate).
#   Every env var and long flag a doc names must appear in a tracked or untracked,
#   not-ignored file of an assigned tree, and every link target or backticked relative path must resolve inside a tree and
#   exist. Doc text is only scanned: nothing from it is eval'd, executed or used as a regex.
#   Backticked tokens that only look like paths (git refs, owner/repo slugs, host/... URLs,
#   ellipses, regex fragments, integrity hashes such as sha512-<base64>) are skipped, and so is
#   a backticked token whose first segment exists nowhere in a tree: not on disk at the doc
#   directory or a tree root, and not a segment of any evidence path. A link target is always
#   checked.
#   A doc named CHANGELOG.md is scanned only inside its [Unreleased] block, from that level-2
#   heading up to the next level-2 heading (released history is not re-gated); with no such
#   heading it yields nothing.
#   Reported line numbers stay file line numbers.
#
# Usage: doc-option-check.sh [--tree <path>]... [--allow <NAME>]... [--allow-path <path>]... [--exclude <path>]... <doc>...
#        doc-option-check.sh --self-test | -h | --help
#
# @arg --tree <path>   Assigned tree root, repeatable. Absent: state.json
#                      .metadata.workspace_path (via corpflow_context_dir), then
#                      $WORKSPACE_ROOT, else exit 3.
# @arg --allow <NAME>  Host-provided env var or flag that no tree defines; repeatable.
# @arg --allow-path <path>  Tree-relative path the code creates at runtime; repeatable.
#                      Suppresses only a `missing` finding whose resolved path is <path> or
#                      lies below it, compared as a literal string. Exit 2 when <path> is
#                      empty, `.`, absolute or holds a `..` segment: each is a broad exemption.
# @arg --exclude <path>  Tree-relative path of a vendored doc or doc directory; repeatable.
#                      A <doc> whose tree-relative path is <path> or lies below it is not
#                      scanned, and stderr gets "doc-option-check: excluded: <doc>". Same
#                      literal match and exit-2 rules as --allow-path.
# @arg <doc>           Documentation files to check.
#
# Evidence: `git ls-files --cached --others --exclude-standard` of each tree, minus the
#   <doc> files and .context/. Names match
#   as fixed strings bounded by non-token characters.
# stdout: JSON Lines, one finding per line, nothing when clean:
#   {"check":"option-exists"|"assigned-tree","kind":"env"|"flag"|"path","name":"<token>",
#    "doc":"<tree-relative doc path>","line":<n>,"reason":"undefined"|"outside"|"missing"}
# stderr: "<doc>:<line>: <kind> <name> <reason>" per finding, plus diagnostics. A `missing`
#   path that its tree git-ignores also gets a runtime-path hint; it still counts as a finding.
#
# @exitcode 0  Clean.
# @exitcode 1  At least one finding.
# @exitcode 2  Usage error.
# @exitcode 3  A tree did not resolve or a doc could not be read.
#
# Minimum shell: bash 3.2+ (macOS default). Requires git, awk, grep, xargs.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
export LC_ALL=C

BUILTIN_ALLOW=$'\nHOME\nPATH\nPWD\nSHELL\nTMPDIR\nUSER\n'

usage_error() {
  printf >&2 'doc-option-check: %s\n' "$1"
  printf >&2 'usage: doc-option-check.sh [--tree <path>]... [--allow <NAME>]... [--allow-path <path>]... [--exclude <path>]... <doc>...\n'
  exit 2
}

unresolved() {
  printf >&2 'doc-option-check: %s\n' "$1"
  exit 3
}

show_help() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$SELF"
  exit 0
}

physical_dir() {
  (CDPATH='' cd -- "$1" 2> /dev/null && pwd -P)
}

# Lexical only: a traversal is judged by where the path text points, never by following
# it on disk, so a hostile `../..` cannot make the check touch anything outside the trees.
normalize_path() {
  local rest="${1#/}" part out=""
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        part="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        part="$rest"
        rest=""
        ;;
    esac
    case "$part" in
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  NORM="${out:-/}"
}

# Sets TREE_OF to the first root containing $1, or empty.
tree_of() {
  local root
  TREE_OF=""
  for root in "${TREES[@]}"; do
    if [ "$1" = "$root" ] || [ "${1#"$root"/}" != "$1" ]; then
      TREE_OF="$root"
      return 0
    fi
  done
  return 1
}

# Ranked fallback when no --tree is given; every rank may be empty.
default_tree() {
  local lib="$SCRIPT_DIR/../../shared/lib/state-read-lib.sh" ctx="" v=""
  if [ -r "$lib" ]; then
    # shellcheck source=../../shared/lib/state-read-lib.sh disable=SC1091  # path is runtime-relative
    . "$lib"
    ctx=$(corpflow_context_dir 2> /dev/null) || ctx=""
    if [ -n "$ctx" ] && [ -f "$ctx/state.json" ]; then
      v=$(corpflow_state_str "$ctx/state.json" '.metadata.workspace_path' '')
    fi
  else
    printf >&2 'doc-option-check: warning: state-read-lib.sh unreachable; skipping state.json\n'
  fi
  [ -n "$v" ] || v="${WORKSPACE_ROOT:-}"
  printf '%s' "$v"
}

is_doc() {
  case "$DOCS_NL" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# Writes the NUL-delimited evidence list, the newline-delimited basename set, and the set of
# every path segment the trees list (the "exists somewhere" test of not_a_path).
build_evidence() {
  local root rel abs
  : > "$WORK/segments"
  for root in "${TREES[@]}"; do
    # --others: DC runs before anything is committed, so files DV just created are still
    # untracked; ignored build output stays out.
    git -C "$root" ls-files -z --cached --others --exclude-standard > "$WORK/ls" 2> /dev/null \
      || unresolved "tree is not a git work tree: $root"
    tr '\0' '\n' < "$WORK/ls" | awk -F/ '{ for (i = 1; i <= NF; i++) if ($i != "") print $i }' >> "$WORK/segments"
    while IFS= read -r -d '' rel; do
      printf '%s\n' "${rel##*/}" >&4
      case "$rel" in .context/*) continue ;; esac
      abs="$root/$rel"
      [ -f "$abs" ] || continue
      is_doc "$abs" && continue
      printf '%s\0' "$abs" >&3
    done < "$WORK/ls"
  done 3> "$WORK/evidence" 4> "$WORK/basenames"
}

# The grep is a cheap fixed-string prefilter; awk then rejects hits inside a longer token
# (API_BIND inside API_BIND_PORT, --tree inside --tree-root), which `grep -w` cannot do
# for flags because it treats `-` as a boundary.
option_defined() { # <name> <env|flag>
  local hit=""
  case "$DEFINED_NL" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  case "$UNDEFINED_NL" in *$'\n'"$1"$'\n'*) return 1 ;; esac
  if [ -s "$WORK/evidence" ]; then
    hit=$(xargs -0 grep -F -h -s -e "$1" -- /dev/null < "$WORK/evidence" 2> /dev/null \
      | DOC_OPT_NAME="$1" DOC_OPT_MODE="$2" awk '
          function istok(c) {
            if (c == "") return 0
            return mode == "flag" ? c ~ /[A-Za-z0-9_-]/ : c ~ /[A-Za-z0-9_]/
          }
          BEGIN { n = ENVIRON["DOC_OPT_NAME"]; mode = ENVIRON["DOC_OPT_MODE"]; L = length(n) }
          {
            s = $0; off = 0
            while ((i = index(s, n)) > 0) {
              if (!istok(substr($0, off + i - 1, 1)) && !istok(substr($0, off + i + L, 1))) {
                print "y"; exit
              }
              s = substr(s, i + 1); off += i
            }
          }') || true
  fi
  if [ "$hit" = y ]; then
    DEFINED_NL="$DEFINED_NL$1"$'\n'
    return 0
  fi
  UNDEFINED_NL="$UNDEFINED_NL$1"$'\n'
  return 1
}

# True when a backticked token only looks like a path: a git ref, a regex fragment, an
# ellipsis, an integrity hash, a token whose first segment exists nowhere in the trees, or an
# owner/repo slug or host/... URL whose first segment is not on disk at a root.
# A missing path under an existing segment (`docs/gone.md`, `skills/gone`) is never exempt.
not_a_path() { # <token> <physical doc dir>
  local p="$1" docdir="$2" first root known=0
  local slug_re='^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'
  local sri_re='^sha(256|384|512)-[A-Za-z0-9+/]+={0,2}$'
  case "$p" in
    *')'* | *'…'* | *...* | origin/* | upstream/* | refs/* | remotes/*) return 0 ;;
  esac
  [[ $p =~ $sri_re ]] && return 0
  first="${p%%/*}"
  for root in "$docdir" "${TREES[@]}"; do
    if [ -e "$root/$first" ]; then known=1; fi
  done
  # Vendored docs name paths of the upstream package; a first segment no tree has at any depth
  # cannot be a stale reference to this tree. A deeper match keeps the old rules below.
  if [ "$known" -eq 0 ] && ! grep -F -x -q -e "$first" -- "$WORK/segments"; then
    return 0
  fi
  # A regex metacharacter reads as a fragment only when no tree holds the first segment, so
  # a real directory with an odd character in a deeper name still reaches the path check.
  if [ "$known" -eq 0 ]; then
    case "$p" in
      *'['* | *']'* | *'|'* | *'^'* | *'+'* | *'?'* | *"\\"*) return 0 ;;
    esac
  fi
  [ "$first" != "$p" ] || return 1
  [ "$known" -eq 0 ] || return 1
  case "$first" in .*) return 1 ;; *.*) return 0 ;; esac
  [[ $p =~ $slug_re ]]
}

# prefix_match <newline list> <tree-relative path> — exact or descendant match, literal.
prefix_match() {
  local a rest="${1#$'\n'}"
  shift
  while [ -n "$rest" ]; do
    a="${rest%%$'\n'*}"
    rest="${rest#*$'\n'}"
    [ "$1" = "$a" ] && return 0
    case "$1" in "$a"/*) return 0 ;; esac
  done
  return 1
}

# Sets PATH_NAME to the checked path, PATH_REASON to "", "outside" or "missing", and MISS_RELS
# to the "<tree>\t<rel>" lines of a missing path's in-tree candidates, tree-root resolutions
# first: the hint must print a value that works as --allow-path from the tree root.
check_path() { # <token> <link|code> <physical doc dir>
  local tok="$1" src="$2" docdir="$3" p cand inside=0 root cands rel doc_miss="" first_cand=0
  local scheme_re='^[A-Za-z][A-Za-z0-9+.-]*:' lineref_re='^(.*[^:]):[0-9]+(:[0-9]+)?$'
  PATH_NAME=""
  PATH_REASON=""
  MISS_RELS=""
  case "$tok" in '#'* | //*) return 0 ;; esac
  [[ $tok =~ $scheme_re ]] && return 0
  p="${tok%%#*}"
  if [ "$src" = code ]; then
    # Backticks are checked as relative paths only; host paths such as /dev/null or
    # ~/.claude would otherwise fail every doc that mentions them.
    case "$p" in /* | '~'* | .context/*) return 0 ;; esac
    [[ $p =~ $lineref_re ]] && p="${BASH_REMATCH[1]}"
    not_a_path "$p" "$docdir" && return 0
  fi
  [ -n "$p" ] || return 0
  PATH_NAME="$p"
  case "$p" in
    /*) cands=("$p") ;;
    *)
      cands=("$docdir/$p")
      first_cand=1
      for root in "${TREES[@]}"; do cands+=("$root/$p"); done
      ;;
  esac
  for cand in "${cands[@]}"; do
    normalize_path "$cand"
    if tree_of "$NORM"; then
      inside=1
      [ -e "$NORM" ] && return 0
      rel="${NORM#"$TREE_OF"/}"
      prefix_match "$ALLOW_PATH_NL" "$rel" && return 0
      if [ "$first_cand" -eq 1 ]; then
        doc_miss="$TREE_OF"$'\t'"$rel"$'\n'
      else
        MISS_RELS="$MISS_RELS$TREE_OF"$'\t'"$rel"$'\n'
      fi
    fi
    first_cand=0
  done
  MISS_RELS="$MISS_RELS$doc_miss"
  if [ "$inside" -eq 1 ]; then PATH_REASON=missing; else PATH_REASON=outside; fi
}

json_str() {
  JSON_IN="$1" awk 'BEGIN {
    for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
    s = ENVIRON["JSON_IN"]; out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\") out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else if (c in ctl) out = out ctl[c]
      else out = out c
    }
    printf "%s", out
  }'
}

report() { # <check> <kind> <name> <doc label> <line> <reason>
  printf '{"check":"%s","kind":"%s","name":"%s","doc":"%s","line":%s,"reason":"%s"}\n' \
    "$1" "$2" "$(json_str "$3")" "$(json_str "$4")" "$5" "$6"
  printf >&2 '%s:%s: %s %s %s\n' "$4" "$5" "$2" "$3" "$6"
  FINDINGS=$((FINDINGS + 1))
}

# Emits one tab-separated candidate per line: kind, name, line number, source.
# Flags whose command word is external are dropped here, since only awk sees the words.
# SCOPE=unreleased limits the scan to the CHANGELOG [Unreleased] block; NR stays the file line.
scan_doc() { # <doc> <all|unreleased>
  awk -v BNFILE="$WORK/basenames" -v SCOPE="$2" '
    function emit(kind, name, no, extra,   key) {
      key = kind SUBSEP name SUBSEP no
      if (key in seen) return
      seen[key] = 1
      printf "%s\t%s\t%d\t%s\n", kind, name, no, extra
    }
    function scan_dollar(s, no, uselocal,   tok, nm, after, brace) {
      while (match(s, /[$][{]?[A-Z][A-Z0-9_]*/)) {
        tok = substr(s, RSTART, RLENGTH)
        after = substr(s, RSTART + RLENGTH, 1)
        s = substr(s, RSTART + RLENGTH)
        brace = (substr(tok, 2, 1) == "{")
        nm = substr(tok, brace ? 3 : 2)
        if (nm == "" || after ~ /[a-z]/) continue
        if (uselocal && (nm in assigned)) continue
        emit("env", nm, no, "-")
      }
    }
    function scan_assign(s,   p, prev, tok) {
      prev = ""
      while (match(s, /[A-Za-z_][A-Za-z0-9_]*=/)) {
        p = (RSTART > 1) ? substr(s, RSTART - 1, 1) : prev
        tok = substr(s, RSTART, RLENGTH - 1)
        prev = "="
        s = substr(s, RSTART + RLENGTH)
        if (p !~ /[A-Za-z0-9_$]/) assigned[tok] = 1
      }
    }
    function scan_export(s,   tok) {
      while (match(s, /(^|[^A-Za-z0-9_])export[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        tok = substr(s, RSTART, RLENGTH)
        sub(/^.*export[ \t]+/, "", tok)
        assigned[tok] = 1
        s = substr(s, RSTART + RLENGTH)
      }
    }
    function scan_flag_word(s, no,   p, prev, tok, after) {
      prev = ""
      while (match(s, /--[a-z][a-z0-9-]+/)) {
        p = (RSTART > 1) ? substr(s, RSTART - 1, 1) : prev
        tok = substr(s, RSTART, RLENGTH)
        after = substr(s, RSTART + RLENGTH, 1)
        prev = substr(tok, length(tok), 1)
        s = substr(s, RSTART + RLENGTH)
        if (p ~ /[A-Za-z0-9_-]/ || after ~ /[A-Z_]/) continue
        sub(/-+$/, "", tok)
        if (length(tok) >= 4) emit("flag", tok, no, "-")
      }
    }
    function is_wrapper(w) {
      return w ~ /^(bash|sh|zsh|dash|ksh|env|sudo|exec|command|nohup|time|xargs|python|python3|node|ruby|perl)$/
    }
    # carry: -1 fresh line, 0 check args (in-tree script or no command word), 1 external.
    # Returns the mode of the last segment so a backslash continuation inherits it.
    function scan_flags(s, no, carry,   nseg, seg, k, t, nw, w, i, j, start, mode, cmd) {
      nseg = split(s, seg, /[|;&]/)
      mode = (carry >= 0) ? carry : 1
      for (k = 1; k <= nseg; k++) {
        t = seg[k]
        sub(/^[ \t]+/, "", t)
        if (t == "") continue
        nw = split(t, w, /[ \t]+/)
        if (k == 1 && carry >= 0) {
          mode = carry; start = 1
        } else {
          i = 1
          if (k == 1 && w[1] == "$") i++
          while (i <= nw && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
          while (i <= nw && is_wrapper(w[i])) { i++; while (i <= nw && w[i] ~ /^-/) i++ }
          if (i > nw) { mode = 1; start = nw + 1 }
          else if (w[i] ~ /^-/) { mode = 0; start = i }
          else {
            cmd = w[i]
            gsub(/^["\047]+|["\047]+$/, "", cmd)
            sub(/^.*\//, "", cmd)
            mode = (cmd in bn) ? 0 : 1
            start = i + 1
          }
        }
        if (mode == 0) for (j = start; j <= nw; j++) scan_flag_word(w[j], no)
      }
      return mode
    }
    function handle_span(s, no) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s == "") return
      if (s ~ /^[A-Z][A-Z0-9]*_[A-Z0-9_]+$/) emit("env", s, no, "-")
      scan_dollar(s, no, 0)
      scan_flags(s, no, -1)
      if (s !~ /[ \t]/ && index(s, "/") > 0 && s !~ /[<>*{}$]/ && substr(s, 1, 9) != ".context/")
        emit("path", s, no, "code")
    }
    function find_run(s, n,   off, i, m) {
      off = 0
      while ((i = index(substr(s, off + 1), "`")) > 0) {
        i += off; m = 0
        while (substr(s, i + m, 1) == "`") m++
        if (m == n) return i
        off = i + m - 1
      }
      return 0
    }
    function scan_links(p, no,   rest, i, t, j, c, depth, out, L, lbl) {
      rest = p
      while ((i = index(rest, "](")) > 0) {
        t = substr(rest, i + 2); rest = t; out = ""
        if (substr(t, 1, 1) == "<") {
          j = index(t, ">")
          if (j == 0) continue
          out = substr(t, 2, j - 2)
        } else {
          depth = 0; L = length(t)
          for (j = 1; j <= L; j++) {
            c = substr(t, j, 1)
            if (c == " " || c == "\t") { if (index(substr(t, j), ")") == 0) out = ""; break }
            if (c == "(") depth++
            else if (c == ")") { if (depth == 0) break; depth-- }
            out = out c
          }
          if (j > L) out = ""
        }
        if (out != "") emit("path", out, no, "link")
      }
      t = p
      sub(/^[ \t]*/, "", t)
      if (substr(t, 1, 1) == "[" && substr(t, 2, 1) != "^" && (j = index(t, "]:")) > 2) {
        lbl = substr(t, 2, j - 2)
        if (index(lbl, "]") == 0) {
          out = substr(t, j + 2)
          sub(/^[ \t]+/, "", out); sub(/[ \t].*$/, "", out)
          if (out ~ /^<.*>$/) out = substr(out, 2, length(out) - 2)
          if (out != "") emit("path", out, no, "link")
        }
      }
    }
    function process_prose(line, no,   rest, rest2, prose, i, n, cl) {
      prose = ""; rest = line
      while ((i = index(rest, "`")) > 0) {
        prose = prose substr(rest, 1, i - 1)
        n = 0
        while (substr(rest, i + n, 1) == "`") n++
        rest2 = substr(rest, i + n)
        cl = find_run(rest2, n)
        if (cl == 0) { prose = prose substr(rest, i, n); rest = rest2; continue }
        handle_span(substr(rest2, 1, cl - 1), no)
        prose = prose "C"
        rest = substr(rest2, cl + n)
      }
      scan_links(prose rest, no)
    }
    function fence_open(line,   t, c, n) {
      t = line; sub(/^[ \t]+/, "", t)
      c = substr(t, 1, 1)
      if (c != "`" && c != "~") return 0
      n = 0
      while (substr(t, n + 1, 1) == c) n++
      if (n < 3 || (c == "`" && index(substr(t, n + 1), "`") > 0)) return 0
      fch = c; flen = n
      return 1
    }
    function fence_close(line,   t, n) {
      t = line; sub(/^[ \t]+/, "", t)
      n = 0
      while (substr(t, n + 1, 1) == fch) n++
      return n >= flen && substr(t, n + 1) ~ /^[ \t]*$/
    }
    # Assignments are collected over the whole block first: a variable set after its first
    # use in the same example is still local to that example.
    function flush_block(   k, carry, mode) {
      split("", assigned)
      for (k = 1; k <= blk_n; k++) { scan_assign(blk[k]); scan_export(blk[k]) }
      carry = -1
      for (k = 1; k <= blk_n; k++) {
        scan_dollar(blk[k], blk_no[k], 1)
        mode = scan_flags(blk[k], blk_no[k], carry)
        carry = (blk[k] ~ /\\[ \t]*$/) ? mode : -1
      }
      blk_n = 0
    }
    BEGIN {
      while ((getline l < BNFILE) > 0) bn[l] = 1
      close(BNFILE)
      infence = 0; blk_n = 0; inrel = 0
    }
    {
      sub(/\r$/, "")
      if (SCOPE == "unreleased" && !infence) {
        if (!inrel) {
          if ($0 ~ /^## \[Unreleased\]([ \t]|$)/) inrel = 1
          next
        }
        if ($0 ~ /^## /) exit
      }
      if (infence) {
        if (fence_close($0)) { flush_block(); infence = 0 }
        else { blk_n++; blk[blk_n] = $0; blk_no[blk_n] = NR }
        next
      }
      if (fence_open($0)) { infence = 1; blk_n = 0; next }
      process_prose($0, NR)
    }
    END { if (infence) flush_block() }
  ' "$1"
}

# A git-ignored missing path is often runtime output; say so, but never exempt it unasked.
# Both spellings are probed because a `dir/` pattern matches only the slash form.
ignored_hint() { # <doc label> <line>
  local line tree rel rest="$MISS_RELS"
  while [ -n "$rest" ]; do
    line="${rest%%$'\n'*}"
    rest="${rest#*$'\n'}"
    tree="${line%%$'\t'*}"
    rel="${line#*$'\t'}"
    if printf '%s\n%s/\n' "$rel" "$rel" | git -C "$tree" check-ignore -q --stdin 2> /dev/null; then
      printf >&2 'doc-option-check: %s:%s: path %s is git-ignored; if the code creates it at runtime, re-run with --allow-path %s\n' \
        "$1" "$2" "$PATH_NAME" "$rel"
      return 0
    fi
  done
}

check_doc() { # <doc as given> <physical abs path>
  local given="$1" abs="$2" label docdir kind name lineno src scope=all
  label="$given"
  if tree_of "$abs"; then
    label="${abs#"$TREE_OF"/}"
    if prefix_match "$EXCLUDE_NL" "$label"; then
      printf >&2 'doc-option-check: excluded: %s\n' "$label"
      return 0
    fi
  fi
  docdir="${abs%/*}"
  [ "${abs##*/}" != CHANGELOG.md ] || scope=unreleased
  # Exit 2 is reserved for usage, so a scanner failure must not leak awk's own status.
  scan_doc "$abs" "$scope" > "$WORK/candidates" || unresolved "could not scan doc: $given"
  while IFS=$'\t' read -r kind name lineno src; do
    case "$kind" in
      env | flag)
        case "$BUILTIN_ALLOW$ALLOW_NL" in *$'\n'"$name"$'\n'*) continue ;; esac
        option_defined "$name" "$kind" || report option-exists "$kind" "$name" "$label" "$lineno" undefined
        ;;
      path)
        check_path "$name" "$src" "$docdir"
        [ -z "$PATH_REASON" ] || report assigned-tree path "$PATH_NAME" "$label" "$lineno" "$PATH_REASON"
        [ "$PATH_REASON" != missing ] || ignored_hint "$label" "$lineno"
        ;;
    esac
  done < "$WORK/candidates"
}

# Sets REL_VALUE to the canonical tree-relative form of an --allow-path or --exclude value, or
# exits 2 when the value would exempt the whole tree or reach outside it.
tree_rel_value() { # <flag> <value>
  local v="$2"
  # Validate the normalized form: `.//x` strips to `/x`, which would never match.
  while [ "${v#./}" != "$v" ]; do v="${v#./}"; done
  while [ "${v%/}" != "$v" ]; do v="${v%/}"; done
  case "$v" in /*) usage_error "$1 must be tree-relative: $2" ;; esac
  # Candidates are compared in normalize_path form, so a//b and a/./b must reach it as a/b.
  while :; do
    case "$v" in
      *//*) v="${v%%//*}/${v#*//}" ;;
      */./*) v="${v%%/./*}/${v#*/./}" ;;
      *) break ;;
    esac
  done
  case "$v" in */.) v="${v%/.}" ;; esac
  case "/$v/" in */../*) usage_error "$1 must not hold '..': $2" ;; esac
  case "$v" in '' | .) usage_error "$1 would exempt the whole tree: $2" ;; esac
  REL_VALUE="$v"
}

TREE_ARGS=()
ALLOW_NL=$'\n'
# A newline string, not an array: an empty array under `set -u` fails on bash 3.2.
ALLOW_PATH_NL=$'\n'
EXCLUDE_NL=$'\n'
REL_VALUE=""
DOC_ARGS=()
CMD=check

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tree | --allow)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
      if [ "$1" = --tree ]; then TREE_ARGS+=("$2"); else ALLOW_NL="$ALLOW_NL$2"$'\n'; fi
      shift 2
      ;;
    --allow-path | --exclude)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
      tree_rel_value "$1" "$2"
      if [ "$1" = --exclude ]; then
        EXCLUDE_NL="$EXCLUDE_NL$REL_VALUE"$'\n'
      else
        ALLOW_PATH_NL="$ALLOW_PATH_NL$REL_VALUE"$'\n'
      fi
      shift 2
      ;;
    --self-test)
      CMD=self-test
      shift
      ;;
    -h | --help) show_help ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        DOC_ARGS+=("$1")
        shift
      done
      ;;
    -?*) usage_error "unknown argument: $1" ;;
    *)
      DOC_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ "$CMD" = self-test ]; then
  SELFTEST_LIB="$SCRIPT_DIR/doc-option-check-selftest.sh"
  # `[ -r ]` first: a failed `.` of a missing file is a special-builtin error that exits
  # the shell before any guard can report it.
  [ -r "$SELFTEST_LIB" ] || {
    printf >&2 'doc-option-check: self-test harness unreachable at %s\n' "$SELFTEST_LIB"
    exit 1
  }
  # shellcheck source=doc-option-check-selftest.sh disable=SC1091  # path is runtime-relative
  . "$SELFTEST_LIB"
  run_self_test
  exit $?
fi

[ "${#DOC_ARGS[@]}" -gt 0 ] || usage_error "no <doc> given"
for cmd in git awk grep xargs; do
  command -v "$cmd" > /dev/null 2>&1 || unresolved "required command not found: $cmd"
done

if [ "${#TREE_ARGS[@]}" -eq 0 ]; then
  fallback="$(default_tree)"
  [ -n "$fallback" ] || unresolved "no --tree, no state.json .metadata.workspace_path, no \$WORKSPACE_ROOT"
  TREE_ARGS=("$fallback")
fi

TREES=()
for t in "${TREE_ARGS[@]}"; do
  real="$(physical_dir "$t")" || unresolved "tree does not resolve: $t"
  git -C "$real" rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    || unresolved "tree is not a git work tree: $t"
  TREES+=("$real")
done

DOCS_NL=$'\n'
DOC_ABS=()
for d in "${DOC_ARGS[@]}"; do
  [ -f "$d" ] && [ -r "$d" ] || unresolved "doc is not a readable file: $d"
  dir="$(physical_dir "$(dirname -- "$d")")" || unresolved "doc is not a readable file: $d"
  DOC_ABS+=("$dir/$(basename -- "$d")")
  DOCS_NL="$DOCS_NL$dir/$(basename -- "$d")"$'\n'
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doc-option-check.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT TERM

DEFINED_NL=$'\n'
UNDEFINED_NL=$'\n'
FINDINGS=0
NORM=""
TREE_OF=""
PATH_NAME=""
PATH_REASON=""
MISS_RELS=""

build_evidence
i=0
while [ "$i" -lt "${#DOC_ARGS[@]}" ]; do
  check_doc "${DOC_ARGS[$i]}" "${DOC_ABS[$i]}"
  i=$((i + 1))
done

[ "$FINDINGS" -eq 0 ] || exit 1
exit 0
