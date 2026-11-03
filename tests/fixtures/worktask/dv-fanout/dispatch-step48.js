const fs = require('fs');
const path = require('path');
const vm = require('vm');

const [skillPath, statePath, taskId, pin] = process.argv.slice(2);
const doc = fs.readFileSync(skillPath, 'utf8');
const section = heading => {
  const start = doc.indexOf(`##### Step 4.8 — ${heading}\n`);
  if (start < 0) throw new Error(`missing section: ${heading}`);
  const restStart = doc.indexOf("\n", start) + 1;
  const rest = doc.slice(restStart);
  const next = rest.search(/^#{1,5} /m);
  const body = doc.slice(start, next < 0 ? undefined : restStart + next);
  const blocks = Array.from(body.matchAll(/```typescript\n([\s\S]*?)\n```/g), match => match[1]);
  if (!blocks.length) throw new Error(`missing code: ${heading}`);
  return blocks.join('\n');
};

let state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const root = state.tasks[taskId].metadata.workspace_path;
const calls = [];
const context = {
  state,
  task: { id: taskId },
  full: state.tasks[taskId],
  _orch_root: root,
  SETTLED: new Set(['completed', 'skipped', 'failed']),
  calls,
  process: { env: pin === 'pinned' ? { WORKSPACE_ROOT: root } : {} },
  fs: {
    realpathSync: p => path.resolve(p),
    readFileSync: () => JSON.stringify(state),
  },
  execFileSync: (_bin, args) => {
    calls.push(args);
    if (args[0].endsWith('workspace-root-banner.sh')) {
      return `WORKSPACE_ROOT=${state.tasks[args[2]].metadata.workspace_path}`;
    }
    if (args[1] === '--task-block') {
      const row = state.tasks[args[2]];
      row.blocked_by = [...new Set([...(row.blocked_by || []), args[4]])];
    }
    if (args[1] === '--task-meta') {
      Object.assign(state.tasks[args[2]].metadata, JSON.parse(args[4]));
    }
  },
  ensureStreamWorktree: task => `/wt/stream-${task.id}`,
};
const code = `let skipped = false; for (let pass = 0; pass < 1; pass++) {
${section('pin the tree')}
${section('re-stamp, then read the banner path')}
} if ((state.tasks[task.id].blocked_by || []).some(id =>
  !SETTLED.has(state.tasks[id]?.status))) skipped = true;
globalThis.result = { state, calls, skipped };`;
vm.runInNewContext(code, context);
console.log(JSON.stringify(context.result));
