# HRIS Enhancements — Phase A: CSV Bulk Ops + Checklist Tasks (Design Spec)

**Date:** 2026-06-30
**Status:** Approved for planning
**Depends on:** HRIS Phase 1 + 2 (live). Tables `hris_employee_details`, `hris_compensation`,
`hris_checklist_templates`, `hris_checklist_template_items`, `hris_employee_checklists`, the
`hris_start_checklist` RPC, and the extended `validate_task_fields()` all exist.

## Context

HR asked for bulk data entry and richer checklist authoring on the HRIS desk:
1. CSV upload to bulk-update the employee **Directory**.
2. CSV upload to bulk-add **compensation** history.
3. Author checklist tasks — both editing template items and adding ad-hoc tasks to a live checklist.

(A 4th request — admin-editable custom-field forms — is **Phase B**, its own spec.) Phase A is
**frontend-only**: it adds no tables and changes no schema. It reuses the hub's CSV importer
pattern (`SeamlessUploader` + `papaparse`), the desk tabs' TanStack-mutation/`useDemoMode`/Sonner
conventions, and writes only to existing HRIS tables under the RLS already in place.

## Locked decisions

- **CSV match key:** primarily `employee_number`; the **Directory** import matches on `profile_id`
  carried in the exported template (most reliable, since `employee_number` may be blank), falling
  back to `employee_number`. The **Compensation** import matches on `employee_number`.
- Each importer ships with an **"Export CSV template"** button that downloads current employees so
  HR fills the file against real identifiers, then re-imports.
- Checklist tasks: **both** a template-item editor and ad-hoc task add on started checklists.

## A1 — Directory CSV (in `EmployeeDirectoryTab.tsx`)

**Export template** (button, `desks.hris.view`): query active profiles + their
`hris_employee_details`; download a CSV with header:
`profile_id, full_name, employee_number, employment_type, employment_status, hire_date, work_location`.
`profile_id` is the stable round-trip key; `full_name` is a read-only reference column (ignored on
import). Use a small client-side CSV builder (or papaparse `unparse`).

**Import** (button + dialog, `desks.hris.manage`):
- Parse with `papaparse` (`header: true, skipEmptyLines: true`), strip BOM (mirror `SeamlessUploader`).
- For each row resolve the target employee: `profile_id` if present and valid, else look up by
  `employee_number`. No match → row reported as **skipped**.
- Validate: `employment_type ∈ {full_time,part_time,contractor,intern}` (or blank → leave unset);
  `employment_status ∈ {active,on_leave,terminated}`; dates parse as ISO `YYYY-MM-DD` (blank ok).
  Invalid row → reported as **invalid** (not written).
- **Upsert** valid rows into `hris_employee_details` keyed on `profile_id`
  (`onConflict: "profile_id"`). **A blank cell leaves the existing value unchanged** (omit that key
  from the patch — never overwrite with null); only non-blank columns are written, plus `updated_at`.
  Because upsert needs a full row, fetch the existing `hris_employee_details` row first and merge the
  CSV's non-blank columns over it. Chunk at 100.
- Result summary dialog: `updated`, `skipped (no match)`, `invalid (with row numbers + reason)`.
- `logActivity(EventTypes.HRIS_EMPLOYEE_DETAILS_UPDATED, "Bulk directory import", { updated, skipped, invalid })`.

## A2 — Compensation CSV (in `CompBenefitsTab.tsx`)

**Export template** (button, `desks.hris.comp`): download CSV with header:
`employee_number, full_name, effective_date, comp_type, annual_salary, hourly_rate, currency, pay_frequency, change_reason`.
Pre-fill one row per employee with `employee_number` + `full_name` (other columns blank) so HR has
the numbers to fill against.

**Import** (button + dialog, `desks.hris.comp`):
- Parse (papaparse). Match each row to an employee by `employee_number`; no match → **skipped**.
- Validate: `comp_type ∈ {salary,hourly}`; exactly one of `annual_salary`/`hourly_rate` present and
  numeric; `effective_date` ISO; `currency` defaults `USD` if blank. Invalid → **invalid**.
- **INSERT** valid rows into `hris_compensation` (append-only — each row is a new comp record),
  setting `employee_id` (resolved), `created_by` = importer, and the parsed fields. Chunk at 100.
  No upsert/update (honors append-only).
- Result summary: `inserted`, `skipped`, `invalid (row + reason)`.
- `logActivity(EventTypes.HRIS_COMP_RECORDED, "Bulk compensation import", { inserted, skipped, invalid })`.
- Comp figures masked under `useDemoMode` wherever previewed.

## A3 — Checklist tasks (in `ChecklistsTab.tsx`)

**Template-item editor** (manage): within a template's detail view, an inline editor over
`hris_checklist_template_items` — add / edit / remove / reorder rows. Fields per item: `title`
(required), `description`, `assignee_role` (Select: new_hire/manager/hr/it), `due_offset_days`
(int ≥ 0), `sort_order`. Reorder updates `sort_order` (move up/down or drag). Each mutation:
clean payload (no `id` in update body), `onError` toast, invalidate `["hris"]`,
`logActivity(EventTypes.HRIS_CHECKLIST_TEMPLATE_UPDATED)`. *(If the current ChecklistsTab already
has partial template-item editing, extend it to full add/edit/remove/reorder rather than duplicate.)*

**Ad-hoc task on a started checklist** (manage): on an `hris_employee_checklists` row, an
"Add task" dialog (title required, description, assignee Select from profiles defaulting to the
checklist's employee, due date). On submit INSERT a `public.tasks` row:
`source_type = 'hris_' || checklist.type` (`hris_onboarding`/`hris_offboarding`),
`source_reference_id = checklist.id`, `assigned_to`, `due_date`, `assigned_by`/`updated_by` = current
user, `status='not_started'`. This matches the shape `hris_start_checklist` produces, so the task
appears in the checklist's progress rollup (`checklistProgress` over linked tasks) and in the
assignee's normal task list. `onError` toast; invalidate the checklist's task query + `["hris"]`;
`logActivity` (reuse `HRIS_CHECKLIST_STARTED` or a clear description).

## Shared bits

- A small reusable **CSV importer component** (`HrisCsvImport.tsx`) parameterized by: template
  columns, a per-row validate+map function, and a commit function (upsert vs insert). Both A1 and
  A2 use it — dropzone/file-input → parse → preview count → commit → summary. Modeled on
  `SeamlessUploader.tsx` but generic over the two HRIS targets. Keeps each tab thin.
- CSV export helper (`papaparse.unparse` + Blob download) shared by both export-template buttons.

## Out of scope (Phase B)

Admin-editable custom-field forms for leave requests / checklist template items / benefit plans —
reuse `custom_field_definitions` + `CustomFieldInput` + `ManageCustomFieldsTab`, extend `applies_to`,
add a generic `hris_custom_field_values` table. Separate spec.

## Verification

1. **Build/lint/tests** — `npm run build`, `npm run test` green. Unit-test the pure
   validate/map functions (e.g. directory row → details patch; comp row → insert payload; enum +
   date validation; match resolution) with colocated `*.test.ts`.
2. **Manual E2E** (`npm run dev`, against live or local):
   - **Directory**: Export template → edit a couple rows (set employment_type, hire_date) → Import
     → confirm `hris_employee_details` updated; feed a bad enum + an unknown `profile_id`/`employee_number`
     → confirm those rows report invalid/skipped and are not written.
   - **Comp**: Export template → add comp rows for 2 employees → Import → confirm new
     `hris_compensation` rows (append-only; re-import adds more, never edits); bad `comp_type`/missing
     amount → invalid.
   - **Checklist template editor**: add/edit/remove/reorder items; Start a checklist → tasks reflect
     the edited template.
   - **Ad-hoc task**: on a started checklist, Add task → appears in progress rollup + the assignee's
     task list with correct `source_type`/`source_reference_id`.
3. **Demo mode** — comp preview masked; names masked where shown.
4. **Permissions** — export/import directory gated `desks.hris.manage`; comp gated `desks.hris.comp`;
   a `desks.hris.view`-only user sees no import buttons.
