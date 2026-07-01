# Plan: Real per-PR Supabase preview databases (Full scope)

> Status: **Draft for review** — investigated & verified 2026-07-01, not yet executed.
> Revised after brainstorming: scope raised to Full; added the client.ts/env keystone,
> buckets-via-config.toml, and deliberate cron handling.

## Context

Branching was enabled on the hub project (`trltcyzskmcveuabypat`) on 6/30, but PRs get no
usable preview database. Investigation against the live DB + repo confirmed the original two
issues **and three additional blockers** that the first pass missed. Chosen scope: **Full** —
a PR should get an isolated preview DB that its Vercel preview deployment actually talks to,
and `db push` to prod should be unblocked.

**Verified problems:**
1. **No per-PR branch.** Only the default `main` branch exists; the "Supabase Preview" check
   is SKIPPED. The check comes from Supabase's GitHub App integration (no preview workflow
   lives in the repo), which isn't configured to create a branch per PR.
2. **A fresh branch couldn't build.** Base schema was created by hand in the dashboard and is
   in **no migration** — `organizations`, `profiles`, `desks`, `has_permission()` don't exist
   in `supabase/migrations` (`has_permission` is *referenced* by 29 migrations, never created).
   The first RLS policy calling it aborts the replay. Same reason `db push` is blocked today.
3. **The app can never use a branch DB (keystone finding).** `src/integrations/supabase/client.ts`
   **hardcodes** the prod URL + anon key (lines 5–6); it reads no env var. So even a working
   branch DB + Vercel env injection would be ignored — the built SPA always hits prod.
   (The file is Lovable-generated but untouched since 2026-02-18, so editing it is low risk.)
4. **8 storage buckets are dashboard-created** (`avatars, logos, documents, project-resources,
   task-attachments, partner-contracts, diagtest, training-resources`) — no migration creates
   them; a schema baseline alone won't reproduce them on a branch.
5. **Migration history is already tangled.** Repo is 7 ahead of prod (92 files vs 85 applied;
   HRIS deferred), plus **two version collisions** (`20260630120000`, `20260630130000` each
   have two files) that break `db push` and branch replay.

**Intended outcome:** open a PR → Supabase creates a preview branch that runs baseline +
migrations + seed cleanly, its buckets exist, and the Vercel preview deploy is built against
that branch's DB — while prod stays untouched and `db push` works going forward.

**Decisions (confirmed with user):** Full scope · full-squash to a single baseline · apply the
pending HRIS/other migrations to prod as part of reconciliation · do migrations+seed+app-plumbing
and walk the GitHub/Vercel dashboard wiring interactively.

Environment: Supabase CLI 2.107.0 linked to `trltcyzskmcveuabypat`; Vite 5 SPA (not Next);
`vite.config.ts` is minimal. All `supabase`/app paths are in the **`linkedalliance` submodule**
— run everything from `C:\Users\aksha\Dev\linkedalliance`. Branch deploy order is
clone→pull→configure→migrate→seed→deploy, and a branch **pulls migration history from prod**,
so prod history must be reconciled for branches to apply the right migrations.

---

## Why full-squash auto-resolves the collisions
The colliding partners (`training_library_foundation`, `training_resources`) are already
applied to prod → folded into the baseline and archived. Only the pending HRIS files remain,
so their versions are no longer shared. No manual renumber needed (verify after archiving).

---

## Execution

### Phase 0 — Safety (no prod writes yet)
- Repo feature branch in the submodule: `git checkout -b chore/supabase-branching-baseline`.
- Back up prod: full schema `supabase db dump -f backup/prod-schema-YYYYMMDD.sql`; snapshot
  history `select * from supabase_migrations.schema_migrations order by version;` (save to file).
- Record the reproducible non-schema state for branch parity: bucket list (8, above), the 9
  `cron.job` rows, and the `supabase_realtime` publication tables
  (`tasks, projects, project_sections, project_favorites, task_project_memberships`).
- Note: `migration repair` edits only the history table; the baseline never runs on prod, so
  prod **data is never touched**.

### Phase 1 — Baseline + decide what replays on branches
- Generate baseline as the earliest migration (full current prod schema):
  `supabase db dump > supabase/migrations/00000000000000_baseline.sql`.
  Sanity-check it contains `organizations`, `profiles`, `desks`, `has_permission`, the
  roles/permissions tables and their RLS.
- Archive every already-applied migration out of the replay path into
  `supabase/migrations/_archive/` (derive the set from the Phase 0 history snapshot). Keep only:
  baseline + the pending migrations (HRIS set + any repo version absent from prod history).
- **Keep replayable on branches** (write as small consolidated migrations sorted after
  baseline, since their originals get archived):
  - `..._storage_policies.sql` — recreate the bucket RLS policies (extract current defs from
    prod `pg_policies` where schemaname='storage'). Runs after buckets are created (configure
    step precedes migrate).
  - `..._realtime_publication.sql` — `alter publication supabase_realtime add table ...` for the
    5 tables above.
- **Intentionally NOT replayed on branches:** the 9 cron jobs. Ephemeral preview branches must
  not fire crons (they hit external APIs / send email). Leave cron migrations archived; log
  this so it's a known, deliberate gap.
- Confirm no duplicate version prefixes remain among non-archived files.

### Phase 2 — Reconcile prod history + apply pending
- Mark baseline applied and drop the stale rows in one pass:
  `supabase migration repair --status applied 00000000000000` then
  `supabase migration repair --status reverted <all 85 old versions>` (single call, versions
  scripted from the snapshot). End state: prod history = `[00000000000000]`.
- Apply pending to prod: `supabase db push` (creates HRIS objects; also applies the new
  storage-policies/realtime consolidated migrations idempotently — verify they no-op on prod
  where those policies already exist, guard with `drop policy if exists` / `if not exists`).
- Verify: `supabase migration list` shows local == remote, clean.

### Phase 3 — Branch resources (config.toml) + seed
- Declare all 8 buckets in `supabase/config.toml` under `[storage.buckets.<name>]` (public flag
  + limits matching prod) so the configure step creates them on every branch.
- Ensure seeding is on for preview branches; create `supabase/seed.sql` (idempotent,
  `on conflict do nothing`, test-only): one organization/firm, one `custom_role` + permission
  rows, one `auth.users` test user with a crypt()'d password + matching `profiles` +
  `user_role_assignments`, and any desk registration needed to land on a page.

### Phase 4 — App env plumbing (the keystone)
- `vite.config.ts`: add a `define` (or `loadEnv`-based) bridge that resolves, at build time,
  `import.meta.env.VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` from — in order — an
  existing `VITE_*` value, then the names Supabase's Vercel integration injects
  (`SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`, anon key), then the current prod literals as
  **fallback** (so local dev + prod builds are unchanged).
- `src/integrations/supabase/client.ts`: replace the two hardcoded literals with
  `import.meta.env.VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` (prod values retained as the
  vite.config fallback). Keep the diff to those two lines; the "do not edit" banner is stale
  (untouched since Feb) but keep the edit minimal.
- Confirm the anon key name aligns with what the integration provides; alias in the bridge if
  needed rather than renaming in Vercel.

### Phase 5 — GitHub + Vercel wiring (guided, interactive)
- **Supabase ↔ GitHub**: in the dashboard, confirm the repo is connected, the supabase
  directory points at the submodule's `supabase` path, and preview branches are created per PR.
  This turns the SKIPPED check green.
- **Supabase ↔ Vercel**: install/confirm the Supabase Vercel integration and connect the
  Supabase project to the Vercel project (discover it via the Vercel MCP; not linked locally).
  It auto-syncs each preview branch's creds into the Vercel Preview env at PR-open (and
  re-deploys the latest preview to dodge the documented race). The vite.config bridge (Phase 4)
  is what makes those synced vars reach the client bundle.
- Sanity: the app is a Vite SPA, so creds are baked at **build** time — every preview deploy
  must rebuild (Vercel does per PR commit).

### Phase 6 — Verification (evidence required)
- Local replay: `supabase db reset` (or `supabase branches create test-preview`) → baseline +
  kept migrations + seed apply with **zero errors**; buckets present; `list_branches` shows
  `ACTIVE_HEALTHY`.
- PR check: open a throwaway PR → Supabase Preview check succeeds; a branch appears via
  `mcp__supabase__list_branches`.
- End-to-end: open the Vercel preview URL, sign in as the seeded user, confirm network calls
  hit the **branch** `*.supabase.co` (not prod), and a bucket-backed asset path resolves.
- Tear down the test branch/PR.

---

## Critical files
- `linkedalliance/supabase/migrations/00000000000000_baseline.sql` — generated baseline.
- `linkedalliance/supabase/migrations/_archive/` — the 85 folded-in migrations.
- `linkedalliance/supabase/migrations/*_storage_policies.sql`, `*_realtime_publication.sql` — kept consolidated.
- `linkedalliance/supabase/config.toml` — add `[storage.buckets.*]`, ensure seed enabled.
- `linkedalliance/supabase/seed.sql` — new test seed.
- `linkedalliance/vite.config.ts` — env bridge with prod fallback.
- `linkedalliance/src/integrations/supabase/client.ts` — two lines → `import.meta.env`.

## Rollback
- Prod data untouched (repair = history-table only; baseline never executes on prod).
- If reconciliation misfires, restore `supabase_migrations.schema_migrations` from the Phase 0
  snapshot and delete the baseline row.
- App/env changes are additive with prod fallback; revert the feature branch to undo everything.

## Open items to confirm during execution
- Exact pending version set (diff repo filenames vs Phase 0 history snapshot).
- Any non-`public` schema/object the baseline must include beyond storage policies + realtime.
- Exact env var names the Supabase Vercel integration emits (drives the vite.config bridge).
- The Vercel project/team ID for the hub app (discover via Vercel MCP).
