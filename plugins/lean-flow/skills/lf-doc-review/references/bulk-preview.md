# Bulk Action Preview

This reference defines the compact plan preview that Interactive mode shows before every bulk action — LFG (routing option B), Append-to-Open-Questions (routing option C), and the walk-through's `LFG the rest` (option D of the per-finding question). The preview gives the user a single-screen view of what the agent is about to do, with exactly two options: Proceed or Cancel.

Interactive mode only.

---

## When the preview fires

Three call sites, all scoped to pending `gated_auto`/`manual` findings at confidence anchor `75` or `100`:

1. **Routing option B (top-level LFG)** — after the user picks the best-judgment routing option, before any action executes. Scope: every pending finding.
2. **Routing option C (top-level Append-to-Open-Questions)** — before any append runs. Scope: every pending finding, all landing in the `Appending to Open Questions (N):` bucket regardless of the agent's natural recommendation, because option C is batch-defer.
3. **Walk-through `LFG the rest`** — before the remaining findings resolve. Scope: the current finding plus everything not yet decided; already-decided findings are excluded.

In all three cases the user confirms with `Proceed` or backs out with `Cancel`. No per-item decisions inside the preview — that's the walk-through's role.

---

## Preview structure

Grouped by intended action; bucket headers appear only when non-empty. One line per finding: `[<severity>] <section> — <one-line summary>`, drawn from the persona's `why_it_matters` first sentence (paraphrased tighter when needed), no section numbering unless disambiguating a shared section. Target ~80 columns; truncate with ellipsis. Fall back to the finding's title when `why_it_matters` is missing (rare — malformed persona output), and note the gap in Coverage if it affects more than a few findings in the run.

```
<Path label> — <scope summary>:

Applying (N):
  [P0] <section> — <one-line plain-English summary>

Appending to Open Questions (N):
  [P2] <section> — <one-line plain-English summary>

Skipping (N):
  [P2] <section> — <one-line plain-English summary>
```

Worked example (routing option B):

```
LFG plan — 8 findings:

Applying (4):
  [P0] Requirements Trace — Renumber R4 to match unit reference
  [P1] Unit 3 Files — Add read-fallback for renamed report file

Appending to Open Questions (2):
  [P2] Scope Boundaries — Unit 2/3 merge judgment call

Skipping (2):
  [P3] Abstraction Commentary — Speculative, subjective
```

**Header wording by path:** routing B → `LFG plan — N findings:`; routing C → `Append plan — N findings as Open Questions entries:` (everything lands in the Appending bucket); walk-through `LFG the rest` → `LFG plan — N remaining findings (K already decided):` (already-decided findings excluded from both preview and counts).

---

## Question and options

After the preview body renders, ask via the platform's blocking question tool (`AskUserQuestion` in Claude Code, `request_user_input` in Codex, `ask_user` in Gemini/Pi), pre-loaded per the Interactive-mode step. Fall back to numbered options + waiting for the next reply only when the harness genuinely lacks a blocking tool. Never silently skip the question.

Stem by path: routing B → `The agent is about to apply the plan above. Proceed?`; routing C → `The agent is about to append the findings above to the doc's Open Questions section. Proceed?`; walk-through → `The agent is about to resolve the remaining findings above. Proceed?`

Options (exactly two, always): `Proceed` (execute the plan as shown) / `Cancel` (do nothing, return to the originating question).

---

## Cancel and Proceed semantics

**Cancel** never changes on-disk or in-memory state. Routing B/C Cancel returns to the four-option routing question. Walk-through `LFG the rest` Cancel returns to the current finding's per-finding question (not the routing question) — the walk-through continues from where it was, prior decisions intact.

**Proceed** executes the plan: Apply findings join the Apply set for a single end-of-batch document-edit pass (see `walkthrough.md`); Defer findings route through `references/open-questions-defer.md`; Skip findings are recorded as no-action. Walk-through `LFG the rest` Proceed merges its Apply set with the ones already picked during the walk-through, dispatching together in the single end-of-walk-through pass. After all actions complete, emit the unified completion report (`walkthrough.md`). A failure mid-Proceed (e.g., one Open Questions append fails during a batch Defer) follows the failure path in `open-questions-defer.md` — surface it inline with Retry / Fall back / Convert to Skip, continue with the rest of the plan, and capture it in the completion report's failure section.

---

## Edge cases

- **Zero findings in a bucket:** omit the header (no empty `Appending to Open Questions (0):` line).
- **All findings in one bucket:** still shows the header; Proceed/Cancel still offered — the common case for routing option C.
- **N=1:** still uses the grouped format with a single-line bucket.
- **Open Questions append unavailable:** routing option C isn't offered upstream (see `open-questions-defer.md`). LFG (B) and walk-through `LFG the rest` can still run with per-finding Defer recommendations — downgrade every Defer to Skip when append-availability is cached false, and surface the downgrade on the preview (a `Skipping — append unavailable (N):` bucket, or a header note).
- **Walk-through `LFG the rest` with zero remaining findings:** the walk-through already suppresses this option at N=1, so the preview should never fire empty. If it does, render `LFG plan — 0 remaining findings` and fall through to Proceed as a no-op.
