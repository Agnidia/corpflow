# Benchmark Analysis — live-20261105T132921Z-5c28c0e-joined-30983432 (live)

_as of 2026-11-05T13:29:21Z_

## totals

| metric | WITH | WITHOUT | Δ | premium % |
|---|---|---|---|---|
| tokens total | 251492 | 179076 | 72416 | 40.4% |
| cost (USD) | 10.20 | 6.41 | 3.78 | 59.0% |

## per-stage

| stage | arm | cost (USD) | cost share % | out tokens | out share % | cache-hit % | tool calls |
|---|---|---|---|---|---|---|---|
| PL | with | 1.30 | 7.8% | 31924 | 8.2% | 91.7% | 23 |
| AR | with | 1.16 | 7.0% | 26764 | 6.9% | 83.2% | 8 |
| TL | with | 0.15 | 0.9% | 4898 | 1.3% | 73.0% | 4 |
| DV | with | 5.30 | 31.9% | 121154 | 31.2% | 96.7% | 47 |
| DR | with | 0.89 | 5.4% | 11493 | 3.0% | 87.9% | 13 |
| SR | with | 0.88 | 5.3% | 15172 | 3.9% | 87.2% | 14 |
| QA | with | 0.14 | 0.9% | 2006 | 0.5% | 76.7% | 4 |
| DC | with | 0.02 | 0.1% | 9583 | 2.5% | 82.2% | 11 |
| FN | with | 0.15 | 0.9% | 3704 | 1.0% | 78.5% | 5 |
| ST | with | 0.20 | 1.2% | 3573 | 0.9% | 75.5% | 5 |
| PL | without | 0.66 | 4.0% | 20434 | 5.3% | 68.9% | 3 |
| AR | without | 1.22 | 7.3% | 36513 | 9.4% | 76.4% | 4 |
| TL | without | 0.16 | 1.0% | 3059 | 0.8% | 65.5% | 3 |
| DV | without | 2.97 | 17.9% | 70856 | 18.3% | 94.9% | 29 |
| DR | without | 0.63 | 3.8% | 7289 | 1.9% | 83.1% | 9 |
| SR | without | 0.53 | 3.2% | 8480 | 2.2% | 80.3% | 7 |
| QA | without | 0.08 | 0.5% | 1618 | 0.4% | 81.5% | 3 |
| DC | without | 0.01 | 0.1% | 5648 | 1.5% | 85.7% | 9 |
| FN | without | 0.10 | 0.6% | 2420 | 0.6% | 87.7% | 5 |
| ST | without | 0.07 | 0.4% | 1642 | 0.4% | 83.4% | 3 |

## paired-tokens

| stage | WITH in | WITH cached-in | WITH out | WITHOUT in | WITHOUT cached-in | WITHOUT out |
|---|---|---|---|---|---|---|
| PL | 2617 | 808874 | 31924 | 2583 | 101887 | 20434 |
| AR | 2033 | 423872 | 26764 | 2025 | 243664 | 36513 |
| TL | 1904 | 91663 | 4898 | 1900 | 92183 | 3059 |
| DV | 2879 | 6358812 | 121154 | 2851 | 2626415 | 70856 |
| DR | 2150 | 594027 | 11493 | 2140 | 325575 | 7289 |
| SR | 2048 | 495389 | 15172 | 2036 | 213066 | 8480 |
| QA | 2127 | 126937 | 2006 | 2125 | 85334 | 1618 |
| DC | 1832 | 251184 | 9583 | 1830 | 231594 | 5648 |
| FN | 1833 | 131532 | 3704 | 1833 | 145137 | 2420 |
| ST | 1798 | 156462 | 3573 | 1794 | 79901 | 1642 |

## cache-economics

| stage | arm | cache_creation |
|---|---|---|
| DV | with | 205620 |
| DV | without | 131325 |
| DR | with | 69783 |
| AR | with | 69561 |
| PL | with | 64478 |

## quality-delta

**Held-out oracle** — the arm's binary scored against goldens captured from
`ttt-template`. This is the only quality signal here the arm did not author.

| metric | WITH | WITHOUT |
|---|---|---|
| oracle cases passed | 42/42 (100.0%) | 42/42 (100.0%) |
| ├ specified (contract restated) | 33/33 (100.0%) | 33/33 (100.0%) |
| └ implied (derived from the rules) | 9/9 (100.0%) | 9/9 (100.0%) |
| pass_fail | pass | pass |

`pass_fail` reads the specified tier alone — an arm is not failed for behaviour
nobody described to it. The implied tier is the discriminating signal.

**Self-graded** — the arm wrote both the implementation and these tests, so
a high count is not evidence of correctness.

| metric | WITH | WITHOUT |
|---|---|---|
| test_count (self-written) | 84 | 81 |

**Descriptive only** — size, not quality. More lines for the same feature is
not a better result.

| metric | WITH | WITHOUT |
|---|---|---|
| loc_produced | 2776 | 2412 |
| tokens per LOC | 90.5951 | 74.2438 |

## validity-caveats

- cross-era vs previous run live-codex-20261102T213202Z-5d14a20: prompt_contract: 'scripted-cli-v4' vs 'scripted-cli-v5'; provider: 'codex' vs 'claude'; pricing: {'id': 'openai-standard-short-2026-11-02', 'source': 'https://developers.openai.com/api/docs/pricing', 'verified_at': '2026-11-02', 'basis': 'API-equivalent USD, standard tier, implicit caching, context limited to 200000 tokens', 'per_million': {'gpt-6.1-sol': {'input': 2.0, 'cached_input': 0.1, 'output': 10.0}, 'gpt-6.1-terra': {'input': 1.0, 'cached_input': 0.05, 'output': 5.0}, 'gpt-6-luna': {'input': 0.1, 'cached_input': 0.01, 'output': 0.5}, 'gpt-6-astra': {'input': 10.0, 'cached_input': 1.0, 'output': 50.0}}} vs {'basis': 'CLI-reported USD', 'source': 'result.total_cost_usd'}; source_digest: 'fed0235dcf56d385fae28759d764aca5297a32afe36a4f4c787b2e5fee9958e8' vs '35d061bf207c7fa7e98a83e191423b9a267c9d96030590b17b3efa873f1e6cd0'; plugin_snapshot_digest: '971200b38c1db61207a308c5e7bcf3a13ff2a2a1f8e7c954b491330bf315afb6' vs None; cli_version: 'codex-cli 0.166.0' vs '2.1.318 (Claude Code)'; efforts: {'PL': 'high', 'AR': 'high', 'TL': 'medium', 'DV': 'high', 'DR': 'high', 'SR': 'xhigh', 'QA': 'medium', 'DC': 'low', 'FN': 'medium', 'ST': 'low'} vs None; context_window: 200000 vs None; model_pins: AR 'gpt-6.1-sol'→'claude-opus-5-5', DC 'gpt-6-luna'→'claude-haiku-5-5', DR 'gpt-6.1-sol'→'claude-opus-5-5', DV 'gpt-6.1-sol'→'claude-opus-5-5', FN 'gpt-6.1-terra'→'claude-sonnet-5-5', PL 'gpt-6.1-sol'→'claude-opus-5-5', QA 'gpt-6.1-terra'→'claude-sonnet-5-5', SR 'gpt-6.1-sol'→'claude-opus-5-5', ST 'gpt-6.1-terra'→'claude-sonnet-5-5', TL 'gpt-6.1-terra'→'claude-sonnet-5-5' — token, cost, and quality figures are NOT comparable across this boundary.
- n=1: single-run comparison; treat deltas as directional, not statistically robust.

## improvement-candidates

- [ ] (stage_cost_outlier) PL [with]: cost $1.3030 is 3.61x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) AR [with]: cost $1.1624 is 3.22x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) DV [with]: cost $5.2987 is 14.67x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) DR [with]: cost $0.8927 is 2.47x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) SR [with]: cost $0.8816 is 2.44x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) PL [without]: cost $0.6562 is 1.82x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) AR [without]: cost $1.2152 is 3.36x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) DV [without]: cost $2.9667 is 8.21x the per-stage median ($0.3612)
- [ ] (stage_cost_outlier) DR [without]: cost $0.6263 is 1.73x the per-stage median ($0.3612)
- [ ] (out_token_spike) PL [with]: out-tokens 31924 is 4.05x the per-stage median (7884)
- [ ] (out_token_spike) AR [with]: out-tokens 26764 is 3.39x the per-stage median (7884)
- [ ] (out_token_spike) DV [with]: out-tokens 121154 is 15.37x the per-stage median (7884)
- [ ] (out_token_spike) SR [with]: out-tokens 15172 is 1.92x the per-stage median (7884)
- [ ] (out_token_spike) PL [without]: out-tokens 20434 is 2.59x the per-stage median (7884)
- [ ] (out_token_spike) AR [without]: out-tokens 36513 is 4.63x the per-stage median (7884)
- [ ] (out_token_spike) DV [without]: out-tokens 70856 is 8.99x the per-stage median (7884)
- [ ] (tool_call_spike) DV [with]: 47 tool calls exceeds max(40, 1.5x median) = 40
