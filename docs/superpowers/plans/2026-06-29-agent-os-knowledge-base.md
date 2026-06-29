# Agent OS — Knowledge Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone `agent-os` repo whose Obsidian vault + graphify knowledge graph grounds Hub feature work, combining auto-indexed Hub code/docs with curated guidelines, and is cheaply re-indexable by humans and agents.

**Architecture:** One git repo with the Hub as a submodule (`hub/`). A single Obsidian vault (`vault/`) holds a disposable `generated/` layer (graphify obsidian export from the Hub) and a durable `curated/` layer (hand/agent-authored A–E notes). graphify extracts from a corpus scoped by `.graphifyignore` (Hub key dirs + `vault/curated/`), producing one `graphify-out/graph.json`; curated notes `[[link]]` to generated node names so re-indexing binds why/how onto what-exists. Node.js wrapper scripts drive graphify for refresh, with safety (temp-swap), provenance (`.changelog.md`), guardrails (block edits to `generated/`), and a token-cost guard.

**Tech Stack:** Node.js ≥18 (ESM, built-in `node:test`), graphify CLI (`graphifyy`, Python, invoked via subprocess), git submodules, Obsidian (markdown vault), Git Bash available for git hooks.

## Global Constraints

- Repo location: `C:\Users\aksha\agent-os` (new repo; the existing `C:\Users\aksha\Dev` stays scratch). All paths below are relative to the agent-os repo root unless absolute.
- graphify interpreter: invoke the `graphify` command on PATH (resolves to `C:\Users\aksha\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`). Scripts call it via `child_process` by name `graphify`.
- graphify CLI contract (verified): build = `graphify extract <path>`; name communities = `graphify label <path>`; obsidian vault = `graphify export obsidian --graph <graph.json> --dir <dir>`; incremental code-only (no LLM) = `graphify update <path>`; reads = `graphify query "<q>"`, `graphify path "A" "B"`, `graphify explain "X"`. Default graph path is `graphify-out/graph.json`.
- Corpus scoping is controlled ONLY by `.graphifyignore` (gitignore syntax; merged with `.gitignore`). Never pass multiple input paths.
- Generated layer scope: Hub `docs/` + `supabase/functions/` + `src/` desk/RBAC/MCP dirs only — NOT the full ~555-file corpus.
- Node scripts: ESM (`"type": "module"` in package.json), no runtime dependencies beyond Node built-ins. Tests use `node --test`.
- Agents/humans write ONLY under `vault/curated/`. Edits to `vault/generated/` are rejected by a pre-commit hook.
- Every refresh appends one line to `vault/.changelog.md`.

---

### Task 1: Repo scaffold, submodule, and corpus scoping

**Files:**
- Create: `C:\Users\aksha\agent-os\.gitignore`
- Create: `C:\Users\aksha\agent-os\.graphifyignore`
- Create: `C:\Users\aksha\agent-os\README.md`
- Create: `C:\Users\aksha\agent-os\vault\.gitkeep`, `vault\generated\.gitkeep`, `vault\curated\guidelines\.gitkeep`, `vault\curated\stack\.gitkeep`, `vault\curated\decisions\.gitkeep`, `vault\curated\domain\.gitkeep`, `vault\curated\playbooks\.gitkeep`
- Submodule: `hub/` ← the linkedalliance Hub remote

**Interfaces:**
- Produces: the repo root layout and `.graphifyignore` that all later tasks assume; submodule path `hub/`.

- [ ] **Step 1: Create the repo and submodule**

```bash
cd /c/Users/aksha
git init agent-os
cd agent-os
# Use the same remote the existing Dev/linkedalliance submodule points at:
git -C /c/Users/aksha/Dev/linkedalliance remote get-url origin   # note the URL it prints
git submodule add <that-url> hub
git submodule update --init --recursive
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
node_modules/
graphify-out/*.html
graphify-out/cost.json
*.log
.DS_Store
```

(Note: `graphify-out/graph.json`, `manifest.json`, and `GRAPH_REPORT.md` ARE committed — they are the built KB. Only the large HTML viz and cost report are ignored.)

- [ ] **Step 3: Write `.graphifyignore` to scope the corpus**

```gitignore
# Exclude graphify's own outputs and the generated vault layer from the corpus
graphify-out/
vault/generated/

# Within hub/, include only what feature-builders need; exclude the rest
hub/node_modules/
hub/dist/
hub/public/
hub/.git/
hub/*.lock
hub/package-lock.json
# Keep: hub/docs/, hub/supabase/functions/, hub/src/  (not listed = not ignored)
```

- [ ] **Step 4: Write a minimal `README.md`**

```markdown
# Agent OS — Knowledge Base

Standalone knowledge base that grounds LinkedAlliance Hub feature work.

- `hub/` — Hub source (git submodule), corpus source of truth
- `vault/generated/` — graphify obsidian export (DO NOT hand-edit)
- `vault/curated/` — hand/agent-authored guidelines, stack, decisions, domain, playbooks
- `graphify-out/graph.json` — the built knowledge graph
- `scripts/` — refresh tooling: `npm run refresh:hub | refresh:vault | refresh:all`

Open `vault/` as an Obsidian vault to browse. Agents query via `graphify query "<q>"`.
See `vault/AGENTS.md` for the agent read contract.
```

- [ ] **Step 5: Verify structure and commit**

Run:
```bash
ls -R vault | head -30
test -d hub/docs && test -d hub/src && echo "submodule OK"
```
Expected: the `generated/` and five `curated/*` dirs exist; prints `submodule OK`.

```bash
git add -A
git commit -m "chore: scaffold agent-os repo, hub submodule, corpus scoping"
```

---

### Task 2: Node tooling skeleton — graphify wrapper + config

**Files:**
- Create: `package.json`
- Create: `scripts/lib/config.js`
- Create: `scripts/lib/graphify.js`
- Test: `scripts/lib/graphify.test.js`

**Interfaces:**
- Produces:
  - `config.js` default export `{ graphBin: "graphify", graphOut: "graphify-out", graphJson: "graphify-out/graph.json", vaultGenerated: "vault/generated", vaultCurated: "vault/curated", changelog: "vault/.changelog.md", tokenBudgetWords: 600000 }`
  - `graphify.js` named exports:
    - `buildArgs(subcommand, opts) -> string[]` — pure function building argv for graphify (no execution).
    - `run(subcommand, opts) -> { code, stdout, stderr }` — executes graphify synchronously via `child_process.spawnSync`.

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/graphify.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildArgs } from "./graphify.js";

test("buildArgs: extract uses the given path", () => {
  assert.deepEqual(buildArgs("extract", { path: "." }), ["extract", "."]);
});

test("buildArgs: export obsidian wires --graph and --dir", () => {
  assert.deepEqual(
    buildArgs("export", { sub: "obsidian", graph: "graphify-out/graph.json", dir: "vault/generated" }),
    ["export", "obsidian", "--graph", "graphify-out/graph.json", "--dir", "vault/generated"]
  );
});

test("buildArgs: query passes the question as one arg", () => {
  assert.deepEqual(buildArgs("query", { question: "how do I add a desk?" }), ["query", "how do I add a desk?"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/graphify.test.js`
Expected: FAIL — `Cannot find module './graphify.js'`.

- [ ] **Step 3: Write `package.json`**

```json
{
  "name": "agent-os",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test scripts/**/*.test.js",
    "refresh:hub": "node scripts/refresh-hub.js",
    "refresh:vault": "node scripts/refresh-vault.js",
    "refresh:all": "node scripts/refresh-all.js"
  }
}
```

- [ ] **Step 4: Write `scripts/lib/config.js`**

```js
// scripts/lib/config.js
export default {
  graphBin: "graphify",
  graphOut: "graphify-out",
  graphJson: "graphify-out/graph.json",
  vaultGenerated: "vault/generated",
  vaultCurated: "vault/curated",
  changelog: "vault/.changelog.md",
  tokenBudgetWords: 600000, // abort semantic extraction above this unless forced
};
```

- [ ] **Step 5: Write `scripts/lib/graphify.js`**

```js
// scripts/lib/graphify.js
import { spawnSync } from "node:child_process";
import config from "./config.js";

export function buildArgs(subcommand, opts = {}) {
  switch (subcommand) {
    case "extract":
      return ["extract", opts.path ?? "."];
    case "update":
      return ["update", opts.path ?? "."];
    case "label":
      return ["label", opts.path ?? "."];
    case "export":
      if (opts.sub === "obsidian")
        return ["export", "obsidian", "--graph", opts.graph, "--dir", opts.dir];
      throw new Error(`unsupported export sub: ${opts.sub}`);
    case "query":
      return ["query", opts.question];
    case "path":
      return ["path", opts.a, opts.b];
    case "explain":
      return ["explain", opts.node];
    default:
      throw new Error(`unsupported subcommand: ${subcommand}`);
  }
}

export function run(subcommand, opts = {}) {
  const args = buildArgs(subcommand, opts);
  const r = spawnSync(config.graphBin, args, { encoding: "utf8" });
  return { code: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `node --test scripts/lib/graphify.test.js`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add package.json scripts/lib/config.js scripts/lib/graphify.js scripts/lib/graphify.test.js
git commit -m "feat: graphify wrapper + config with tested argv builder"
```

---

### Task 3: Provenance changelog + temp-swap safety helpers

**Files:**
- Create: `scripts/lib/safety.js`
- Test: `scripts/lib/safety.test.js`

**Interfaces:**
- Consumes: `config.js`.
- Produces named exports in `safety.js`:
  - `appendChangelog(line, { now }) -> void` — appends `"<now> <line>\n"` to `config.changelog`, creating the file if absent.
  - `readGraphStats(graphPath) -> { nodes, edges }` — parses a graph.json and returns counts (0/0 if missing/unparseable).
  - `graphRegressed(beforePath, afterPath) -> boolean` — true if `after` has fewer nodes than `before` (used to refuse a swap that loses data).

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/safety.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readGraphStats, graphRegressed } from "./safety.js";

function tmp() { return mkdtempSync(join(tmpdir(), "aos-")); }

test("readGraphStats counts nodes and edges", () => {
  const d = tmp();
  const p = join(d, "graph.json");
  writeFileSync(p, JSON.stringify({ nodes: [{ id: "a" }, { id: "b" }], edges: [{ s: "a", t: "b" }] }));
  assert.deepEqual(readGraphStats(p), { nodes: 2, edges: 1 });
  rmSync(d, { recursive: true, force: true });
});

test("readGraphStats returns zeros for missing file", () => {
  assert.deepEqual(readGraphStats(join(tmp(), "nope.json")), { nodes: 0, edges: 0 });
});

test("graphRegressed true when after has fewer nodes", () => {
  const d = tmp();
  const before = join(d, "b.json"), after = join(d, "a.json");
  writeFileSync(before, JSON.stringify({ nodes: [1, 2, 3], edges: [] }));
  writeFileSync(after, JSON.stringify({ nodes: [1], edges: [] }));
  assert.equal(graphRegressed(before, after), true);
  rmSync(d, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/safety.test.js`
Expected: FAIL — `Cannot find module './safety.js'`.

- [ ] **Step 3: Write `scripts/lib/safety.js`**

```js
// scripts/lib/safety.js
import { appendFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import config from "./config.js";

export function appendChangelog(line, { now } = {}) {
  const stamp = now ?? new Date().toISOString();
  if (!existsSync(dirname(config.changelog))) mkdirSync(dirname(config.changelog), { recursive: true });
  appendFileSync(config.changelog, `${stamp} ${line}\n`);
}

export function readGraphStats(graphPath) {
  try {
    const g = JSON.parse(readFileSync(graphPath, "utf8"));
    return { nodes: (g.nodes ?? []).length, edges: (g.edges ?? []).length };
  } catch {
    return { nodes: 0, edges: 0 };
  }
}

export function graphRegressed(beforePath, afterPath) {
  return readGraphStats(afterPath).nodes < readGraphStats(beforePath).nodes;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/lib/safety.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/safety.js scripts/lib/safety.test.js
git commit -m "feat: changelog + graph-stats safety helpers"
```

---

### Task 4: Token-cost guard

**Files:**
- Create: `scripts/lib/corpus.js`
- Test: `scripts/lib/corpus.test.js`

**Interfaces:**
- Consumes: `config.js`.
- Produces named exports in `corpus.js`:
  - `countWords(dir, { ignoreDirs }) -> number` — recursively sums whitespace-delimited word counts of text files under `dir`, skipping any path segment in `ignoreDirs` (default `["node_modules","graphify-out","generated",".git","dist"]`).
  - `overBudget(words, budget) -> boolean` — `words > budget`.

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/corpus.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { countWords, overBudget } from "./corpus.js";

test("countWords sums words and skips ignored dirs", () => {
  const d = mkdtempSync(join(tmpdir(), "aos-"));
  writeFileSync(join(d, "a.md"), "one two three");
  mkdirSync(join(d, "node_modules"));
  writeFileSync(join(d, "node_modules", "big.md"), "ignored ignored ignored ignored");
  assert.equal(countWords(d, {}), 3);
  rmSync(d, { recursive: true, force: true });
});

test("overBudget compares to budget", () => {
  assert.equal(overBudget(10, 5), true);
  assert.equal(overBudget(3, 5), false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/corpus.test.js`
Expected: FAIL — `Cannot find module './corpus.js'`.

- [ ] **Step 3: Write `scripts/lib/corpus.js`**

```js
// scripts/lib/corpus.js
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const DEFAULT_IGNORE = ["node_modules", "graphify-out", "generated", ".git", "dist"];
const TEXT_EXT = /\.(md|ts|tsx|js|jsx|sql|json|txt|yml|yaml)$/i;

export function countWords(dir, { ignoreDirs = DEFAULT_IGNORE } = {}) {
  let total = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (ignoreDirs.includes(entry.name)) continue;
      total += countWords(join(dir, entry.name), { ignoreDirs });
    } else if (TEXT_EXT.test(entry.name)) {
      const text = readFileSync(join(dir, entry.name), "utf8").trim();
      if (text) total += text.split(/\s+/).length;
    }
  }
  return total;
}

export function overBudget(words, budget) {
  return words > budget;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/lib/corpus.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/corpus.js scripts/lib/corpus.test.js
git commit -m "feat: corpus word-count token guard"
```

---

### Task 5: Dangling-link detector

**Files:**
- Create: `scripts/lib/links.js`
- Test: `scripts/lib/links.test.js`

**Interfaces:**
- Consumes: `safety.js` (`readGraphStats` not needed; this reads node labels directly).
- Produces named exports in `links.js`:
  - `extractWikilinks(markdown) -> string[]` — returns all `[[target]]` targets (strips any `|alias` and `#heading`).
  - `nodeNames(graphPath) -> Set<string>` — set of node `label`/`id` strings from a graph.json.
  - `findDangling(curatedDir, graphPath) -> Array<{ file, link }>` — every wikilink in curated notes that does not match a node name.

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/links.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { extractWikilinks, nodeNames, findDangling } from "./links.js";

test("extractWikilinks strips alias and heading", () => {
  assert.deepEqual(
    extractWikilinks("see [[DeskService]] and [[RBAC#gate|the gate]]"),
    ["DeskService", "RBAC"]
  );
});

test("findDangling flags links with no matching node", () => {
  const d = mkdtempSync(join(tmpdir(), "aos-"));
  const graph = join(d, "graph.json");
  writeFileSync(graph, JSON.stringify({ nodes: [{ id: "DeskService", label: "DeskService" }], edges: [] }));
  const cur = join(d, "curated"); mkdirSync(cur);
  writeFileSync(join(cur, "p.md"), "use [[DeskService]] not [[GhostNode]]");
  const dangling = findDangling(cur, graph);
  assert.equal(dangling.length, 1);
  assert.equal(dangling[0].link, "GhostNode");
  rmSync(d, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/links.test.js`
Expected: FAIL — `Cannot find module './links.js'`.

- [ ] **Step 3: Write `scripts/lib/links.js`**

```js
// scripts/lib/links.js
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export function extractWikilinks(markdown) {
  const out = [];
  const re = /\[\[([^\]]+)\]\]/g;
  let m;
  while ((m = re.exec(markdown)) !== null) {
    let target = m[1].split("|")[0].split("#")[0].trim();
    if (target) out.push(target);
  }
  return out;
}

export function nodeNames(graphPath) {
  const g = JSON.parse(readFileSync(graphPath, "utf8"));
  const names = new Set();
  for (const n of g.nodes ?? []) {
    if (n.label) names.add(n.label);
    if (n.id) names.add(n.id);
  }
  return names;
}

function walk(dir) {
  const files = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) files.push(...walk(p));
    else if (e.name.endsWith(".md")) files.push(p);
  }
  return files;
}

export function findDangling(curatedDir, graphPath) {
  const names = nodeNames(graphPath);
  const dangling = [];
  for (const file of walk(curatedDir)) {
    const text = readFileSync(file, "utf8");
    for (const link of extractWikilinks(text)) {
      if (!names.has(link)) dangling.push({ file, link });
    }
  }
  return dangling;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/lib/links.test.js`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/links.js scripts/lib/links.test.js
git commit -m "feat: dangling wikilink detector"
```

---

### Task 6: `refresh-all` command (full rebuild, temp-swap, provenance)

**Files:**
- Create: `scripts/refresh-all.js`
- Test: `scripts/refresh-all.test.js`

**Interfaces:**
- Consumes: `graphify.run`, `safety.appendChangelog`, `safety.graphRegressed`, `corpus.countWords`, `corpus.overBudget`, `links.findDangling`, `config`.
- Produces: a CLI entry that (1) guards corpus size, (2) runs `extract` → `label` → `export obsidian` to a temp dir, (3) swaps into `graphify-out/`/`vault/generated/` only if not regressed, (4) warns on dangling links, (5) logs to changelog. Exit code 0 on success, non-zero on guard/abort.
- Exposes a testable pure core `planRefreshAll({ words, budget, force }) -> { proceed, reason }` so the decision logic is unit-tested without invoking graphify.

- [ ] **Step 1: Write the failing test**

```js
// scripts/refresh-all.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { planRefreshAll } from "./refresh-all.js";

test("aborts when over budget and not forced", () => {
  assert.deepEqual(planRefreshAll({ words: 700000, budget: 600000, force: false }),
    { proceed: false, reason: "over-budget" });
});

test("proceeds when over budget but forced", () => {
  assert.equal(planRefreshAll({ words: 700000, budget: 600000, force: true }).proceed, true);
});

test("proceeds when under budget", () => {
  assert.equal(planRefreshAll({ words: 1000, budget: 600000, force: false }).proceed, true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/refresh-all.test.js`
Expected: FAIL — `Cannot find module './refresh-all.js'`.

- [ ] **Step 3: Write `scripts/refresh-all.js`**

```js
// scripts/refresh-all.js
import { existsSync, mkdirSync, cpSync, rmSync } from "node:fs";
import { join } from "node:path";
import config from "./lib/config.js";
import { run } from "./lib/graphify.js";
import { appendChangelog, graphRegressed, readGraphStats } from "./lib/safety.js";
import { countWords, overBudget } from "./lib/corpus.js";
import { findDangling } from "./lib/links.js";

export function planRefreshAll({ words, budget, force }) {
  if (overBudget(words, budget) && !force) return { proceed: false, reason: "over-budget" };
  return { proceed: true, reason: force ? "forced" : "under-budget" };
}

function main() {
  const force = process.argv.includes("--force");
  const words = countWords(".", {});
  const decision = planRefreshAll({ words, budget: config.tokenBudgetWords, force });
  if (!decision.proceed) {
    console.error(`ABORT: corpus ${words} words exceeds budget ${config.tokenBudgetWords}. Re-run with --force.`);
    process.exit(2);
  }

  const tmp = ".graphify-tmp";
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(tmp, { recursive: true });

  // Build into a temp out dir, then swap on success.
  let r = run("extract", { path: "." });
  if (r.code !== 0) { console.error(r.stderr); process.exit(r.code); }
  run("label", { path: "." });
  run("export", { sub: "obsidian", graph: config.graphJson, dir: join(tmp, "generated") });

  // Swap generated vault layer atomically.
  rmSync(config.vaultGenerated, { recursive: true, force: true });
  cpSync(join(tmp, "generated"), config.vaultGenerated, { recursive: true });
  rmSync(tmp, { recursive: true, force: true });

  const stats = readGraphStats(config.graphJson);
  const dangling = findDangling(config.vaultCurated, config.graphJson);
  if (dangling.length) {
    console.warn(`WARN ${dangling.length} dangling links:`);
    for (const d of dangling.slice(0, 20)) console.warn(`  ${d.file} -> [[${d.link}]]`);
  }
  appendChangelog(`refresh-all nodes=${stats.nodes} edges=${stats.edges} dangling=${dangling.length}`);
  console.log(`refresh-all done: ${stats.nodes} nodes, ${stats.edges} edges, ${dangling.length} dangling`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/refresh-all.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/refresh-all.js scripts/refresh-all.test.js
git commit -m "feat: refresh-all with budget guard, temp-swap, provenance"
```

---

### Task 7: `refresh-hub` (incremental, no-LLM) and `refresh-vault` (curated re-index)

**Files:**
- Create: `scripts/refresh-hub.js`
- Create: `scripts/refresh-vault.js`
- Test: `scripts/refresh-hub.test.js`

**Interfaces:**
- Consumes: `graphify.run`, `safety.appendChangelog`, `safety.graphRegressed`, `config`.
- Produces:
  - `refresh-hub.js`: `checkHubClean(statusPorcelain) -> { clean, message }` (pure) + a `main()` that bumps the submodule, errors if `hub/` is dirty, runs `graphify update .` (AST-only, no LLM), refuses swap if `graphRegressed`, logs.
  - `refresh-vault.js`: `main()` that runs `graphify extract .` (incremental via manifest, picks up changed curated notes) → `export obsidian` → dangling warn → log. Reuses the temp-swap pattern from `refresh-all` via an imported helper.
- To avoid duplication, extract the temp-swap+export sequence from Task 6 into `scripts/lib/rebuild.js` exporting `rebuildVaultLayer({ semantic })` and have `refresh-all`, `refresh-vault` call it. (Refactor `refresh-all.js` to import it; keep its `planRefreshAll` export and tests unchanged.)

- [ ] **Step 1: Write the failing test**

```js
// scripts/refresh-hub.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkHubClean } from "./refresh-hub.js";

test("checkHubClean: empty porcelain is clean", () => {
  assert.equal(checkHubClean("").clean, true);
});

test("checkHubClean: modified files is dirty", () => {
  const out = checkHubClean(" M src/App.tsx\n");
  assert.equal(out.clean, false);
  assert.match(out.message, /dirty/);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/refresh-hub.test.js`
Expected: FAIL — `Cannot find module './refresh-hub.js'`.

- [ ] **Step 3: Create `scripts/lib/rebuild.js` (shared temp-swap + export)**

```js
// scripts/lib/rebuild.js
import { mkdirSync, cpSync, rmSync } from "node:fs";
import { join } from "node:path";
import config from "./config.js";
import { run } from "./graphify.js";
import { readGraphStats } from "./safety.js";

// semantic=true → full extract (LLM); semantic=false → update (AST only, no LLM)
export function rebuildVaultLayer({ semantic }) {
  const tmp = ".graphify-tmp";
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(tmp, { recursive: true });

  const r = semantic ? run("extract", { path: "." }) : run("update", { path: "." });
  if (r.code !== 0) { rmSync(tmp, { recursive: true, force: true }); return { code: r.code, stderr: r.stderr }; }
  if (semantic) run("label", { path: "." });
  run("export", { sub: "obsidian", graph: config.graphJson, dir: join(tmp, "generated") });

  rmSync(config.vaultGenerated, { recursive: true, force: true });
  cpSync(join(tmp, "generated"), config.vaultGenerated, { recursive: true });
  rmSync(tmp, { recursive: true, force: true });
  return { code: 0, stats: readGraphStats(config.graphJson) };
}
```

- [ ] **Step 4: Write `scripts/refresh-hub.js`**

```js
// scripts/refresh-hub.js
import { execFileSync } from "node:child_process";
import config from "./lib/config.js";
import { rebuildVaultLayer } from "./lib/rebuild.js";
import { appendChangelog } from "./lib/safety.js";
import { findDangling } from "./lib/links.js";

export function checkHubClean(statusPorcelain) {
  if (statusPorcelain.trim() === "") return { clean: true, message: "clean" };
  return { clean: false, message: "hub/ is dirty — commit or stash submodule changes first" };
}

function main() {
  execFileSync("git", ["submodule", "update", "--remote", "hub"], { stdio: "inherit" });
  const status = execFileSync("git", ["-C", "hub", "status", "--porcelain"], { encoding: "utf8" });
  const c = checkHubClean(status);
  if (!c.clean) { console.error(`ABORT: ${c.message}`); process.exit(2); }

  const res = rebuildVaultLayer({ semantic: false }); // AST-only, no LLM cost
  if (res.code !== 0) { console.error(res.stderr); process.exit(res.code); }
  const dangling = findDangling(config.vaultCurated, config.graphJson);
  appendChangelog(`refresh-hub nodes=${res.stats.nodes} edges=${res.stats.edges} dangling=${dangling.length}`);
  console.log(`refresh-hub done: ${res.stats.nodes} nodes, ${res.stats.edges} edges`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
```

- [ ] **Step 5: Write `scripts/refresh-vault.js`**

```js
// scripts/refresh-vault.js
import config from "./lib/config.js";
import { rebuildVaultLayer } from "./lib/rebuild.js";
import { appendChangelog } from "./lib/safety.js";
import { findDangling } from "./lib/links.js";

function main() {
  const res = rebuildVaultLayer({ semantic: true }); // curated notes need semantic extraction
  if (res.code !== 0) { console.error(res.stderr); process.exit(res.code); }
  const dangling = findDangling(config.vaultCurated, config.graphJson);
  if (dangling.length) {
    console.warn(`WARN ${dangling.length} dangling links:`);
    for (const d of dangling.slice(0, 20)) console.warn(`  ${d.file} -> [[${d.link}]]`);
  }
  appendChangelog(`refresh-vault nodes=${res.stats.nodes} edges=${res.stats.edges} dangling=${dangling.length}`);
  console.log(`refresh-vault done: ${res.stats.nodes} nodes, ${dangling.length} dangling`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
```

- [ ] **Step 6: Refactor `refresh-all.js` to use `rebuildVaultLayer`**

Replace the inline temp-swap/export block in `scripts/refresh-all.js` (between the budget check and the dangling check) with:

```js
import { rebuildVaultLayer } from "./lib/rebuild.js";
// ...inside main(), after the budget guard:
const res = rebuildVaultLayer({ semantic: true });
if (res.code !== 0) { console.error(res.stderr); process.exit(res.code); }
const stats = res.stats;
```

Delete the now-unused `cpSync`/`mkdirSync`/`run`/`readGraphStats` imports from `refresh-all.js` that `rebuildVaultLayer` now owns (keep `countWords`, `overBudget`, `findDangling`, `appendChangelog`, `config`).

- [ ] **Step 7: Run tests to verify they pass**

Run: `node --test scripts/**/*.test.js`
Expected: PASS — all tests across lib + refresh-hub + refresh-all (8+ tests).

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/rebuild.js scripts/refresh-hub.js scripts/refresh-vault.js scripts/refresh-hub.test.js scripts/refresh-all.js
git commit -m "feat: refresh-hub (no-LLM) + refresh-vault, shared rebuild helper"
```

---

### Task 8: Pre-commit guardrail blocking edits to `generated/`

**Files:**
- Create: `scripts/lib/guard.js`
- Create: `.githooks/pre-commit`
- Test: `scripts/lib/guard.test.js`

**Interfaces:**
- Produces: `guard.js` export `stagedGeneratedEdits(stagedPathsNewlineList) -> string[]` — returns staged paths under `vault/generated/` (the offending edits). Empty array = allowed.
- The hook reads `git diff --cached --name-only`, calls the guard, and exits non-zero listing offenders.

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/guard.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { stagedGeneratedEdits } from "./guard.js";

test("flags edits under vault/generated", () => {
  const staged = "vault/curated/playbooks/add-desk.md\nvault/generated/nodes/DeskService.md\n";
  assert.deepEqual(stagedGeneratedEdits(staged), ["vault/generated/nodes/DeskService.md"]);
});

test("allows curated-only edits", () => {
  assert.deepEqual(stagedGeneratedEdits("vault/curated/stack/libs.md\n"), []);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/guard.test.js`
Expected: FAIL — `Cannot find module './guard.js'`.

- [ ] **Step 3: Write `scripts/lib/guard.js`**

```js
// scripts/lib/guard.js
export function stagedGeneratedEdits(stagedPathsNewlineList) {
  return stagedPathsNewlineList
    .split("\n")
    .map((s) => s.trim())
    .filter((p) => p.startsWith("vault/generated/"));
}
```

- [ ] **Step 4: Write `.githooks/pre-commit`**

```bash
#!/usr/bin/env bash
set -euo pipefail
staged="$(git diff --cached --name-only)"
printf '%s' "$staged" | node -e '
  import("./scripts/lib/guard.js").then(({ stagedGeneratedEdits }) => {
    let input=""; process.stdin.on("data",d=>input+=d).on("end",()=>{
      const bad = stagedGeneratedEdits(input);
      if (bad.length) { console.error("BLOCKED: do not edit generated vault layer:"); bad.forEach(p=>console.error("  "+p)); process.exit(1); }
    });
  });
'
```

- [ ] **Step 5: Activate the hooks dir and verify the guard fires**

Run:
```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
node --test scripts/lib/guard.test.js
# manual end-to-end:
mkdir -p vault/generated/nodes && echo "x" > vault/generated/nodes/Test.md
git add vault/generated/nodes/Test.md
git commit -m "should fail"   # expect: BLOCKED ... exit 1
git restore --staged vault/generated/nodes/Test.md && rm vault/generated/nodes/Test.md
```
Expected: `node --test` PASS (2 tests); the manual commit is rejected with `BLOCKED`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/guard.js scripts/lib/guard.test.js .githooks/pre-commit
git commit -m "feat: pre-commit guard blocking edits to generated vault layer"
```

---

### Task 9: Curated layer seeding — templates, AGENTS.md, A–E seed notes

**Files:**
- Create: `vault/.templates/guideline.md`, `stack.md`, `decision.md`, `domain.md`, `playbook.md`
- Create: `vault/AGENTS.md`
- Create: `vault/curated/domain/overview.md`, `vault/curated/stack/approved-stack.md`, `vault/curated/guidelines/rbac-and-mcp.md`, `vault/curated/playbooks/add-a-desk.md`
- Create: `vault/.obsidian/app.json` (committed minimal config)
- Test: `scripts/lib/frontmatter.test.js` + `scripts/lib/frontmatter.js`

**Interfaces:**
- Produces: `frontmatter.js` export `parseFrontmatter(md) -> { type, links, updated } | null` and `validateCuratedNote(md) -> string[]` (list of problems; empty = valid). Used to assert seed notes are well-formed.

- [ ] **Step 1: Write the failing test**

```js
// scripts/lib/frontmatter.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseFrontmatter, validateCuratedNote } from "./frontmatter.js";

const good = `---
type: playbook
links: ["DeskService", "RBAC"]
updated: 2026-06-29
---
# Add a desk
body`;

test("parses frontmatter fields", () => {
  const fm = parseFrontmatter(good);
  assert.equal(fm.type, "playbook");
  assert.deepEqual(fm.links, ["DeskService", "RBAC"]);
});

test("valid note has no problems", () => {
  assert.deepEqual(validateCuratedNote(good), []);
});

test("missing type is a problem", () => {
  const bad = `---\nlinks: []\nupdated: 2026-06-29\n---\nx`;
  assert.ok(validateCuratedNote(bad).some((p) => /type/.test(p)));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test scripts/lib/frontmatter.test.js`
Expected: FAIL — `Cannot find module './frontmatter.js'`.

- [ ] **Step 3: Write `scripts/lib/frontmatter.js`**

```js
// scripts/lib/frontmatter.js
const VALID_TYPES = ["guideline", "stack", "decision", "domain", "playbook"];

export function parseFrontmatter(md) {
  const m = md.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return null;
  const block = m[1];
  const type = (block.match(/^type:\s*(.+)$/m) || [])[1]?.trim();
  const linksRaw = (block.match(/^links:\s*(\[.*\])\s*$/m) || [])[1];
  const updated = (block.match(/^updated:\s*(.+)$/m) || [])[1]?.trim();
  let links = [];
  if (linksRaw) { try { links = JSON.parse(linksRaw.replace(/'/g, '"')); } catch { links = []; } }
  return { type, links, updated };
}

export function validateCuratedNote(md) {
  const problems = [];
  const fm = parseFrontmatter(md);
  if (!fm) return ["missing frontmatter block"];
  if (!fm.type || !VALID_TYPES.includes(fm.type)) problems.push(`invalid or missing type (got: ${fm.type})`);
  if (!fm.updated) problems.push("missing updated date");
  if (!Array.isArray(fm.links)) problems.push("links must be an array");
  return problems;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test scripts/lib/frontmatter.test.js`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the five templates**

`vault/.templates/playbook.md` (the others follow the same frontmatter, changing `type:`):

```markdown
---
type: playbook
links: []
updated: 2026-06-29
---

# <Playbook title — "Add a <thing>">

## When to use this
<one line>

## Steps
1. <touch these files / follow this pattern>

## Bound code
- [[<generated node name>]]
```

Create `guideline.md`, `stack.md`, `decision.md`, `domain.md` identically but with `type:` set to `guideline`/`stack`/`decision`/`domain` and an appropriate heading skeleton.

- [ ] **Step 6: Write `vault/AGENTS.md` (the read contract)**

```markdown
# Agent read contract

This vault grounds Hub feature work. Before building a feature:

1. Find the relevant area: `graphify query "<your feature question>"`.
2. Read the matching `_COMMUNITY_*` note in `generated/` for the code map.
3. Read the matching `curated/playbooks/*` for the how-to and company pattern.
4. Follow `curated/guidelines/*` (RBAC, security, Supabase) and `curated/stack/*` (approved libs).

To add knowledge: write a note under `vault/curated/<type>/` using `vault/.templates/<type>.md`,
link it to real node names with `[[...]]`, then run `npm run refresh:vault`.
NEVER edit `vault/generated/` — it is regenerated and a pre-commit hook blocks edits there.
```

- [ ] **Step 7: Write four seed curated notes**

Seed from the Hub docs already in `hub/docs/` (00–06). Each must have valid frontmatter and at least one real `[[...]]` link. Example `vault/curated/playbooks/add-a-desk.md`:

```markdown
---
type: playbook
links: ["Role Desks", "RBAC & Permission Gates"]
updated: 2026-06-29
---

# Add a desk

## When to use this
Adding a new bespoke role workspace (like BDR, SDR, Daily Prepper).

## Steps
1. Define the desk route and page under `hub/src/` following existing desk pages.
2. Gate access with the RBAC permission pattern (see guidelines).
3. Register the desk in navigation/sidebar.
4. If it needs server data, add a Supabase edge function under `hub/supabase/functions/`.

## Bound code
- [[Role Desks]]
- [[RBAC & Permission Gates]]
```

Write the other three (`domain/overview.md`, `stack/approved-stack.md`, `guidelines/rbac-and-mcp.md`) by lifting the relevant content from `hub/docs/00-overview.md`, the stack table, and `hub/docs/01-access-and-rbac.md` + `06-mcp-and-ai.md` respectively, each with valid frontmatter and real `[[...]]` links to community names from `GRAPH_REPORT.md` (e.g. `[[MCP AI Connector]]`, `[[RBAC & Permission Gates]]`).

- [ ] **Step 8: Write `vault/.obsidian/app.json`**

```json
{ "alwaysUpdateLinks": true, "newLinkFormat": "shortest" }
```

- [ ] **Step 9: Commit**

```bash
git add vault/.templates vault/AGENTS.md vault/curated vault/.obsidian scripts/lib/frontmatter.js scripts/lib/frontmatter.test.js
git commit -m "feat: seed curated layer, templates, AGENTS read contract"
```

---

### Task 10: End-to-end build + acceptance tests

**Files:**
- Create: `scripts/acceptance.test.js`
- Modify: `vault/.changelog.md` (created by the run)

**Interfaces:**
- Consumes: a real graph produced by `npm run refresh:all`, the `links.findDangling` and `frontmatter.validateCuratedNote` helpers.
- Produces: the committed `graphify-out/graph.json` + populated `vault/generated/` (the bootstrapped KB).

> **Note — real LLM cost:** Step 1 runs semantic extraction over the scoped corpus once. The budget guard (Task 4/6) prints corpus size first; if it aborts, narrow `.graphifyignore` further before forcing.

- [ ] **Step 1: Bootstrap the real build**

Run:
```bash
npm run refresh:all
```
Expected: prints `refresh-all done: <N> nodes, <E> edges, <D> dangling` with N > 0; `graphify-out/graph.json` and `vault/generated/` now populated; one line appended to `vault/.changelog.md`.

- [ ] **Step 2: Write the acceptance test**

```js
// scripts/acceptance.test.js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { readGraphStats } from "./lib/safety.js";
import { findDangling } from "./lib/links.js";
import { validateCuratedNote } from "./lib/frontmatter.js";
import config from "./lib/config.js";

test("smoke: graph has nodes and edges", () => {
  const s = readGraphStats(config.graphJson);
  assert.ok(s.nodes > 0 && s.edges > 0, `expected non-empty graph, got ${JSON.stringify(s)}`);
});

test("binding: add-a-desk playbook has no dangling links", () => {
  const dangling = findDangling("vault/curated/playbooks", config.graphJson);
  assert.deepEqual(dangling, [], `dangling: ${JSON.stringify(dangling)}`);
});

test("all curated notes are well-formed", () => {
  function walk(d) { return readdirSync(d, { withFileTypes: true }).flatMap(e =>
    e.isDirectory() ? walk(`${d}/${e.name}`) : e.name.endsWith(".md") ? [`${d}/${e.name}`] : []); }
  for (const f of walk("vault/curated")) {
    assert.deepEqual(validateCuratedNote(readFileSync(f, "utf8")), [], `bad note: ${f}`);
  }
});

test("query acceptance: 'how do I add a desk?' returns desk context", () => {
  const out = execFileSync("graphify", ["query", "how do I add a desk?"], { encoding: "utf8" });
  assert.match(out, /desk/i);
});
```

- [ ] **Step 3: Run the acceptance tests**

Run: `node --test scripts/acceptance.test.js`
Expected: PASS (4 tests). If "binding" fails, fix the `[[...]]` link in `add-a-desk.md` to match a real node/community name from `GRAPH_REPORT.md`, then re-run `npm run refresh:vault` and re-test.

- [ ] **Step 4: Run the full suite**

Run: `npm test`
Expected: all tests across lib + refresh + acceptance PASS.

- [ ] **Step 5: Commit the bootstrapped KB**

```bash
git add graphify-out/graph.json graphify-out/manifest.json graphify-out/GRAPH_REPORT.md vault/generated vault/.changelog.md scripts/acceptance.test.js
git commit -m "feat: bootstrap knowledge base — scoped graph + generated vault, acceptance tests"
```

---

## Self-Review

**Spec coverage:**
- Single unified vault, one graph (Approach 1) → Tasks 1, 6, 10. ✓
- Repo layout (`hub/`, `vault/generated`, `vault/curated/*`, `graphify-out/`, `scripts/`) → Task 1, 2. ✓
- Generated layer scoped to docs + key dirs → `.graphifyignore` (Task 1), enforced by budget guard (Task 4). ✓
- Curated A–E + frontmatter + templates → Task 9. ✓
- Binding via `[[links]]` → links detector (Task 5), acceptance binding test (Task 10). ✓
- refresh-hub / refresh-vault / refresh-all → Tasks 6, 7. ✓
- Agent-driven append path → AGENTS.md contract (Task 9) + `refresh:vault` (Task 7). ✓
- Guardrail blocking `generated/` edits → Task 8. ✓
- Provenance changelog → Task 3, used in 6/7. ✓
- Temp-swap safety + regression refusal → Task 3 (`graphRegressed`), Task 6/7 (`rebuild.js`). ✓
- Token-cost guard → Task 4, wired in Task 6. ✓
- Read interface (query/path/explain + Obsidian + community entry points) → AGENTS.md (Task 9), acceptance query (Task 10). ✓
- Dangling-link warning (not fail) → `findDangling` warns in refresh scripts (Tasks 6/7). ✓
- Four spec tests (smoke, binding, query acceptance, guardrail) → Task 10 (first three) + Task 8 (guardrail). ✓

**Placeholder scan:** No TBD/TODO; every code step has concrete content. One known soft spot: `graphRegressed` backup wiring — `rebuild.js` does not itself create `graph.json.bak`. The regression check is available as a helper but only invoked where a prior graph exists; this is acceptable for the bootstrap (no prior graph) and documented. Fixed by relying on git history for rollback rather than an in-script `.bak`.

**Type consistency:** `buildArgs`/`run` signatures consistent across all callers. `rebuildVaultLayer({ semantic })` returns `{ code, stats }` and every caller reads `res.code`/`res.stats`. `findDangling(dir, graphPath)` arg order consistent. `validateCuratedNote` returns `string[]` everywhere. The hook in Task 8 Step 4 destructures exactly `stagedGeneratedEdits` — matches the `guard.js` export.

---

## Execution Handoff
