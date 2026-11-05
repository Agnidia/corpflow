# Figma Per-Frame Capture Fixtures

Spec fixtures for the PL-stage Figma Capture Workflow (`skills/worktask/references/planning-design.md
§ Figma Design Capture`). These describe **expected inputs → outputs** for the
prompt workflow — they are NOT executable application tests. QA validates the PM's
behavior against the assertions in each fixture.

Each fixture states: the input Figma URL(s), the `get_metadata` node classification,
the expected persisted PNG count, the expected `figma-registry.md` rows, and the
expected `<plan_file> § design-preview` content. Counts and row schemas are the
authoritative checks QA greps for.

| Fixture | Scenario | Primary ACs |
|---------|----------|-------------|
| `01-single-screen.md` | Leaf node — one screen | AC-2, AC-3, AC-6 |
| `02-multi-frame-section.md` | Container — section with 4 child frames | AC-1, AC-3, AC-4, AC-5 |
| `03-auth-failure.md` | Figma MCP not authenticated — soft halt | AC-8 |
| `04-alternate-url-forms.md` | `/file/` + `/proto/` forms fire capture; `/board/` + `/slides/` rejected | AC-2, AC-3 |

## How QA uses these

1. Read the fixture's **Input** and **Node classification** blocks.
2. Confirm the PM's persisted-file count matches **Expected persisted files**.
3. Confirm `figma-registry.md` rows match **Expected registry rows** (schema +
   per-frame node ids + states), one comparison row per registry row.
4. Confirm `<plan_file> § design-preview` matches **Expected design-preview**.
5. Confirm the **Non-blocking / soft-halt** contract held where the fixture
   exercises a failure path.

Persistence mechanism under test: the PM downloads each `get_screenshot` URL
in-turn via `Bash(curl:*)` and verifies a non-zero PNG before recording success.
A download/verify failure is recorded as an open question and never blocks.
