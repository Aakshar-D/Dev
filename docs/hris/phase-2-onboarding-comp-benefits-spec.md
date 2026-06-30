# HRIS Desk — Phase 2: Onboarding/Offboarding + Compensation & Benefits (Design Spec)

**Date:** 2026-06-29
**Status:** Approved for planning
**Depends on:** Phase 1 (merged) — desk at `/desks/hris`, `hris_employee_details`, profiles/manager
hierarchy, `desks.hris.view`/`desks.hris.manage` keys, `HrisDeskContent` tab shell.

## Context

Phase 1 shipped HRIS self-service + time-off. Phase 2 completes the module with the two remaining
pillars the user selected: **onboarding/offboarding** (structured new-hire / departure checklists)
and **compensation & benefits** (salary history + benefit enrollment). Comp data is sensitive, so
it gets its own permission key and the tightest RLS in the module.

Locked decisions (with the user):
- **Onboarding instantiation:** manual — HR picks a template + employee + start date and clicks
  "Start". No auto-creation on hire/termination.
- **Checklist storage:** hybrid — a lightweight per-employee checklist *header* in HRIS; the
  individual action items live in the existing `public.tasks` engine (reuses assignees, due dates,
  comments, automations), linked by `source_type` + `source_reference_id`.
- **Item assignees:** per-item role on the template — `new_hire` → the employee, `manager` → the
  employee's `manager_id`, `hr`/`it` → **left unassigned** (HR reassigns via the normal task UI).
- **Comp/benefits visibility:** employee SEES their own comp + benefits (read-only in My HR); only
  `desks.hris.comp` / `admin.access` may write. **Managers are excluded entirely** from comp.
  Benefit enrollments are recorded by HR (no self-enroll).

Strictly additive — new tables + new tab components + one extension to the `tasks.source_type`
validator. No existing behavior changes.

## Access / Permission Model

| Key | Grants |
|-----|--------|
| `desks.hris.view` (existing) | Read checklists/templates; open Checklists tab |
| `desks.hris.manage` (existing) | Create/manage templates; start checklists |
| `desks.hris.comp` (**new**) | Read **and** write compensation & benefits |

Row tiers:
- **Onboarding/checklists** — checklist headers readable by self + direct-manager + `desks.hris.view`;
  writable by `desks.hris.manage`/`admin.access`. The *tasks* themselves inherit the existing
  `tasks` RLS (assignee/manager/creator visibility), so assignees see their own items automatically.
- **Comp & benefits** — read = self (`employee_id = auth.uid()`) **OR** `desks.hris.comp` **OR**
  `admin.access`; write = `desks.hris.comp`/`admin.access` only. Managers get nothing here.

## Database

Conventions identical to Phase 1 (mirror `supabase/migrations/20260520120000_ssg_engagements_foundation.sql`).
Timestamp prefixes continue after Phase 1's `20260629121000`.

### Migration `20260629122000_hris_onboarding.sql`

**Extend the task source-type validator** — the trigger/function from
`20260603120000_extend_task_source_types_for_ssg.sql` rejects unknown `source_type` values.
Add `hris_onboarding` and `hris_offboarding` to its allowed set (re-create the function with the
extended `IN (...)` list). Without this, inserting checklist tasks fails.

Tables:
- `hris_checklist_templates`: `id`, `name`, `type` CHECK (onboarding/offboarding), `description`,
  `is_active bool default true`, timestamps.
- `hris_checklist_template_items`: `id`, `template_id` FK CASCADE, `title`, `description`,
  `assignee_role` CHECK (new_hire/manager/hr/it), `due_offset_days int default 0`,
  `sort_order int default 0`, timestamps. Index on `template_id`.
- `hris_employee_checklists`: `id`, `employee_id` FK profiles, `template_id` FK
  `hris_checklist_templates(id) ON DELETE RESTRICT`, `type` CHECK (onboarding/offboarding),
  `status` CHECK (not_started/in_progress/completed) default 'not_started', `start_date date`,
  `started_by` FK profiles, `started_at`, `completed_at`, timestamps. Indexes on `employee_id`.

RLS:
- templates + template_items: read = any active user with `desks.hris.view` OR `admin.access`
  (templates aren't employee data); write = `desks.hris.manage`/`admin.access`.
- employee_checklists: read = self OR direct-manager OR `desks.hris.view` OR `admin.access`;
  write = `desks.hris.manage`/`admin.access`.

No new task-items table — items are `public.tasks` rows. The header's progress is derived at read
time from its linked tasks (see Frontend), not stored.

### Migration `20260629123000_hris_comp_benefits.sql`

- `hris_compensation` (**append-only**): `id`, `employee_id` FK profiles, `effective_date date`,
  `comp_type` CHECK (salary/hourly), `annual_salary numeric`, `hourly_rate numeric`,
  `currency text default 'USD'`, `pay_frequency text`, `change_reason text`, `created_by` FK
  profiles, `created_at`. Index on `employee_id`. **No UPDATE/DELETE policy** (immutable history,
  mirrors `nine_box_scores`).
- `hris_benefit_plans`: `id`, `name`, `type` CHECK (health/dental/vision/retirement_401k/life/other),
  `provider`, `description`, `is_active bool default true`, timestamps.
- `hris_benefit_enrollments`: `id`, `employee_id` FK profiles, `plan_id` FK
  `hris_benefit_plans(id) ON DELETE RESTRICT`, `status` CHECK (enrolled/waived/pending),
  `coverage_level text`, `effective_date date`, `employee_cost numeric`, `employer_cost numeric`,
  timestamps. Indexes on `employee_id`, `plan_id`.

RLS (all three):
- `hris_compensation`: SELECT = self OR `desks.hris.comp` OR `admin.access`; INSERT =
  `desks.hris.comp`/`admin.access`; no UPDATE/DELETE policy.
- `hris_benefit_plans`: SELECT = any active authenticated user (plan catalog is generic, not
  employee data, and costs live on enrollments — so an employee can resolve plan names for their
  own "My Benefits" card; mirrors `hris_leave_types` in Phase 1); write = `desks.hris.comp`/`admin.access`.
- `hris_benefit_enrollments`: SELECT = self OR `desks.hris.comp` OR `admin.access`; write =
  `desks.hris.comp`/`admin.access`.

After applying, regenerate Supabase types (`db = supabase as any` until then).

## Onboarding hybrid mechanics

**Start a checklist** (HR, `desks.hris.manage`):
1. Insert `hris_employee_checklists` header (employee, template, type, start_date, started_by =
   current user, status='in_progress').
2. For each `hris_checklist_template_items` row, insert a `public.tasks` row:
   - `source_type` = `'hris_onboarding'` or `'hris_offboarding'` (matching the checklist type)
   - `source_reference_id` = the checklist header `id`
   - `title`/`description` from the template item
   - `due_date` = `start_date + due_offset_days`
   - `assigned_to` resolved by `assignee_role`: `new_hire` → `employee_id`; `manager` →
     the employee's `profiles.manager_id`; `hr`/`it` → **null (unassigned)**
   - `created_by` = current user
   Do this in a server-side RPC (`hris_start_checklist(template_id, employee_id, start_date)`) so
   the multi-row insert is atomic and the source-type/assignee logic lives in one place. The RPC is
   `SECURITY DEFINER`, gated internally on `desks.hris.manage`/`admin.access`.

**Progress / completion:** read the linked tasks (`source_type IN (hris_onboarding,hris_offboarding)
AND source_reference_id = checklist.id`); header status is derived — `completed` when all linked
tasks are done, else `in_progress`. A lightweight reconcile (set `completed_at`) can run in the RPC
that marks the last task done, or be computed in the UI for Phase 2 (compute in UI to avoid extra
triggers; revisit if needed).

## Frontend — new tab components under `src/components/desks/hris/`

- **`ChecklistsTab.tsx`** (gated `desks.hris.view`): template management (CRUD, `desks.hris.manage`);
  a "Start checklist" dialog (template + employee + start date → calls `hris_start_checklist` RPC);
  list of employee checklists with rolled-up progress (X/Y tasks done); drill-in shows the linked
  `public.tasks` (link into the existing task views). Activity log on start.
- **`CompBenefitsTab.tsx`** (gated `desks.hris.comp`): per-employee comp history (table; "Add
  compensation record" dialog — insert only, no edit/delete to honor append-only); benefit plans
  catalog (manage) + per-employee enrollments editor. `useDemoMode` masks salary/rate/cost figures.
- **`MyHrHome.tsx`** (extend): add read-only "My Compensation" (latest + history) and "My Benefits"
  (current enrollments) cards, self-scoped. Masked under demo mode.
- **`HrisDeskContent.tsx`** (extend): add Checklists tab (show if `desks.hris.view`) and Comp &
  Benefits tab (show if `desks.hris.comp`), following the existing top-level `usePermission` +
  `show` pattern.

Conventions carry over from Phase 1: `db` reads, TanStack `useMutation` + `invalidateQueries`
(use `["hris"]` prefix), RHF+Zod dialogs, Sonner `onError` toasts, clean payloads (no `id`/PK in
update bodies; comp has no updates anyway), shadcn `ui/`, `useDemoMode` masking.

## Activity logging

Add to `EventTypes` in `src/lib/activityLogger.ts`: `HRIS_CHECKLIST_TEMPLATE_UPDATED`,
`HRIS_CHECKLIST_STARTED`, `HRIS_COMP_RECORDED`, `HRIS_BENEFIT_PLAN_UPDATED`,
`HRIS_BENEFIT_ENROLLED` (all `hris.*`). Call on each mutation/RPC.

## Permission grants (post-deploy)

Grant `desks.hris.comp` to HR/finance roles via Admin → Roles (`RolesAdminTab`). Admins inherit via
`*`. `desks.hris.view`/`manage` already exist from Phase 1.

## Verification

1. **RLS audit** — `node scripts/check-supabase-security.mjs` passes for the 5 new tables;
   `hris_compensation` has SELECT+INSERT only (no UPDATE/DELETE).
2. **Build/lint/tests** — `npm run build`, `npm run lint`, `npm run test` green.
3. **Unit test** — pure logic (e.g. due-date = start + offset; checklist progress rollup) colocated
   `*.test.ts`.
4. **Manual E2E** (post-migration deploy):
   - **HR (`manage`)**: create an onboarding template with items of each role; Start a checklist for
     a new hire → verify tasks created in `public.tasks` with correct `source_type`,
     `source_reference_id`, due dates, and assignees (new_hire→employee, manager→manager, hr/it→
     unassigned); progress reflects task completion.
   - **Employee**: sees their onboarding tasks in the normal task views; sees own comp/benefits
     read-only in My HR; cannot see others' or write comp.
   - **Manager**: cannot see any comp/benefits (tab absent; queries denied).
   - **HR (`comp`)**: add a comp record (verify append-only — prior records not editable); enroll a
     benefit.
5. **Demo mode** — comp figures and salaries masked.
