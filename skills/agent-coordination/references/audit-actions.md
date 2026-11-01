# Audit action registry

Every `action` value a shipped writer puts in `.context/logs/audit.jsonl`, grouped by writer. Row shape: `../SKILL.md § Schema`; per-writer metadata: `../SKILL.md § Writers` and the writer's own doc.

Each group's `actions:` line is the registry: `tests/shell/skills/agent-coordination__audit-action-enum.bats` fails when a script writes a literal action no line lists. Add a new action here in the same change that first writes it.

## Orchestrator — stage loop

Writers: `skills/worktask/SKILL.md` Steps 4–7 and § Hand-back guard, `commands/worktask.md`, `skills/megatask/SKILL.md` (track hold), `brief-compose.sh` (`gate_remediation_injected`).

actions: `worktask_init`, `stage_transition`, `approval_received`, `resume`, `stage_replay`, `permission_mode_pinned`, `dispatch_depth_projected`, `stage_returned_incomplete`, `reattach_send_result`, `gate_remediation_injected`, `dv_checkpoint_resume`, `dv_worktree_enforced`, `dv_test_scope_enforced`, `stage_test_ban_enforced`, `brief_compose_failed`, `model_resolution_constrained`, `artifact_path_resolved`, `routing_override`, `routing_override_partial`, `effort_clamped`, `resolver_skipped`, `workspace_path_unstamped`, `worktree_isolation_waived`, `handback_guard`, `consult_divergence`

## Orchestrator — parks, mailbox and contracts

Writers: `permission-park.sh`, `blocked-on-dispatch.sh`, `mailbox.sh`, `land-artifacts.sh`; `permission_denied` also comes from `hook:permission-denied`.

actions: `blocked_on`, `mailbox_ingest`, `escalation_parked`, `permission_denied`, `permission_resumed`, `ar_contract_landed`, `contract_landed`, `ar_ref_check`

## Orchestrator — plan gate and sweeps

Writers: `commands/worktask.md` Steps A–C, `autonomy-preflight.sh`, `publish-pl-issue.sh`, `refine-branch-target.sh`.

actions: `autonomy_preflight`, `autonomy_preflight_record_failed`, `preflight_issue_candidates`, `auto_decision_dispatched`, `auto_decision_resolved`, `plan_revision_dispatched`, `approval_rejected`, `github_issue_created`, `branch_convention_check`, `branch_slug_truncated`, `branch_target_refined`, `sweep_check`, `sweep_recorded`, `sweep_resolved`, `sweep_escalation_unprompted`

## FN lane

Writers: `skills/worktask/references/fn-gate.md`, `fn-preflight-cmds.sh`, `fn-stream-merge.sh`, `branch-name.sh`, `pr-body-lint.sh`, `stream-diff.sh`.

actions: `fn_gate_waiting`, `fn_gate_bypass`, `fn_revision_dispatched`, `base_sanity`, `branch_continuity`, `branch_divergence_detected`, `branch_renamed`, `issue_close_required`, `pr_body_gate`, `pr_body_lint`, `pr_body_sanitised`, `pr_issue_link`, `staging`, `unresolved_decisions_emitted`, `fn_stream_arm`, `fn_stream_commit`, `fn_stream_merge`, `stream_diff_resolved`

## FN lane — visual evidence and wrap-up

Writers: `attach-visual-evidence.sh`, `attachments-preseed.sh`, `adhoc-visual-evidence.sh`, `/improve-yourself`.

actions: `fn_attachments_preseed_failed`, `visual_evidence_degraded`, `visual_evidence_issue_commented`, `visual_evidence_pr_emitted`, `completion_summary_commented`, `adhoc_visual_evidence`, `self_improvement_applied`

## Megatask

Writers: `commands/megatask.md` R1, `hook:megatask-monitor`, `megatask-settle.sh`.

actions: `batch_approved`, `batch_rejected`, `megatask_progress`, `megatask_escalated`

## Stage agents

Writers: the agent files under `agents/`; `external_dispatch` from a CI or shell dispatcher.

actions: `artifact_created`, `error_recorded`, `retry_attempt`, `escalation`, `full_test_run`, `scoped_test_run`, `message_ack`, `dispatch_flattened`, `approval_check`, `platform_detected`, `delegation`, `plugin_unavailable`, `exploration_extended`, `workspace_path_mismatch`, `worktree_isolation_missing`, `external_dispatch`

## Ledger scripts

Writers: `state-patch.sh`, `handoff-harness.sh`.

actions: `facts_items_rejected`, `lock_release_foreign`, `state_write_unlocked`, `model_override`, `model_override_unknown`, `model_override_unparsed`, `model_unresolved`, `count_corroboration`

## Plugin hooks

Writers: `hooks/`: audit-subagent, audit-tooluse, precompact, agent-stop, state-merge, session-end-finalize, test-execution-gate.

actions: `subagent_stopped`, `subagent_stops_suppressed`, `tool_invoked`, `precompact_checkpoint`, `stage_completion_hook`, `state_repair`, `session_end_finalize`, `test_execution_blocked`, `test_execution_deduped`, `test_dedupe_skipped_zero_prior`, `test_delegation_observed`, `test_gate_disabled`, `test_dedupe_disabled`

## Plugin hooks — model switch, decisions, DV gates

Writers: `hooks/`: model-switch-gate, model-switch-audit, user-decision-record, dv-comment-density-gate, dv-screenshot-gate.

actions: `model_switch_blocked`, `model_switch_confirm_requested`, `model_switch_annotated`, `model_switch_gate_disabled`, `model_switched`, `user_decision_recorded`, `user_decision_refused`, `user_decision_ledger_write_denied`, `comment_density_pass`, `comment_density_block`, `screenshot_gate_pass`, `screenshot_gate_block`

## Screenshot capture

Writers: `skills/dv-screenshot-capture/` adapters and scripts.

actions: `canvas_render`, `preview_added`, `visual_diff_run`, `screenshot_captured`, `screenshot_skipped`, `screenshot_platform_fallback`, `screenshot_size_warn`, `screenshot_size_fail`, `screenshot_count_exceeded`, `screenshot_capture_failed`, `screenshot_flag_escalated`
