# HRIS Phase B (Admin-Editable Custom Fields) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins add/remove custom fields on five HRIS forms (leave request, benefit plan, checklist template + item, employee details) by reusing and extending the hub's existing custom-fields system.

**Architecture:** One additive migration relaxes the `custom_field_definitions.applies_to` CHECK and adds a generic `hris_custom_field_values` table whose RLS reads via parent-`EXISTS` (inherits parent visibility) and writes via HR-perm gates. The admin manages fields in the existing `ManageCustomFieldsTab` (extended with an "applies to" multi-select). A shared `useHrisCustomFields` hook + `HrisCustomFieldsSection` render dynamic `CustomFieldInput`s on each form.

**Tech Stack:** React 18 + TS, Supabase (Postgres + RLS), TanStack Query, shadcn/ui, Vitest. `db` from `@/lib/db`.

**Spec:** `docs/hris/phase-b-custom-fields-spec.md`

## Global Constraints

- Reuse the existing system: `custom_field_definitions`, `CustomFieldInput` (`src/components/tasks/CustomFieldInput.tsx`), `CustomFieldDefinition`/`readValue`/`toValuePatch` (`src/hooks/useCustomFields.ts`). Do NOT fork the field-type model.
- Field types: `number/text/single_select/date/checkbox`. Type→column map: `number→value_number`, `checkbox→value_bool`, `date→value_date`, `text|single_select→value_text` (identical to `task_custom_field_values`).
- The 5 HRIS entity_type keys (verbatim): `hris_leave_request`, `hris_benefit_plan`, `hris_checklist_template`, `hris_checklist_template_item`, `hris_employee_details`. `entity_id` is the record's `id` (`profile_id` for employee_details).
- Migration is additive: relax one CHECK (DROP+ADD), add one table + trigger + RLS. Naming `YYYYMMDDHHMMSS_name.sql`, after `20260629123000`.
- Value RLS: **read** = parent-`EXISTS` per entity_type (inherits parent RLS); **write** = `desks.hris.manage` OR `admin.access` OR (own `hris_leave_request`). No comp-tier.
- Frontend: query via `db`; TanStack mutations; shadcn from `ui/`; `useDemoMode` masking on PII-ish text; invalidate the hook's query after writes. Submodule-relative paths (`src/...`).
- DB apply is via the Supabase Dashboard SQL Editor / Management API (auto-mode blocks Bash prod DDL); frontend builds against `db as any` regardless.

---

### Task 1: Migration — relax applies_to CHECK + hris_custom_field_values + RLS

**Files:**
- Create: `linkedalliance/supabase/migrations/20260630120000_hris_custom_fields.sql`

**Interfaces:**
- Produces: relaxed `custom_field_definitions_applies_to_valid` CHECK (adds 5 HRIS keys); table `public.hris_custom_field_values`.

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================
-- HRIS Phase B — Admin-editable custom fields for HRIS entities.
-- Additive: relaxes one CHECK, adds one value table + trigger + RLS.
-- ============================================================

-- 1. Relax applies_to allowlist to include the 5 HRIS entity keys.
ALTER TABLE public.custom_field_definitions
  DROP CONSTRAINT IF EXISTS custom_field_definitions_applies_to_valid;
ALTER TABLE public.custom_field_definitions
  ADD CONSTRAINT custom_field_definitions_applies_to_valid
  CHECK (cardinality(applies_to) >= 1
    AND applies_to <@ ARRAY['task','project',
      'hris_leave_request','hris_benefit_plan','hris_checklist_template',
      'hris_checklist_template_item','hris_employee_details']::text[]);

-- 2. Generic value table (mirrors task_custom_field_values typed columns).
CREATE TABLE IF NOT EXISTS public.hris_custom_field_values (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL CHECK (entity_type IN
    ('hris_leave_request','hris_benefit_plan','hris_checklist_template',
     'hris_checklist_template_item','hris_employee_details')),
  entity_id uuid NOT NULL,
  field_id uuid NOT NULL REFERENCES public.custom_field_definitions(id) ON DELETE CASCADE,
  value_number numeric,
  value_text text,
  value_date date,
  value_bool boolean,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id, field_id)
);
CREATE INDEX IF NOT EXISTS idx_hcfv_entity ON public.hris_custom_field_values(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_hcfv_field  ON public.hris_custom_field_values(field_id);

CREATE TRIGGER trg_hcfv_touch BEFORE UPDATE ON public.hris_custom_field_values
  FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at();

-- 3. RLS
ALTER TABLE public.hris_custom_field_values ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "hcfv read"   ON public.hris_custom_field_values;
DROP POLICY IF EXISTS "hcfv write"  ON public.hris_custom_field_values;

-- Read inherits the parent record's visibility (each parent's own RLS filters the EXISTS).
CREATE POLICY "hcfv read" ON public.hris_custom_field_values
  FOR SELECT TO authenticated USING (
    (entity_type='hris_leave_request'            AND EXISTS(SELECT 1 FROM public.hris_leave_requests r WHERE r.id = entity_id))
    OR (entity_type='hris_employee_details'      AND EXISTS(SELECT 1 FROM public.hris_employee_details d WHERE d.profile_id = entity_id))
    OR (entity_type='hris_benefit_plan'          AND EXISTS(SELECT 1 FROM public.hris_benefit_plans p WHERE p.id = entity_id))
    OR (entity_type='hris_checklist_template'      AND EXISTS(SELECT 1 FROM public.hris_checklist_templates t WHERE t.id = entity_id))
    OR (entity_type='hris_checklist_template_item' AND EXISTS(SELECT 1 FROM public.hris_checklist_template_items i WHERE i.id = entity_id))
  );

-- Write: HR-manage/admin anywhere; plus self for own leave-request values.
CREATE POLICY "hcfv write" ON public.hris_custom_field_values
  FOR ALL TO authenticated
  USING (
    public.has_permission(auth.uid(),'desks.hris.manage')
    OR public.has_permission(auth.uid(),'admin.access')
    OR (entity_type='hris_leave_request'
        AND EXISTS(SELECT 1 FROM public.hris_leave_requests r WHERE r.id = entity_id AND r.employee_id = auth.uid()))
  )
  WITH CHECK (
    public.has_permission(auth.uid(),'desks.hris.manage')
    OR public.has_permission(auth.uid(),'admin.access')
    OR (entity_type='hris_leave_request'
        AND EXISTS(SELECT 1 FROM public.hris_leave_requests r WHERE r.id = entity_id AND r.employee_id = auth.uid()))
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.hris_custom_field_values TO authenticated;
```

- [ ] **Step 2: Verify SQL** — visual check: CHECK relaxed (DROP IF EXISTS then ADD with 7 total keys); table created with the entity_type CHECK + UNIQUE; trigger reuses `public.tg_touch_updated_at`; RLS enabled; read = parent-EXISTS OR-chain (5 types); write = manage/admin/self-leave; GRANT present.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260630120000_hris_custom_fields.sql
git -C linkedalliance commit -m "feat(hris): phase-b migration — custom fields applies_to + hris_custom_field_values"
```

---

### Task 2: Export + test the value mapping (TDD)

**Files:**
- Modify: `linkedalliance/src/hooks/useCustomFields.ts` (add `export` to `toValuePatch`)
- Test: `linkedalliance/src/hooks/customFieldMapping.test.ts`

**Interfaces:**
- Consumes: `readValue` (already exported), `toValuePatch` (make exported) from `@/hooks/useCustomFields`.
- Produces: `toValuePatch` is now importable by the hook (Task 3).

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from "vitest";
import { readValue, toValuePatch } from "@/hooks/useCustomFields";

const def = (t: any, config: any = {}) => ({ id: "f", name: "F", description: null, field_type: t, config, applies_to: ["hris_leave_request"], is_active: true });

describe("toValuePatch", () => {
  it("number → value_number, clamped to config max", () => {
    expect(toValuePatch(def("number", { max: 10 }), "25")).toEqual({ value_number: 10, value_text: null, value_date: null, value_bool: null });
  });
  it("checkbox → value_bool", () => {
    expect(toValuePatch(def("checkbox"), true)).toEqual({ value_number: null, value_text: null, value_date: null, value_bool: true });
  });
  it("date → value_date", () => {
    expect(toValuePatch(def("date"), "2026-03-01")).toEqual({ value_number: null, value_text: null, value_date: "2026-03-01", value_bool: null });
  });
  it("single_select → value_text", () => {
    expect(toValuePatch(def("single_select"), "x")).toEqual({ value_number: null, value_text: "x", value_date: null, value_bool: null });
  });
  it("blank → all null", () => {
    expect(toValuePatch(def("text"), "")).toEqual({ value_number: null, value_text: null, value_date: null, value_bool: null });
  });
});

describe("readValue", () => {
  it("reads the typed column for the def type", () => {
    const row: any = { id: "v", task_id: "t", field_id: "f", value_number: 3, value_text: null, value_date: null, value_bool: null };
    expect(readValue(def("number") as any, row)).toBe(3);
  });
  it("null row → null", () => {
    expect(readValue(def("text") as any, null)).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/hooks/customFieldMapping.test.ts`
Expected: FAIL — `toValuePatch` is not exported (import error).

- [ ] **Step 3: Make `toValuePatch` exported**

In `src/hooks/useCustomFields.ts` change `function toValuePatch(` to `export function toValuePatch(`. No other change.

- [ ] **Step 4: Run to verify it passes**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/hooks/customFieldMapping.test.ts`
Expected: PASS (7).

- [ ] **Step 5: Commit**

```bash
git -C linkedalliance add src/hooks/useCustomFields.ts src/hooks/customFieldMapping.test.ts
git -C linkedalliance commit -m "test(hris): export + cover custom-field value mapping"
```

---

### Task 3: `useHrisCustomFields` hook

**Files:**
- Create: `linkedalliance/src/components/desks/hris/useHrisCustomFields.ts`

**Interfaces:**
- Consumes: `db`, `readValue`, `toValuePatch`, `CustomFieldDefinition` from `@/hooks/useCustomFields`; `useAuth`.
- Produces: `useHrisCustomFields(entityType: string, entityId: string | undefined): { definitions: CustomFieldDefinition[]; values: Record<string, any>; loading: boolean; setValue: (def: CustomFieldDefinition, raw: any) => Promise<void>; reload: () => Promise<void>; }` where `values` is keyed by `field_id` and holds the typed value-row (use `readValue(def, values[def.id])` to get the display value).

- [ ] **Step 1: Implement the hook**

```typescript
import { useCallback, useEffect, useState } from "react";
import { db } from "@/lib/db";
import { useAuth } from "@/hooks/useAuth";
import { readValue, toValuePatch, type CustomFieldDefinition } from "@/hooks/useCustomFields";

export function useHrisCustomFields(entityType: string, entityId: string | undefined) {
  const { user } = useAuth();
  const [definitions, setDefinitions] = useState<CustomFieldDefinition[]>([]);
  const [values, setValues] = useState<Record<string, any>>({}); // field_id -> value row
  const [loading, setLoading] = useState(true);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const { data: defs } = await db.from("custom_field_definitions")
        .select("*").contains("applies_to", [entityType]).eq("is_active", true).order("name");
      setDefinitions((defs as CustomFieldDefinition[]) ?? []);
      if (entityId) {
        const { data: vals } = await db.from("hris_custom_field_values")
          .select("*").eq("entity_type", entityType).eq("entity_id", entityId);
        const byField: Record<string, any> = {};
        (vals ?? []).forEach((v: any) => { byField[v.field_id] = v; });
        setValues(byField);
      } else {
        setValues({});
      }
    } catch {
      setDefinitions([]); setValues({});
    } finally {
      setLoading(false);
    }
  }, [entityType, entityId]);

  useEffect(() => { reload(); }, [reload]);

  const setValue = useCallback(async (def: CustomFieldDefinition, raw: any) => {
    if (!entityId) return;
    const patch = toValuePatch(def, raw);
    const { error } = await db.from("hris_custom_field_values").upsert(
      { entity_type: entityType, entity_id: entityId, field_id: def.id, ...patch, updated_by: user?.id ?? null },
      { onConflict: "entity_type,entity_id,field_id" }
    );
    if (error) throw error;
    await reload();
  }, [entityType, entityId, user, reload]);

  return { definitions, values, loading, setValue, reload, readValue };
}
```

- [ ] **Step 2: Verify build** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build` succeeds.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/useHrisCustomFields.ts
git -C linkedalliance commit -m "feat(hris): useHrisCustomFields hook (load defs + values, upsert)"
```

---

### Task 4: Extend `ManageCustomFieldsTab` — applies_to multi-select

**Files:**
- Modify: `linkedalliance/src/components/admin/ManageCustomFieldsTab.tsx`

**Interfaces:**
- Consumes: existing create/edit dialog + `useManageCustomFields`.

- [ ] **Step 1: Implement.** READ `ManageCustomFieldsTab.tsx` and `src/hooks/useManageCustomFields.ts` first.
- Add an **"Applies to"** multi-select (checkbox list) to the create/edit field dialog with options:
  `{ value: "task", label: "Task" }`, `{ "hris_leave_request": "Leave Request" }`, `{ "hris_benefit_plan": "Benefit Plan" }`, `{ "hris_checklist_template": "Checklist Template" }`, `{ "hris_checklist_template_item": "Checklist Item" }`, `{ "hris_employee_details": "Employee Details" }`. (Use shadcn `Checkbox` rows, or a multi-toggle — match the file's existing control style.)
- On **create**: persist the selected array as `applies_to` (require ≥1; default `["task"]` if the dialog is opened without changing it, preserving current behavior). Replace the hard-coded `applies_to: ['task']` in the insert.
- On **edit**: load the field's current `applies_to` into the control; persist changes. `useManageCustomFields.updateField` currently patches name/description/config — extend its allowed patch to include `applies_to` (and update the hook's `updateField` type/whitelist accordingly).
- Show each field's targets as badges in the list. `logActivity(EventTypes.ADMIN_CUSTOM_FIELD_UPDATED, ...)` as today.

- [ ] **Step 2: Verify build** — `npm run build` succeeds.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/admin/ManageCustomFieldsTab.tsx src/hooks/useManageCustomFields.ts
git -C linkedalliance commit -m "feat(hris): custom-field admin editor — applies_to multi-select for HRIS entities"
```

---

### Task 5: Shared `HrisCustomFieldsSection` component

**Files:**
- Create: `linkedalliance/src/components/desks/hris/HrisCustomFieldsSection.tsx`

**Interfaces:**
- Consumes: `useHrisCustomFields` (Task 3), `CustomFieldInput` (`@/components/tasks/CustomFieldInput`), `readValue`.
- Produces:
  ```ts
  interface Props { entityType: string; entityId: string | undefined; canEdit: boolean; }
  export function HrisCustomFieldsSection(props: Props): JSX.Element | null
  ```

- [ ] **Step 1: Implement**

```tsx
import { useHrisCustomFields } from "./useHrisCustomFields";
import { CustomFieldInput } from "@/components/tasks/CustomFieldInput";
import { readValue } from "@/hooks/useCustomFields";

interface Props { entityType: string; entityId: string | undefined; canEdit: boolean; }

export function HrisCustomFieldsSection({ entityType, entityId, canEdit }: Props) {
  const { definitions, values, loading, setValue } = useHrisCustomFields(entityType, entityId);
  if (loading || definitions.length === 0) return null;
  return (
    <div className="space-y-3">
      <div className="text-sm font-medium text-muted-foreground">Custom fields</div>
      {definitions.map((def) => (
        <div key={def.id} className="space-y-1">
          <label className="text-xs text-muted-foreground">{def.name}</label>
          <CustomFieldInput
            definition={def}
            value={readValue(def, values[def.id])}
            canEdit={canEdit && !!entityId}
            onCommit={(raw) => { void setValue(def, raw); }}
          />
        </div>
      ))}
    </div>
  );
}
```
> When `entityId` is undefined (e.g. a not-yet-saved new record), the section still renders the definitions but `canEdit` is false so values can't be committed until the parent saves and passes a real id. The leave-request form (Task 8) handles the new-record case explicitly.

- [ ] **Step 2: Verify build** — `npm run build` succeeds.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/HrisCustomFieldsSection.tsx
git -C linkedalliance commit -m "feat(hris): HrisCustomFieldsSection (dynamic custom-field renderer)"
```

---

### Task 6: Wire custom fields into Employee Details + My HR

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/EmployeeDirectoryTab.tsx`
- Modify: `linkedalliance/src/components/desks/hris/MyHrHome.tsx`

- [ ] **Step 1: EmployeeDirectoryTab** — in the employee-details edit panel/dialog, render
  `<HrisCustomFieldsSection entityType="hris_employee_details" entityId={selectedProfileId} canEdit={canManage} />`
  (use the same `profile_id` the details editor targets, and the existing `desks.hris.manage` gate as `canEdit`).

- [ ] **Step 2: MyHrHome** — render `<HrisCustomFieldsSection entityType="hris_employee_details" entityId={user.id} canEdit={false} />` (self, read-only) in the My HR view.

- [ ] **Step 3: Verify build + tests** — `npm run build && npx vitest run src/components/desks/hris/` green.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/EmployeeDirectoryTab.tsx src/components/desks/hris/MyHrHome.tsx
git -C linkedalliance commit -m "feat(hris): custom fields on employee details (edit) + My HR (read-only)"
```

---

### Task 7: Wire custom fields into Benefit Plan + Checklist Template/Item

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/CompBenefitsTab.tsx`
- Modify: `linkedalliance/src/components/desks/hris/ChecklistsTab.tsx`

- [ ] **Step 1: CompBenefitsTab** — in the benefit-plan edit dialog, render
  `<HrisCustomFieldsSection entityType="hris_benefit_plan" entityId={editingPlanId} canEdit={true} />`
  (the tab is comp-gated; plan editing is allowed there). `editingPlanId` is set after a plan exists (edit an existing plan; for a brand-new plan, save it first then its custom fields — mirror the leave-request approach if needed, else only show the section when editing an existing plan).

- [ ] **Step 2: ChecklistsTab** — in the template header editor render
  `<HrisCustomFieldsSection entityType="hris_checklist_template" entityId={templateId} canEdit={canManage} />`;
  in the template-item add/edit dialog render
  `<HrisCustomFieldsSection entityType="hris_checklist_template_item" entityId={editingItemId} canEdit={canManage} />`
  (show item-level section only when editing an existing item that has an id).

- [ ] **Step 3: Verify build + tests** — `npm run build && npx vitest run src/components/desks/hris/` green.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/CompBenefitsTab.tsx src/components/desks/hris/ChecklistsTab.tsx
git -C linkedalliance commit -m "feat(hris): custom fields on benefit plans + checklist templates/items"
```

---

### Task 8: Wire custom fields into the Leave Request form (new-record case)

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/TimeOffTab.tsx`

- [ ] **Step 1: Implement.** In the request-leave dialog render
  `<HrisCustomFieldsSection entityType="hris_leave_request" entityId={editingRequestId} canEdit={true} />`.
  - When **editing** an existing request, `editingRequestId` is the request id → fields are immediately editable.
  - For a **new** request (no id yet), the leave-request INSERT already returns the new row — change that insert to `.insert({...}).select("id").single()`, capture the returned id, and if the user filled any custom-field values, write them after the insert. Simplest correct flow: keep local state of pending custom values (Record<fieldId, raw>) collected from the section via an `onPendingChange` — OR (simpler, less code) after creating the request, set `editingRequestId` to the new id and let the user fill custom fields on the now-saved request. **Use the latter**: on successful create, transition the dialog to "edit" mode for the new request id so the custom-fields section becomes editable; show a hint "Save the request to add custom fields." This avoids threading pending values through the insert. (RLS allows the requester to write their own leave-request custom values.)

- [ ] **Step 2: Verify build + tests** — `npm run build && npx vitest run src/components/desks/hris/` green.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/TimeOffTab.tsx
git -C linkedalliance commit -m "feat(hris): custom fields on leave requests (edit + post-create)"
```

---

### Task 9: Apply migration + verification

**Files:** none (DB apply + manual).

- [ ] **Step 1: Lint/build/tests** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build && npx vitest run` — build clean; mapping tests + prior HRIS tests pass.

- [ ] **Step 2: Apply the migration to the DB** — the user runs `supabase/migrations/20260630120000_hris_custom_fields.sql` in the Supabase Dashboard SQL Editor (or via the Management API query endpoint). Then `node scripts/check-supabase-security.mjs` — confirm `hris_custom_field_values` has RLS enabled.

- [ ] **Step 3: Manual E2E** (`npm run dev`, against live):
  - Admin → Custom Fields → add a `single_select` "Reason Category" applying to **Leave Request** → open the leave-request form → field renders → set a value, save, reopen → persists.
  - Add a `text` field to **Employee Details** → shows in Directory details editor (editable as manage) and read-only in My HR for that employee.
  - Add fields to **benefit plan**, **checklist template**, **checklist item** → render on those editors.
  - **Archive** the field in the admin tab → it disappears from the form; the saved value row remains (re-query `hris_custom_field_values`).
  - **RLS**: as a plain employee, confirm custom values readable/writable only on your OWN leave request + your own employee-details values; cannot read others'.
  - **Multi-entity**: one field applied to both Leave Request + Employee Details renders on both.

---

## Self-Review

- **Spec coverage:** applies_to CHECK relax + value table + RLS (T1); mapping reuse/export + test (T2); hook (T3); admin applies_to multi-select (T4); shared renderer (T5); wiring on all 5 entities — employee_details (T6), benefit_plan + checklist template + item (T7), leave_request incl. new-record (T8); apply + verify incl. archive-retains-values + RLS + multi-entity (T9). All spec sections map to a task.
- **Placeholders:** none — migration SQL, hook, mapping test, and section component are concrete; form-wiring tasks give the exact `<HrisCustomFieldsSection .../>` calls with entity_type + entity_id source named per form.
- **Type consistency:** `useHrisCustomFields` returns `{definitions, values, loading, setValue, reload, readValue}`; `HrisCustomFieldsSection` consumes `definitions`/`values`/`setValue` + `readValue(def, values[def.id])`; `toValuePatch`/`readValue` imported from `@/hooks/useCustomFields` (T2 exports `toValuePatch`); entity_type keys identical across migration CHECK, hook calls, and section props; `CustomFieldInput` props (`definition,value,canEdit,onCommit`) match its real interface.

## Notes
- Branch off integrated `main` (e.g. `hris-phase-b`). One migration (apply via dashboard/Management API — auto-mode blocks Bash prod DDL). Frontend builds without it (`db as any`).
