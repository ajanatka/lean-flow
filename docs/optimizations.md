# How this setup is optimized

`plugins/lean-flow/` + `harness/` is the core workflow: the skills, review personas, and hooks that make planning, review, and the learning loop happen reliably. None of that requires anything below. But the setup this project was built alongside also leans on a handful of surrounding tools that make it cheap to run continuously rather than only occasionally — filtering what enters model context, indexing code and knowledge so agents query instead of re-read, and adding a second, independent reviewer with different blind spots. This doc names those tools as recommendations and explains what each buys you and how to adopt it. None of them are required to use Lean Flow; they compound with it.

The throughline is the same one in `docs/orchestration.md`: the expensive resource is the orchestrator model's own context and output tokens, so the highest-leverage optimizations are the ones that keep raw, unfiltered output from ever entering it.

## A command-output filter (the "token killer" pattern)

Long-running agent sessions burn a surprising fraction of their budget on command output the model barely reads: full `git diff`, verbose build logs, `npm install` chatter, entire test-suite output when only the failures matter. A CLI proxy that sits in front of your shell tool and filters/compresses that output before it reaches the model can cut 60–90% of those tokens with no loss of the information that actually matters — pass/fail counts, diff hunks, the specific failing assertions, not fifteen lines of scaffolding noise per command. The concrete tool this setup uses is **RTK (Rust Token Killer)** — a Rust CLI proxy that intercepts common dev commands and returns dense, filtered output, with `rtk gain` analytics showing what it saved and `rtk proxy <cmd>` as the raw passthrough.

- **What it is**: a thin wrapper binary that intercepts common dev commands (`git`, build tools, test runners) and rewrites their output into a denser form before it's returned to the model.
- **Why it helps**: it's a durable win that requires zero per-session discipline — once wired in, every command benefits, and the model never sees the savings as a decision it has to make.
- **How to adopt**: wire it in as a `PreToolUse` hook on your Bash tool that rewrites the command (e.g. `git status` → `<proxy> git status`) transparently, so no skill, agent, or CLAUDE.md instruction has to know it exists. If you build or adopt one, keep a raw passthrough mode available for debugging the proxy itself — you'll occasionally need to see what the filter is discarding.

This is the read-side complement to the return-contract discipline in `docs/orchestration.md` (workers return bounded results, not dumps) — one filters at the command boundary, the other at the agent-handoff boundary. Different layers, same principle.

## Code-graph memory (query the structure, don't re-read the files)

Grepping a large codebase into context repeatedly — "where is this function defined," "who calls this," "what's the call chain from A to B" — is expensive and gets more expensive as the repo grows, because the model re-derives structure it already derived in a previous session. A code-graph index (functions, classes, call edges, file/module boundaries) that an agent queries instead of grepping raw files turns that into a fast structured lookup.

- **What it is**: an MCP server (a codebase-memory MCP — the one this setup runs exposes `search_graph`, `trace_path`, `get_code_snippet`, and Cypher-style `query_graph`) that indexes a repo into a queryable graph — "who calls X," "what does X call," "trace the path from A to B," "what's the architecture of this subsystem" — backed by static analysis rather than an LLM re-reading source on every question.
- **Why it helps**: for anything shaped like "find the caller" or "trace this flow," a graph query is both cheaper and more reliable than grep-and-infer, especially in codebases too large to hold in context at once.
- **How to adopt**: install a codebase-graph MCP, index the target repo once, and add a lightweight session-start or pre-search reminder ("prefer graph queries over grep for structural questions about code") so the model reaches for it before falling back to raw file reads. Keep grep/file-read as the fallback for text search, config files, and anything the graph doesn't model (docs, non-code assets).

## Institutional memory (a semantic layer over your learning docs)

The learning-loop pattern in this repo (`lf-learn` writing to `docs/solutions/`) is grep-discoverable at moderate scale, but grep misses paraphrase, cross-repo knowledge, and genuinely semantic matches ("have we solved something like this before" phrased differently than the original doc). A semantic index over that corpus — plus session exports and any shared policy docs — turns "grep and hope for the right keyword" into a synthesized-answer or ranked-conclusions query.

- **What it is**: a semantic/embedding index over your learning-doc corpus (and optionally session history, shared team policy) exposed as a query or chat interface, queryable from any repo rather than scoped to the one you're sitting in.
- **Why it helps**: cross-repo reach is the actual point — a session in one repo can retrieve a decision or a pattern documented while working in a different one, without the model having to know to go spelunking there.
- **How to adopt**: pick a semantic-memory backend (self-hosted or hosted), ingest `docs/solutions/` plus any session-export corpus you keep, and wire it as the *first* lookup step before the grep-based fallback (`lf-learnings-researcher`, or a dispatched scan-worker grep) — never as a replacement, since the index re-ingests periodically and won't have same-day docs yet. Keep `docs/solutions/` itself as the write-side source of truth regardless of what read-side index sits on top; the index should be rebuildable from the Markdown corpus at any time. [Honcho](https://github.com/plastic-labs/honcho) (self-hosted) is the implementation this setup uses — see `docs/customization.md` for the wiring pattern.

## Issue-tracker light index

Paging a full issue-tracker API response into context to check "does an issue already exist for this" is expensive and mostly wasted — the model needs a handful of fields (id, title, status) to dedup, not the full payload. The pattern already shipped in `harness/hooks/` (optional, Linear-specific) generalizes to any tracker: maintain a flat local index file, refreshed on a staleness check, and dedup by grepping it instead of calling the API cold every time.

- **What it is**: a periodically-refreshed flat file (TSV/JSON-lines) of open issues for your team/project, kept in local state rather than re-fetched per lookup.
- **Why it helps**: grepping a local file is close to free; paging tracker API JSON into context on every "should I file this" check is not, and it's a check that happens constantly in a workflow with a commit-nudge hook.
- **How to adopt**: see `docs/customization.md`'s "Swapping in your own issue tracker" section for the concrete adaptation steps if you're not on Linear.

## Second-model adversarial review

A model reviewing its own (or its own family's) output shares blind spots with the model that produced it — the same training biases, the same classes of mistake it's structurally prone to miss. An independent second model, ideally from a different provider, catches a different slice of problems than a same-family review pass does.

- **What it is**: a review pass run through a genuinely different model (e.g. a Codex/GPT-backed MCP tool, or any second-provider agent) on hard-trigger diffs and complex plans — the review-policy tiering in `docs/orchestration.md` already calls this out as the "optional second-model adversarial pass."
- **Why it helps**: non-overlapping blind spots. It's not about one model being "better" — it's that different training and different failure modes catch different bugs.
- **How to adopt**: wire a second-provider review tool (MCP-based, e.g. a Codex integration) as an optional step after your primary persona-review pass on hard-trigger diffs (schema/API/auth/migrations/cross-repo contracts). Loop it: apply the P1/P2 findings, run one follow-up pass if the diff changed substantially, then stop — don't chase stylistic disagreement indefinitely.

## Model-lane economics, briefly

The full reasoning on orchestrator-vs-worker routing, handoff packets, return contracts, and effort levels lives in `docs/orchestration.md` — this is just the one-paragraph pointer. The short version: the strongest model orchestrates and judges; mid-tier and cheap-tier models execute bounded briefs and return bounded results, never raw dumps; you escalate a tier only on a demonstrated failure, not by default; and once a task lane is working, you don't reroute it mid-task in a way that thrashes prompt-cache affinity. Read `docs/orchestration.md` for the full model.

## Deployment and observability access

For agents that need to check whether a deploy went out, read production logs, or confirm a fix actually landed, wiring in your hosting/observability platform's MCP (Railway, Vercel, Better Stack, or your own stack's equivalent) lets the model check deploy status and logs directly instead of asking a human to paste them in. This is a convenience layer, not a requirement of the workflow — add it if your team already uses one of these platforms and wants agents to close the loop on "did this actually ship" themselves.
