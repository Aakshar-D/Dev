# Agent OS — Knowledge Base (Sub-project 1) — Design

**Date:** 2026-06-29
**Status:** Approved design, pre-implementation
**Author:** brainstormed with Claude

---

## Context

The **Agent OS** is a planned standalone system that talks to the LinkedAlliance Hub via
its MCP server and carries a unified enterprise knowledge base. The intent: when anyone
(human or AI agent) wants to build a new Hub feature, the OS supplies the company's
guidelines, existing build documentation, and tech-stack standards as grounding — so new
work follows established patterns instead of reinventing them.

"Agent OS" as a whole is several independent subsystems:

1. **Knowledge base** — Obsidian vault + graphify graph (this spec)
2. **Query layer** — programmatic MCP/API read access for agents
3. **Hub MCP client** — the OS acting against the live Hub
4. **Agents** — things that consume the KB and take action
5. **Human UI** — querying/editing the same store

This document specs **only sub-project 1, the Knowledge Base.** Subsystems 2–5 are
follow-on specs and are explicitly out of scope here.

### Primary consumer

Agents first, humans second. The KB is built to be consumed programmatically (the read
contract here becomes what sub-project 2 wraps in MCP), with humans querying/editing the
same store via Obsidian.

### Existing assets reused

- graphify already ran over the Hub (`linkedalliance`): 2847 nodes, 8810 edges, 165
  communities. Output is Obsidian-shaped (`[[wikilinks]]`, `_COMMUNITY_*` hub notes).
- The Hub is already tracked as a git submodule.
- graphify keeps a `manifest.json` with per-file `ast_hash` / `semantic_hash` → incremental
  re-index is cheap.

---

## Goals / Non-goals

**Goals**
- A single, queryable, updatable knowledge graph that grounds Hub feature work.
- Combine auto-indexed Hub code/docs ("what exists") with curated guidelines/decisions
  ("why/how") in one graph so a query reaches both.
- "Updatable later": cheap incremental refresh, plus an agent-driven path to append
  knowledge.

**Non-goals (deferred to specs 2–5)**
- No MCP server / API wrapper.
- No web UI (Obsidian is the human surface for now).
- No agents that act against the live Hub.
- No autonomous feature-building pipeline.

---

## Architecture (Approach 1 — single unified vault, one graph)

One Obsidian vault holds two folders — a disposable `generated/` layer (graphify output
from the Hub) and a durable `curated/` layer (hand- and agent-authored A–E knowledge).
graphify indexes the **whole vault** into one graph. Curated notes `[[link]]` to generated
node names, so re-indexing turns those links into real edges binding why/how onto
what-exists.

Rejected alternatives:
- **Two graphs, federated** — cross-links break across graph boundaries; query layer gets
  complex. Bad for agents-first.
- **Curated-only vault, Hub indexed separately** — two refresh paths, fragile name-based
  links.

### Repo layout

```
agent-os/                        # new git repo at C:\Users\aksha\agent-os
├─ hub/                          # linkedalliance Hub as submodule (code source of truth)
├─ vault/                        # the Obsidian vault (the KB)
│  ├─ .obsidian/                 #   committed config so vault opens consistently
│  ├─ .templates/                #   one note template per curated type
│  ├─ AGENTS.md                  #   the read contract (Section: Read interface)
│  ├─ .changelog.md              #   refresh provenance log
│  ├─ generated/                 # graphify output — DO NOT hand-edit
│  │  ├─ nodes/                  #   per-node notes
│  │  └─ communities/            #   _COMMUNITY_* hub notes
│  └─ curated/                   # hand + agent authored — the editable KB
│     ├─ guidelines/             #   (A) coding standards, RBAC/security, Supabase patterns
│     ├─ stack/                  #   (B) approved libs/versions, use-vs-avoid + why
│     ├─ decisions/              #   (C) ADRs
│     ├─ domain/                 #   (D) desk/module purpose, glossary, business rules
│     └─ playbooks/              #   (E) "to add feature X, touch these files, follow this pattern"
├─ graphify-out/                 # built graph (graph.json, graph.html, manifest.json, report)
├─ scripts/                      # refresh/ingest tooling
└─ README.md
```

- `generated/` is disposable — rebuilt from `hub/` anytime. `curated/` is the durable asset.
- Both folders live in one vault → one graph.

---

## Components

### 1. Generated layer (auto-indexed from Hub)

- graphify runs over `hub/` and emits node + community notes into `vault/generated/`.
- **Scope:** Hub `docs/` + key source dirs only (edge functions, `src/` desks, RBAC, MCP) —
  NOT the full 555-file / ~550k-word corpus. The existing run flagged semantic extraction
  over the full corpus as expensive; scoping keeps token cost sane and focuses the KB on
  what feature-builders need.
- Output is already Obsidian-shaped, so it drops straight in.

### 2. Curated layer (A–E, hand + agent authored)

- Five subfolders, one per knowledge type (guidelines, stack, decisions, domain, playbooks).
- Seeded once from existing material: the Hub's `docs/00–06` become `domain/` + `guidelines/`
  notes; the stack table → `stack/`; MCP/RBAC docs → `guidelines/`.
- Each curated note carries frontmatter:
  ```yaml
  ---
  type: guideline | stack | decision | domain | playbook
  links: [ "node-name-1", "node-name-2" ]   # generated nodes this note binds to
  updated: 2026-06-29
  ---
  ```
- Templates per type live in `vault/.templates/` so humans and agents write consistent notes.

### 3. Binding layer

- Curated notes reference generated node names via `[[...]]`.
- When graphify re-indexes the whole vault, those links become real edges.
- Result: an agent querying "how do I build a desk" reaches both the playbook *and* the
  actual desk code nodes.

### 4. Refresh tooling (`scripts/`)

Thin wrappers over graphify + git:

- **`refresh-hub`** — bump `hub/` submodule, run graphify incrementally over the scoped Hub
  dirs (manifest hashes → only changed files re-extract). Rewrites `vault/generated/`.
- **`refresh-vault`** — re-index after curated notes change. Incremental over `vault/curated/`.
- **`refresh-all`** — full rebuild of the graph from both layers.

**Agent-driven path:** an agent that learns something new writes a curated note (type
template + frontmatter), then calls `refresh-vault`. Self-updating KB.

**Guardrail:** agents/humans write only under `vault/curated/`, never `generated/`. A
pre-commit check rejects edits to `generated/`.

**Provenance:** every refresh appends a line to `vault/.changelog.md` (what ran, which layer,
node/edge delta from the graph report).

### 5. Read interface (v1 — minimal; full wrapper is sub-project 2)

- **Agents:** query via graphify's existing graph tools (query / path / explain) against
  `graphify-out/graph.json`. `vault/AGENTS.md` documents the contract: "to build feature X,
  query the graph for the relevant community → read its playbook + bound code nodes." This
  is the interface sub-project 2 will wrap in MCP.
- **Humans:** open `vault/` in Obsidian — graph view, backlinks, search over both layers.
  No new UI built.
- **Entry points:** the 165 `_COMMUNITY_*` notes are the navigation index. Curated
  `playbooks/` are the task-oriented entry, each linking into its community.

---

## Data flow

```
Hub submodule (hub/)
   │  refresh-hub (graphify, incremental)
   ▼
vault/generated/  ──┐
                    ├─►  graphify index (refresh-all)  ──►  graphify-out/graph.json
vault/curated/  ────┘            ▲                                  │
   ▲   refresh-vault             │ [[links]] → edges                │ query/path/explain
   │                             │                                  ▼
human edits (Obsidian)    agent writes note            agents (read contract) + humans (Obsidian)
```

---

## Error handling

- graphify run fails → build to a temp dir, swap into `graphify-out/` only on success;
  previous graph stays intact. Failure logged to `.changelog.md`.
- Dangling `[[links]]` in curated notes → refresh warns (lists them), does not fail.
- Submodule out of sync → `refresh-hub` errors clearly if `hub/` is dirty or detached.
- Token-cost guard → `refresh-hub` prints estimated corpus size before semantic extraction
  and aborts if over a set budget unless `--force` is passed.

---

## Testing

- **Smoke:** `refresh-all` on a clean checkout produces a non-empty `graph.json` + report
  with node/edge counts > 0.
- **Binding test:** at least one curated playbook resolves its `[[...]]` links to real
  generated nodes (no dangling links).
- **Query acceptance:** the canned question "how do I add a desk?" returns the desk playbook
  + desk code community via the graph tools (end-to-end grounding proof).
- **Guardrail test:** an edit under `generated/` is rejected by the pre-commit check.

---

## Deliverables (definition of done)

1. New `agent-os` repo with Hub submodule and the layout above.
2. `vault/` with seeded curated A–E notes, templates, and `AGENTS.md` read contract.
3. `vault/generated/` populated from a scoped graphify run over the Hub.
4. `scripts/refresh-hub`, `refresh-vault`, `refresh-all` working, with token-cost guard,
   temp-swap safety, dangling-link warnings, and `.changelog.md` provenance.
5. Pre-commit guardrail blocking edits to `generated/`.
6. All four tests above passing.

---

## Follow-on specs (not this one)

- **Sub-project 2:** Query layer — wrap the read contract in MCP/API.
- **Sub-project 3:** Hub MCP client — OS acting against the live Hub.
- **Sub-project 4:** Agents — consume KB + act.
- **Sub-project 5:** Human UI beyond Obsidian.
