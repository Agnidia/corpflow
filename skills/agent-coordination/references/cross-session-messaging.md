# Cross-Session Messaging — SendMessage Reach, Authority & Delivery

Read when a stage messages a peer session: who `SendMessage` reaches, what a receiver refuses, and how to read a delivery result. Same-session subagent replies stay in `skills/agent-coordination/SKILL.md § Replies from a subagent land in the parent conversation`.

## Cross-session reach & SendMessage authority

`SendMessage` reaches sessions on other machines. `ListAgents` discovers them — labelling disconnected Remote Control rows `offline` and cloud rows `cloud` — and also lists live teammates and the session's own name (the `name` key), the address peers use. `crossSessionInbound` (holds messages into a bypassed-permissions session for approval) and `dialogExpiry` govern inbound traffic; an invalid `crossSessionInbound` value holds messages (user settings) or refuses them (managed settings) rather than being ignored. A message held by the receiving session's own permission-mode policy is not delivered: since 2.1.288 the sender's notice says so and names the holding session, and an SDK sender learns of it mid-turn (earlier builds reported it as delivered). Log it as `result: "blocked"` with `metadata.reason: "held"` (§ Delivery is reported, so check it).

### Restricted sessions & dialog timeout

A `--restricted` session opens no messaging socket (2.1.290), so it is unreachable by design, not gone. A `CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS` value with a unit suffix (`5m`) falls back to `dialogExpiry` instead of reading as milliseconds (2.1.290).

### Sessions without SendMessage & cloud restarts

A session launched without the `SendMessage` tool, as Claude Desktop launches some, is not told to message other sessions, so expect no outbound message from it. The same holds for a subagent or a resumed session when a host, a permission rule or a `--tools` list removed `SendMessage`: it is no longer told to continue or message subagents with it (2.1.293). A cloud session tells Claude about background agents that finished just before a worker restart, so a completion there survives the restart. After a restart it also names the stopped background agents Claude can resume by id (2.1.292).

### Authority does not relay

Receivers refuse relayed permission requests, and auto mode blocks them outright — across machines as on one. A reattach may nudge a parked agent (re-prompt, supply an awaited answer) but never authorize: permission escalations and the PL gate stay operator-owned.

### Delivery is reported, so check it

A send can come back `refused`, `dropped` (full or rate-limited inbox), `oversized`, `burst_limited`, `queued` or `held` (waiting for a person's approval at the recipient), and `SendMessage`/`ListAgents` say when the session list was too long to enumerate fully — a "peer is gone" conclusion drawn then is unconfirmed, not established. `queued` means the target is an offline Remote Control session on another machine and delivery waits for it to reconnect: never re-send, or the message arrives twice. `held` has the same rule: approval at the named session releases the copy it holds. A subagent or teammate that receives a message mid-run keeps its earlier thinking and prompt cache on resume (2.1.290). Branch on the result per `skills/worktask/references/recovery-liveness.md § Reattach rows — the SendMessage has a result too`.

### notify_when_idle, availability & preview collapse

When awaiting one same-machine peer, prefer `SendMessage` with `notify_when_idle` over discovery polling.
It requests one idle notice, opt-in, on macOS/Linux.
Messaging supports every provider and host, including Bedrock/Vertex/Foundry, disabled telemetry, Windows, and rootless containers.
Never gate handoffs, dispatch flags, or reattach paths on provider or OS.

Put a handoff's verdict first: peer previews show `Message from @<sender>: <first line>`.
Delivery notices distinguish similar session names; expiry notices identify the terminal session responsible (2.1.292).

A `/rename` name stays the peer-visible address after a VS Code reload or a non-interactive `--resume` (2.1.309).
Ctrl+O lists messages still waiting for delivery, marked as waiting (2.1.309). ↑ no longer recalls a waiting message for a duplicate send (2.1.311).
