# Benchmark Analysis — live-20261102T084536Z-9171724 (live)

_as of 2026-11-02T08:45:38Z_

## totals

| metric | WITH | WITHOUT | Δ | premium % |
|---|---|---|---|---|
| tokens total | 223275 | 180053 | 43222 | 24.0% |
| cost (USD) | 10.18 | 6.97 | 3.21 | 46.0% |

## per-stage

| stage | arm | cost (USD) | cost share % | out tokens | out share % | cache-hit % | tool calls |
|---|---|---|---|---|---|---|---|
| PL | with | 1.17 | 6.8% | 31911 | 7.9% | 90.6% | 18 |
| AR | with | 1.11 | 6.5% | 24787 | 6.2% | 82.6% | 8 |
| TL | with | 0.11 | 0.6% | 2792 | 0.7% | 71.2% | 3 |
| DV | with | 5.59 | 32.6% | 116371 | 28.9% | 95.1% | 42 |
| DR | with | 0.86 | 5.0% | 11799 | 2.9% | 89.2% | 13 |
| SR | with | 0.78 | 4.6% | 13692 | 3.4% | 88.0% | 14 |
| QA | with | 0.14 | 0.8% | 2192 | 0.5% | 77.9% | 5 |
| DC | with | 0.02 | 0.1% | 11492 | 2.9% | 89.3% | 11 |
| FN | with | 0.16 | 1.0% | 3420 | 0.8% | 69.9% | 3 |
| ST | with | 0.23 | 1.4% | 4543 | 1.1% | 88.2% | 10 |
| PL | without | 0.61 | 3.6% | 18145 | 4.5% | 83.0% | 5 |
| AR | without | 1.24 | 7.2% | 38620 | 9.6% | 49.8% | 2 |
| TL | without | 0.16 | 0.9% | 3479 | 0.9% | 66.8% | 3 |
| DV | without | 3.37 | 19.6% | 88480 | 22.0% | 94.9% | 27 |
| DR | without | 0.72 | 4.2% | 9355 | 2.3% | 85.7% | 8 |
| SR | without | 0.60 | 3.5% | 8514 | 2.1% | 90.8% | 14 |
| QA | without | 0.08 | 0.4% | 1836 | 0.5% | 90.1% | 5 |
| DC | without | 0.01 | 0.1% | 5910 | 1.5% | 86.3% | 6 |
| FN | without | 0.12 | 0.7% | 3709 | 0.9% | 89.5% | 6 |
| ST | without | 0.07 | 0.4% | 1837 | 0.5% | 86.4% | 3 |

## paired-tokens

| stage | WITH in | WITH cached-in | WITH out | WITHOUT in | WITHOUT cached-in | WITHOUT out |
|---|---|---|---|---|---|---|
| PL | 34 | 577038 | 31911 | 12 | 164309 | 18145 |
| AR | 16 | 395353 | 24787 | 6 | 112872 | 38620 |
| TL | 8 | 66602 | 2792 | 6 | 91030 | 3479 |
| DV | 102 | 5607604 | 116371 | 54 | 2654486 | 88480 |
| DR | 28 | 601142 | 11799 | 18 | 401981 | 9355 |
| SR | 24 | 445112 | 13692 | 24 | 470615 | 8514 |
| QA | 10 | 120679 | 2192 | 12 | 120547 | 1836 |
| DC | 24 | 448971 | 11492 | 14 | 232726 | 5910 |
| FN | 8 | 102465 | 3420 | 14 | 165821 | 3709 |
| ST | 22 | 334954 | 4543 | 8 | 74662 | 1837 |

## cache-economics

| stage | arm | cache_creation |
|---|---|---|
| DV | with | 273925 |
| DV | without | 136488 |
| AR | with | 68787 |
| DR | with | 64848 |
| DR | without | 57591 |

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
| test_count (self-written) | 61 | 133 |

**Descriptive only** — size, not quality. More lines for the same feature is
not a better result.

| metric | WITH | WITHOUT |
|---|---|---|
| loc_produced | 2425 | 2838 |
| tokens per LOC | 92.0722 | 63.4436 |

## validity-caveats

- n=1: single-run comparison; treat deltas as directional, not statistically robust.

## improvement-candidates

- [ ] (stage_cost_outlier) PL [with]: cost $1.1748 is 2.81x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) AR [with]: cost $1.1114 is 2.66x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) DV [with]: cost $5.5860 is 13.38x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) DR [with]: cost $0.8621 is 2.06x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) SR [with]: cost $0.7807 is 1.87x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) AR [without]: cost $1.2371 is 2.96x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) DV [without]: cost $3.3653 is 8.06x the per-stage median ($0.4176)
- [ ] (stage_cost_outlier) DR [without]: cost $0.7168 is 1.72x the per-stage median ($0.4176)
- [ ] (out_token_spike) PL [with]: out-tokens 31911 is 3.57x the per-stage median (8934)
- [ ] (out_token_spike) AR [with]: out-tokens 24787 is 2.77x the per-stage median (8934)
- [ ] (out_token_spike) DV [with]: out-tokens 116371 is 13.02x the per-stage median (8934)
- [ ] (out_token_spike) SR [with]: out-tokens 13692 is 1.53x the per-stage median (8934)
- [ ] (out_token_spike) PL [without]: out-tokens 18145 is 2.03x the per-stage median (8934)
- [ ] (out_token_spike) AR [without]: out-tokens 38620 is 4.32x the per-stage median (8934)
- [ ] (out_token_spike) DV [without]: out-tokens 88480 is 9.90x the per-stage median (8934)
- [ ] (tool_call_spike) DV [with]: 42 tool calls exceeds max(40, 1.5x median) = 40
