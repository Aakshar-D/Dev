# 01 — Access & RBAC

## Auth flows

The application uses Supabase Auth. The following routes handle identity:

| Route | Page | Purpose |
|-------|------|---------|
| `/auth` | `Auth.tsx` | Login: email/password, Google SSO, Microsoft SSO |
| `/auth/callback` | `AuthCallback.tsx` | OAuth redirect handler |
| `/reset-password` | `ResetPassword.tsx` | Password reset form |
| `/setup-account` | `SetupAccount.tsx` | First-time password set for invited users |
| `/claim?token=` | `ClaimInvite.tsx` | Claims an invite token via the `claim-invite` edge function |
| `/shared/project/:token` | `SharedProject.tsx` | Read-only external project view — no login required |

**Invite → onboarding flow:**
1. Admin creates user → invite email sent → user clicks link → `/claim?token=` → `/setup-account` (set password) → logged in with `status = "pending"` → shows `PendingApproval.tsx` screen until admin approves → `status = "active"` → full access.

**Session gating (in `App.tsx`):**
- No session → render `Auth`
- Session + `status === "pending"` (non-impersonation) → render `PendingApproval`
- Session + `status === "pending"` (impersonation target) → render `PendingApproval`
- All other cases → `ImpersonationAwareRoutes` → full app

---

## Custom RBAC model

Source: `linkedalliance/docs/custom-rbac-migration.sql`

### Tables

```sql
custom_roles           (id uuid PK, name, description, color, is_system bool, created_by, created_at)
role_permissions       (id uuid PK, role_id → custom_roles, permission_key text, UNIQUE(role_id, permission_key))
user_role_assignments  (id uuid PK, user_id → profiles UNIQUE, role_id → custom_roles, assigned_by, assigned_at)
```

One role per user (enforced by `UNIQUE(user_id)` on `user_role_assignments`).

### Permission resolution

RPC `get_user_permissions(p_user_id uuid) RETURNS SETOF text`:
- If the user's role has `is_system = true` → returns single value `"*"` (all permissions).
- Otherwise → returns all `permission_key` strings from `role_permissions` for that role.

Client hook `usePermission("resource.action")` returns `true` if the resolved array contains the key **or** `"*"`. Fail-closed while loading.

### Permission key format: `resource.action`

**Resources and actions:**

| Resource | Actions |
|----------|---------|
| `users` | `view`, `edit_own`, `edit_any`, `invite`, `approve`, `assign_roles`, `deactivate` |
| `orgs` | `view`, `create`, `edit`, `delete` |
| `projects` | `view`, `view_all`, `create`, `edit`, `edit_any`, `delete`, `manage_members`, `create_from_template`, `manage_templates` |
| `tasks` | `view`, `view_all`, `create`, `edit_own`, `edit_any`, `delete`, `reassign`, `bulk_edit` |
| `tickets` | `view_own`, `view_all`, `create`, `edit_own`, `assign`, `change_status`, `internal_notes`, `delete`, `manage_categories` |
| `documents` | `view_alliance`, `view_org`, `view_private`, `upload`, `approve`, `delete_own`, `delete_any`, `manage_folders` |
| `kb` | `view`, `create`, `edit_own`, `edit_any`, `delete`, `manage_categories` |
| `announcements` | `view`, `create`, `edit_own`, `edit_any`, `delete` |
| `vendors` | `view`, `create`, `edit`, `delete` |
| `ssg` | `view`, `submit_request`, `manage_team`, `view_rates` |
| `performance` | `view_own_team`, `view_org`, `submit_scores`, `manage` |
| `orgchart` | `view`, `manage` |
| `activity` | `view_own`, `view_all`, `export` |
| `admin` | `access`, `manage_quick_links`, `manage_tags` |
| `mcp` | `access`, `read`, `write`, `delete` |

Documents use tiered visibility: `view_alliance` (all active members) > `view_org` (org-scoped) > `view_private` (owner + explicit grants).

### Seeded roles (fixed UUIDs)

| Role | UUID suffix | `is_system` | Color | Notes |
|------|-------------|-------------|-------|-------|
| Admin | `...0001` | `true` | `#dc2626` | Gets `"*"` implicitly; cannot be modified/deleted |
| Executives | `...0002` | `false` | `#7c3aed` | Broad access + all `admin.*` + `mcp.*` |
| Board Member | `...0003` | `false` | `#6d28d9` | Read-wide + `mcp.read` only |
| Partner | `...0004` | `false` | `#2563eb` | Project/task management + `mcp.write` |
| Manager | `...0005` | `false` | `#0891b2` | Partner + task delete + performance.view_org + orgchart.manage |
| Member | `...0006` | `false` | `#059669` | Default on signup; standard access + `mcp.write` |
| SSG Member | `...0007` | `false` | `#0d9488` | Member + ticket management + `ssg.manage_team`/`view_rates` |
| Content Editor | `...0008` | `false` | `#d97706` | Member + full kb/announcements write + document approval |
| Read Only | `...0009` | `false` | `#6b7280` | Read-only across modules; no MCP |
| External | `...000a` | `false` | `#9ca3af` | Minimal: `documents.view_alliance`, `announcements.view`, `kb.view` only |

**Migration rules applied at RBAC rollout:**
- Legacy "Admin" → Admin role
- Legacy "Member" → Member role
- Legacy "Viewer" → Read Only role
- Any unassigned → Read Only role
- Profiles tagged `SSG` + Member role → upgraded to SSG Member

---

## Impersonation

- **How:** Admin selects a user in the admin console → `ImpersonationProvider` swaps the effective user context.
- **Effect:** `usePermissions` resolves against the impersonated user's role. `useAuth` returns impersonated user's profile/role. A warm-colored banner is shown. "End Session" button exits.
- **Audit:** The _real_ admin's identity is preserved for logging. Activity written during impersonation records the real actor.
- **Code:** `src/hooks/useImpersonation.tsx`, `src/hooks/useEffectiveUser.ts`

## Demo Mode

- **How:** Admin or demo user toggles demo mode on (stored in Supabase, reflected by `useDemoMode()`).
- **Effect:** `mask(value)` replaces names, emails, phone numbers with synthetic placeholders. A "Demo Mode Active" banner is shown. Data in CRM/wealth pages checks `isDemoMode` before rendering real values.
- **Mock data:** `src/lib/demoData.ts` provides fallback mock records when demo mode is active.
- **Code:** `src/hooks/useDemoMode.tsx`

---

## Legacy RBAC (not yet dropped)

A first-generation FK-based RBAC (`linkedalliance/docs/rbac-migration.sql`) still exists in the database:
- Tables: `roles`, `permissions`, `role_permissions` (FK-based, not string keys)
- Helper functions: `has_role(uid, app_role)`, `has_permission(uid, key)`, `get_user_role_name(uid)`, `is_active_user(uid)`
- System roles: Admin / Member / Viewer (the `app_role` enum)
- Many RLS policies on older tables still use `has_role(auth.uid(), 'admin'::app_role)` and `is_active_user(auth.uid())`

The custom RBAC is what `useAuth`/`usePermissions` query at runtime. The legacy tables are intentionally not dropped yet — deprecation pending.
