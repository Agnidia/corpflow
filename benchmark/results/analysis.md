# Benchmark Analysis — live-20261020T142527Z-f3f093f (live)

_as of 2026-10-20T14:25:40Z_

## totals

| metric | WITH | WITHOUT | Δ | premium % |
|---|---|---|---|---|
| tokens total | 210259 | 163139 | 47120 | 28.9% |
| cost (USD) | 9.27 | 6.61 | 2.67 | 40.4% |

## per-stage

| stage | arm | cost (USD) | cost share % | out tokens | out share % | cache-hit % | tool calls |
|---|---|---|---|---|---|---|---|
| PL | with | 1.23 | 7.8% | 31861 | 8.5% | 91.4% | 21 |
| AR | with | 1.02 | 6.4% | 22718 | 6.1% | 80.1% | 7 |
| TL | with | 0.13 | 0.8% | 3254 | 0.9% | 71.4% | 4 |
| DV | with | 4.41 | 27.8% | 97989 | 26.3% | 96.6% | 45 |
| DR | with | 1.07 | 6.8% | 14182 | 3.8% | 88.6% | 16 |
| SR | with | 0.85 | 5.4% | 14933 | 4.0% | 87.8% | 12 |
| QA | with | 0.14 | 0.9% | 2132 | 0.6% | 78.3% | 5 |
| DC | with | 0.02 | 0.1% | 14741 | 4.0% | 91.4% | 16 |
| FN | with | 0.16 | 1.0% | 3300 | 0.9% | 75.3% | 4 |
| ST | with | 0.25 | 1.5% | 4883 | 1.3% | 86.6% | 9 |
| PL | without | 0.54 | 3.4% | 16008 | 4.3% | 73.6% | 3 |
| AR | without | 1.08 | 6.8% | 33184 | 8.9% | 54.8% | 2 |
| TL | without | 0.16 | 1.0% | 3392 | 0.9% | 68.9% | 3 |
| DV | without | 3.28 | 20.7% | 78609 | 21.1% | 95.9% | 31 |
| DR | without | 0.64 | 4.0% | 9263 | 2.5% | 85.2% | 8 |
| SR | without | 0.57 | 3.6% | 7936 | 2.1% | 85.1% | 8 |
| QA | without | 0.10 | 0.6% | 1906 | 0.5% | 83.4% | 4 |
| DC | without | 0.01 | 0.1% | 5837 | 1.6% | 82.4% | 6 |
| FN | without | 0.15 | 0.9% | 4781 | 1.3% | 89.3% | 6 |
| ST | without | 0.08 | 0.5% | 2067 | 0.6% | 85.9% | 3 |

## paired-tokens

| stage | WITH in | WITH cached-in | WITH out | WITHOUT in | WITHOUT cached-in | WITHOUT out |
|---|---|---|---|---|---|---|
| PL | 38 | 682165 | 31861 | 8 | 97042 | 16008 |
| AR | 14 | 322165 | 22718 | 6 | 110735 | 33184 |
| TL | 8 | 76920 | 3254 | 6 | 98871 | 3392 |
| DV | 82 | 5243786 | 97989 | 64 | 3271631 | 78609 |
| DR | 30 | 727394 | 14182 | 16 | 335884 | 9263 |
| SR | 26 | 479276 | 14933 | 16 | 305110 | 7936 |
| QA | 10 | 121423 | 2132 | 8 | 105948 | 1906 |
| DC | 30 | 543795 | 14741 | 10 | 159232 | 5837 |
| FN | 10 | 115947 | 3300 | 14 | 189292 | 4781 |
| ST | 18 | 315243 | 4883 | 8 | 89055 | 2067 |

## cache-economics

| stage | arm | cache_creation |
|---|---|---|
| DV | with | 179749 |
| DV | without | 135168 |
| DR | with | 82581 |
| AR | with | 64139 |
| PL | with | 58831 |

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
| test_count (self-written) | 54 | 91 |

**Descriptive only** — size, not quality. More lines for the same feature is
not a better result.

| metric | WITH | WITHOUT |
|---|---|---|
| loc_produced | 2838 | 2779 |
| tokens per LOC | 74.087 | 58.7042 |

## validity-caveats

- n=1: single-run comparison; treat deltas as directional, not statistically robust.

## improvement-candidates

- [ ] (stage_cost_outlier) PL [with]: cost $1.2327 is 3.14x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) AR [with]: cost $1.0191 is 2.60x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) DV [with]: cost $4.4109 is 11.24x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) DR [with]: cost $1.0734 is 2.74x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) SR [with]: cost $0.8515 is 2.17x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) AR [without]: cost $1.0762 is 2.74x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) DV [without]: cost $3.2811 is 8.36x the per-stage median ($0.3924)
- [ ] (stage_cost_outlier) DR [without]: cost $0.6392 is 1.63x the per-stage median ($0.3924)
- [ ] (out_token_spike) PL [with]: out-tokens 31861 is 3.70x the per-stage median (8600)
- [ ] (out_token_spike) AR [with]: out-tokens 22718 is 2.64x the per-stage median (8600)
- [ ] (out_token_spike) DV [with]: out-tokens 97989 is 11.39x the per-stage median (8600)
- [ ] (out_token_spike) DR [with]: out-tokens 14182 is 1.65x the per-stage median (8600)
- [ ] (out_token_spike) SR [with]: out-tokens 14933 is 1.74x the per-stage median (8600)
- [ ] (out_token_spike) DC [with]: out-tokens 14741 is 1.71x the per-stage median (8600)
- [ ] (out_token_spike) PL [without]: out-tokens 16008 is 1.86x the per-stage median (8600)
- [ ] (out_token_spike) AR [without]: out-tokens 33184 is 3.86x the per-stage median (8600)
- [ ] (out_token_spike) DV [without]: out-tokens 78609 is 9.14x the per-stage median (8600)
- [ ] (tool_call_spike) DV [with]: 45 tool calls exceeds max(40, 1.5x median) = 40
