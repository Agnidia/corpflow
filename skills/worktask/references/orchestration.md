# Orchestration

Select the procedure for the current boundary.


## Procedures 1

| Read when | Canonical module |
|---|---|
| lifecycle | [lifecycle](lifecycle.md) <!-- canonical-module: lifecycle.md --> |
| workspace scheduling | [workspace-scheduling](workspace-scheduling.md) <!-- canonical-module: workspace-scheduling.md --> |
| stage guards | [stage-guards](stage-guards.md) <!-- canonical-module: stage-guards.md --> |
| stage validation | [stage-validation](stage-validation.md) <!-- canonical-module: stage-validation.md --> |
| dispatch readiness | [dispatch-readiness](dispatch-readiness.md) <!-- canonical-module: dispatch-readiness.md --> |
| prompt dispatch | [prompt-dispatch](prompt-dispatch.md) <!-- canonical-module: prompt-dispatch.md --> |
| loop entry | [loop-entry](loop-entry.md) <!-- canonical-module: loop-entry.md --> |

## Procedures 2

| Read when | Canonical module |
|---|---|
| dispatch context | [dispatch-context](dispatch-context.md) <!-- canonical-module: dispatch-context.md --> |
| dispatch budgets | [dispatch-budgets](dispatch-budgets.md) <!-- canonical-module: dispatch-budgets.md --> |
| dispatch workspace | [dispatch-workspace](dispatch-workspace.md) <!-- canonical-module: dispatch-workspace.md --> |
| dispatch isolation | [dispatch-isolation](dispatch-isolation.md) <!-- canonical-module: dispatch-isolation.md --> |
| finalization gate | [finalization-gate](finalization-gate.md) <!-- canonical-module: finalization-gate.md --> |
| dispatch routing | [dispatch-routing](dispatch-routing.md) <!-- canonical-module: dispatch-routing.md --> |
| dispatch agent | [dispatch-agent](dispatch-agent.md) <!-- canonical-module: dispatch-agent.md --> |

## Procedures 3

| Read when | Canonical module |
|---|---|
| dispatch recording | [dispatch-recording](dispatch-recording.md) <!-- canonical-module: dispatch-recording.md --> |
| completion merge | [completion-merge](completion-merge.md) <!-- canonical-module: completion-merge.md --> |
| completion artifacts | [completion-artifacts](completion-artifacts.md) <!-- canonical-module: completion-artifacts.md --> |
| completion sweep | [completion-sweep](completion-sweep.md) <!-- canonical-module: completion-sweep.md --> |
| completion boundary | [completion-boundary](completion-boundary.md) <!-- canonical-module: completion-boundary.md --> |
| retry routing | [retry-routing](retry-routing.md) <!-- canonical-module: retry-routing.md --> |

## Procedures 4

| Read when | Canonical module |
|---|---|
| completion handoff | [completion-handoff](completion-handoff.md) <!-- canonical-module: completion-handoff.md --> |
| decision delegation | [decision-delegation](decision-delegation.md) <!-- canonical-module: decision-delegation.md --> |
| finalization policy | [finalization-policy](finalization-policy.md) <!-- canonical-module: finalization-policy.md --> |
| finalization publish | [finalization-publish](finalization-publish.md) <!-- canonical-module: finalization-publish.md --> |
| script routing | [script-routing](script-routing.md) <!-- canonical-module: script-routing.md --> |


## Compatibility routing

These published anchors redirect to their canonical owners. They contain no independent rules.
### <a id="worktask-system"></a> [worktask-system](lifecycle.md#worktask-system) · <a id="pipelines"></a> [pipelines](lifecycle.md#pipelines)
### <a id="state-machine"></a> [state-machine](lifecycle.md#state-machine) · <a id="post-compact-recovery-states"></a> [post-compact-recovery-states](lifecycle.md#post-compact-recovery-states)
### <a id="state-machine-references"></a> [state-machine-references](lifecycle.md#state-machine-references) · <a id="dynamic-worktask-sizing"></a> [dynamic-worktask-sizing](lifecycle.md#dynamic-worktask-sizing)
### <a id="complexity-assessment"></a> [complexity-assessment](lifecycle.md#complexity-assessment) · <a id="decision-rules"></a> [decision-rules](lifecycle.md#decision-rules)
### <a id="recording-skipped-and-added-stages"></a> [recording-skipped-and-added-stages](lifecycle.md#recording-skipped-and-added-stages) · <a id="mid-run-escalation--the-orchestrator-is-the-consumer"></a> [mid-run-escalation--the-orchestrator-is-the-consumer](lifecycle.md#mid-run-escalation--the-orchestrator-is-the-consumer)
### <a id="workspace-mode"></a> [workspace-mode](workspace-scheduling.md#workspace-mode) · <a id="parallel-execution"></a> [parallel-execution](workspace-scheduling.md#parallel-execution)
### <a id="dc--qa-parallel-default"></a> [dc--qa-parallel-default](workspace-scheduling.md#dc--qa-parallel-default) · <a id="monitor-tool-integration"></a> [monitor-tool-integration](workspace-scheduling.md#monitor-tool-integration)
### <a id="never-parallelize"></a> [never-parallelize](workspace-scheduling.md#never-parallelize) · <a id="error-handling"></a> [error-handling](workspace-scheduling.md#error-handling)
### <a id="retry-logic"></a> [retry-logic](workspace-scheduling.md#retry-logic) · <a id="escalation-chains"></a> [escalation-chains](workspace-scheduling.md#escalation-chains)
### <a id="user-under-megatask"></a> [user-under-megatask](workspace-scheduling.md#user-under-megatask) · <a id="rule-checks"></a> [rule-checks](stage-guards.md#rule-checks)
### <a id="optimization-hooks"></a> [optimization-hooks](stage-guards.md#optimization-hooks) · <a id="pre-stage"></a> [pre-stage](stage-guards.md#pre-stage)
### <a id="pre-stage-disk-guard-enospc"></a> [pre-stage-disk-guard-enospc](stage-guards.md#pre-stage-disk-guard-enospc) · <a id="disk-guard--semantics"></a> [disk-guard--semantics](stage-guards.md#disk-guard--semantics)
### <a id="post-stage"></a> [post-stage](stage-guards.md#post-stage) · <a id="pre-stage-validation"></a> [pre-stage-validation](stage-validation.md#pre-stage-validation)
### <a id="validation-checks-15"></a> [validation-checks-15](stage-validation.md#validation-checks-15) · <a id="validation-checks-67"></a> [validation-checks-67](stage-validation.md#validation-checks-67)
### <a id="validation-check-8"></a> [validation-check-8](stage-validation.md#validation-check-8) · <a id="validation-check-9"></a> [validation-check-9](stage-validation.md#validation-check-9)
### <a id="validation-check-10"></a> [validation-check-10](stage-validation.md#validation-check-10) · <a id="validation-check-10--pass-a-title-preview-freely"></a> [validation-check-10--pass-a-title-preview-freely](stage-validation.md#validation-check-10--pass-a-title-preview-freely)
### <a id="validation-check-10--stamping-and-post-check"></a> [validation-check-10--stamping-and-post-check](stage-validation.md#validation-check-10--stamping-and-post-check) · <a id="validation-check-10--post-check-and-the-host-rule"></a> [validation-check-10--post-check-and-the-host-rule](stage-validation.md#validation-check-10--post-check-and-the-host-rule)
### <a id="validation-check-11"></a> [validation-check-11](stage-validation.md#validation-check-11) · <a id="validation-check-11--what-warns-and-what-stays-quiet"></a> [validation-check-11--what-warns-and-what-stays-quiet](stage-validation.md#validation-check-11--what-warns-and-what-stays-quiet)
### <a id="never-blocks-forecast-not-observation"></a> [never-blocks-forecast-not-observation](stage-validation.md#never-blocks-forecast-not-observation) · <a id="validation-check-12--routing-resolution"></a> [validation-check-12--routing-resolution](stage-validation.md#validation-check-12--routing-resolution)
### <a id="check-12--audit-rows-and-lifecycle"></a> [check-12--audit-rows-and-lifecycle](stage-validation.md#check-12--audit-rows-and-lifecycle) · <a id="validation-check-13--model-resolution"></a> [validation-check-13--model-resolution](stage-validation.md#validation-check-13--model-resolution)
### <a id="on-validation-failure"></a> [on-validation-failure](stage-validation.md#on-validation-failure) · <a id="orchestrator-execution-loop"></a> [orchestrator-execution-loop](dispatch-readiness.md#orchestrator-execution-loop)
### <a id="before-this-loop--autonomy-preflight-phase-1"></a> [before-this-loop--autonomy-preflight-phase-1](dispatch-readiness.md#before-this-loop--autonomy-preflight-phase-1) · <a id="delegation-only"></a> [delegation-only](dispatch-readiness.md#delegation-only)
### <a id="delegation-only--the-build-tooling-corollary"></a> [delegation-only--the-build-tooling-corollary](dispatch-readiness.md#delegation-only--the-build-tooling-corollary) · <a id="dispatch-on-the-same-turn"></a> [dispatch-on-the-same-turn](dispatch-readiness.md#dispatch-on-the-same-turn)
### <a id="readiness-is-mechanical-not-a-judgement-call"></a> [readiness-is-mechanical-not-a-judgement-call](dispatch-readiness.md#readiness-is-mechanical-not-a-judgement-call) · <a id="cache-friendly-prompt-layout--statejson-handoff-protocol"></a> [cache-friendly-prompt-layout--statejson-handoff-protocol](prompt-dispatch.md#cache-friendly-prompt-layout--statejson-handoff-protocol)
### <a id="composing-the-brief"></a> [composing-the-brief](prompt-dispatch.md#composing-the-brief) · <a id="cite-sources-in-6-and-7-by-path"></a> [cite-sources-in-6-and-7-by-path](prompt-dispatch.md#cite-sources-in-6-and-7-by-path)
### <a id="preamble-layout"></a> [preamble-layout](prompt-dispatch.md#preamble-layout) · <a id="step-0--section-3-comes-from-ledger-digestsh"></a> [step-0--section-3-comes-from-ledger-digestsh](prompt-dispatch.md#step-0--section-3-comes-from-ledger-digestsh)
### <a id="artifact-path-helper"></a> [artifact-path-helper](prompt-dispatch.md#artifact-path-helper) · <a id="stageartifactpath"></a> [stageartifactpath](prompt-dispatch.md#stageartifactpath)
### <a id="step-65--after-agent-returns-enforce-statejson-patch"></a> [step-65--after-agent-returns-enforce-statejson-patch](prompt-dispatch.md#step-65--after-agent-returns-enforce-statejson-patch) · <a id="completion-signal-subagents-run-in-the-background-by-default"></a> [completion-signal-subagents-run-in-the-background-by-default](prompt-dispatch.md#completion-signal-subagents-run-in-the-background-by-default)
### <a id="dispatch-tracking-helpers-steps-6a65--ledger-writes-3-only-points-at-the-ledger"></a> [dispatch-tracking-helpers-steps-6a65--ledger-writes-3-only-points-at-the-ledger](prompt-dispatch.md#dispatch-tracking-helpers-steps-6a65--ledger-writes-3-only-points-at-the-ledger) · <a id="shell-quoting-for-headless-dispatch"></a> [shell-quoting-for-headless-dispatch](prompt-dispatch.md#shell-quoting-for-headless-dispatch)
### <a id="banner-relocation--cache-prefix-hygiene"></a> [banner-relocation--cache-prefix-hygiene](prompt-dispatch.md#banner-relocation--cache-prefix-hygiene) · <a id="precondition-check"></a> [precondition-check](loop-entry.md#precondition-check)
### <a id="signals-13-incl-2b"></a> [signals-13-incl-2b](loop-entry.md#signals-13-incl-2b) · <a id="signal-2b-decision-gate"></a> [signal-2b-decision-gate](loop-entry.md#signal-2b-decision-gate)
### <a id="signal-3-fn-gate"></a> [signal-3-fn-gate](loop-entry.md#signal-3-fn-gate) · <a id="after-pl0--steps-13"></a> [after-pl0--steps-13](loop-entry.md#after-pl0--steps-13)
### <a id="step-3--publish-snippet"></a> [step-3--publish-snippet](loop-entry.md#step-3--publish-snippet) · <a id="step-3--publish-fallback-helper_not_found"></a> [step-3--publish-fallback-helper_not_found](loop-entry.md#step-3--publish-fallback-helper_not_found)
### <a id="step-3--non-blocking--skip-rules"></a> [step-3--non-blocking--skip-rules](loop-entry.md#step-3--non-blocking--skip-rules) · <a id="steps-13"></a> [steps-13](loop-entry.md#steps-13)
### <a id="handoff_schema"></a> [handoff_schema](loop-entry.md#handoff_schema) · <a id="steps-23--completion-loop--ready-filter"></a> [steps-23--completion-loop--ready-filter](loop-entry.md#steps-23--completion-loop--ready-filter)
### <a id="step-40"></a> [step-40](dispatch-context.md#step-40) · <a id="agent-type-resolution"></a> [agent-type-resolution](dispatch-context.md#agent-type-resolution)
### <a id="step-45"></a> [step-45](dispatch-context.md#step-45) · <a id="step-46-pre"></a> [step-46-pre](dispatch-context.md#step-46-pre)
### <a id="prompt-injection-steps-4648b--shared-rules"></a> [prompt-injection-steps-4648b--shared-rules](dispatch-context.md#prompt-injection-steps-4648b--shared-rules) · <a id="step-46"></a> [step-46](dispatch-context.md#step-46)
### <a id="step-46--remediation-injection--audit"></a> [step-46--remediation-injection--audit](dispatch-context.md#step-46--remediation-injection--audit) · <a id="step-47"></a> [step-47](dispatch-budgets.md#step-47)
### <a id="step-47--resume-injection"></a> [step-47--resume-injection](dispatch-budgets.md#step-47--resume-injection) · <a id="step-47--resume-audit"></a> [step-47--resume-audit](dispatch-budgets.md#step-47--resume-audit)
### <a id="step-47--turn-budget-banner"></a> [step-47--turn-budget-banner](dispatch-budgets.md#step-47--turn-budget-banner) · <a id="step-47--portability-banner"></a> [step-47--portability-banner](dispatch-budgets.md#step-47--portability-banner)
### <a id="step-47a"></a> [step-47a](dispatch-budgets.md#step-47a) · <a id="step-47a--the-stray-set"></a> [step-47a--the-stray-set](dispatch-budgets.md#step-47a--the-stray-set)
### <a id="step-47a--landing-and-audit"></a> [step-47a--landing-and-audit](dispatch-budgets.md#step-47a--landing-and-audit) · <a id="step-47a--why-the-orchestrator-and-not-a-stash"></a> [step-47a--why-the-orchestrator-and-not-a-stash](dispatch-budgets.md#step-47a--why-the-orchestrator-and-not-a-stash)
### <a id="step-48"></a> [step-48](dispatch-workspace.md#step-48) · <a id="step-48--isolation-banner"></a> [step-48--isolation-banner](dispatch-workspace.md#step-48--isolation-banner)
### <a id="step-48--pin-the-tree"></a> [step-48--pin-the-tree](dispatch-workspace.md#step-48--pin-the-tree) · <a id="step-48--re-stamp-then-read-the-banner-path"></a> [step-48--re-stamp-then-read-the-banner-path](dispatch-workspace.md#step-48--re-stamp-then-read-the-banner-path)
### <a id="step-48--land-consumed-artifacts"></a> [step-48--land-consumed-artifacts](dispatch-workspace.md#step-48--land-consumed-artifacts) · <a id="step-48--a-refused-landing-and-its-release"></a> [step-48--a-refused-landing-and-its-release](dispatch-workspace.md#step-48--a-refused-landing-and-its-release)
### <a id="step-48--assigned-tree-banner--audit"></a> [step-48--assigned-tree-banner--audit](dispatch-workspace.md#step-48--assigned-tree-banner--audit) · <a id="step-48a"></a> [step-48a](dispatch-isolation.md#step-48a)
### <a id="step-48a--scope-banner"></a> [step-48a--scope-banner](dispatch-isolation.md#step-48a--scope-banner) · <a id="step-48a--inject--audit"></a> [step-48a--inject--audit](dispatch-isolation.md#step-48a--inject--audit)
### <a id="step-48b"></a> [step-48b](dispatch-isolation.md#step-48b) · <a id="step-48b--ban-banner--audit"></a> [step-48b--ban-banner--audit](dispatch-isolation.md#step-48b--ban-banner--audit)
### <a id="step-49"></a> [step-49](finalization-gate.md#step-49) · <a id="step-49--sweep-collection-and-classification-a1a2"></a> [step-49--sweep-collection-and-classification-a1a2](finalization-gate.md#step-49--sweep-collection-and-classification-a1a2)
### <a id="step-49--classify-then-auto-answer-a2"></a> [step-49--classify-then-auto-answer-a2](finalization-gate.md#step-49--classify-then-auto-answer-a2) · <a id="step-49--checkpoint-and-bypass-paths"></a> [step-49--checkpoint-and-bypass-paths](finalization-gate.md#step-49--checkpoint-and-bypass-paths)
### <a id="step-49--sweep-render-then-the-unmoved-stop-cd"></a> [step-49--sweep-render-then-the-unmoved-stop-cd](finalization-gate.md#step-49--sweep-render-then-the-unmoved-stop-cd) · <a id="step-49--the-approvereject-stop-d-unmoved"></a> [step-49--the-approvereject-stop-d-unmoved](finalization-gate.md#step-49--the-approvereject-stop-d-unmoved)
### <a id="step-49--bypass-path"></a> [step-49--bypass-path](finalization-gate.md#step-49--bypass-path) · <a id="steps-55a"></a> [steps-55a](dispatch-routing.md#steps-55a)
### <a id="step-5b"></a> [step-5b](dispatch-routing.md#step-5b) · <a id="step-5c--no-platform-warm-up"></a> [step-5c--no-platform-warm-up](dispatch-routing.md#step-5c--no-platform-warm-up)
### <a id="step-5d"></a> [step-5d](dispatch-routing.md#step-5d) · <a id="step-5e"></a> [step-5e](dispatch-routing.md#step-5e)
### <a id="step-6--typed-schema-dispatch"></a> [step-6--typed-schema-dispatch](dispatch-agent.md#step-6--typed-schema-dispatch) · <a id="step-6--degrade-path--cache-prefix"></a> [step-6--degrade-path--cache-prefix](dispatch-agent.md#step-6--degrade-path--cache-prefix)
### <a id="step-5f--model-resolution"></a> [step-5f--model-resolution](dispatch-agent.md#step-5f--model-resolution) · <a id="step-6--compose-the-brief"></a> [step-6--compose-the-brief](dispatch-agent.md#step-6--compose-the-brief)
### <a id="step-6--splice-the-injections"></a> [step-6--splice-the-injections](dispatch-agent.md#step-6--splice-the-injections) · <a id="step-6--session-identifiers-r4-2"></a> [step-6--session-identifiers-r4-2](dispatch-agent.md#step-6--session-identifiers-r4-2)
### <a id="step-6--route-before-every-dispatch-headless-or-in-process"></a> [step-6--route-before-every-dispatch-headless-or-in-process](dispatch-agent.md#step-6--route-before-every-dispatch-headless-or-in-process) · <a id="step-6--the-effort-argument-and-the-route-row"></a> [step-6--the-effort-argument-and-the-route-row](dispatch-agent.md#step-6--the-effort-argument-and-the-route-row)
### <a id="step-6--agent-dispatch-inproc-or-headless-dispatchsh-headless"></a> [step-6--agent-dispatch-inproc-or-headless-dispatchsh-headless](dispatch-agent.md#step-6--agent-dispatch-inproc-or-headless-dispatchsh-headless) · <a id="step-6--the-dispatch-call"></a> [step-6--the-dispatch-call](dispatch-agent.md#step-6--the-dispatch-call)
### <a id="step-6a"></a> [step-6a](dispatch-recording.md#step-6a) · <a id="step-6a--id-less-entry"></a> [step-6a--id-less-entry](dispatch-recording.md#step-6a--id-less-entry)
### <a id="step-6a--keys---dispatch-does-not-write"></a> [step-6a--keys---dispatch-does-not-write](dispatch-recording.md#step-6a--keys---dispatch-does-not-write) · <a id="step-65"></a> [step-65](completion-merge.md#step-65)
### <a id="step-65a--errored-return"></a> [step-65a--errored-return](completion-merge.md#step-65a--errored-return) · <a id="step-65a--last_error-patch"></a> [step-65a--last_error-patch](completion-merge.md#step-65a--last_error-patch)
### <a id="step-65a--why-the-arm-ends-in-continue"></a> [step-65a--why-the-arm-ends-in-continue](completion-merge.md#step-65a--why-the-arm-ends-in-continue) · <a id="step-65a1a4--the-return-arms-before-layer-2"></a> [step-65a1a4--the-return-arms-before-layer-2](completion-merge.md#step-65a1a4--the-return-arms-before-layer-2)
### <a id="step-65a2--incomplete-return-mid-stage-yield"></a> [step-65a2--incomplete-return-mid-stage-yield](completion-merge.md#step-65a2--incomplete-return-mid-stage-yield) · <a id="step-65a3--route-every-typed-blocked-return"></a> [step-65a3--route-every-typed-blocked-return](completion-merge.md#step-65a3--route-every-typed-blocked-return)
### <a id="step-65a3--what-the-route-result-decides"></a> [step-65a3--what-the-route-result-decides](completion-merge.md#step-65a3--what-the-route-result-decides) · <a id="step-65a4--message-ack-check"></a> [step-65a4--message-ack-check](completion-artifacts.md#step-65a4--message-ack-check)
### <a id="step-65a4--detect-and-park-permission-denial"></a> [step-65a4--detect-and-park-permission-denial](completion-artifacts.md#step-65a4--detect-and-park-permission-denial) · <a id="step-65a4--which-returns-reach-classify"></a> [step-65a4--which-returns-reach-classify](completion-artifacts.md#step-65a4--which-returns-reach-classify)
### <a id="step-65a4--what-the-orchestrator-never-does-with-a-denial"></a> [step-65a4--what-the-orchestrator-never-does-with-a-denial](completion-artifacts.md#step-65a4--what-the-orchestrator-never-does-with-a-denial) · <a id="step-65--verdict--status"></a> [step-65--verdict--status](completion-artifacts.md#step-65--verdict--status)
### <a id="step-65--layer-2-synchronous-patch"></a> [step-65--layer-2-synchronous-patch](completion-artifacts.md#step-65--layer-2-synchronous-patch) · <a id="step-65--layer-3-f3"></a> [step-65--layer-3-f3](completion-artifacts.md#step-65--layer-3-f3)
### <a id="step-65b--dispatch-entry-completed"></a> [step-65b--dispatch-entry-completed](completion-artifacts.md#step-65b--dispatch-entry-completed) · <a id="step-65c--sweep-checks-before-anything-reads-the-sweep"></a> [step-65c--sweep-checks-before-anything-reads-the-sweep](completion-sweep.md#step-65c--sweep-checks-before-anything-reads-the-sweep)
### <a id="step-65d--land-the-producers-artifacts"></a> [step-65d--land-the-producers-artifacts](completion-sweep.md#step-65d--land-the-producers-artifacts) · <a id="step-65d--resume-a-stage-parked-on-this-producers-artifact"></a> [step-65d--resume-a-stage-parked-on-this-producers-artifact](completion-sweep.md#step-65d--resume-a-stage-parked-on-this-producers-artifact)
### <a id="step-65d--a-parked-stage-is-never-landed-into"></a> [step-65d--a-parked-stage-is-never-landed-into](completion-sweep.md#step-65d--a-parked-stage-is-never-landed-into) · <a id="step-65d--reporting-a-refused-landing"></a> [step-65d--reporting-a-refused-landing](completion-sweep.md#step-65d--reporting-a-refused-landing)
### <a id="step-65d--settle-the-consumers-of-a-re-opened-task"></a> [step-65d--settle-the-consumers-of-a-re-opened-task](completion-sweep.md#step-65d--settle-the-consumers-of-a-re-opened-task) · <a id="step-65d--settle-invocation"></a> [step-65d--settle-invocation](completion-sweep.md#step-65d--settle-invocation)
### <a id="step-65d--resume-the-stage-that-raised-the-correction"></a> [step-65d--resume-the-stage-that-raised-the-correction](completion-sweep.md#step-65d--resume-the-stage-that-raised-the-correction) · <a id="step-65d--notes"></a> [step-65d--notes](completion-sweep.md#step-65d--notes)
### <a id="step-66--blocking-sweep-items-before-the-next-dispatch"></a> [step-66--blocking-sweep-items-before-the-next-dispatch](completion-boundary.md#step-66--blocking-sweep-items-before-the-next-dispatch) · <a id="step-66a--resolve"></a> [step-66a--resolve](completion-boundary.md#step-66a--resolve)
### <a id="route-the-resolver-tier"></a> [route-the-resolver-tier](completion-boundary.md#route-the-resolver-tier) · <a id="step-66b--render-the-remainder"></a> [step-66b--render-the-remainder](completion-boundary.md#step-66b--render-the-remainder)
### <a id="step-7"></a> [step-7](retry-routing.md#step-7) · <a id="step-7a--the-mailbox-round-before-both-batches"></a> [step-7a--the-mailbox-round-before-both-batches](retry-routing.md#step-7a--the-mailbox-round-before-both-batches)
### <a id="step-7a--permission-batch-at-the-boundary"></a> [step-7a--permission-batch-at-the-boundary](retry-routing.md#step-7a--permission-batch-at-the-boundary) · <a id="step-7a--one-prompt-then-each-resume"></a> [step-7a--one-prompt-then-each-resume](retry-routing.md#step-7a--one-prompt-then-each-resume)
### <a id="step-7a--wake-on-the-earliest-deadline"></a> [step-7a--wake-on-the-earliest-deadline](retry-routing.md#step-7a--wake-on-the-earliest-deadline) · <a id="step-7a--the-parked-need-arms"></a> [step-7a--the-parked-need-arms](retry-routing.md#step-7a--the-parked-need-arms)
### <a id="step-7--loop-back-arm"></a> [step-7--loop-back-arm](retry-routing.md#step-7--loop-back-arm) · <a id="step-7--loop-back-full-set-fallback"></a> [step-7--loop-back-full-set-fallback](retry-routing.md#step-7--loop-back-full-set-fallback)
### <a id="step-7--loop-back-replay-then-stamp"></a> [step-7--loop-back-replay-then-stamp](retry-routing.md#step-7--loop-back-replay-then-stamp) · <a id="key-rules"></a> [key-rules](completion-handoff.md#key-rules)
### <a id="key-rules--completion--tooling"></a> [key-rules--completion--tooling](completion-handoff.md#key-rules--completion--tooling) · <a id="do-not-reintroduce-the-task-system"></a> [do-not-reintroduce-the-task-system](completion-handoff.md#do-not-reintroduce-the-task-system)
### <a id="pl-issue-publish"></a> [pl-issue-publish](completion-handoff.md#pl-issue-publish) · <a id="platform-tooling-ownership"></a> [platform-tooling-ownership](completion-handoff.md#platform-tooling-ownership)
### <a id="no-pre-warm-and-what-to-expect"></a> [no-pre-warm-and-what-to-expect](completion-handoff.md#no-pre-warm-and-what-to-expect) · <a id="dv-batch-checkpointing"></a> [dv-batch-checkpointing](completion-handoff.md#dv-batch-checkpointing)
### <a id="hand-back-guard"></a> [hand-back-guard](completion-handoff.md#hand-back-guard) · <a id="hand-back-guard--the-live-check"></a> [hand-back-guard--the-live-check](completion-handoff.md#hand-back-guard--the-live-check)
### <a id="hand-back-guard--verdicts"></a> [hand-back-guard--verdicts](completion-handoff.md#hand-back-guard--verdicts) · <a id="hand-back-guard--parked-children"></a> [hand-back-guard--parked-children](completion-handoff.md#hand-back-guard--parked-children)
### <a id="hand-back-guard--the-audit-row"></a> [hand-back-guard--the-audit-row](completion-handoff.md#hand-back-guard--the-audit-row) · <a id="auto-decision-delegation-decision_gate"></a> [auto-decision-delegation-decision_gate](decision-delegation.md#auto-decision-delegation-decision_gate)
### <a id="decision_gate--what-none-of-the-three-may-touch"></a> [decision_gate--what-none-of-the-three-may-touch](decision-delegation.md#decision_gate--what-none-of-the-three-may-touch) · <a id="delegate-duties"></a> [delegate-duties](decision-delegation.md#delegate-duties)
### <a id="orchestrator-ledger-merge"></a> [orchestrator-ledger-merge](decision-delegation.md#orchestrator-ledger-merge) · <a id="sweep-items-at-the-fn-gate"></a> [sweep-items-at-the-fn-gate](decision-delegation.md#sweep-items-at-the-fn-gate)
### <a id="escalation-class"></a> [escalation-class](decision-delegation.md#escalation-class) · <a id="fn-gate"></a> [fn-gate](finalization-policy.md#fn-gate)
### <a id="fn-gate-paths"></a> [fn-gate-paths](finalization-policy.md#fn-gate-paths) · <a id="fn-gate-paths--bypass"></a> [fn-gate-paths--bypass](finalization-policy.md#fn-gate-paths--bypass)
### <a id="fn-gate-rejection--resume-path"></a> [fn-gate-rejection--resume-path](finalization-policy.md#fn-gate-rejection--resume-path) · <a id="fn-gate-rejection--invariants"></a> [fn-gate-rejection--invariants](finalization-policy.md#fn-gate-rejection--invariants)
### <a id="at-the-fn-stage"></a> [at-the-fn-stage](finalization-policy.md#at-the-fn-stage) · <a id="post-capture-issue-update-visual-evidence"></a> [post-capture-issue-update-visual-evidence](finalization-publish.md#post-capture-issue-update-visual-evidence)
### <a id="post-capture-publish-snippet"></a> [post-capture-publish-snippet](finalization-publish.md#post-capture-publish-snippet) · <a id="post-capture-fallback-audit-helper_not_found"></a> [post-capture-fallback-audit-helper_not_found](finalization-publish.md#post-capture-fallback-audit-helper_not_found)
### <a id="post-capture-self-gating--dedup"></a> [post-capture-self-gating--dedup](finalization-publish.md#post-capture-self-gating--dedup) · <a id="post-merge-completion-comment"></a> [post-merge-completion-comment](finalization-publish.md#post-merge-completion-comment)
### <a id="completion-snippet"></a> [completion-snippet](finalization-publish.md#completion-snippet) · <a id="completion-pr-ref-resolution"></a> [completion-pr-ref-resolution](finalization-publish.md#completion-pr-ref-resolution)
### <a id="completion-issue-resolution--summary-sourcing"></a> [completion-issue-resolution--summary-sourcing](finalization-publish.md#completion-issue-resolution--summary-sourcing) · <a id="completion-dedup-audit-rows--timing"></a> [completion-dedup-audit-rows--timing](finalization-publish.md#completion-dedup-audit-rows--timing)
### <a id="post-worktask-self-improvement"></a> [post-worktask-self-improvement](finalization-publish.md#post-worktask-self-improvement) · <a id="resume-after-interruption"></a> [resume-after-interruption](finalization-publish.md#resume-after-interruption)
### <a id="scripts"></a> [scripts](script-routing.md#scripts) · <a id="blocked-on-libsh--the-arm-table"></a> [blocked-on-libsh--the-arm-table](script-routing.md#blocked-on-libsh--the-arm-table)
### <a id="related"></a> [related](script-routing.md#related)
