# Plan-Gate Open-Question Fixtures

Spec fixtures for `skills/worktask/references/planning-decisions.md § Plan-Gate Open-Question Batching`
— specifically `§ Facts are PL0's job; decisions are the user's` and
`§ Dependency ordering across gate rounds`. They describe **expected inputs → outputs** for the
prompt workflow and are NOT executable application tests. QA validates the PM's behaviour against
the assertions in each fixture.

| Fixture | Scenario | Primary ACs |
|---------|----------|-------------|
| `01-facts-only-zero-questions.md` | Every candidate question is answerable by inspection → zero questions reach the plan gate | AC-8 |

## How QA uses these

1. Read the fixture's **Input** block and run the PL0 stage against it.
2. Count the entries in the produced plan's `handoff.open_questions[]` and the items under its
   `## elicitation-sweep` heading. Both counts must match **Expected gate output**; the heading
   itself is mandatory even at zero items.
3. Confirm each resolved fact appears in the plan with the command that resolved it.
