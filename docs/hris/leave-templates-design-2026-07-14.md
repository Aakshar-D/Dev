# HRIS Leave Structure Templates — Design

**Date:** 2026-07-14
**Status:** Approved (brainstorm with Akshar)
**Repo:** linkedalliance (HRIS desk)

## Purpose

HR currently seeds leave balances one employee at a time (Directory → "Set leave balance").
A leave structure template is a named policy bundling per-leave-type annual allotments
(entered in **days**, converted to hours) that HR applies to one or many employees to
create/update their `hris_leave_balances` rows for a year.

## Decisions (from brainstorm)

| Question | Decision |
|---|---|
| Template concept | Allotment policy (leave types + annual amounts), not a leave-type designer |
| Units | Days, with per-template `hours_per_day` factor (default 8); stored balances stay hours |
| Conflict handling | Chosen per apply: "Skip existing" (default) or "Overwrite allotted" |
| Access | `desks.hris.manage` OR `admin.access` for everything (templates + apply) |
| UI home | New "Leave Templates" tab in HRIS desk, visible to manage/admin only |
| Apply mechanism | SECURITY DEFINER RPC (atomic), mirroring `hris_start_checklist` |

## Data model

```sql
hris_leave_templates
  id uuid pk default gen_random_uuid()
  name text not null
  description text
  hours_per_day numeric not null default 8 check (hours_per_day > 0)
  is_active boolean not null default true
  created_at / updated_at timestamptz

hris_leave_template_items
  id uuid pk default gen_random_uuid()
  template_id uuid not null references hris_leave_templates(id) on delete cascade
  leave_type_id uuid not null references hris_leave_types(id)
  days numeric not null check (days >= 0)
  unique (template_id, leave_type_id)
```

RLS (both tables, SELECT and ALL): `has_permission(auth.uid(), 'desks.hris.manage') OR
has_permission(auth.uid(), 'admin.access')`. Employees never see templates; they see only
the resulting `hris_leave_balances` rows (existing RLS unchanged).

## RPC

```sql
hris_apply_leave_template(
  _template_id uuid,
  _employee_ids uuid[],
  _year int,
  _overwrite boolean
) returns jsonb  -- {created, updated, skipped}
```

- SECURITY DEFINER; first statement re-checks manage/admin permission, raises if absent.
- Raises on: template not found or inactive, empty `_employee_ids`.
- For each employee × active template item:
  - `allotted_hours := days * hours_per_day`
  - No balance row for (employee, leave_type, year) → INSERT (used=0, carryover=0) → `created++`
  - Row exists and `_overwrite` → UPDATE `allotted_hours` only (never `used_hours`/`carryover_hours`) → `updated++`
  - Row exists and not `_overwrite` → `skipped++`
- Items whose leave type is inactive are skipped (counted in `skipped`).
- Single transaction (function body) — all or nothing.

## UI

New tab in `HrisDeskContent.tsx`: key `leave-templates`, label "Leave Templates",
`show: canManage`. New component `src/components/desks/hris/LeaveTemplatesTab.tsx`,
patterned on `ChecklistsTab.tsx`:

1. **Templates list** — card per template (name, description, hours/day, item count,
   active badge; edit/delete with confirm). Expanded card shows items table:
   leave type, days, computed hours. Inline add/edit/remove items; leave-type dropdown
   sourced from active `hris_leave_types`.
2. **Apply dialog** — template → employee multi-select (searchable checkbox list from
   `profiles`) → year (default current) → toggle "Skip existing balances" (default) /
   "Overwrite allotted amounts" → Apply → RPC → toast with created/updated/skipped counts.

Activity logging: new `EventTypes.HRIS_LEAVE_TEMPLATE_UPDATED` (create/edit/delete
template or items) and `EventTypes.HRIS_LEAVE_TEMPLATE_APPLIED` (metadata: template_id,
employee count, year, overwrite, result counts).

Directory tab's manual "Set leave balance" stays as the override path.

## Errors & testing

- Zod: template name required; days ≥ 0; hours_per_day > 0.
- RPC errors surface as toasts.
- Unit tests (vitest, colocated): days→hours conversion and skip/overwrite decision
  helpers as pure functions.
- Post-migration SQL verification: create template → apply to a test employee →
  assert balances → clean up.
- Migration lives in `linkedalliance/supabase/migrations/` + copy in Dev
  `docs/supabase/`; prod apply requires explicit user approval (classifier-gated).

## Out of scope

- Auto-apply on hire / checklist integration
- Carryover rules and accrual schedules (balances remain year-granular)
- Employee-visible template names
