# HRIS Phase B — Admin-Editable Custom Fields (Design Spec)

**Date:** 2026-06-30
**Status:** Approved for planning
**Depends on:** HRIS Phase 1 + 2 (live) and the hub's existing custom-fields system
(`custom_field_definitions`, `task_custom_field_values`, `ManageCustomFieldsTab`,
`CustomFieldInput`, `useCustomFields`/`useManageCustomFields`).

## Context

HR admins want to add/remove their own fields on HRIS forms without code changes. The hub already
has a custom-fields system (a definition library + typed value table + admin editor + dynamic
renderer), today scoped to tasks. Phase B **extends that same system** to five HRIS entities so an
admin defines a field in one place and it renders on the matching HRIS form; archiving the field
removes it from the form while preserving entered values.

Locked decisions:
- Entities that get custom fields: **leave request, benefit plan, checklist template (header),
  checklist template item, employee details** (5 keys).
- A field may target **multiple** entities (multi-select `applies_to`).
- Admin manages fields in the **existing** `/admin/custom-fields` tab (extended with an "applies
  to" picker) — not a new section.
- "Remove a field" = **archive** (`is_active=false`): hides it from forms, keeps values.

## Data model

### Extend `custom_field_definitions`
The table has a CHECK: `applies_to <@ ARRAY['task','project']`. Migration must **drop and recreate**
that constraint to allow the new keys (additive relaxation; no data touched):
```
ALTER TABLE public.custom_field_definitions DROP CONSTRAINT custom_field_definitions_applies_to_valid;
ALTER TABLE public.custom_field_definitions ADD CONSTRAINT custom_field_definitions_applies_to_valid
  CHECK (cardinality(applies_to) >= 1
         AND applies_to <@ ARRAY['task','project',
           'hris_leave_request','hris_benefit_plan','hris_checklist_template',
           'hris_checklist_template_item','hris_employee_details']::text[]);
```
Field types/config unchanged (`number/text/single_select/date/checkbox`). Existing definitions RLS
(read all-auth, create self, update creator-or-admin, delete admin) is reused as-is.

### New table `hris_custom_field_values`
One generic value table for all HRIS entities (mirrors `task_custom_field_values`' typed columns):
```
CREATE TABLE public.hris_custom_field_values (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL CHECK (entity_type IN
    ('hris_leave_request','hris_benefit_plan','hris_checklist_template',
     'hris_checklist_template_item','hris_employee_details')),
  entity_id uuid NOT NULL,            -- the record's id (profile_id for employee_details)
  field_id uuid NOT NULL REFERENCES public.custom_field_definitions(id) ON DELETE CASCADE,
  value_number numeric, value_text text, value_date date, value_bool boolean,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id, field_id)
);
CREATE INDEX idx_hcfv_entity ON public.hris_custom_field_values(entity_type, entity_id);
CREATE INDEX idx_hcfv_field  ON public.hris_custom_field_values(field_id);
```
Reuse `public.tg_touch_updated_at()` trigger for `updated_at`. Type→column mapping identical to
the task value table: `number→value_number`, `checkbox→value_bool`, `date→value_date`,
`text|single_select→value_text`.

### RLS on `hris_custom_field_values`
**Read inherits the parent record's visibility** via an `EXISTS` against each parent table (each
parent's own RLS filters the subquery — the same trick `task_custom_field_values` uses, so a value
is visible exactly when its parent row is):
```
USING (
  (entity_type='hris_leave_request'           AND EXISTS(SELECT 1 FROM public.hris_leave_requests r WHERE r.id = entity_id))
  OR (entity_type='hris_employee_details'      AND EXISTS(SELECT 1 FROM public.hris_employee_details d WHERE d.profile_id = entity_id))
  OR (entity_type='hris_benefit_plan'          AND EXISTS(SELECT 1 FROM public.hris_benefit_plans p WHERE p.id = entity_id))
  OR (entity_type='hris_checklist_template'      AND EXISTS(SELECT 1 FROM public.hris_checklist_templates t WHERE t.id = entity_id))
  OR (entity_type='hris_checklist_template_item' AND EXISTS(SELECT 1 FROM public.hris_checklist_template_items i WHERE i.id = entity_id))
)
```
**Writes (INSERT/UPDATE/DELETE)** are tighter than read — gated on HR perms, plus self for own
leave-request values (so an employee filling a custom field while requesting leave can save it):
```
USING / WITH CHECK (
  public.has_permission(auth.uid(),'desks.hris.manage')
  OR public.has_permission(auth.uid(),'admin.access')
  OR (entity_type='hris_leave_request'
      AND EXISTS(SELECT 1 FROM public.hris_leave_requests r WHERE r.id = entity_id AND r.employee_id = auth.uid()))
)
```
(No comp-tier — `hris_compensation` is deliberately NOT in the field-enabled entity list.) Enable
RLS; `GRANT SELECT,INSERT,UPDATE,DELETE ... TO authenticated`.

Migration: `supabase/migrations/20260630120000_hris_custom_fields.sql` (additive; relaxes one CHECK,
adds one table + trigger + RLS).

## Admin editor — extend `ManageCustomFieldsTab`

- Add an **"Applies to"** control to the create/edit-field dialog: a multi-select over
  `Task`, `Leave Request`, `Benefit Plan`, `Checklist Template`, `Checklist Item`, `Employee Details`
  → persists to `applies_to` (array). Default for new fields stays `['task']` unless changed.
- The create path currently hard-codes `applies_to=['task']`; change it to use the picker value
  (at least one selected). Edit allows changing `applies_to`. Archive/unarchive + option editing
  unchanged. `logActivity(EventTypes.ADMIN_CUSTOM_FIELD_UPDATED, ...)` as today.
- The library list may show an "Applies to" column/badges so admins see each field's targets.

## Rendering — shared hook + form sections

New hook **`useHrisCustomFields(entityType: string, entityId: string | undefined)`** in
`src/components/desks/hris/useHrisCustomFields.ts` (mirrors `useTaskCustomFields`):
- Loads active definitions where `applies_to` contains `entityType`
  (`db.from("custom_field_definitions").select("*").contains("applies_to",[entityType]).eq("is_active",true)`).
- Loads values: `hris_custom_field_values` where `entity_type=entityType AND entity_id=entityId`.
- `setValue(def, raw)`: upsert one row on `onConflict: "entity_type,entity_id,field_id"`, writing the
  typed column for the def's `field_type` + `updated_by`. Returns `{ definitions, values, loading, setValue, reload }`.
- Reuse the existing `readValue`/`toValuePatch` type-mapping logic (extract from `useCustomFields.ts`
  into a shared helper if cleanest, else replicate the small mapping).

Drop a **"Custom fields"** section (loop rendering `CustomFieldInput` per definition) into:
- **Leave request** dialog (`TimeOffTab`): entity_type `hris_leave_request`, entity_id = the request
  id. For a NEW request, save the leave request first, then its custom values (entity_id needs the id).
- **Benefit plan** editor (`CompBenefitsTab`): `hris_benefit_plan`, entity_id = plan id.
- **Checklist template header + item** editors (`ChecklistsTab`): `hris_checklist_template` (entity_id
  = template id) and `hris_checklist_template_item` (entity_id = item id).
- **Employee details** editor (`EmployeeDirectoryTab`): `hris_employee_details`, entity_id =
  `profile_id`. Read-only mirror of the employee's own values in `MyHrHome`.

Each section: render only definitions that exist for the entity (none → render nothing); `canEdit`
follows the form's existing permission (e.g. employee details → manage; leave request → the
requester or manage). Respect `useDemoMode` masking on text values that could be PII. Invalidate the
relevant `["hris", ...]` query (or the hook's own query) after `setValue`.

## Verification

1. **Migration**: applies cleanly; the relaxed CHECK accepts the 5 HRIS keys; `hris_custom_field_values`
   created with RLS enabled. `node scripts/check-supabase-security.mjs` passes for the new table.
2. **Build/lint/tests**: `npm run build`, `npm run test` green. Unit-test the hook's type→column
   mapping (e.g. a `number` def writes `value_number`, a `checkbox` writes `value_bool`) with a
   colocated `*.test.ts` on the extracted mapping helper.
3. **E2E** (against live, which has the HRIS tables):
   - Admin → Custom Fields → add a `single_select` field "Reason Category" applying to `Leave Request`
     → it renders on the leave-request dialog; pick a value, submit, reopen → value persists.
   - Add a `text` field to `Employee Details` → shows in the Directory details editor (manage) and
     read-only in My HR for the employee.
   - Add fields to benefit plan + checklist template + item → render on those editors.
   - **Archive** the field → it disappears from the form; the previously saved value row remains in
     `hris_custom_field_values` (un-archive → value still there).
   - **RLS**: as a plain employee, confirm you can read/write custom values only on your OWN leave
     request + see your own employee-details custom values; cannot read others'.
4. **Multi-entity**: one field targeting both `Leave Request` and `Employee Details` renders on both.

## Out of scope

- Compensation records get no custom fields (kept append-only + minimal).
- Per-record field ordering/column config on HRIS list views (tasks have it; not needed here).
- Filtering/sorting HRIS lists by custom field value (the typed columns + indexes leave the door
  open, but no UI in this phase).
