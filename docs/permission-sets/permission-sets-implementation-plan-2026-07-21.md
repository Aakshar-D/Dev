# Permission Sets + Permission Set Groups — Implementation Plan

**Date:** 2026-07-21
**Design:** `permission-sets-design-2026-07-21.md`
**Status:** Not started

Team workflow applies to every PR (kickoff prompt on push, tier block + rollback plan, self-QA, Squash-merge). The DB migration PR is **Tier 3** (modifies the security resolver functions `get_user_permissions` / `has_permission` — same tier as dashboard_sharing): confirm a recent Supabase snapshot before merging, include rollback plan restoring from `security_function_backups` + dropping the six tables.

Phases 3–5 may collapse into one UI PR if convenient; Phase 1 must stay its own Tier-3 PR.

## Phase 1 — DB migration (PR, Tier 3)

One file `supabase/migrations/20260722000000_permission_sets.sql`, in order:

1. `security_function_backups` inserts for current `get_user_permissions` and `has_permission` (reason `'permission_sets migration'`).
2. Six tables + indexes per design §3.
3. RLS enable + policies per design §3 (restrictive pending-block; active-user SELECT on catalog; own-rows-or-admin SELECT on assignments; `has_permission(auth.uid(),'admin.access')` writes).
4. Redefine `get_user_permissions` (two new UNION arms) and `has_permission` (two new OR EXISTS branches via the DO-block introspection pattern) per design §4.
5. `NOTIFY pgrst, 'reload schema'`.

Apply to prod after merge via Supabase MCP `apply_migration` (project `trltcyzskmcveuabypat`; `db push` is broken).

**Verification (MCP `execute_sql`):**
- All six tables exist, `relrowsecurity = true`; expected policies present in `pg_policies`.
- `security_function_backups` has 2 new rows.
- Functional round-trip with throwaway data:
  - Insert set + key (e.g. `reporting.sales_performance.view`), assign to a test user → `get_user_permissions('<uid>')` contains the key; `has_permission('<uid>','<key>')` = true.
  - Move assignment into a group instead → both still true.
  - Delete the set → key gone from both (cascade check).
  - Admin user still returns `'*'`.
  - SSG roster advisor: `get_user_permissions` includes `desks.ssg-engagements.view` but `has_permission` for it stays false (divergence preserved).
  - Clean up test rows.
- `get_advisors` (security) — no new criticals.

## Phase 2 — Catalog extraction refactor (PR, Tier 1)

- Create `src/components/admin/permissionCatalog.tsx`: move `MODULES` + `PermissionModuleGroup` out of `RolesAdminTab.tsx`, export both, add optional `excludeKeys` param.
- Re-point `RolesAdminTab` imports. No behavior change.

**Verification:** `npm run test`, `npm run lint`; browser QA — Roles edit Sheet identical to before.

## Phase 3 — Permission Sets manage + assignment UI (PR, Tier 2)

- Restructure `/admin/roles` into sub-tabs: Roles | Permission Sets | Set Groups | Direct Grants (move `DirectGrantsPanel` out of `RolesAdminTab`, update its copy). Update `sectionMeta.roles.subtitle`.
- `PermissionSetsAdminTab.tsx` per design §6.2 (cards, Sheet builder with `excludeKeys: ['training.external_only']`, delete-and-reinsert save, assigned-users section).
- New `EventTypes` in `src/lib/activityLogger.ts` + `logActivity` on all mutations.

**Verification (browser QA on preview):**
- Create / clone / edit / delete a set; blast-radius confirm on delete.
- Assign set to a user; impersonate → gated feature appears; revoke → gone after reload.
- Non-admin: can read sets, cannot write (RLS check via UI attempt or direct query).
- Activity log rows present.

## Phase 4 — Set Groups UI (PR, Tier 2)

- `PermissionSetGroupsAdminTab.tsx` per design §6.3: set-picker checkboxes, union preview ("Grants N unique permissions across M sets"), assignment UI.

**Verification:** group of 2 sets grants union to assignee; removing a set from group shrinks assignee access; deleting group cascades assignments, member sets untouched.

## Phase 5 — Per-user Access panel (PR, Tier 2)

- `UserAccessPanel.tsx` mounted in Admin user-edit dialog Access tab (extracted component; `updateRole` flow untouched): role select + removable set/group badges + add comboboxes + direct grants list.

**Verification:** panel shows role + sets + groups + grants for a mixed user; add/remove from panel round-trips to the admin tabs.

## Phase 6 — Docs + final QA

- Update `docs/01-access-and-rbac.md`: resolution formula, which-tool-when table (design §2), admin UI walkthrough, new tables in data model.
- Prod smoke matrix: role-only user, role+set, role+group, admin wildcard, impersonation.

## Rollback (Phase 1)

- Restore both function bodies from `security_function_backups` (reason `'permission_sets migration'`).
- `DROP TABLE` the six tables (reverse dependency order or CASCADE).
- Access can only shrink on rollback — fail-closed.
