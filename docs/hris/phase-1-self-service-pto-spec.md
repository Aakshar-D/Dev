# HRIS Desk — Phase 1: Self-Service + PTO (Design Spec)

**Date:** 2026-06-29
**Status:** Approved for planning
**Scope:** Phase 1 of the HRIS desk. Phase 2 (onboarding, comp & benefits) is outlined at the
end and gets its own spec.

## Context

The LinkedAlliance hub needs an HRIS so HR staff, managers, and employees manage people
operations in one place. The foundation already exists — `profiles` carries employee records,
manager hierarchy (`manager_id`), team, org; `/org-chart` renders reporting lines; check-ins +
nine-box cover performance. What's missing is structured time-off and richer employee data.

Locked decisions (with the user):
- Build as a **role desk at `/desks/hris`** (not a top-level page or admin tab).
- **Native records only** — no QuickBooks/external payroll sync.
- **Phased**: Phase 1 = foundation + employee self-service + PTO (the daily-use core). Phase 2 =
  onboarding + compensation/benefits.
- Onboarding (Phase 2) uses a **hybrid** model (header table + `public.tasks`).
- PTO balances are **manually set + auto-decremented** on approval (no accrual engine).

This work is **strictly additive** — new tables, new desk row, new frontend module. The only edits
to existing files are `DeskMode.tsx` (one switch case) and `activityLogger.ts` (new event types).

## Access / Permission Model

Permission keys (defined by usage; granted via Admin → Roles; admins inherit via `*`):

| Key | Grants (Phase 1) |
|-----|------------------|
| `desks.hris.view` | Open the desk; read **all** employees' details + PTO (HR roster) |
| `desks.hris.manage` | Write employee details, leave types, set balances, decide any request |
| `desks.hris.comp` | *(Phase 2)* read/write compensation & benefits — not used yet |

Entry also requires the existing `desks.access` gate (checked in `DeskMode.tsx:29`).

Row-level tiers in RLS, mirroring the direct-report pattern at
`supabase/migrations/20260609120000_tasks_rls_shared_access_model.sql:233`:

- **Self** — any active user reads their own rows (`employee_id = auth.uid()`), edits their own
  emergency contacts, and creates/cancels their own leave requests.
- **Manager** — reads **direct reports'** details + leave (`employee_id IN (SELECT id FROM
  public.profiles WHERE manager_id = auth.uid())`) and approves/denies their reports' requests.
- **HR / Admin** — `desks.hris.view` reads all; `desks.hris.manage` or `admin.access` writes all.

## Database

Pattern reference: `supabase/migrations/20260520120000_ssg_engagements_foundation.sql` —
`CREATE TABLE IF NOT EXISTS`, snake_case plural, `created_at`/`updated_at`, FK to `profiles(id)`,
indexes, `ENABLE ROW LEVEL SECURITY`, `DROP POLICY IF EXISTS` then `CREATE POLICY`, RLS via
`public.has_permission(auth.uid(), 'key')`. Timestamp prefixes continue from latest
(`20260622130000`) using today's date.

### Migration `20260629120000_hris_foundation.sql` — self-service + desk

**`hris_employee_details`** (1:1 with profiles)
- `profile_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE`
- `employee_number text`
- `employment_type text CHECK (employment_type IN ('full_time','part_time','contractor','intern'))`
- `employment_status text NOT NULL DEFAULT 'active' CHECK (employment_status IN ('active','on_leave','terminated'))`
- `hire_date date`, `termination_date date`
- `work_location text`, `date_of_birth date`, `home_address text`
- `created_at`, `updated_at`

**`hris_emergency_contacts`**
- `id uuid PRIMARY KEY DEFAULT gen_random_uuid()`
- `employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE`
- `name text NOT NULL`, `relationship text`, `phone text`, `email text`, `is_primary boolean DEFAULT false`
- `created_at`, `updated_at`
- Index on `employee_id`.

**Seed the desk row** into `public.desks` (`name 'HRIS'`, `slug 'hris'`, description,
`icon '👥'`, `color '#0e7490'`, `permission_key 'desks.hris.view'`, `is_active true`,
`sort_order 70`), `ON CONFLICT (slug) DO NOTHING`.

**RLS** (both tables): the "self" column is `profile_id` on `hris_employee_details` and
`employee_id` on `hris_emergency_contacts`; "manager-of" matches that same column against the
direct-report subquery. SELECT = self OR manager-of OR `desks.hris.view` OR `admin.access`;
INSERT/UPDATE/DELETE on `hris_emergency_contacts` = self OR `desks.hris.manage` OR `admin.access`;
`hris_employee_details` writes = `desks.hris.manage` OR `admin.access` (HR owns employment fields).

### Migration `20260629121000_hris_timeoff.sql` — PTO

**`hris_leave_types`**
- `id uuid PK DEFAULT gen_random_uuid()`, `name text NOT NULL`, `color text`,
  `is_paid boolean NOT NULL DEFAULT true`, `requires_approval boolean NOT NULL DEFAULT true`,
  `is_active boolean NOT NULL DEFAULT true`, `created_at`, `updated_at`.

**`hris_leave_balances`** (manually set by HR)
- `id uuid PK`, `employee_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`,
  `leave_type_id uuid NOT NULL REFERENCES hris_leave_types(id) ON DELETE CASCADE`,
  `year int NOT NULL`, `allotted_hours numeric NOT NULL DEFAULT 0`,
  `used_hours numeric NOT NULL DEFAULT 0`, `carryover_hours numeric NOT NULL DEFAULT 0`,
  `created_at`, `updated_at`, `UNIQUE(employee_id, leave_type_id, year)`.

**`hris_leave_requests`**
- `id uuid PK`, `employee_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`,
  `leave_type_id uuid NOT NULL REFERENCES hris_leave_types(id)`,
  `start_date date NOT NULL`, `end_date date NOT NULL`, `hours numeric NOT NULL`,
  `reason text`, `status text NOT NULL DEFAULT 'pending' CHECK (status IN
  ('pending','approved','denied','cancelled'))`,
  `approver_id uuid REFERENCES profiles(id)`, `decided_at timestamptz`,
  `decided_by uuid REFERENCES profiles(id)`, `decision_note text`,
  `created_at`, `updated_at`. Indexes on `employee_id` and `status`.

**Balance auto-decrement trigger** — `public.hris_apply_leave_balance()`, fired
`AFTER UPDATE OF status ON hris_leave_requests`:
- On transition **→ `approved`**: `UPDATE hris_leave_balances SET used_hours = used_hours +
  NEW.hours` for the matching `(employee_id, leave_type_id, year = extract(year from start_date))`.
- On transition **approved → (denied|cancelled)**: subtract `OLD.hours` back.
- `SECURITY DEFINER` so the decrement runs regardless of who flipped the status, and cannot be
  bypassed by a client writing `used_hours` directly. If no matching balance row exists, the
  trigger is a no-op (HR sets balances first). Idempotent on repeated same-status writes (guard on
  `OLD.status IS DISTINCT FROM NEW.status`).

**RLS**:
- `hris_leave_types`: SELECT = any active user; write = `desks.hris.manage` OR `admin.access`.
- `hris_leave_balances`: SELECT = self OR manager-of OR `desks.hris.view` OR `admin.access`;
  write = `desks.hris.manage` OR `admin.access`.
- `hris_leave_requests`: SELECT = self OR manager-of OR `desks.hris.view` OR `admin.access`;
  INSERT = self (`employee_id = auth.uid()`) OR `desks.hris.manage`; UPDATE = manager-of (to
  approve/deny) OR self (only to cancel own pending) OR `desks.hris.manage` OR `admin.access`.

After applying, regenerate Supabase types (`types.ts` is auto-generated — do not hand-edit). Use
`db` from `src/lib/db.ts` for queries until types catch up.

## Frontend — `src/components/desks/hris/`

Mirror an existing desk (`ClientExpansionDeskContent.tsx:75` for tab/state pattern).

- **`HrisDeskContent.tsx`** — entry. `usePermission("desks.hris.view")` +
  `useCurrentUserPermissions()` loading guard. Internal tab bar (shadcn `Tabs`):
  - **My HR** (always) → `MyHrHome`
  - **Time Off** (always) → `TimeOffTab`
  - **Directory** (only if `desks.hris.view`) → `EmployeeDirectoryTab`
- **`MyHrHome.tsx`** — own `hris_employee_details` (read), own emergency contacts (editable),
  own leave balances, own recent requests.
- **`TimeOffTab.tsx`** — request-leave dialog (React Hook Form + Zod: type, dates, hours, reason);
  "My Requests" list with status; "My Balances"; **manager approval queue** (pending requests
  where `employee_id` is a direct report) with approve/deny + note. Show the queue only when the
  user has reports.
- **`EmployeeDirectoryTab.tsx`** — HR roster: list profiles + employment status/type/hire date,
  drill into a panel to edit `hris_employee_details`.
- Small shared bits: leave-status badge, leave-type badge.

Conventions: direct `db.from("hris_*").select(...)` for reads; TanStack `useMutation` +
`queryClient.invalidateQueries` for writes (per CLAUDE.md); shadcn primitives from `ui/`; Lucide
icons; `cn()` for conditional classes. Respect `useDemoMode()` masking on names/emails/phones.

**Wire into the router** — `src/pages/DeskMode.tsx`:
1. Import `HrisDeskContent`.
2. In `DeskContent` (line ~114): `if (desk.slug === "hris") return <HrisDeskContent />;`
3. Add `"hris"` to the `overflow-auto` slug list in `<main>` (line 107).

No change to `App.tsx` (`/desks/:slug` is generic) or `navItems.ts` (desks surface via the gallery).

## Activity logging

Add to `EventTypes` in `src/lib/activityLogger.ts` and call `logActivity()` on each mutation:
`HRIS_EMPLOYEE_DETAILS_UPDATED: "hris.employee_details_updated"`,
`HRIS_EMERGENCY_CONTACT_UPDATED: "hris.emergency_contact_updated"`,
`HRIS_LEAVE_REQUESTED: "hris.leave_requested"`,
`HRIS_LEAVE_DECIDED: "hris.leave_decided"`,
`HRIS_LEAVE_CANCELLED: "hris.leave_cancelled"`,
`HRIS_BALANCE_SET: "hris.balance_set"`,
`HRIS_LEAVE_TYPE_UPDATED: "hris.leave_type_updated"`.
Category derives from the `hris.` prefix automatically.

## Permission grants (post-deploy, no migration)

Grant `desks.hris.view` / `desks.hris.manage` to the relevant custom roles via Admin → Roles
(`RolesAdminTab`). Admins inherit via `*`. Users also need `desks.access` to enter the desk.

## Verification

1. **RLS audit** — `node scripts/check-supabase-security.mjs` passes for all new tables.
2. **Build/lint** — `npm run build` and `npm run lint` clean.
3. **Unit test** — trigger logic is DB-side, so cover pure frontend logic (e.g. hours-from-date-range
   calc) with a colocated `*.test.ts`; `npm run test`.
4. **Manual E2E** (`npm run dev`, localhost:8080):
   - **Employee**: open `/desks/hris` → My HR shows only own data; edit an emergency contact; submit
     a leave request; confirm cannot see other employees.
   - **Manager**: approval queue lists a direct report's pending request; approve it → status flips,
     `hris_leave_balances.used_hours` increments via trigger, activity log records `hris.leave_decided`.
     Deny/cancel a previously approved one → balance restored.
   - **HR (`desks.hris.view`+`manage`)**: see full roster; set a balance; create a leave type.
   - Confirm the HRIS card shows in the desks gallery; a user without `desks.access` is redirected.
5. **Demo mode** — toggle `useDemoMode()`; verify names/emails/phones masked.

---

## Phase 2 (outline — separate spec)

- **Onboarding/Offboarding (hybrid)**: `hris_checklist_templates` + `hris_checklist_template_items`
  define reusable checklists; `hris_employee_checklists` is a per-employee header (status, progress);
  individual action items live in `public.tasks` with `source_type='hris_onboarding'` /
  `'hris_offboarding'` and `source_reference_id` → the checklist (reuses the SSG action-item pattern,
  assignees, due dates, automations). Frontend: `ChecklistsTab`.
- **Compensation & Benefits**: introduces `desks.hris.comp`. `hris_compensation` append-only history
  (no UPDATE/DELETE policy, like `nine_box_scores`); `hris_benefit_plans`; `hris_benefit_enrollments`.
  RLS read = self OR `desks.hris.comp` OR `admin.access` (**managers excluded**); write = comp/admin
  only. Frontend: `CompBenefitsTab`, gated on `desks.hris.comp`; `useDemoMode` masks comp figures.
