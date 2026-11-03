#!/usr/bin/env bash
set -euo pipefail

include=0
if [ "${1:-}" = "--include-artifacts" ]; then include=1; shift; fi
[ "$#" -le 1 ] || { printf >&2 'usage: source-inventory.sh [--include-artifacts] [root]\n'; exit 2; }
root="${1:-.}"
[ -d "$root" ] || { printf >&2 'source-inventory: root is not a directory\n'; exit 2; }
args=(--files --hidden -g '!.git' -g '!**/.git' -g '!**/.git/**' -g '!**/.worktrees/**')
if [ "$include" -eq 1 ]; then
  args+=(--no-ignore)
else
  args+=(-g '!**/.build/**' -g '!**/build/**' -g '!**/dist/**'
    -g '!**/DerivedData/**' -g '!**/node_modules/**' -g '!**/__pycache__/**'
    -g '!**/generated-capture-tools/**' -g '!**/capture-tools/**' -g '!**/SnapshotHost/**'
    -g '!**/workdirs/**' -g '!**/archive/**' -g '!**/archives/**' -g '!**/logs/**'
    -g '!*.{png,jpg,jpeg,gif,webp,heic,tiff,ico,zip,tar,gz,log}')
fi
cd -- "$root"
rg "${args[@]}" .
