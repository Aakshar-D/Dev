# Build HRIS Desk in LinkedAlliance Hub

## Context

The hub needs an HRIS (Human Resources Information System) so HR staff, managers, and
employees can manage people operations in one place. The hub already has the *foundation* —
the `profiles` table carries employee records, manager hierarchy (`manager_id`), team, and
org; `/org-chart` renders reporting lines; check-ins + nine-box cover performance. Missing are
the four HRIS pillars the user selected:

1. **Time-off / PTO** — leave requests, approval up the manager chain, balances, team calendar
2. **Onboarding / Offboarding** — checklist templates instantiated per employee
3. **Compensation & Benefits** — salary history + benefit enrollments (sensitive, HR-only)
4. **Employee Self-Service** — richer employee detail (emergency contacts, employment fields)

Decisions locked with the user: build as a **role desk at `/desks/hris`**, store **native records
only** (no QuickBooks/external payroll sync). HRIS data is sensitive, so RLS is the core of this
work — three access tiers (self / manager / HR-admin).

This is **strictly additive** — new tables, new desk row, new frontend module. Nothing existing
is modified except adding HRIS event types to `activityLogger.ts` and one switch case in
`DeskMode.tsx`.

## Access / Permission Model

Three permission keys (defined by usage — granted later via Admin → Roles UI; admins inherit via
the `*` wildcard in `has_permission`):

| Key | Grants |
|-----|--------|
| `desks.hris.view` | Open the desk; HR staff read **all** employees' PTO, checklists, details |
| `desks.hris.manage` | HR/admin write everything incl. comp & benefits |
| `desks.hris.comp` | Read/write **compensation & benefits** (separate, tighter than view) |

Row-level tiers enforced in RLS (mirrors `manager_id = auth.uid()` pattern from
`20260609120000_tasks_rls_shared_access_model.sql:233`):

- **Self** — every active user reads their own HRIS rows (`employee_id = auth.uid()`) and can
  create/cancel their own leave requests.
- **Manager** — reads **direct reports'** PTO + checklists + employment details via
  `employee_id IN (SELECT id FROM profiles WHERE manager_id = auth.uid())`. Managers approve/deny
  their reports' leave requests. Managers do **NOT** see comp/benefits.
- **HR / Admin** — `desks.hris.view` reads all (except comp); `desks.hris.comp` and `admin.access`
  read/write comp & benefits.

`DeskMode` itself also requires `desks.access` (the gate to enter any desk) — already present.

## Database — migrations

Follow the SSG foundation pattern exactly (`supabase/migrations/20260520120000_ssg_engagements_foundation.sql`):
`CREATE TABLE IF NOT EXISTS`, snake_case plural, `created_at`/`updated_at`, FKs to `profiles(id)`
and `organizations(id)`, indexes, `ENABLE ROW LEVEL SECURITY`, `DROP POLICY IF EXISTS` then
`CREATE POLICY`, helper `public.has_permission(auth.uid(), 'key')`. Timestamp prefix: continue
from latest (`20260622130000`) using today, e.g. `20260629xxxxxx_*`.

Split into 4 additive migrations (one per pillar) for reviewability:

**`20260629120000_hris_foundation.sql`** — desk + self-service
- `hris_employee_details` (1:1 with profiles): `profile_id uuid UNIQUE REFERENCES profiles(id) ON DELETE CASCADE`,
  `employee_number`, `employment_type` CHECK (full_time/part_time/contractor/intern),
  `employment_status` CHECK (active/on_leave/terminated), `hire_date`, `termination_date`,
  `work_location`, `date_of_birth`, `home_address`, timestamps.
- `hris_emergency_contacts`: `id`, `employee_id` FK profiles, `name`, `relationship`, `phone`,
  `email`, `is_primary`, timestamps.
- RLS: self + manager(read) + `desks.hris.view`(read all) + `desks.hris.manage`(write).
- **Seed the desk row** into `public.desks` (`name 'HRIS'`, `slug 'hris'`,
  `permission_key 'desks.hris.view'`, `icon '👥'`, `color`, `is_active true`, `sort_order ~70`),
  `ON CONFLICT (slug) DO NOTHING`.

**`20260629121000_hris_timeoff.sql`**
- `hris_leave_types`: `name`, `color`, `is_paid`, `requires_approval`, `default_annual_hours`, `is_active`.
- `hris_leave_balances`: `employee_id`, `leave_type_id`, `year int`, `accrued_hours`, `used_hours`,
  `carryover_hours`, UNIQUE(employee_id, leave_type_id, year).
- `hris_leave_requests`: `employee_id`, `leave_type_id`, `start_date`, `end_date`, `hours numeric`,
  `reason`, `status` CHECK (pending/approved/denied/cancelled) DEFAULT 'pending', `approver_id`,
  `decided_at`, `decided_by`, `decision_note`, timestamps.
- RLS: self read/insert/cancel-own; manager read+update(approve) reports' requests; types readable
  by all active users, writable by `desks.hris.manage`.

**`20260629122000_hris_onboarding.sql`**
- `hris_checklist_templates`: `name`, `type` CHECK (onboarding/offboarding), `description`, `is_active`.
- `hris_checklist_template_items`: `template_id` FK CASCADE, `title`, `description`, `assignee_role`,
  `due_offset_days int`, `sort_order`.
- `hris_employee_checklists`: `employee_id`, `template_id`, `type`, `status` CHECK
  (not_started/in_progress/completed), `started_at`, `completed_at`.
- `hris_checklist_items`: `checklist_id` FK CASCADE, `title`, `description`, `assignee_id` FK profiles,
  `due_date`, `status` CHECK (pending/done) DEFAULT 'pending', `completed_at`.
- RLS: templates managed by `desks.hris.manage`; employee checklists/items readable by self +
  manager + view; writable by manage (item completion also allowed by the assignee).

**`20260629123000_hris_comp_benefits.sql`** — tightest RLS
- `hris_compensation` (append-only history): `employee_id`, `effective_date`, `comp_type` CHECK
  (salary/hourly), `annual_salary numeric`, `hourly_rate numeric`, `currency DEFAULT 'USD'`,
  `pay_frequency`, `change_reason`, `created_by`, `created_at`. No UPDATE/DELETE policy (immutable,
  like `nine_box_scores`).
- `hris_benefit_plans`: `name`, `type` CHECK (health/dental/vision/retirement_401k/life/other),
  `provider`, `description`, `is_active`.
- `hris_benefit_enrollments`: `employee_id`, `plan_id`, `status` CHECK (enrolled/waived/pending),
  `coverage_level`, `effective_date`, `employee_cost numeric`, `employer_cost numeric`, timestamps.
- RLS: read = self **OR** `desks.hris.comp` **OR** `admin.access` (managers excluded);
  write = `desks.hris.comp` OR `admin.access` only.

After applying, regenerate Supabase types (CI/`supabase gen types` — `types.ts` is auto-generated,
do not hand-edit). Use `db` from `src/lib/db.ts` for queries until types catch up.

## Frontend — desk module

Mirror an existing desk (Client Expansion / SSG). All files under `src/components/desks/hris/`.

- **`HrisDeskContent.tsx`** — entry. `usePermission("desks.hris.view")`, internal tab bar
  (Tabs from `ui/`) routing the four pillars + a "My HR" self-service home. Tab visibility keyed on
  permissions (e.g. Comp tab only if `desks.hris.comp`). Mirror tab/state pattern from
  `ClientExpansionDeskContent.tsx:75`.
- **`MyHrHome.tsx`** — self-service: own details, emergency contacts, leave balances, current
  benefits, active onboarding checklist.
- **`TimeOffTab.tsx`** — request leave (RHF + Zod dialog), my requests, balances; manager approval
  queue (pending requests from direct reports) when user has reports.
- **`ChecklistsTab.tsx`** — template management (manage perm), employee checklist instances,
  item completion.
- **`CompBenefitsTab.tsx`** — comp history + benefit enrollments; gated on `desks.hris.comp`.
- **`EmployeeDirectoryTab.tsx`** — HR roster (view perm): list employees, drill into details.
- Shared dialogs/badges as needed (status badges, leave-type badges).

Data access: direct `db.from("hris_*").select(...)` per existing desk convention; prefer TanStack
Query (`useQuery`/`useMutation`) for mutations per CLAUDE.md. Respect `useDemoMode()` masking on
names/emails and **especially** comp figures. Use shadcn primitives from `ui/`; Lucide icons;
`cn()` for conditional classes.

**Wire into the desk router** — `src/pages/DeskMode.tsx`:
1. Import `HrisDeskContent`.
2. Add `if (desk.slug === "hris") return <HrisDeskContent />;` in `DeskContent` (line ~114).
3. Add `"hris"` to the `overflow-auto` slug list in `<main>` (line 107) so it scrolls full-bleed.

No change needed to `App.tsx` (the `/desks/:slug` route is generic) or `navItems.ts` (desks surface
via the desks gallery, not the main sidebar).

## Activity logging

Add HRIS event types to `EventTypes` in `src/lib/activityLogger.ts` (e.g. `HRIS_LEAVE_REQUESTED:
"hris.leave_requested"`, `HRIS_LEAVE_DECIDED`, `HRIS_CHECKLIST_STARTED`, `HRIS_CHECKLIST_ITEM_DONE`,
`HRIS_COMP_RECORDED`, `HRIS_BENEFIT_ENROLLED`, `HRIS_EMPLOYEE_DETAILS_UPDATED`). Category derives
from the `hris.` prefix automatically. Call `logActivity(...)` on each significant mutation.

## Permission grants (post-deploy, no migration)

Grant `desks.hris.view` / `desks.hris.manage` / `desks.hris.comp` to the appropriate custom roles
via **Admin → Roles** (`RolesAdminTab`). Admins already inherit via `*`. Users also need
`desks.access` to enter the desk (most non-external roles have it).

## Critical files

| Purpose | Path |
|---------|------|
| Desk router (edit) | `src/pages/DeskMode.tsx` |
| New desk module | `src/components/desks/hris/*` (new) |
| Migration pattern ref | `supabase/migrations/20260520120000_ssg_engagements_foundation.sql` |
| Manager-RLS pattern ref | `supabase/migrations/20260609120000_tasks_rls_shared_access_model.sql:233` |
| Immutable-table ref | `nine_box_scores` policies |
| Activity events (edit) | `src/lib/activityLogger.ts` |
| Desk content ref | `src/components/desks/client-expansion/ClientExpansionDeskContent.tsx` |
| Query escape hatch | `src/lib/db.ts` |

## Verification

1. **RLS audit** — `node scripts/check-supabase-security.mjs` passes for all new tables.
2. **Build/lint** — `npm run build` and `npm run lint` clean.
3. **Unit tests** — colocate `*.test.ts` for any pure logic (e.g. balance math, due-date offset
   from `due_offset_days`); `npm run test`.
4. **Manual E2E** (`npm run dev`, localhost:8080):
   - As an **employee**: open `/desks/hris` → My HR shows own details only; submit a leave request;
     confirm cannot see others' or any comp.
   - As a **manager**: see direct reports' pending requests; approve one; confirm status flips and
     activity log records `hris.leave_decided`; confirm comp tab hidden.
   - As **HR (`desks.hris.comp`)**: see full roster, add a comp record (verify append-only — no edit
     of prior rows), enroll a benefit.
   - Confirm desk card appears in the desks gallery and `desks.access`-less users are redirected.
5. **Demo mode** — toggle `useDemoMode()`; verify names, emails, and comp figures are masked.
