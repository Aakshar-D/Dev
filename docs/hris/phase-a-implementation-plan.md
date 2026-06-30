# HRIS Phase A (CSV Bulk Ops + Checklist Tasks) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CSV export-template + import for the employee Directory and Compensation history, a full checklist template-item editor, and ad-hoc task creation on started checklists — frontend-only, on the existing HRIS desk.

**Architecture:** A shared, tested CSV core (pure parse/validate/map + a generic `HrisCsvImport` UI built on `papaparse`, modeled on `SeamlessUploader.tsx`) drives both importers. Directory upserts `hris_employee_details` (blank-preserving merge); Compensation inserts `hris_compensation` (append-only). Checklist work extends `ChecklistsTab` with a template-item editor and an ad-hoc `public.tasks` insert matching the `hris_start_checklist` shape. No schema changes.

**Tech Stack:** React 18 + TS, TanStack Query, shadcn/ui, papaparse, Vitest. Supabase via `db` from `@/lib/db`.

**Spec:** `docs/hris/phase-a-bulk-ops-checklist-tasks-spec.md`

## Global Constraints

- **Frontend-only.** No migrations, no schema/RLS changes. Writes go to existing tables under existing RLS.
- Query via `db` from `@/lib/db` (`db = supabase as any`). TanStack `useMutation` + invalidate `["hris"]`. Sonner `onError` toast on every mutation. Clean payloads (no PK in update bodies).
- Match keys: **Directory** import resolves employee by `profile_id` (from exported template) then falls back to `employee_number`; **Compensation** import resolves by `employee_number`.
- Blank CSV cell on Directory import = **leave existing value unchanged** (merge non-blank columns over the fetched existing row; never overwrite with null).
- Compensation import is **insert-only** (append-only table); re-import adds new rows, never edits.
- Enum sets (validate against these verbatim): `employment_type ∈ {full_time,part_time,contractor,intern}`; `employment_status ∈ {active,on_leave,terminated}`; `comp_type ∈ {salary,hourly}`; checklist `assignee_role ∈ {new_hire,manager,hr,it}`.
- Permissions: Directory export/import gated `desks.hris.manage`; Comp gated `desks.hris.comp`; template editor + ad-hoc task gated `desks.hris.manage`. A `desks.hris.view`-only user sees no import/edit buttons.
- `public.tasks` insert shape: PK `id` (default); required `title`; set `source_type`, `source_reference_id`, `assigned_to`, `assigned_by`, `updated_by`, `due_date`, `status='not_started'`. `source_type` must be `hris_onboarding` or `hris_offboarding` (validator allows these).
- Mask comp figures + names via `useDemoMode` wherever previewed.
- `papaparse` is already a dependency. Import: `import Papa from "papaparse";`

---

### Task 1: CSV core — pure parse/validate/map + tests (TDD)

**Files:**
- Create: `linkedalliance/src/components/desks/hris/csv.ts`
- Test: `linkedalliance/src/components/desks/hris/csv.test.ts`

**Interfaces:**
- Produces:
  - `type RowResult<T> = { ok: true; value: T } | { ok: false; reason: string }`
  - `parseDirectoryRow(row: Record<string,string>): RowResult<{ profile_id?: string; employee_number?: string; patch: Record<string, any> }>` — `patch` holds only non-blank, valid detail columns.
  - `parseCompRow(row: Record<string,string>): RowResult<{ employee_number: string; insert: Record<string, any> }>`
  - `toCsv(headers: string[], rows: Record<string,string>[]): string` — wraps `Papa.unparse`.
  - Constants `DIRECTORY_TEMPLATE_HEADERS`, `COMP_TEMPLATE_HEADERS` (string[]).

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from "vitest";
import { parseDirectoryRow, parseCompRow, toCsv, DIRECTORY_TEMPLATE_HEADERS } from "./csv";

describe("parseDirectoryRow", () => {
  it("keeps only non-blank valid columns in patch", () => {
    const r = parseDirectoryRow({ profile_id: "p1", full_name: "Ada", employee_number: "E7",
      employment_type: "full_time", employment_status: "", hire_date: "2026-01-15", work_location: "" });
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.value.profile_id).toBe("p1");
      expect(r.value.employee_number).toBe("E7");
      expect(r.value.patch).toEqual({ employee_number: "E7", employment_type: "full_time", hire_date: "2026-01-15" });
    }
  });
  it("rejects a bad employment_type", () => {
    const r = parseDirectoryRow({ profile_id: "p1", employment_type: "Full-time" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/employment_type/);
  });
  it("rejects a bad date", () => {
    const r = parseDirectoryRow({ profile_id: "p1", hire_date: "01/15/2026" });
    expect(r.ok).toBe(false);
  });
  it("rejects when neither profile_id nor employee_number present", () => {
    const r = parseDirectoryRow({ full_name: "Ada" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/profile_id|employee_number/);
  });
});

describe("parseCompRow", () => {
  it("accepts a salary row", () => {
    const r = parseCompRow({ employee_number: "E7", effective_date: "2026-02-01", comp_type: "salary",
      annual_salary: "90000", hourly_rate: "", currency: "", pay_frequency: "monthly", change_reason: "merit" });
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.value.employee_number).toBe("E7");
      expect(r.value.insert).toMatchObject({ effective_date: "2026-02-01", comp_type: "salary",
        annual_salary: 90000, currency: "USD", pay_frequency: "monthly", change_reason: "merit" });
    }
  });
  it("rejects when no employee_number", () => {
    expect(parseCompRow({ comp_type: "salary", annual_salary: "1", effective_date: "2026-02-01" }).ok).toBe(false);
  });
  it("rejects when both salary and rate present", () => {
    expect(parseCompRow({ employee_number: "E7", comp_type: "salary", annual_salary: "9", hourly_rate: "5", effective_date: "2026-02-01" }).ok).toBe(false);
  });
  it("rejects bad comp_type", () => {
    expect(parseCompRow({ employee_number: "E7", comp_type: "bonus", annual_salary: "9", effective_date: "2026-02-01" }).ok).toBe(false);
  });
});

describe("toCsv", () => {
  it("builds header + rows", () => {
    const csv = toCsv(DIRECTORY_TEMPLATE_HEADERS, [{ profile_id: "p1", full_name: "Ada" }]);
    expect(csv.split(/\r?\n/)[0]).toBe(DIRECTORY_TEMPLATE_HEADERS.join(","));
    expect(csv).toMatch(/p1/);
    expect(csv).toMatch(/Ada/);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/components/desks/hris/csv.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```typescript
import Papa from "papaparse";

export type RowResult<T> = { ok: true; value: T } | { ok: false; reason: string };

export const DIRECTORY_TEMPLATE_HEADERS = [
  "profile_id", "full_name", "employee_number",
  "employment_type", "employment_status", "hire_date", "work_location",
];
export const COMP_TEMPLATE_HEADERS = [
  "employee_number", "full_name", "effective_date", "comp_type",
  "annual_salary", "hourly_rate", "currency", "pay_frequency", "change_reason",
];

const EMPLOYMENT_TYPES = ["full_time", "part_time", "contractor", "intern"];
const EMPLOYMENT_STATUSES = ["active", "on_leave", "terminated"];
const COMP_TYPES = ["salary", "hourly"];
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

const blank = (v: unknown) => v == null || String(v).trim() === "";
const g = (row: Record<string, string>, k: string) => (row[k] ?? "").trim();

export function parseDirectoryRow(
  row: Record<string, string>
): RowResult<{ profile_id?: string; employee_number?: string; patch: Record<string, any> }> {
  const profile_id = g(row, "profile_id") || undefined;
  const employee_number = g(row, "employee_number") || undefined;
  if (!profile_id && !employee_number) {
    return { ok: false, reason: "row needs a profile_id or employee_number" };
  }
  const patch: Record<string, any> = {};
  if (employee_number) patch.employee_number = employee_number;

  const etype = g(row, "employment_type");
  if (!blank(etype)) {
    if (!EMPLOYMENT_TYPES.includes(etype)) return { ok: false, reason: `employment_type must be one of ${EMPLOYMENT_TYPES.join("/")}` };
    patch.employment_type = etype;
  }
  const estatus = g(row, "employment_status");
  if (!blank(estatus)) {
    if (!EMPLOYMENT_STATUSES.includes(estatus)) return { ok: false, reason: `employment_status must be one of ${EMPLOYMENT_STATUSES.join("/")}` };
    patch.employment_status = estatus;
  }
  for (const dcol of ["hire_date"]) {
    const d = g(row, dcol);
    if (!blank(d)) {
      if (!ISO_DATE.test(d)) return { ok: false, reason: `${dcol} must be ISO YYYY-MM-DD` };
      patch[dcol] = d;
    }
  }
  const loc = g(row, "work_location");
  if (!blank(loc)) patch.work_location = loc;

  return { ok: true, value: { profile_id, employee_number, patch } };
}

export function parseCompRow(
  row: Record<string, string>
): RowResult<{ employee_number: string; insert: Record<string, any> }> {
  const employee_number = g(row, "employee_number");
  if (blank(employee_number)) return { ok: false, reason: "employee_number required" };

  const comp_type = g(row, "comp_type");
  if (!COMP_TYPES.includes(comp_type)) return { ok: false, reason: "comp_type must be salary or hourly" };

  const effective_date = g(row, "effective_date");
  if (!ISO_DATE.test(effective_date)) return { ok: false, reason: "effective_date must be ISO YYYY-MM-DD" };

  const salaryStr = g(row, "annual_salary");
  const rateStr = g(row, "hourly_rate");
  const hasSalary = !blank(salaryStr);
  const hasRate = !blank(rateStr);
  if (hasSalary === hasRate) return { ok: false, reason: "provide exactly one of annual_salary / hourly_rate" };
  const annual_salary = hasSalary ? Number(salaryStr) : null;
  const hourly_rate = hasRate ? Number(rateStr) : null;
  if (hasSalary && Number.isNaN(annual_salary)) return { ok: false, reason: "annual_salary not a number" };
  if (hasRate && Number.isNaN(hourly_rate)) return { ok: false, reason: "hourly_rate not a number" };

  const insert: Record<string, any> = {
    effective_date, comp_type, annual_salary, hourly_rate,
    currency: g(row, "currency") || "USD",
    pay_frequency: g(row, "pay_frequency") || null,
    change_reason: g(row, "change_reason") || null,
  };
  return { ok: true, value: { employee_number, insert } };
}

export function toCsv(headers: string[], rows: Record<string, string>[]): string {
  return Papa.unparse({ fields: headers, data: rows.map((r) => headers.map((h) => r[h] ?? "")) });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/components/desks/hris/csv.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/csv.ts src/components/desks/hris/csv.test.ts
git -C linkedalliance commit -m "feat(hris): CSV parse/validate/map core + tests"
```

---

### Task 2: Shared CSV importer component + export helper

**Files:**
- Create: `linkedalliance/src/components/desks/hris/HrisCsvImport.tsx`
- Create: `linkedalliance/src/components/desks/hris/downloadCsv.ts`

**Interfaces:**
- Consumes: `toCsv` (Task 1), shadcn `Dialog`/`Button`, `Papa`.
- Produces:
  - `downloadCsv(filename: string, csv: string): void` (Blob + anchor click).
  - `HrisCsvImport` component:
    ```ts
    interface CommitResult { ok: number; skipped: number; invalid: { row: number; reason: string }[] }
    interface Props {
      label: string;                       // dialog title, e.g. "Import Directory CSV"
      onCommit: (rows: Record<string,string>[]) => Promise<CommitResult>;
      onDone: () => void;                  // invalidate queries after commit
      triggerLabel?: string;               // button text, default "Import CSV"
    }
    ```

- [ ] **Step 1: Implement `downloadCsv.ts`**

```typescript
export function downloadCsv(filename: string, csv: string): void {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click(); a.remove();
  URL.revokeObjectURL(url);
}
```

- [ ] **Step 2: Implement `HrisCsvImport.tsx`**

Responsibilities (~120 lines): a Button that opens a Dialog with a file input (`accept=".csv"`); on file pick, read text (strip a leading BOM `﻿`), `Papa.parse(text, { header: true, skipEmptyLines: true })`, show parsed row count + a "Import N rows" button; on click call `onCommit(rows)`, show the returned `CommitResult` summary (ok / skipped / invalid list with row numbers + reasons), then call `onDone`. `onError`-style guard: wrap commit in try/catch → toast.error. Follow `src/components/desks/sdr/SeamlessUploader.tsx` for the file-read + parse + phase-state shape. Use shadcn `Dialog`, `Button`, `Input type=file`.

Concrete parse snippet:
```tsx
import Papa from "papaparse";
const text = (await file.text()).replace(/^﻿/, "");
const parsed = Papa.parse<Record<string,string>>(text, { header: true, skipEmptyLines: true });
const rows = (parsed.data || []).filter(r => Object.values(r).some(v => String(v ?? "").trim() !== ""));
```

- [ ] **Step 3: Verify build**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npm run build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/HrisCsvImport.tsx src/components/desks/hris/downloadCsv.ts
git -C linkedalliance commit -m "feat(hris): shared CSV import dialog + download helper"
```

---

### Task 3: Directory export template + import

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/EmployeeDirectoryTab.tsx`

**Interfaces:**
- Consumes: `parseDirectoryRow`, `DIRECTORY_TEMPLATE_HEADERS`, `toCsv` (Task 1); `downloadCsv`, `HrisCsvImport` (Task 2); `db`, `useQueryClient`, `logActivity`/`EventTypes`, `usePermission("desks.hris.manage")`.

- [ ] **Step 1: Add Export-template button** (visible when `canManage`)

On click: fetch all active profiles + their details (reuse the existing roster query data if present), build rows `{ profile_id: p.id, full_name, employee_number, employment_type, employment_status, hire_date, work_location }` from the joined `hris_employee_details`, then `downloadCsv("hris-directory-template.csv", toCsv(DIRECTORY_TEMPLATE_HEADERS, rows))`.

- [ ] **Step 2: Add `<HrisCsvImport>`** (when `canManage`) with this `onCommit`:

```tsx
const onCommit = async (rows: Record<string,string>[]) => {
  const res = { ok: 0, skipped: 0, invalid: [] as {row:number;reason:string}[] };
  // resolve employee_number -> profile_id for fallback matching
  const { data: profs = [] } = await db.from("profiles").select("id");
  const validIds = new Set(profs.map((p:any)=>p.id));
  const { data: details = [] } = await db.from("hris_employee_details").select("profile_id, employee_number");
  const byEmpNo = new Map(details.filter((d:any)=>d.employee_number).map((d:any)=>[String(d.employee_number), d.profile_id]));
  const patches: Record<string, any>[] = [];
  rows.forEach((row, i) => {
    const parsed = parseDirectoryRow(row);
    if (!parsed.ok) { res.invalid.push({ row: i+2, reason: parsed.reason }); return; }
    let pid = parsed.value.profile_id && validIds.has(parsed.value.profile_id) ? parsed.value.profile_id : undefined;
    if (!pid && parsed.value.employee_number) pid = byEmpNo.get(parsed.value.employee_number);
    if (!pid) { res.skipped++; return; }
    patches.push({ profile_id: pid, ...parsed.value.patch });
  });
  // blank-preserving merge: fetch existing rows for these profile_ids, merge non-blank columns over them
  const ids = patches.map(p=>p.profile_id);
  const { data: existing = [] } = ids.length ? await db.from("hris_employee_details").select("*").in("profile_id", ids) : { data: [] };
  const exById = new Map(existing.map((e:any)=>[e.profile_id, e]));
  const merged = patches.map(p => ({ ...(exById.get(p.profile_id) || {}), ...p, updated_at: new Date().toISOString() }));
  for (let i=0;i<merged.length;i+=100) {
    const chunk = merged.slice(i,i+100);
    const { error } = await db.from("hris_employee_details").upsert(chunk, { onConflict: "profile_id" });
    if (error) throw error;
    res.ok += chunk.length;
  }
  logActivity(EventTypes.HRIS_EMPLOYEE_DETAILS_UPDATED, "Bulk directory import", { metadata: { updated: res.ok, skipped: res.skipped, invalid: res.invalid.length } });
  return res;
};
```
`onDone` → `queryClient.invalidateQueries({ queryKey: ["hris"] })` (covers the `["hris","roster"]` query).

- [ ] **Step 3: Verify build + tests**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npm run build && npx vitest run src/components/desks/hris/`
Expected: build succeeds; csv tests still pass.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/EmployeeDirectoryTab.tsx
git -C linkedalliance commit -m "feat(hris): directory CSV export template + bulk import"
```

---

### Task 4: Compensation export template + import

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/CompBenefitsTab.tsx`

**Interfaces:**
- Consumes: `parseCompRow`, `COMP_TEMPLATE_HEADERS`, `toCsv`, `downloadCsv`, `HrisCsvImport`, `db`, `useAuth` (importer id), `useQueryClient`, `logActivity`/`EventTypes`, `usePermission("desks.hris.comp")` (already gates the tab).

- [ ] **Step 1: Export template** — fetch profiles + their `hris_employee_details.employee_number`; build one row per employee `{ employee_number, full_name }` (other columns blank); `downloadCsv("hris-comp-template.csv", toCsv(COMP_TEMPLATE_HEADERS, rows))`.

- [ ] **Step 2: `<HrisCsvImport>`** with `onCommit` (insert-only):

```tsx
const onCommit = async (rows: Record<string,string>[]) => {
  const res = { ok: 0, skipped: 0, invalid: [] as {row:number;reason:string}[] };
  const { data: details = [] } = await db.from("hris_employee_details").select("profile_id, employee_number");
  const byEmpNo = new Map(details.filter((d:any)=>d.employee_number).map((d:any)=>[String(d.employee_number), d.profile_id]));
  const inserts: Record<string, any>[] = [];
  rows.forEach((row, i) => {
    const parsed = parseCompRow(row);
    if (!parsed.ok) { res.invalid.push({ row: i+2, reason: parsed.reason }); return; }
    const pid = byEmpNo.get(parsed.value.employee_number);
    if (!pid) { res.skipped++; return; }
    inserts.push({ ...parsed.value.insert, employee_id: pid, created_by: user.id });
  });
  for (let i=0;i<inserts.length;i+=100) {
    const chunk = inserts.slice(i,i+100);
    const { error } = await db.from("hris_compensation").insert(chunk);
    if (error) throw error;
    res.ok += chunk.length;
  }
  logActivity(EventTypes.HRIS_COMP_RECORDED, "Bulk compensation import", { metadata: { inserted: res.ok, skipped: res.skipped, invalid: res.invalid.length } });
  return res;
};
```
`onDone` → invalidate `["hris"]`.

- [ ] **Step 3: Verify build** — `npm run build` succeeds.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/CompBenefitsTab.tsx
git -C linkedalliance commit -m "feat(hris): compensation CSV export template + append-only bulk import"
```

---

### Task 5: Checklist template-item editor

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/ChecklistsTab.tsx`

**Interfaces:**
- Consumes: `db`, `useQueryClient`, RHF+Zod, shadcn `Select`/`Input`/`Button`/`Dialog`, `logActivity`/`EventTypes`, `usePermission("desks.hris.manage")`.

- [ ] **Step 1: Implement the editor.** First READ `ChecklistsTab.tsx`; if a partial template-item view exists, extend it rather than add a parallel one. Within a selected template, render its `hris_checklist_template_items` ordered by `sort_order` with add / edit / remove / reorder:
- **Add/Edit** dialog: `title` (required), `description`, `assignee_role` Select (new_hire/manager/hr/it), `due_offset_days` (number ≥ 0). Insert/update `hris_checklist_template_items` (update payload excludes `id`).
- **Remove**: delete the item row.
- **Reorder**: move up/down buttons swap `sort_order` with the neighbor (two `update`s).
- Every mutation: `onError` toast, invalidate `["hris"]`, `logActivity(EventTypes.HRIS_CHECKLIST_TEMPLATE_UPDATED, "...")`.

Insert example:
```tsx
const { error } = await db.from("hris_checklist_template_items").insert({
  template_id: templateId, title, description: description||null,
  assignee_role: assigneeRole, due_offset_days: Number(dueOffset)||0,
  sort_order: (maxSortOrder ?? 0) + 1,
});
```

- [ ] **Step 2: Verify build + tests** — `npm run build && npx vitest run src/components/desks/hris/` green.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/ChecklistsTab.tsx
git -C linkedalliance commit -m "feat(hris): checklist template-item editor (add/edit/remove/reorder)"
```

---

### Task 6: Ad-hoc task on a started checklist

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/ChecklistsTab.tsx`

**Interfaces:**
- Consumes: `db`, `useAuth`, `useQueryClient`, RHF+Zod, shadcn dialog/select, `logActivity`/`EventTypes`. Needs each checklist's `type` (onboarding/offboarding), `id`, and `employee_id` (already loaded in the active-checklists list from Task-7 of Phase 2).

- [ ] **Step 1: Implement "Add task".** On an `hris_employee_checklists` row (manage), an "Add task" dialog: `title` (required), `description`, `assigned_to` (Select from profiles, default = the checklist's `employee_id`), `due_date` (date). On submit:

```tsx
const { error } = await db.from("tasks").insert({
  title,
  description: description || null,
  source_type: "hris_" + checklist.type,        // hris_onboarding | hris_offboarding
  source_reference_id: checklist.id,
  assigned_to: assignedTo || null,
  assigned_by: user.id,
  updated_by: user.id,
  due_date: dueDate || null,
  status: "not_started",
});
if (error) throw error;
```
`onError` toast; on success invalidate the checklist's task query (key `["hris","checklist-tasks",checklist.id]`) **and** `["hris"]`; `logActivity(EventTypes.HRIS_CHECKLIST_STARTED, "Added ad-hoc checklist task", { metadata: { checklist_id: checklist.id } })`.

> The inserted row's `source_type`/`source_reference_id` match what `hris_start_checklist` produces, so it flows into the same `checklistProgress(tasks)` rollup and the assignee's task list. `status='not_started'` is in the validator's allowed set.

- [ ] **Step 2: Verify build** — `npm run build` succeeds; vitest green.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/ChecklistsTab.tsx
git -C linkedalliance commit -m "feat(hris): add ad-hoc tasks to a started checklist"
```

---

### Task 7: Verification

**Files:** none (commands + manual).

- [ ] **Step 1: Lint/build/tests** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build && npx vitest run` — build clean; csv tests + prior HRIS tests pass.

- [ ] **Step 2: Manual E2E** (`npm run dev`, against the live DB which has HRIS):
  - **Directory**: Export template → set `employment_type`/`hire_date` on 2 rows, leave others blank → Import → confirm only those columns changed (blanks preserved), summary shows `updated:2`; add a row with a bad enum + an unknown id → reported invalid/skipped, not written.
  - **Comp**: Export template → add salary row for an employee → Import → new `hris_compensation` row; re-import same file → another row added (append-only, never edits); bad `comp_type`/both amounts → invalid.
  - **Template editor**: add/edit/remove/reorder items; Start a checklist → generated tasks reflect edits.
  - **Ad-hoc task**: on a started checklist, Add task → appears in its progress rollup + assignee's task list with correct `source_type`/`source_reference_id`.

- [ ] **Step 3: Permissions + demo mode** — a `desks.hris.view`-only user sees no import/edit buttons; comp masked under `useDemoMode`.

---

## Self-Review

- **Spec coverage:** A1 directory CSV (T1 parse, T2 importer, T3 wiring); A2 comp CSV (T1, T2, T4); A3 template editor (T5) + ad-hoc task (T6); shared importer + export helper (T2); verification (T7). Blank-preserving merge (T3 onCommit), append-only comp (T4), match-key resolution (T3/T4), enum/date validation (T1) all present.
- **Placeholders:** none — CSV core + onCommit handlers + task insert are concrete; tab-wiring tasks give full mutation/query code, remaining JSX follows the existing tabs.
- **Type consistency:** `RowResult`, `parseDirectoryRow`/`parseCompRow` signatures + the `{profile_id?,employee_number?,patch}` / `{employee_number,insert}` shapes match T1↔T3/T4; `HrisCsvImport` `CommitResult {ok,skipped,invalid}` matches the `onCommit` returns; `toCsv`/`downloadCsv`/`*_TEMPLATE_HEADERS` consistent; task insert columns match the documented `public.tasks` shape; `source_type='hris_'+type` matches the validator + Phase-2 progress query `.in("source_type",["hris_onboarding","hris_offboarding"])`.

## Notes
- Branch off integrated `main` (e.g. `hris-phase-a`). Frontend-only; no migrations to apply.
- After approval, this plan already lives in `docs/hris/` per the docs-location preference.
