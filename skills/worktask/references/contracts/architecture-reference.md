# Architecture reference

Read when executing or checking architecture reference. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### Architecture reference contract (tpl-dv)

When AR ran, both `refs.decisions` and the `architecture` object are required; both are omitted
when AR was excluded. They are not alternatives: `refs.decisions` is the anchor-read pointer
downstream stages follow, `architecture.ref` is the typed carrier the `DVHandoff` schema
validates, and `architecture.applied` is the assertion DR checks. The harness accepts either
(precedence below), but DR rejects an absent `architecture` object as `missing_input`.

Gate precedence, shared by the harness, the schema and the DR rule: `refs.decisions`, then
`architecture.ref`. The chosen value must match `^architecture-[0-9]+\.md(#[a-z-]+)?$` and resolve
to a file next to the artifact — warn-only by default, blocking under `--strict`. An architecture
reference with no `tasks.AR0` entry trips the inverse guard (warn, never a failure).

##### Unreadable-state exception

An unreadable `--state` warns by default and fails (exit 1) under `--strict`.
