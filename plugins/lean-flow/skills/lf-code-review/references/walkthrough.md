# Per-finding Walk-through

This reference defines Interactive mode's per-finding walk-through — the path the user enters by picking option A (`Review each finding one by one — accept the recommendation or choose another action`) from the routing question. It also covers the unified completion report that every terminal path (walk-through, LFG, File tickets, zero findings) emits.

Interactive mode only.

---

## Entry

The walk-through receives, from the orchestrator: the merged findings list in severity order (P0 → P1 → P2 → P3), filtered to `gated_auto`/`manual` findings surviving the Stage 5 anchor gate (75+, with P0 escape at 50; advisory findings included when the flow routes them here for acknowledgment — see Adaptations); the cached tracker-detection tuple from `tracker-defer.md` (`{ tracker_name, confidence, named_sink_available, any_sink_available }`); and the run id for artifact lookups.

Each finding's recommended action was already normalized by Stage 5 (step 7b — tie-break on action). The walk-through surfaces that recommendation but does not recompute it.

---

## Per-finding presentation

Each finding is presented in two parts: a **terminal output block** carrying the explanation, and a **question** via the platform's blocking question tool (`AskUserQuestion` in Claude Code, `request_user_input` in Codex, `ask_user` in Gemini/Pi) carrying the decision. Never merge the two — the terminal block uses markdown; the question uses plain text.

In Claude Code the tool should already be loaded from the Interactive-mode pre-load step in `SKILL.md`. Fall back to a numbered-list presentation only when the harness genuinely lacks a blocking tool (`ToolSearch` returns no match, the call errors, or the runtime mode doesn't expose it) — never because a schema load is pending. Never silently skip the question.

### Terminal output block

```
## Finding {N} of {M} — {severity} {plain-English title}

{file}:{line}

**What's wrong**

{plain-English problem statement from why_it_matters}

**Proposed fix**

{suggested_fix, rendered per the governing principles below}

**Why it works**

{short reasoning, grounded in a codebase pattern when available}

{R15 conflict context line, when applicable}
```

`why_it_matters` is read from the contributing reviewer's artifact file at `.context/lean-flow/lf-code-review/{run_id}/{reviewer_name}.json`, matched the same way Stage 6 detail enrichment matches (`file + line_bucket(line, +/-3) + normalize(title)`). Try contributing reviewers in list order; use the first match. When no artifact match exists (merge-synthesized finding, or a failed artifact write), the block degrades to the heading + `suggested_fix` only, and the gap is recorded in the completion report's Coverage section.

**Governing principles for rendering `suggested_fix` as prose (pick the first that fits):**

1. **Default: one sentence of intent, not syntax.** The fixer subagent owns the exact code; the walk-through only needs enough for the user to trust or reject the action — what changes and where it lives (`Throw on non-2xx response before parsing JSON.`), never the literal diff. Inline code references, if used, stay to a couple of single-identifier spans with surrounding spaces (`` `response.ok` ``, not glued text) — a backtick span touching adjacent text breaks the terminal's markdown renderer. If intent needs more than that, abstract up a level instead.
2. **Raw code block, only for short (≤5 line) purely additive new code** with no before-state (new file/function, new guard in an empty body). Anything modifying existing code, or longer, becomes prose or a pointer — never a diff block.
3. **Summary + artifact pointer, when prose genuinely can't carry the fix:** one-sentence transformation + key symbol/location + `Full fix: .context/lean-flow/lf-code-review/{run_id}/{reviewer_name}.json → findings[].suggested_fix`.

**`Why it works`:** grounded reasoning, ideally referencing a similar pattern already used elsewhere in the codebase (e.g., "matches the format-validation pattern already used at src/cli/io.ts:41"). One to three sentences.

**R15 conflict context line (when applicable):** when contributing reviewers implied different actions for this finding and Stage 5 step 7b broke the tie, surface it briefly, e.g. `Correctness recommends Apply; Testing recommends Skip (low confidence). Agent's recommendation: Skip.` The post-tie-break value is what the menu labels "recommended."

### Question stem

Fire the platform's blocking question tool with a compact two-line stem:

```
Finding {N} of {M} — {severity} {short handle}.
{Action framing in a phrase}?
```

The short handle matches the terminal block's heading. The action framing is a yes/no phrase for the *single recommended action* — never enumerate alternatives in the stem (the option list carries those). Surface disagreement in the R15 conflict context line, not as a multi-option stem, e.g.:

```
Finding 1 of 9 — P0 hardcoded admin token.
Skip the fix since the fixture is being deleted?
(Security recommends Apply; file context recommends Skip. Agent's recommendation: Skip.)
```

Never embed code blocks, diff syntax, or the full fix/reasoning in the stem.

### Confirmation between findings

After the user answers and before the next terminal block, emit a one-line confirmation: `→ Applied. Fix staged at src/utils/api-client.ts:36-37.`, `→ Deferred. Ticket filed: <url>.`, `→ Skipped.`, `→ Acknowledged.`

### Options and adaptations

Fixed order, never reordered:

```
1. Apply the proposed fix
2. Defer — file a [TRACKER] ticket
3. Skip — don't apply, don't track
4. LFG the rest — apply the agent's best judgment to this and remaining findings
```

Render `[TRACKER]` per `tracker-defer.md` (concrete tracker name when confidence is high and a named sink is available; the generic `Defer — file a ticket` otherwise). **Mark the post-tie-break recommendation with `(recommended)` on its option label — required, not optional** — even when reviewers disagreed; surface the disagreement separately in the R15 conflict line.

This four-option menu adapts along two independent axes, and both can apply at once:

- **Advisory-only finding:** option 1 becomes `Acknowledge — mark as reviewed` (the only case where Acknowledge appears).
- **Exactly one pending finding (N=1):** drop the `Finding N of M` framing from both the heading and stem, and suppress option 4 (no remaining findings to apply judgment to).
- **No tracker sink available** (`any_sink_available: false`): omit option 2, and append one stem line explaining why (e.g., `Defer unavailable on this platform — no durable tracker sink detected.`). Before rendering, remap any per-finding `Defer` recommendation to `Skip` so `(recommended)` never lands on a hidden option — note the remap on the R15 conflict line.

Combine both (N=1 + no sink) and the menu shrinks to two options (Apply/Acknowledge + Skip). Only fall back to a numbered list when the platform genuinely lacks a blocking question tool.

---

## Per-finding routing

For each finding's answer:

- **Apply** — add the finding's id to an in-memory Apply set. Advance. Do not dispatch the fixer inline — Apply accumulates for end-of-walk-through batch dispatch.
- **Acknowledge** (advisory variant) — record it in the decision list. Advance. No side effects.
- **Defer** — invoke the tracker-defer flow from `tracker-defer.md`. Stay on the current finding during any failure-path sub-question (Retry / Fall back / Convert to Skip). On success, record the tracker reference and advance; on conversion-to-Skip, advance with the failure noted in the completion report.
- **Skip** — record it in the decision list. Advance. No side effects.
- **LFG the rest** — exit the walk-through loop. Run Stage 5b on the remaining action set (current finding plus any undecided) using the same gate as LFG routing (option B): validator template at `references/validator-template.md`, 15-finding cap, parallel per-finding dispatch. Findings Stage 5b rejects are dropped. Dispatch the bulk preview from `bulk-preview.md` scoped to the survivors, reporting "K already decided" in the header. `Cancel` returns to the current finding's question (not the routing question); `Proceed` executes the plan (Apply set merges with already-picked Applies, Defer routes through `tracker-defer.md`, Skip/Acknowledge no-op), then proceeds to end-of-walk-through dispatch.

---

## Override rule

"Override" means picking a different preset action (Defer or Skip in place of Apply, or Apply in place of the recommendation) — never inline freeform custom-fix authoring. The walk-through is a decision loop, not a pair-programming surface. A user who wants a variant of the proposed fix picks Skip and hand-edits outside the flow.

## State

Walk-through state is **in-memory only**: an Apply set, a decision list (action + metadata like `tracker_url`/`reason` per finding), and the current position. Nothing is written to disk per-decision. An interrupted walk-through discards all in-memory state — Defer actions that already executed remain in the tracker (external side effects, can't roll back); Apply decisions haven't dispatched yet, so they're cleanly lost with no code changes. Formal cross-session resumption is out of scope for v1.

---

## End-of-walk-through dispatch

After the loop terminates (every finding answered, or `LFG the rest → Proceed`):

1. **Apply set:** spawn one fixer subagent for the full accumulated set in one pass against the current working tree — this preserves "one fixer, consistent tree" and lets the fixer handle inter-fix dependencies. The queue may be heterogeneous (`gated_auto` and `manual` mixed with `safe_auto`).
2. **Defer set:** already executed inline during the walk-through.
3. **Skip / Acknowledge:** no-op.

Then emit the unified completion report below.

---

## Unified completion report

Every terminal path of Interactive mode emits the same structure: walk-through completed, walk-through bailed via `LFG the rest → Proceed`, top-level LFG (option B), top-level File tickets (option C), or zero findings after `safe_auto` (a one-line degenerate case).

**Minimum required fields (per R12):** per-finding entries (title, severity, action taken, tracker URL for Deferred, one-line reason for Skipped); summary counts by action (e.g., `4 applied, 2 deferred, 2 skipped`); failures called out explicitly above the per-finding list; end-of-review verdict (Ready to merge / Ready with fixes / Not ready) computed from residual state.

**Coverage section:** carries forward existing Coverage data (suppressed-finding count, residual risks, testing gaps, failed reviewers) plus **framing-enrichment gaps** — count of findings where artifact lookup found no match, naming the contributing personas so a persona-upgrade decision has a trail to work from.

**Report ordering:** failures first, then per-finding entries grouped Applied → Deferred → Skipped → Acknowledged, then summary counts, then Coverage, then verdict.

**Zero-findings degenerate case:** when the routing question was skipped because no `gated_auto`/`manual` findings remained after `safe_auto`, the report collapses to summary counts + verdict, with one added line for the `safe_auto` fix count. Use the unqualified `All findings resolved` form only when no advisory/pre-existing findings remain in the report; otherwise use the qualified form naming what was cleared and what remains, e.g. `All actionable findings resolved — 3 safe_auto fixes applied. (2 advisory, 1 pre-existing findings remain in the report.)`

---

## Execution posture

The walk-through is operationally read-only except for two permitted writes: the in-memory Apply set/decision list, and the tracker-defer dispatch (external ticket creation). Persona agents remain strictly read-only. The end-of-walk-through fixer dispatch is the single point where file modifications happen, governed by the existing Step 3 fixer contract in `SKILL.md`.
