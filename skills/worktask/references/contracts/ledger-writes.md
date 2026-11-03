# Ledger writes

Read before a ledger write or when diagnosing a merge lock failure.

<!-- canonical-body:start -->
# Handoff Protocol — Inter-Stage Communication Reference

Canonical spec for worktask inter-stage communication: the `state.json` ledger, the YAML `handoff:` frontmatter contract, the typed-return schemas, the cache-friendly preamble layout, and the fallback paths.

---

## #atomic-write

Atomic state.json write: lock → read → merge → temp → fsync → rename → unlock. An
mkdir-spinlock serializes the read-merge-rename window (macOS has no `flock(1)`), so legal
sibling overlap (parallel DVN tracks, DC+QA) cannot drop a patch to last-rename-wins.
POSIX-shell pseudocode:

### Lock acquisition (step 0)

```bash
# 0. Acquire the merge lock (mkdir is atomic on POSIX). Env knobs:
#    STATE_LOCK_TIMEOUT_S (default 5), STATE_LOCK_STALE_S (default 60).
lockdir=".context/state.json.lock.d"; waited=0
until mkdir "$lockdir" 2>/dev/null; do
  # Break a leaked lock older than STATE_LOCK_STALE_S (by dir mtime).
  age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir") ))
  (( age >= STATE_LOCK_STALE_S )) && { rmdir "$lockdir" 2>/dev/null; continue; }
  # Timeout ⇒ proceed UNLOCKED + WARN (never a silent no-op). break_unlocked=1.
  (( waited >= STATE_LOCK_TIMEOUT_S )) && { echo "WARN: lock timeout — unlocked" >&2; break_unlocked=1; break; }
  sleep 1; waited=$(( waited + 1 ))
done
trap 'rmdir "$lockdir" 2>/dev/null' EXIT   # release on process end/failure
```

### Merge, write, rename (steps 1–6)

```bash
# …continued: same script, after lock acquisition
cur=$(cat .context/state.json)                                   # 1. last-known-good
new=$(echo "$cur" | jq --argjson patch "$PATCH_JSON" '. * $patch')  # 2. merge in-memory (idempotent)
tmp=".context/.state.json.$$.${RANDOM}.tmp"                      # 3. temp in same dir ⇒ same FS
printf '%s' "$new" > "$tmp"
sync "$tmp" 2>/dev/null || sync || true                          # 4. fsync (best-effort)
mv -f "$tmp" .context/state.json                                 # 5. POSIX-atomic rename
rmdir "$lockdir" 2>/dev/null                                     # 6. release (also on EXIT trap)
```

`$RANDOM` in the temp name guards against PID reuse inside Task subagents.

### Failure semantics

- Crash before step 3 — state.json untouched (last-known-good preserved).
- Crash between 3 and 5 — temp file orphaned. Cleanup on next worktask start: `rm -f .context/.state.json.*.tmp`. state.json untouched.
- Crash after 5 — state.json holds the new value; idempotent, so re-running the same patch is a no-op.
- Crash while holding the lock — the EXIT trap releases it; if the trap is skipped, the next writer breaks the dir once it is older than `STATE_LOCK_STALE_S`.

### Single-writer invariant

One writer per stage key, not one writer globally. Sibling overlap is legal (two stages, or two
DVN tracks writing distinct keys, may merge concurrently); the spinlock serializes their windows so
neither patch is lost. There is no "exactly one agent `in_progress`" requirement. On lock timeout
the write proceeds unlocked with a WARN, never as a silent exit-0 no-op.

### Lock implementation

`skills/worktask/scripts/state-patch.sh` — `atomic_merge()` plus `_lock_acquire` /
`_lock_release` / `_lock_break_if_stale` — is the single merge implementation, inherited by the
SubagentStop hook via delegation; when it is absent `state-merge.sh` warns and exits 0 without
merging.

---
