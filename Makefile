# Makefile — corpflow plugin test suite + dual-path TTT benchmark (Python harness)
#
# Targets:
#   make bootstrap       vendored-bats present-check; swift toolchain check;
#                        resolve kcov (system→brew→proxy). Idempotent.
#   make test            ./run-tests.sh — full deterministic suite. No network, no live.
#   make coverage        bats under kcov (bash) + `swift test --enable-code-coverage`
#                        per package, jq line-coverage gate ≥85% (Views/ excluded).
#   make test-ios        TicTacToeKit suite on an iOS Simulator (SKIPs cleanly when
#                        no iOS runtime is installed). Never inside the benchmark Timer.
#   make benchmark       deterministic dual-path TTT benchmark. No --live, no network.
#   make benchmark-live  opt-in live A/B (credential-gated, budget-capped). Never CI.
#                        Honors BUDGET=<usd>, STAGES=PL,AR,..., WITHOUT_ARM=real|skip
#                        and ARM=with|without|both (single arm = half a comparison:
#                        written to results/runs/live-arm/, never rotated into history).
#   make benchmark-pair  join two single-arm records into one paired record.
#                        A=<with.json> B=<without.json> OUT=<joined.json>. Offline.
#   make benchmark-analyze  render benchmark/results/history.json -> analysis.md.
#   make report          render benchmark/results/history.json -> result.html.
#   make clean           remove workdirs, coverage intermediates, .build dirs.
#
# Honors COVERAGE=1 to route `make test` through `make coverage`.

SHELL        := /usr/bin/env bash
PLUGIN_ROOT  := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
BATS         := $(PLUGIN_ROOT)/tests/vendor/bats-core/bin/bats
COVDIR       := $(PLUGIN_ROOT)/.coverage-kcov
COVERAGE     ?= 0
PROVIDER     ?= claude
# Coverage line-coverage gate (per AC-3; 85 is the floor).
COV_MIN      ?= 85

# The retained Swift artifact package (measurement instrument).
TTT_PKG      := $(PLUGIN_ROOT)/benchmark/ttt-template
# The Python harness directory (NOT a Swift package — stdlib-only entrypoints + tests).
HARNESS_DIR  := $(PLUGIN_ROOT)/benchmark/harness

# kcov instrumentation scope.
KCOV_INCLUDE := $(PLUGIN_ROOT)/skills,$(PLUGIN_ROOT)/hooks,$(PLUGIN_ROOT)/.claude/hooks
KCOV_EXCLUDE := $(PLUGIN_ROOT)/tests

# All bats files under tests/shell/**.
SHELL_TESTS  := $(shell find $(PLUGIN_ROOT)/tests/shell -type f -name '*.bats' 2>/dev/null | sort)

.PHONY: all test test-changed test-select bootstrap coverage test-ios benchmark benchmark-live benchmark-pair benchmark-analyze report clean help
.DEFAULT_GOAL := help

help:
	@echo "corpflow test suite — targets:"
	@echo "  make bootstrap       resolve bats/swift/kcov (idempotent)"
	@echo "  make test            full deterministic suite (offline)"
	@echo "  make test-changed    only the tests the change matrix selects (BASE=<ref>)"
	@echo "  make test-select     print the selection plan, run nothing"
	@echo "  make coverage        suite under kcov + swift coverage, gate >=$(COV_MIN)%"
	@echo "  make test-ios        TicTacToeKit on iOS Simulator (SKIPs w/o runtime)"
	@echo "  make benchmark       deterministic dual-path TTT benchmark (offline)"
	@echo "  make benchmark-live  opt-in live A/B (credential+budget gated; STAGES=, WITHOUT_ARM=, ARM=)"
	@echo "  make benchmark-pair  join two single-arm records (A= B= OUT=; offline)"
	@echo "  make benchmark-analyze  render an evidence-backed A/B analysis report"
	@echo "  make clean           remove workdirs / coverage / .build dirs"

# ---------------------------------------------------------------------------
# bootstrap: vendored bats present-check + swift toolchain + kcov tiered probe
# ---------------------------------------------------------------------------
bootstrap:
	@echo "[bootstrap] checking vendored bats…"
	@test -x "$(BATS)" || { echo "[bootstrap] FATAL: vendored bats missing at $(BATS)"; exit 1; }
	@echo "[bootstrap] vendored bats OK: $$("$(BATS)" --version 2>/dev/null)"
	@echo "[bootstrap] checking swift toolchain…"
	@if command -v swift >/dev/null 2>&1; then \
	   echo "[bootstrap] swift OK: $$(swift --version 2>/dev/null | head -1)"; \
	 else \
	   echo "[bootstrap] SKIP: swift toolchain absent — Swift build and coverage phases will be skipped. Shell tests are unaffected. Install: Xcode CLT (macOS) | https://swift.org/install (Linux)."; \
	 fi
	@echo "[bootstrap] resolving kcov (tiered: system -> brew -> documented proxy)…"
	@if command -v kcov >/dev/null 2>&1; then \
	    echo "[bootstrap] tier-1: system kcov found at $$(command -v kcov)"; \
	  elif command -v brew >/dev/null 2>&1; then \
	    echo "[bootstrap] tier-2: attempting 'brew install kcov' (may require network)…"; \
	    brew install kcov >/dev/null 2>&1 && echo "[bootstrap] kcov installed via brew" \
	      || echo "[bootstrap] tier-2 FAILED -> tier-3 documented per-file proxy (see tests/COVERAGE.md)"; \
	  else \
	    echo "[bootstrap] tier-3: no kcov, no brew -> documented per-file assertion-ratio proxy (tests/COVERAGE.md)"; \
	  fi
	@echo "[bootstrap] done."

# ---------------------------------------------------------------------------
# test: the deterministic suite. Routes to coverage when COVERAGE=1.
# ---------------------------------------------------------------------------
test:
ifeq ($(COVERAGE),1)
	@$(MAKE) --no-print-directory coverage
else
	@COVERAGE=0 "$(PLUGIN_ROOT)/run-tests.sh"
endif

# ---------------------------------------------------------------------------
# test-changed / test-select: scoped runs off the change→test matrix. Additive —
# SHELL_TESTS and the coverage recipe are deliberately untouched, and there is no
# coverage-changed target (rationale in tests/COVERAGE.md).
# ---------------------------------------------------------------------------
test-changed:
	@COVERAGE=0 "$(PLUGIN_ROOT)/run-tests.sh" --changed $(if $(BASE),--base $(BASE),)

test-select:
	@COVERAGE=0 "$(PLUGIN_ROOT)/run-tests.sh" --changed --print-selection $(if $(BASE),--base $(BASE),)

# ---------------------------------------------------------------------------
# coverage: kcov (bash) UNCHANGED + swift test --enable-code-coverage per
# package with a jq ≥$(COV_MIN)% line gate. Sources/TicTacToeKit/Views/ is
# excluded from the denominator (SwiftUI bodies are exercised structurally,
# not unit-covered — rationale in tests/COVERAGE.md). Test sources and .build
# are always excluded.
# ---------------------------------------------------------------------------
coverage: bootstrap
	@echo "[coverage] preparing $(COVDIR)…"
	@rm -rf "$(COVDIR)"; mkdir -p "$(COVDIR)"
	@if command -v kcov >/dev/null 2>&1; then \
	    echo "[coverage] kcov present — instrumenting each .bats target"; \
	    set -e; \
	    for f in $(SHELL_TESTS); do \
	      stem=$$(echo "$$f" | sed 's#$(PLUGIN_ROOT)/tests/shell/##; s#/#__#g; s#\.bats$$##'); \
	      echo "[coverage]   kcov -> $$stem"; \
	      kcov --include-path="$(KCOV_INCLUDE)" --exclude-path="$(KCOV_EXCLUDE)" \
	        "$(COVDIR)/$$stem" "$(BATS)" "$$f" || exit $$?; \
	    done; \
	    echo "[coverage] kcov per-target runs complete; merged report under $(COVDIR)/"; \
	  else \
	    echo "[coverage] kcov UNAVAILABLE — tier-3 documented per-file assertion-ratio proxy."; \
	    echo "[coverage] running bats uninstrumented so tests still gate; see tests/COVERAGE.md."; \
	    "$(BATS)" $(SHELL_TESTS); \
	  fi
	@echo "[coverage] swift coverage phase (ttt-template artifact, gate >=$(COV_MIN)%)…"
	@if ! command -v swift >/dev/null 2>&1; then \
	   echo "[coverage] SKIP: swift toolchain absent — Swift coverage phase skipped. Shell coverage above is unaffected. Install: Xcode CLT (macOS) | https://swift.org/install (Linux)."; \
	 else \
	   set -e; \
	   for pkg in "$(TTT_PKG)"; do \
	     echo "[coverage]   swift test --enable-code-coverage ($$pkg)"; \
	     swift test --enable-code-coverage --package-path "$$pkg" >/dev/null || exit $$?; \
	     cov=$$(swift test --show-codecov-path --package-path "$$pkg" 2>/dev/null | tail -1); \
	     [ -f "$$cov" ] || { echo "[coverage] FATAL: codecov JSON missing for $$pkg"; exit 1; }; \
	     pct=$$(jq '[.data[0].files[] \
	           | select(.filename | contains("/.build/") | not) \
	           | select(.filename | contains("/Tests/") | not) \
	           | select(.filename | contains("Sources/TicTacToeKit/Views/") | not)] \
	           | (map(.summary.lines.covered) | add) as $$cov \
	           | (map(.summary.lines.count) | add) as $$cnt \
	           | if $$cnt == 0 then 100 else ($$cov / $$cnt * 100) end' "$$cov"); \
	     printf '[coverage]   %s line coverage: %.1f%% (gate %s%%)\n' "$$(basename $$pkg)" "$$pct" "$(COV_MIN)"; \
	     ok=$$(jq -n --argjson p "$$pct" --argjson m "$(COV_MIN)" '$$p >= $$m'); \
	     [ "$$ok" = "true" ] || { echo "[coverage] FAIL: $$pkg below $(COV_MIN)%"; exit 1; }; \
	   done; \
	 fi
	@echo "[coverage] python phase (coverage.py measures when present; the suites always gate)…"
	@py_rc=0; \
	  if command -v coverage >/dev/null 2>&1; then \
	    echo "[coverage]   coverage.py present — measuring the Python suites"; \
	    coverage run -m unittest discover -s "$(PLUGIN_ROOT)/tests/python" -p 'test_*.py' || py_rc=$$?; \
	    ( cd "$(HARNESS_DIR)" && PYTHONPATH="$(HARNESS_DIR)/tests" coverage run -a -m unittest discover -s tests -t . -p 'test_*.py' ) || py_rc=$$?; \
	    coverage report || true; \
	  else \
	    echo "[coverage]   coverage.py absent — running the Python suites uninstrumented (behavioral gate)"; \
	    python3 -m unittest discover -s "$(PLUGIN_ROOT)/tests/python" -p 'test_*.py' || py_rc=$$?; \
	    ( cd "$(HARNESS_DIR)" && PYTHONPATH="$(HARNESS_DIR)/tests" python3 -m unittest discover -s tests -t . -p 'test_*.py' ) || py_rc=$$?; \
	  fi; \
	  [ "$$py_rc" -eq 0 ] || { echo "[coverage] FAIL: Python suite(s) failed (rc=$$py_rc)"; exit "$$py_rc"; }
	@echo "[coverage] done."

# ---------------------------------------------------------------------------
# test-ios: best-effort iOS Simulator pass for TicTacToeKit. SKIPs cleanly on
# hosts without an iOS simulator runtime (portability contract) — never a dep
# of test/benchmark, never inside the benchmark Timer.
# ---------------------------------------------------------------------------
test-ios:
	@if xcrun simctl list runtimes 2>/dev/null | grep -q 'iOS'; then \
	    echo "[test-ios] iOS simulator runtime present — running full xcodebuild test…"; \
	    cd "$(TTT_PKG)" && xcodebuild test -scheme TicTacToe-Package \
	      -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'; \
	  else \
	    echo "SKIP: no iOS simulator runtime installed (make test-ios skipped)"; \
	    exit 0; \
	  fi

# ---------------------------------------------------------------------------
# benchmark: deterministic dual-path TTT. NEVER --live, NEVER network (AC-8).
# ---------------------------------------------------------------------------
benchmark:
	@echo "[benchmark] deterministic dual-path TTT (no --live, no network)…"
	@"$(PLUGIN_ROOT)/benchmark/run-benchmark.sh" --provider "$(PROVIDER)"
	@echo "[benchmark] running harness self-tests (schema / rotation / generators)…"
	@( cd "$(HARNESS_DIR)" && PYTHONPATH="$(HARNESS_DIR)/tests" python3 -m unittest discover -s tests -t . -p 'test_*.py' )
	@python3 "$(HARNESS_DIR)/bin/bench-report" \
	  --history "$(PLUGIN_ROOT)/benchmark/results/history.json" \
	  --out "$(PLUGIN_ROOT)/benchmark/results/result.html" \
	  --plugin-root "$(PLUGIN_ROOT)"

# ---------------------------------------------------------------------------
# benchmark-live: opt-in. Credential-gated, budget-capped. Never a dep of any
# other target. Never CI. Honors BUDGET=, STAGES= (subset probe),
# WITHOUT_ARM=real|skip (overrides the default real-on-full/skip-on-subset policy)
# and ARM=with|without|both. ARM=with|without dispatches a single arm and leaves
# its record out of history.json — pair it with benchmark-pair before reading it
# as a comparison.
# ---------------------------------------------------------------------------
benchmark-live:
	@echo "[benchmark-live] OPT-IN live A/B — credential probe + budget cap apply."
	@live_args="--live --provider $(PROVIDER) --budget $${BUDGET:-50.00}"; \
	  [ -n "$(STAGES)" ] && live_args="$$live_args --stages $(STAGES)"; \
	  [ -n "$(WITHOUT_ARM)" ] && live_args="$$live_args --without-arm $(WITHOUT_ARM)"; \
	  [ -n "$(ARM)" ] && live_args="$$live_args --arm $(ARM)"; \
	  "$(PLUGIN_ROOT)/benchmark/run-benchmark.sh" $$live_args
	@$(MAKE) --no-print-directory report

# ---------------------------------------------------------------------------
# benchmark-pair: join two single-arm records (results/runs/live-arm/) into one
# paired record. Pure analysis — reads two JSON files and writes a third; no
# dispatch, no credential, no spend, so unlike benchmark-live it is safe to run
# anywhere. bench-pair exits 64 on usage and 65 when the two runs are not
# comparable, writing nothing in either case — those codes are observable only
# when bench-pair is invoked directly, because make collapses any recipe failure
# into its own exit 2. Script the executable, not this target, if you branch on
# 64 vs 65. The joined record lands where OUT points; ingesting it into
# history.json stays a separate, deliberate step (bench-pair prints the command).
# ---------------------------------------------------------------------------
benchmark-pair:
	@[ -n "$(A)" ] && [ -n "$(B)" ] && [ -n "$(OUT)" ] || { \
	    echo "[benchmark-pair] usage: make benchmark-pair A=<arm.json> B=<arm.json> OUT=<record.json>" >&2; \
	    exit 64; }
	@python3 "$(HARNESS_DIR)/bin/bench-pair" --a "$(A)" --b "$(B)" --out "$(OUT)"
	@echo "[benchmark-pair] joined -> $(OUT)"

# ---------------------------------------------------------------------------
# report: render benchmark/results/history.json -> benchmark/results/result.html
# ---------------------------------------------------------------------------
report:
	@python3 "$(HARNESS_DIR)/bin/bench-report" \
	  --history "$(PLUGIN_ROOT)/benchmark/results/history.json" \
	  --out "$(PLUGIN_ROOT)/benchmark/results/result.html" \
	  --plugin-root "$(PLUGIN_ROOT)"

# ---------------------------------------------------------------------------
# benchmark-analyze: render an evidence-backed A/B analysis report from the
# latest live record in benchmark/results/history.json.
# ---------------------------------------------------------------------------
benchmark-analyze:
	@python3 "$(HARNESS_DIR)/bin/bench-analyze" \
	  --history "$(PLUGIN_ROOT)/benchmark/results/history.json" \
	  --out "$(PLUGIN_ROOT)/benchmark/results/analysis.md"

.PHONY: benchmark-native
benchmark-native:
	@[ -n "$(APP)" ] || { echo "usage: make benchmark-native APP=<generated-app>" >&2; exit 64; }
	@python3 "$(HARNESS_DIR)/bin/bench-native-check" --app "$(APP)"

# ---------------------------------------------------------------------------
# clean: remove generated workdirs + coverage intermediates + caches + the
# three packages' .build dirs. Leaves history.json + vendored frameworks.
# ---------------------------------------------------------------------------
clean:
	@echo "[clean] removing workdirs / coverage / .build dirs / caches…"
	@rm -rf "$(PLUGIN_ROOT)/benchmark/workdirs"/* 2>/dev/null || true
	@rm -rf "$(COVDIR)" 2>/dev/null || true
	@rm -rf "$(TTT_PKG)/.build" 2>/dev/null || true
	@rm -f "$(PLUGIN_ROOT)/.coverage" "$(HARNESS_DIR)/.coverage" 2>/dev/null || true
	@find "$(PLUGIN_ROOT)" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "[clean] done (history.json + tests/vendor preserved)."
