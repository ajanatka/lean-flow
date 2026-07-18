# Per-finding Walk-through

This reference defines Interactive mode's per-finding walk-through — the path the user enters by picking option A (`Review each finding one by one — accept the recommendation or choose another action`) from the routing question, plus the unified completion report that every terminal path (walk-through, LFG, Append-to-Open-Questions, zero findings) emits.

Interactive mode only.

---

## Routing question (the entry point)

After `safe_auto` fixes apply and synthesis produces the remaining finding set, the orchestrator asks a four-option routing question before any walk-through or bulk action runs.

Use the platform's blocking question tool (`AskUserQuestion` in Claude Code, `request_user_input` in Codex, `ask_user` in Gemini/Pi). In Claude Code the tool should already be loaded from the Interactive-mode pre-load step in `SKILL.md` — if not, `ToolSearch` with `select:AskUserQuestion` first. Fall back to a numbered list only when the harness genuinely lacks a blocking tool. Never silently skip the question.

**Stem:** `What should the agent do with the remaining N findings?`

**Options (fixed order; no option is labeled `(recommended)` here — the routing choice is user-intent, not finding-shape):**

```
A. Review each finding one by one — accept the recommendation or choose another action
B. LFG. Apply the agent's best-judgment action per finding
C. Append findings to the doc's Open Questions section and proceed
D. Report only — take no further action
```

Per-finding `(recommended)` labeling lives inside the walk-through (option A) and the bulk preview (options B/C), applied per-finding from synthesis step 3.5b's `recommended_action`. If all remaining findings are FYI-subsection-only (anchor `50`, no `gated_auto`/`manual` at anchor 75/100), skip the routing question and flow to the Phase 5 terminal question.

**Append-availability adaptation.** When `references/open-questions-defer.md` has cached `append_available: false` (read-only document, unwritable filesystem), option C is suppressed and the stem gets one added line explaining why. The menu becomes A / B / D. This mirrors the per-finding option-B suppression under "Adaptations" below — routing-level and per-finding Defer share the same availability signal.

**Dispatch:** A loads this walk-through. B loads `references/bulk-preview.md` scoped to every pending finding (Proceed → Apply set batch-edits, Defer set → `open-questions-defer.md`, Skip → no-op; Cancel → back to routing question). C loads `bulk-preview.md` with every pending finding in the Open-Questions bucket (Proceed routes everything through `open-questions-defer.md`, no document edits; Cancel → back to routing question). D emits the completion report and flows to Phase 5.

---

## Entry (walk-through mode)

The walk-through receives, from the orchestrator: the merged findings list in severity order (P0 → P1 → P2 → P3), filtered to actionable findings (anchor `75`/`100`, `autofix_class` `gated_auto`/`manual` — FYI-subsection anchor-`50` findings have no walk-through entry); the run id for artifact lookups; and premise-dependency chain annotations from synthesis step 3.5c (`depends_on: <root_id>` / `dependents: [<ids>]`).

Each finding's recommended action was already normalized by synthesis step 3.5b (`Skip > Defer > Apply` tie-break) and surfaces via `recommended_action` — the walk-through does not recompute it.

**Root-first iteration.** A finding with `dependents` iterates before any dependent, regardless of severity order within the chain — the root decision needs to exist before it can cascade.

**Cascading root decisions.** When the user picks Skip or Defer on a finding with `dependents`: announce the cascade ("Skipping/Deferring this root will auto-resolve N dependent finding(s): {titles}. Continue?"), then fire a two-option blocking question — `Cascade — apply same action to all dependents` (recommended) vs. `Decide each dependent individually`. On Cascade, apply the root's action to every dependent and skip their walk-through entries: cascaded Apply adds to the Apply set, cascaded Defer invokes the open-questions append flow (falling back to the per-finding failure path on append failure), cascaded Skip is decision-list-only. Every cascaded entry is annotated `cascaded from {root_title}`. On Individual, each dependent gets its own walk-through entry. **Apply never cascades** — the premise held, so dependents each need their own decision. **Orphaned dependents** (root suppressed this round per R29) are treated as standalone findings with no chain context.

---

## Per-finding presentation

Each finding is presented in two parts: a terminal output block carrying the explanation, and a question via the platform's blocking question tool carrying the decision. Never merge the two — the terminal block uses markdown; the question uses plain text.

### Terminal output block

```
## Finding {N} of {M} — {severity} {plain-English title}

Section: {section}

**What's wrong**

{plain-English problem statement from why_it_matters}

**Proposed fix**

{suggested_fix, rendered per the governing principle below}

**Why it works**

{short reasoning, grounded in a pattern cited in the document or codebase when available}

{Conflict-context line, when applicable}
```

`{plain-English title}` is a 3-8 word summary rephrased as observable consequence for the reader/implementer/downstream decision (e.g., "Implementers will pick different tiers", not "Section X-Y lists four tiers"). `why_it_matters` renders as-is from the merged finding — the subagent template's framing guidance already makes it observable-consequence-first.

**Governing principle for rendering `suggested_fix` as prose:** default to one sentence describing the fix's effect and location, not raw markup — the user's job is to trust or reject the action, not review exact text (`Drop the Advisory tier from the enum; advisory-style findings surface in an FYI subsection at the presentation layer.`, not a line-numbered diff of the schema file). Inline code references stay to a couple of single-identifier spans with surrounding spaces. Only use a raw block for short (≤5 line) genuinely additive content with no before-state; above that, or for any modification of existing text, switch to a one-sentence summary — never a diff block.

**`Why it works`:** grounded reasoning, ideally referencing a pattern already used in the document or codebase. One to three sentences.

**Conflict-context line (when applicable):** when contributing personas implied different actions and synthesis step 3.6 broke the tie, surface it briefly, e.g. `Coherence recommends Apply; scope-guardian recommends Skip. Agent's recommendation: Skip.` The post-tie-break value is what the menu labels "recommended."

### Question stem

```
Finding {N} of {M} — {severity} {short handle}.
{Action framing in a phrase}?
```

The short handle matches the terminal heading. The action framing is a yes/no phrase for the single recommended action (`Apply the rename?`, `Defer to Open Questions since the tradeoff is genuine?`) — never enumerate alternatives in the stem; surface disagreement in the conflict-context line instead.

### Confirmation between findings

One-line confirmation after each answer: `→ Applied. Edit staged at "Scope Boundaries" section.`, `→ Deferred. Entry appended to "## Deferred / Open Questions".`, `→ Skipped.`

### Options and adaptations

Fixed order, never reordered:

```
A. Apply the proposed fix
B. Defer — append to the doc's Open Questions section
C. Skip — don't apply, don't append
D. LFG the rest — apply the agent's best judgment to this and remaining findings
```

**Mark the post-tie-break recommendation with `(recommended)` — required, not optional.** Only A/B/C can carry it (synthesis emits `recommended_action` as Apply/Defer/Skip); D is a bulk-execution shortcut, never a finding-level resolution, so it's never marked. When reviewers disagreed, still mark whichever option synthesis produced and surface the disagreement in the conflict-context line.

This four-option menu adapts along two independent axes, and both can apply at once:

- **N=1 (exactly one pending finding):** drop the `Finding N of M` framing from heading and stem; suppress option D (nothing left to apply judgment to) — menu shows Apply/Defer/Skip.
- **Open-Questions append unavailable** (read-only document, write-failed): omit option B, append one stem line explaining why, and remap any per-finding `Defer` recommendation to `Skip` so `(recommended)` never lands on a hidden option (note the remap on the conflict-context line) — menu shows Apply/Skip/LFG.

Combine both and the menu shrinks to Apply/Skip. Only fall back to a numbered list when the platform genuinely lacks a blocking question tool.

---

## Per-finding routing

- **Apply** — add the finding's id to an in-memory Apply set. Advance. Do not edit the document inline — Apply accumulates for end-of-walk-through batch execution. **No-fix guard:** if the merged finding has no `suggested_fix` (possible on `manual` findings flagged as observation without a concrete resolution), Apply is not executable — do not add it to the Apply set; instead surface the no-fix sub-question below before advancing.
- **Defer** — invoke the append flow from `references/open-questions-defer.md`. Stay on the current finding during any failure-path sub-question (Retry / Fall back / Convert to Skip). On success, record the append location and advance; on conversion-to-Skip, advance with the failure noted in the completion report.
- **Skip** — record it in the decision list. Advance. No side effects.
- **LFG the rest** — exit the walk-through loop. Dispatch the bulk preview from `references/bulk-preview.md` scoped to the current finding plus everything undecided, reporting "K already decided" in the header. `Cancel` returns to the current finding's question (not the routing question); `Proceed` executes the plan (Apply set merges with already-picked Applies, Defer routes through `open-questions-defer.md`, Skip no-ops), then proceeds to end-of-walk-through execution.

### No-fix sub-question (Apply picked on a finding with no `suggested_fix`)

Synthesis step 3.5b already demotes the default recommendation from Apply to Defer for any merged finding without a `suggested_fix`, so `(recommended)` never lands on Apply for these — but the menu still lets the user pick Apply manually. When that happens, don't add the finding to the Apply set (the execution pass has no edit payload), and instead fire a blocking sub-question. Position indicator stays on the current finding.

**Stem:** `Apply isn't executable for this finding — the review surfaced the issue without a concrete fix. How should the agent proceed?`

```
A. Defer to Open Questions  (recommended)
B. Skip — don't apply, don't append
C. Acknowledge without applying — record the decision, no document edit
```

**Routing:** A invokes the append flow as if Defer had been picked originally (same failure-path handling), annotated `redirected from Apply — no suggested_fix`. B records Skip with the same annotation. C records `acknowledged` (annotated `Apply picked but no suggested_fix — no edit dispatched`) with no Apply-set entry — Acknowledged is its own bucket in the completion report (own count, own report-ordering slot) and, for round-to-round suppression, carries forward in the multi-round decision primer as a rejected-class decision alongside Skip/Defer so round-N+1 synthesis suppresses re-raises via R29.

**Availability adaptation:** when append is unavailable for the session, omit option A, explain why in the stem, and the menu becomes Skip (recommended) / Acknowledge.

**Cascading roots:** when the finding is a root with dependents and the user picks A or B here, run the cascade announcement from "Entry" above, treating the sub-question's choice as the root's effective action. Option C does not cascade — the root is recorded as acknowledged and each dependent gets its own walk-through entry.

---

## Override rule

"Override" means picking a different preset action, never inline freeform custom-fix authoring — the walk-through is a decision loop, not a pair-editing surface. A user who wants a variant of the proposed fix picks Skip and hand-edits outside the flow; if they also want it tracked, they can Defer first and edit afterward.

## State

Walk-through state is **in-memory only**: an Apply set, a decision list, and the current position. Nothing is written to disk per-decision except the in-doc Open Questions appends (external, can't roll back). An interruption discards the rest — Apply decisions haven't dispatched yet, so they're cleanly lost with no document changes. Cross-session persistence is out of scope, mirroring `lf-code-review`'s walk-through state rules.

---

## End-of-walk-through execution

After the loop terminates (every finding answered, or `LFG the rest → Proceed`):

1. **Apply set:** in a single pass, the orchestrator applies every accumulated finding's `suggested_fix` to the document directly via the platform's edit tool — lf-doc-review has no batch-fixer subagent (per scope boundary); `gated_auto`/`manual` document fixes are single-file markdown changes with no cross-file dependencies. **Defensive no-fix check:** before each edit, verify the finding carries a `suggested_fix` (the decision-time no-fix guard should prevent a miss, but treat this as a fallback) — if absent, skip the edit, record it in the completion report's failure section as `Apply skipped — no suggested_fix available`, and continue the batch.
2. **Defer set:** already executed inline via `references/open-questions-defer.md`.
3. **Skip:** no-op.

Then emit the unified completion report below.

---

## Unified completion report

Every terminal path of Interactive mode emits the same structure: walk-through completed, walk-through bailed via `LFG the rest → Proceed`, top-level LFG (option B), top-level Append-to-Open-Questions (option C), or zero findings after `safe_auto` (a one-line degenerate case).

**Minimum required fields:** per-finding entries (title, severity, action taken, append location for Deferred, one-line reason for Skipped grounded in confidence anchor or `why_it_matters`, acknowledgement reason for Acknowledged); summary counts by action (e.g., `4 applied, 2 deferred, 2 skipped`, with an `acknowledged` count only when nonzero); failures called out explicitly above the per-finding list (failed Apply, failed append); end-of-review verdict carried over from Phase 4's Coverage section.

**Report ordering:** failures first, then per-finding entries grouped Applied → Deferred → Skipped → Acknowledged, then summary counts, then Coverage (FYI observations, residual concerns), then verdict. Omit any bucket whose count is zero.

**Zero-findings degenerate case:** when the routing question was skipped because no `gated_auto`/`manual` findings at anchor 75/100 remained after `safe_auto`, the report collapses to summary counts + verdict with one added line for the `safe_auto` fix count. Use the unqualified `All findings resolved` form only when no FYI/residual concerns remain; otherwise use the qualified form, e.g. `All actionable findings resolved — 3 fixes applied. (2 FYI observations, 1 residual concern remain in the report.)`

---

## Execution posture

The walk-through is operationally read-only except for three permitted writes: the in-memory Apply set/decision list, the in-doc Open Questions appends (managed by `references/open-questions-defer.md`), and the end-of-walk-through batch document edits (the orchestrator's final Apply pass). Persona agents remain strictly read-only. Unlike `lf-code-review`, there is no fixer subagent — the orchestrator owns the document edit directly.
