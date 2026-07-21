# Permission Sets + Permission Set Groups — Design

**Date:** 2026-07-21
**Status:** Draft — design approved for spec, implementation not started
**App:** Linked Alliance Hub (linkedalliance, portal.linkedalliance.co)

## 1. Problem

The hub's RBAC gives each user exactly one `custom_role` (`user_role_assignments` has `UNIQUE(user_id)`). The only way to grant access beyond a user's role is a direct single-key grant in `user_permissions` (Dashboard Sharing, PR-era `20260721000000_dashboard_sharing.sql`). There is no reusable way to layer a *bundle* of extra access on top of a role — e.g. "give these five people the HRIS-manager capabilities without changing their roles" requires N×M individual grants.

## 2. Concept

Salesforce-style additive access:

- **Permission set** — a named, reusable bundle of permission keys (same `resource.action` vocabulary as `role_permissions`, sourced from the `MODULES` catalog in `src/components/admin/RolesAdminTab.tsx`). Assigned to users *in addition to* their single role. Many sets per user. Union semantics — a set can only add access, never remove it.
- **Permission set group** — a named bundle of permission sets. Assigning a group to a user grants the union of all member sets' keys. Groups contain sets only — **no nested groups** (prevents cycles, keeps resolution one join deep).

Effective permissions for a user:

```
role keys ∪ direct-set keys ∪ group-set keys ∪ user_permissions direct grants ∪ SSG-advisor keys (client path only)
```

The Admin system role still resolves to `'*'` (wildcard) — unchanged.

### Which tool when

| Tool | Shape | Who manages | Use for |
|---|---|---|---|
| Role (`custom_roles`) | exactly one per user, baseline | Admin | Who the user *is* |
| Permission set | many per user, additive bundle | Admin | Reusable capability add-ons |
| Permission set group | bundle of sets, one assignment | Admin | Common combinations of add-ons |
| Direct grant (`user_permissions`) | one key, one user | Admin or delegated (dashboard share RPCs) | One-off shares, esp. dashboard sharing by non-admins |

`user_permissions`, `DirectGrantsPanel`, and the `grant_user_permission` / `revoke_user_permission` RPCs are **kept as-is** — they serve delegated single-key dashboard sharing by non-admins, which sets (admin-only) would regress. A "convert grants to set" affordance is deferred.

## 3. Schema

Six new tables in one migration, `supabase/migrations/20260722000000_permission_sets.sql`, modeled on `20260721000000_dashboard_sharing.sql` (header with tier + rollback plan, `security_function_backups` inserts before redefining functions, `NOTIFY pgrst, 'reload schema'` at the end). Applied to prod via Supabase MCP `apply_migration` (project `trltcyzskmcveuabypat`) — `db push` remains broken per the discarded branching plan.

```sql
-- Catalog
CREATE TABLE public.permission_sets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  description text,
  color       text,
  is_system   boolean NOT NULL DEFAULT false,  -- reserved for future app-managed sets; UI renders read-only
  created_by  uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX permission_sets_name_key ON public.permission_sets (lower(name));

CREATE TABLE public.permission_set_keys (
  set_id         uuid NOT NULL REFERENCES public.permission_sets(id) ON DELETE CASCADE,
  permission_key text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (set_id, permission_key)
);
CREATE INDEX permission_set_keys_key_idx ON public.permission_set_keys (permission_key);

CREATE TABLE public.permission_set_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  description text,
  color       text,
  created_by  uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX permission_set_groups_name_key ON public.permission_set_groups (lower(name));

CREATE TABLE public.permission_set_group_members (
  group_id uuid NOT NULL REFERENCES public.permission_set_groups(id) ON DELETE CASCADE,
  set_id   uuid NOT NULL REFERENCES public.permission_sets(id) ON DELETE CASCADE,
  added_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, set_id)
);
CREATE INDEX psgm_set_id_idx ON public.permission_set_group_members (set_id);

-- Assignments (audit columns mirror user_permissions)
CREATE TABLE public.user_permission_set_assignments (
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  set_id      uuid NOT NULL REFERENCES public.permission_sets(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  note        text,
  PRIMARY KEY (user_id, set_id)
);
CREATE INDEX upsa_set_id_idx ON public.user_permission_set_assignments (set_id);

CREATE TABLE public.user_permission_set_group_assignments (
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  group_id    uuid NOT NULL REFERENCES public.permission_set_groups(id) ON DELETE CASCADE,
  assigned_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  note        text,
  PRIMARY KEY (user_id, group_id)
);
CREATE INDEX upsga_group_id_idx ON public.user_permission_set_group_assignments (group_id);
```

Design choices:

- **Composite PKs, no surrogate ids** on join/assignment tables — follows the newer `user_permissions` style, not the older surrogate-id + UNIQUE style of `role_permissions`.
- **FKs to `profiles(id)`** for `user_id` (matches `user_role_assignments`; `profiles.id` = auth uid).
- **ON DELETE CASCADE from sets/groups everywhere** — deletion only *removes* access (fail-closed), so cascading is safe. The UI adds a blast-radius confirm (see §7).
- **Case-insensitive unique names** on sets and groups — they are picked from lists by name in two UIs; duplicates would confuse.
- **`is_system` only on `permission_sets`**, default false, unused at launch. No seed data — bundles are org-specific; seeding invents policy.

### RLS

All six tables: `ENABLE ROW LEVEL SECURITY` plus the RESTRICTIVE "block pending users" policy (`is_active_user(auth.uid())`), per the pattern in `linkedalliance/docs/custom-rbac-migration.sql`.

- Catalog tables (`permission_sets`, `permission_set_keys`, `permission_set_groups`, `permission_set_group_members`): SELECT for active authenticated users (parity with `role_permissions`); INSERT/UPDATE/DELETE gated on `has_permission(auth.uid(), 'admin.access')`.
- Assignment tables: SELECT own rows (`user_id = auth.uid()`) OR admin; writes admin only.
- Admin UI writes tables directly (like `custom_roles`) — no RPC layer. `has_permission` is SECURITY DEFINER, so using it in these policies does not recurse (the resolver reads base tables directly, not through RLS).

## 4. Resolution

The two SECURITY DEFINER functions are the only resolution funnel — extending them lights up client gates (`usePermission`, `PermissionGate`) and every RLS policy at once. Both redefinitions back up current definitions into `security_function_backups` first (reason `'permission_sets migration'`).

**`get_user_permissions(p_user_id uuid)`** — reproduce current body verbatim (Admin `'*'` branch, role keys, SSG-advisor unnest, `user_permissions` branch), append two UNION arms:

```sql
  UNION
  -- Permission sets assigned directly to the user
  SELECT psk.permission_key
  FROM public.user_permission_set_assignments upsa
  JOIN public.permission_set_keys psk ON psk.set_id = upsa.set_id
  WHERE upsa.user_id = p_user_id
  UNION
  -- Permission sets granted via an assigned permission set group
  SELECT psk.permission_key
  FROM public.user_permission_set_group_assignments upsga
  JOIN public.permission_set_group_members psgm ON psgm.group_id = upsga.group_id
  JOIN public.permission_set_keys psk ON psk.set_id = psgm.set_id
  WHERE upsga.user_id = p_user_id
```

`UNION` (not `UNION ALL`) dedupes keys held via role + set + group simultaneously.

**`has_permission(uuid, text)`** — do **not** delegate to `get_user_permissions`; that would newly grant SSG roster advisors RLS-level access via advisor keys (the deliberate divergence documented in §4 of the dashboard_sharing migration). Reuse its `DO $do$` introspection block and append two `OR EXISTS` branches to the current four-branch body:

```sql
        OR EXISTS (
          SELECT 1
          FROM public.user_permission_set_assignments upsa
          JOIN public.permission_set_keys psk ON psk.set_id = upsa.set_id
          WHERE upsa.user_id = $1 AND psk.permission_key = $2
        )
        OR EXISTS (
          SELECT 1
          FROM public.user_permission_set_group_assignments upsga
          JOIN public.permission_set_group_members psgm ON psgm.group_id = upsga.group_id
          JOIN public.permission_set_keys psk ON psk.set_id = psgm.set_id
          WHERE upsga.user_id = $1 AND psk.permission_key = $2
        )
```

**Wildcard:** `'*'` is synthesized only for the Admin system role inside the resolver; sets store concrete keys and the catalog contains no `'*'`. No wildcard handling needed in the new arms.

## 5. Client

**Zero changes to `src/hooks/usePermissions.tsx`.** Resolution stays server-side in the RPC; the provider already fetches `get_user_permissions(effectiveUserId)`:

- Impersonation works for free (sets/groups resolve for the impersonated user's id).
- Fail-closed behavior, `PermissionGate`, `useIsExternalTrainee` untouched.
- Existing behavior (unchanged): permissions are fetched per session — a newly assigned set takes effect for the target user on next reload/login, same as role changes today.

Generated `types.ts` will lag; new UI uses `db` from `src/lib/db.ts` per repo convention.

## 6. Admin UI

**Location: extend the existing `/admin/roles` section with sub-tabs** (the `ssg` section in `Admin.tsx` already establishes Tabs-inside-a-section). One "access control" home, no new route/nav item; update `sectionMeta.roles.subtitle`.

Tabs: **Roles** (existing `RolesAdminTab` minus `DirectGrantsPanel`) | **Permission Sets** | **Set Groups** | **Direct Grants** (relocated `DirectGrantsPanel` with updated copy: "one-off, per-person dashboard shares — for reusable bundles of access, use Permission Sets").

Components:

1. **`src/components/admin/permissionCatalog.tsx`** (extraction refactor) — move `MODULES` and `PermissionModuleGroup` out of `RolesAdminTab.tsx` and export; `RolesAdminTab` imports back. Add optional `excludeKeys` param so the sets UI hides `training.external_only` — it is a *restriction marker*, not additive access; granting it via a set would confine the user, the opposite of set semantics.
2. **`PermissionSetsAdminTab.tsx`** — clone of RolesAdminTab structure: card grid (name, description, color dot, key count, assigned-user count, "in N groups" badge); create/edit/clone via Sheet + searchable collapsible checkbox matrix; save = insert/update `permission_sets` + delete-and-reinsert `permission_set_keys` (RolesAdminTab.handleSave pattern). Assigned-users section in the Sheet: searchable combobox to add, rows show assignee / assigned_by / assigned_at / note / remove. `logActivity` on every mutation with new `EventTypes` (`ADMIN_PERMISSION_SET_CREATED/UPDATED/DELETED/ASSIGNED/REVOKED` + group equivalents) in `src/lib/activityLogger.ts`.
3. **`PermissionSetGroupsAdminTab.tsx`** — group cards + Sheet builder listing **permission sets as checkboxes** (name, description, key-count badge — not the key matrix), plus computed union preview: "Grants N unique permissions across M sets" with expandable read-only key list. Assignment UI identical to sets, writing `user_permission_set_group_assignments`.
4. **`UserAccessPanel.tsx`** — mounted in the Admin user-edit dialog's Access tab (extracted as a component rather than growing the 98KB `Admin.tsx`). Shows current role (existing select), assigned sets and groups as removable badges + "Add set / Add group" comboboxes, and the user's direct grants — "everything this user can do and why" in one place. The single-role `updateRole` flow (dual-write to `profiles.role_id` + `user_role_assignments`) is untouched.

## 7. Edge cases

| Case | Decision |
|---|---|
| Delete a set that's in groups / assigned | Allowed. DB cascades memberships + assignments (access only shrinks — fail-closed). UI confirm shows blast radius: "Assigned to N users, member of M groups — those users lose this access." (Roles block delete while members exist because users must always have a role; sets have no such invariant.) |
| Delete a group | Allowed, cascades assignments; member sets untouched. Same blast-radius confirm. |
| Same key via role + set + group | `UNION` dedupes; `has_permission` is OR-of-EXISTS. No double count. |
| Empty set / empty group | Allowed; grants nothing; UI shows "0 permissions" badge. |
| Key catalog drift | Keys are free text (same as `role_permissions`). A key removed from `MODULES` stays in DB but gates nothing; dropped silently on next edit-save (delete-and-reinsert) — identical to role behavior today. |
| `training.external_only` | Excluded from set/group catalog (restriction marker; additive semantics don't apply). |
| Wildcard `'*'` | Never stored in sets; only synthesized for Admin system role. |
| Nested groups | Not supported — groups contain sets only; no cycle handling needed. |
| Impersonation | Automatic: `get_user_permissions(p_user_id)` is called with the impersonated id. |
| SSG-advisor divergence | Preserved exactly — `has_permission` does not gain SSG keys. |
| Seed data | None. `is_system` ships unused. |
| Legacy `profiles.role_id` dual-write | Untouched — sets never interact with the role machinery. |

## 8. Reference files

- `linkedalliance/supabase/migrations/20260721000000_dashboard_sharing.sql` — migration template (backup table, resolver redefinition, RLS style)
- `linkedalliance/src/components/admin/RolesAdminTab.tsx` — MODULES catalog + Sheet/checkbox-matrix pattern
- `linkedalliance/src/pages/Admin.tsx` — section router, user-edit Access tab mount point, `updateRole` (untouched)
- `linkedalliance/src/hooks/usePermissions.tsx` — confirms zero client change
- `linkedalliance/docs/custom-rbac-migration.sql` — RLS policy patterns and base RBAC
- `docs/01-access-and-rbac.md` — authoritative RBAC doc; must be updated when this ships

See `permission-sets-implementation-plan-2026-07-21.md` for phasing and verification.
