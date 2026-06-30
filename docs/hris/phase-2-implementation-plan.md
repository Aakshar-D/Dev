# HRIS Desk — Phase 2 (Onboarding/Offboarding + Comp & Benefits) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the HRIS desk with onboarding/offboarding checklists (manual-start, hybrid over `public.tasks`) and compensation & benefits (append-only comp, self-view + HR-write, managers excluded).

**Architecture:** Three additive migrations (checklist tables + `tasks.source_type` validator extension; a `SECURITY DEFINER` `hris_start_checklist` RPC that atomically creates a checklist header + one `public.tasks` row per template item with role-resolved assignees; comp/benefits tables). Two new desk tabs + comp/benefits cards in My HR, following the Phase-1 desk conventions.

**Tech Stack:** React 18 + Vite + TypeScript, Supabase (Postgres + RLS + plpgsql RPC), TanStack React Query v5, shadcn/ui + Tailwind, React Hook Form + Zod, Vitest.

**Spec:** `docs/hris/phase-2-onboarding-comp-benefits-spec.md`

## Global Constraints

- Strictly additive. Migration naming `YYYYMMDDHHMMSS_name.sql`, timestamps after Phase 1's `20260629121000`.
- SQL conventions (mirror `supabase/migrations/20260520120000_ssg_engagements_foundation.sql`): `CREATE TABLE IF NOT EXISTS`, snake_case plural, `created_at`/`updated_at timestamptz NOT NULL DEFAULT now()`, FK to `public.profiles(id)`, `ENABLE ROW LEVEL SECURITY`, `DROP POLICY IF EXISTS` then `CREATE POLICY ... TO authenticated`, gate with `public.has_permission(auth.uid(), 'key')` (note the space after the comma — the RLS-audit script style).
- Permission keys: existing `desks.hris.view`/`desks.hris.manage`; new `desks.hris.comp`. Admins inherit via `*`.
- `public.tasks`: PK `id`; only `title` is required on insert (`source_type` default 'standalone', `status` default 'not_started'); assignee columns are `assigned_to`, `assigned_by`, `updated_by` (all nullable). `source_type` is gated by `public.validate_task_fields()`.
- Direct-report pattern (verbatim): `employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())`.
- `hris_compensation` is append-only: SELECT + INSERT policies only, NO UPDATE/DELETE (mirror `nine_box_scores`).
- `src/integrations/supabase/types.ts` is auto-generated — query via `db` from `@/lib/db` (`db = supabase as any`). TS strict off.
- Frontend: TanStack `useMutation` + invalidate `["hris"]`; RHF+Zod dialogs; Sonner `onError` toasts; clean payloads (no PK in update bodies); shadcn `ui/`; `useDemoMode` masks comp figures/salaries.
- **DB apply is deferred** (no local Docker): migrations apply via the normal deploy; type regen + RLS audit + live E2E happen post-deploy. Frontend builds against `db as any` meanwhile.

---

### Task 1: Onboarding migration — source-type extension + checklist tables + RLS

**Files:**
- Create: `linkedalliance/supabase/migrations/20260629122000_hris_onboarding.sql`

**Interfaces:**
- Consumes: `public.profiles`, `public.validate_task_fields()`, permission keys.
- Produces: extended `validate_task_fields()` allowing `hris_onboarding`/`hris_offboarding`; tables `public.hris_checklist_templates`, `public.hris_checklist_template_items`, `public.hris_employee_checklists`.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- HRIS Desk — Phase 2 Onboarding/Offboarding (tables + source-type extend)
-- Strictly additive. Items live in public.tasks (see RPC migration).
-- ============================================================

-- ===== 1. EXTEND TASK SOURCE-TYPE VALIDATOR =====
-- Relaxes the allowlist to permit HRIS checklist tasks. CREATE OR REPLACE
-- preserves existing triggers. Additive only (mirrors the ssg extension).
CREATE OR REPLACE FUNCTION public.validate_task_fields()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF NEW.priority NOT IN ('low', 'medium', 'high', 'urgent') THEN
    RAISE EXCEPTION 'priority must be low, medium, high, or urgent';
  END IF;
  IF NEW.status NOT IN ('not_started', 'in_progress', 'blocked', 'complete') THEN
    RAISE EXCEPTION 'status must be not_started, in_progress, blocked, or complete';
  END IF;
  IF NEW.source_type NOT IN ('standalone', 'checklist', 'ticket', 'project', 'ssg_engagement', 'hris_onboarding', 'hris_offboarding') THEN
    RAISE EXCEPTION 'source_type must be standalone, checklist, ticket, project, ssg_engagement, hris_onboarding, or hris_offboarding';
  END IF;
  RETURN NEW;
END;
$function$;

-- ===== 2. TABLES =====
CREATE TABLE IF NOT EXISTS public.hris_checklist_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  type text NOT NULL CHECK (type IN ('onboarding','offboarding')),
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hris_checklist_template_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES public.hris_checklist_templates(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  assignee_role text NOT NULL DEFAULT 'new_hire' CHECK (assignee_role IN ('new_hire','manager','hr','it')),
  due_offset_days int NOT NULL DEFAULT 0,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_template_items_template
  ON public.hris_checklist_template_items(template_id);

CREATE TABLE IF NOT EXISTS public.hris_employee_checklists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  template_id uuid NOT NULL REFERENCES public.hris_checklist_templates(id) ON DELETE RESTRICT,
  type text NOT NULL CHECK (type IN ('onboarding','offboarding')),
  status text NOT NULL DEFAULT 'not_started' CHECK (status IN ('not_started','in_progress','completed')),
  start_date date,
  started_by uuid REFERENCES public.profiles(id),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_employee_checklists_employee
  ON public.hris_employee_checklists(employee_id);

-- ===== 3. RLS =====
ALTER TABLE public.hris_checklist_templates       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_checklist_template_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_employee_checklists       ENABLE ROW LEVEL SECURITY;

-- templates: read = view/admin; write = manage/admin
DROP POLICY IF EXISTS "hris tmpl read"  ON public.hris_checklist_templates;
DROP POLICY IF EXISTS "hris tmpl write" ON public.hris_checklist_templates;
CREATE POLICY "hris tmpl read" ON public.hris_checklist_templates
  FOR SELECT TO authenticated USING (
    public.has_permission(auth.uid(), 'desks.hris.view')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris tmpl write" ON public.hris_checklist_templates
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'));

-- template_items: same access as templates
DROP POLICY IF EXISTS "hris tmpl item read"  ON public.hris_checklist_template_items;
DROP POLICY IF EXISTS "hris tmpl item write" ON public.hris_checklist_template_items;
CREATE POLICY "hris tmpl item read" ON public.hris_checklist_template_items
  FOR SELECT TO authenticated USING (
    public.has_permission(auth.uid(), 'desks.hris.view')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris tmpl item write" ON public.hris_checklist_template_items
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'));

-- employee_checklists: read = self/manager/view/admin; write = manage/admin
DROP POLICY IF EXISTS "hris ec_list read"  ON public.hris_employee_checklists;
DROP POLICY IF EXISTS "hris ec_list write" ON public.hris_employee_checklists;
CREATE POLICY "hris ec_list read" ON public.hris_employee_checklists
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(), 'desks.hris.view')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris ec_list write" ON public.hris_employee_checklists
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(), 'desks.hris.manage') OR public.has_permission(auth.uid(), 'admin.access'));

-- ===== 4. PERMISSION KEYS (defined by usage) =====
--   desks.hris.view/manage (existing) gate checklist read/write.
```

- [ ] **Step 2: Verify SQL** — visual check: `validate_task_fields` now lists both `hris_onboarding` and `hris_offboarding` in the IN clause AND the error message; 3 tables created with RLS enabled and DROP-then-CREATE policies; CHECK constraints present. Run `npx supabase db lint` if available; else say so.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260629122000_hris_onboarding.sql
git -C linkedalliance commit -m "feat(hris): onboarding tables + extend task source-type validator"
```

---

### Task 2: Start-checklist RPC

**Files:**
- Create: `linkedalliance/supabase/migrations/20260629122500_hris_start_checklist_rpc.sql`

**Interfaces:**
- Consumes: tables from Task 1, `public.tasks`, `public.has_permission`.
- Produces: `public.hris_start_checklist(p_template_id uuid, p_employee_id uuid, p_start_date date) RETURNS uuid` — creates the checklist header + one task per template item; returns the checklist id.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- HRIS Desk — Phase 2: hris_start_checklist RPC
-- Atomically creates a checklist header and one public.tasks row per
-- template item, with role-resolved assignees. SECURITY DEFINER so the
-- multi-row insert + assignee logic live in one gated place.
-- ============================================================
CREATE OR REPLACE FUNCTION public.hris_start_checklist(
  p_template_id uuid,
  p_employee_id uuid,
  p_start_date date
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_type text;
  v_checklist_id uuid;
  v_manager_id uuid;
  r RECORD;
  v_assignee uuid;
BEGIN
  -- Authorize: only HR (manage) or admin may start checklists.
  IF NOT (public.has_permission(v_caller, 'desks.hris.manage')
          OR public.has_permission(v_caller, 'admin.access')) THEN
    RAISE EXCEPTION 'not authorized to start checklists';
  END IF;

  SELECT type INTO v_type FROM public.hris_checklist_templates WHERE id = p_template_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'template % not found', p_template_id;
  END IF;

  SELECT manager_id INTO v_manager_id FROM public.profiles WHERE id = p_employee_id;

  INSERT INTO public.hris_employee_checklists
    (employee_id, template_id, type, status, start_date, started_by, started_at)
  VALUES
    (p_employee_id, p_template_id, v_type, 'in_progress', p_start_date, v_caller, now())
  RETURNING id INTO v_checklist_id;

  FOR r IN
    SELECT * FROM public.hris_checklist_template_items
    WHERE template_id = p_template_id
    ORDER BY sort_order
  LOOP
    v_assignee := CASE r.assignee_role
      WHEN 'new_hire' THEN p_employee_id
      WHEN 'manager'  THEN v_manager_id
      ELSE NULL            -- 'hr' / 'it' start unassigned
    END;

    INSERT INTO public.tasks
      (title, description, source_type, source_reference_id, due_date,
       assigned_to, assigned_by, updated_by, status)
    VALUES
      (r.title, r.description, 'hris_' || v_type, v_checklist_id,
       p_start_date + (r.due_offset_days || ' days')::interval,
       v_assignee, v_caller, v_caller, 'not_started');
  END LOOP;

  RETURN v_checklist_id;
END;
$$;

-- Allow authenticated users to call it; the function body enforces the
-- manage/admin gate itself.
GRANT EXECUTE ON FUNCTION public.hris_start_checklist(uuid, uuid, date) TO authenticated;
```

- [ ] **Step 2: Verify SQL** — visual check: `SECURITY DEFINER` + `SET search_path = public`; authorization gate raises when caller lacks manage/admin; `source_type` built as `'hris_' || v_type` (yields `hris_onboarding`/`hris_offboarding`); assignee CASE maps new_hire→employee, manager→manager_id, hr/it→NULL; `due_date` = start + offset days; GRANT EXECUTE to authenticated present.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260629122500_hris_start_checklist_rpc.sql
git -C linkedalliance commit -m "feat(hris): hris_start_checklist RPC (atomic checklist + tasks)"
```

---

### Task 3: Compensation & benefits migration

**Files:**
- Create: `linkedalliance/supabase/migrations/20260629123000_hris_comp_benefits.sql`

**Interfaces:**
- Produces: tables `public.hris_compensation` (append-only), `public.hris_benefit_plans`, `public.hris_benefit_enrollments`; introduces `desks.hris.comp` (by usage).

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- HRIS Desk — Phase 2: Compensation & Benefits
-- Comp is append-only (no UPDATE/DELETE). Self-view + HR(comp)-write.
-- Managers are excluded from comp entirely.
-- ============================================================

-- ===== 1. TABLES =====
CREATE TABLE IF NOT EXISTS public.hris_compensation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  effective_date date NOT NULL,
  comp_type text NOT NULL CHECK (comp_type IN ('salary','hourly')),
  annual_salary numeric,
  hourly_rate numeric,
  currency text NOT NULL DEFAULT 'USD',
  pay_frequency text,
  change_reason text,
  created_by uuid REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_compensation_employee
  ON public.hris_compensation(employee_id);

CREATE TABLE IF NOT EXISTS public.hris_benefit_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  type text NOT NULL CHECK (type IN ('health','dental','vision','retirement_401k','life','other')),
  provider text,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hris_benefit_enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  plan_id uuid NOT NULL REFERENCES public.hris_benefit_plans(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('enrolled','waived','pending')),
  coverage_level text,
  effective_date date,
  employee_cost numeric,
  employer_cost numeric,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_benefit_enrollments_employee
  ON public.hris_benefit_enrollments(employee_id);
CREATE INDEX IF NOT EXISTS idx_hris_benefit_enrollments_plan
  ON public.hris_benefit_enrollments(plan_id);

-- ===== 2. RLS =====
ALTER TABLE public.hris_compensation        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_benefit_plans       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_benefit_enrollments ENABLE ROW LEVEL SECURITY;

-- compensation: append-only. read = self/comp/admin; insert = comp/admin. NO update/delete policy.
DROP POLICY IF EXISTS "hris comp read"   ON public.hris_compensation;
DROP POLICY IF EXISTS "hris comp insert" ON public.hris_compensation;
CREATE POLICY "hris comp read" ON public.hris_compensation
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(), 'desks.hris.comp')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris comp insert" ON public.hris_compensation
  FOR INSERT TO authenticated WITH CHECK (
    public.has_permission(auth.uid(), 'desks.hris.comp')
    OR public.has_permission(auth.uid(), 'admin.access')
  );

-- benefit_plans: catalog. read = any active authenticated user; write = comp/admin.
DROP POLICY IF EXISTS "hris plan read"  ON public.hris_benefit_plans;
DROP POLICY IF EXISTS "hris plan write" ON public.hris_benefit_plans;
CREATE POLICY "hris plan read" ON public.hris_benefit_plans
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "hris plan write" ON public.hris_benefit_plans
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(), 'desks.hris.comp') OR public.has_permission(auth.uid(), 'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(), 'desks.hris.comp') OR public.has_permission(auth.uid(), 'admin.access'));

-- benefit_enrollments: read = self/comp/admin; write = comp/admin.
DROP POLICY IF EXISTS "hris enroll read"  ON public.hris_benefit_enrollments;
DROP POLICY IF EXISTS "hris enroll write" ON public.hris_benefit_enrollments;
CREATE POLICY "hris enroll read" ON public.hris_benefit_enrollments
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(), 'desks.hris.comp')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris enroll write" ON public.hris_benefit_enrollments
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(), 'desks.hris.comp') OR public.has_permission(auth.uid(), 'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(), 'desks.hris.comp') OR public.has_permission(auth.uid(), 'admin.access'));
```

- [ ] **Step 2: Verify SQL** — visual check: `hris_compensation` has ONLY read + insert policies (no UPDATE/DELETE → append-only); comp/enrollment read includes `employee_id = auth.uid()` (self) but NOT a manager subquery (managers excluded); `benefit_plans` read is `USING (true)`; all 3 tables RLS-enabled.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260629123000_hris_comp_benefits.sql
git -C linkedalliance commit -m "feat(hris): compensation (append-only) + benefits tables + RLS"
```

---

### Task 4: Activity event types

**Files:**
- Modify: `linkedalliance/src/lib/activityLogger.ts` (extend the `// HRIS` block added in Phase 1)

- [ ] **Step 1: Add constants**

```typescript
  HRIS_CHECKLIST_TEMPLATE_UPDATED: "hris.checklist_template_updated",
  HRIS_CHECKLIST_STARTED: "hris.checklist_started",
  HRIS_COMP_RECORDED: "hris.comp_recorded",
  HRIS_BENEFIT_PLAN_UPDATED: "hris.benefit_plan_updated",
  HRIS_BENEFIT_ENROLLED: "hris.benefit_enrolled",
```

- [ ] **Step 2: Verify** — `cd C:/Users/aksha/Dev/linkedalliance && npx tsc --noEmit -p tsconfig.app.json` → no new errors.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/lib/activityLogger.ts
git -C linkedalliance commit -m "feat(hris): phase-2 activity event types"
```

---

### Task 5: Checklist helpers + tests (TDD)

**Files:**
- Create: `linkedalliance/src/components/desks/hris/checklist.ts`
- Test: `linkedalliance/src/components/desks/hris/checklist.test.ts`

**Interfaces:**
- Produces: `dueDateFromOffset(startISO: string, offsetDays: number): string` (returns ISO "YYYY-MM-DD"); `checklistProgress(tasks: { status: string }[]): { done: number; total: number; complete: boolean }` (complete = total > 0 && done === total; "done" = status === 'complete').

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from "vitest";
import { dueDateFromOffset, checklistProgress } from "./checklist";

describe("dueDateFromOffset", () => {
  it("adds zero days", () => {
    expect(dueDateFromOffset("2026-07-01", 0)).toBe("2026-07-01");
  });
  it("adds positive days across month boundary", () => {
    expect(dueDateFromOffset("2026-06-29", 5)).toBe("2026-07-04");
  });
});

describe("checklistProgress", () => {
  it("counts complete tasks", () => {
    expect(checklistProgress([{ status: "complete" }, { status: "not_started" }]))
      .toEqual({ done: 1, total: 2, complete: false });
  });
  it("is complete when all done", () => {
    expect(checklistProgress([{ status: "complete" }, { status: "complete" }]))
      .toEqual({ done: 2, total: 2, complete: true });
  });
  it("empty list is not complete", () => {
    expect(checklistProgress([])).toEqual({ done: 0, total: 0, complete: false });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/components/desks/hris/checklist.test.ts`
Expected: FAIL — module/functions undefined.

- [ ] **Step 3: Implement**

```typescript
// Pure helpers for HRIS checklists. Dates are ISO "YYYY-MM-DD".
export function dueDateFromOffset(startISO: string, offsetDays: number): string {
  const d = new Date(startISO + "T00:00:00");
  d.setDate(d.getDate() + offsetDays);
  return d.toISOString().slice(0, 10);
}

export function checklistProgress(
  tasks: { status: string }[]
): { done: number; total: number; complete: boolean } {
  const total = tasks.length;
  const done = tasks.filter((t) => t.status === "complete").length;
  return { done, total, complete: total > 0 && done === total };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npx vitest run src/components/desks/hris/checklist.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/checklist.ts src/components/desks/hris/checklist.test.ts
git -C linkedalliance commit -m "feat(hris): checklist date/progress helpers + tests"
```

---

### Task 6: Desk shell — add two tabs + stubs

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/HrisDeskContent.tsx`
- Create: `linkedalliance/src/components/desks/hris/ChecklistsTab.tsx` (stub), `linkedalliance/src/components/desks/hris/CompBenefitsTab.tsx` (stub)

**Interfaces:**
- Consumes: existing `usePermission` calls (`canView`, `canManage`); add `canComp = usePermission("desks.hris.comp")` at top (unconditional).
- Produces: two new tab entries; `ChecklistsTab` and `CompBenefitsTab` components (filled in Tasks 7-8).

- [ ] **Step 1: Extend the shell**

Read the current `HrisDeskContent.tsx`. Add at top (with the other unconditional permission hooks):
```tsx
const canComp = usePermission("desks.hris.comp");
```
Add to the `tabs` array (after Directory), and import the two new components + icons (e.g. `ClipboardList`, `DollarSign` from lucide-react):
```tsx
{ key: "checklists", label: "Checklists", icon: ClipboardList, show: canView },
{ key: "comp", label: "Comp & Benefits", icon: DollarSign, show: canComp },
```
Extend the `TabKey` union with `"checklists" | "comp"` and render:
```tsx
{tab === "checklists" && canView && <ChecklistsTab canManage={canManage} />}
{tab === "comp" && canComp && <CompBenefitsTab />}
```

- [ ] **Step 2: Create stubs**

```tsx
// ChecklistsTab.tsx
export function ChecklistsTab({ canManage }: { canManage: boolean }) { return <div>Checklists</div>; }
// CompBenefitsTab.tsx
export function CompBenefitsTab() { return <div>Comp & Benefits</div>; }
```

- [ ] **Step 3: Verify** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build` succeeds.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/HrisDeskContent.tsx src/components/desks/hris/ChecklistsTab.tsx src/components/desks/hris/CompBenefitsTab.tsx
git -C linkedalliance commit -m "feat(hris): add Checklists + Comp&Benefits tabs to desk shell"
```

---

### Task 7: Checklists tab

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/ChecklistsTab.tsx` (replace stub)

**Interfaces:**
- Consumes: `db`, `useAuth`, `useDemoMode`, `logActivity`/`EventTypes`, `dueDateFromOffset`/`checklistProgress` (Task 5), shadcn `ui/`, RHF+Zod. Props `{ canManage: boolean }`.

- [ ] **Step 1: Implement** — three areas:
1. **Templates** (manage): list `hris_checklist_templates` (+ item count); create/edit template (name, type, description) and manage its `hris_checklist_template_items` (title, description, assignee_role select [new_hire/manager/hr/it], due_offset_days, sort_order). Mutations → `logActivity(EventTypes.HRIS_CHECKLIST_TEMPLATE_UPDATED)` + invalidate `["hris"]`.
2. **Start checklist** dialog (manage): pick template (Select), employee (Select from profiles), start_date (date). On submit call the RPC and log:
```tsx
const start = useMutation({
  mutationFn: async (v: { template_id: string; employee_id: string; start_date: string }) => {
    const { error } = await db.rpc("hris_start_checklist", {
      p_template_id: v.template_id, p_employee_id: v.employee_id, p_start_date: v.start_date,
    });
    if (error) throw error;
  },
  onSuccess: () => { logActivity(EventTypes.HRIS_CHECKLIST_STARTED, "Started checklist"); qc.invalidateQueries({ queryKey: ["hris"] }); },
  onError: () => toast.error("Failed to start checklist."),
});
```
3. **Active checklists** list: query `hris_employee_checklists` (join employee name via a separate profiles lookup keyed on employee_ids, like TimeOffTab — do NOT rely on an FK alias); for each, fetch its linked tasks to compute progress:
```tsx
const { data: tasks = [] } = useQuery({
  queryKey: ["hris", "checklist-tasks", checklist.id],
  queryFn: async () => (await db.from("tasks")
    .select("id,status").eq("source_reference_id", checklist.id)
    .in("source_type", ["hris_onboarding","hris_offboarding"])).data ?? [],
});
// progress via checklistProgress(tasks)
```
Show `done/total` and complete badge. Mask employee names via `useDemoMode`.

- [ ] **Step 2: Verify** — `npm run build` succeeds; `npx vitest run src/components/desks/hris/` still green (5 from Task 5 + Phase 1's 6).

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/ChecklistsTab.tsx
git -C linkedalliance commit -m "feat(hris): checklists tab — templates, start, progress"
```

---

### Task 8: Comp & Benefits tab

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/CompBenefitsTab.tsx` (replace stub)

**Interfaces:**
- Consumes: `db`, `useDemoMode`, `logActivity`/`EventTypes`, shadcn `ui/`, RHF+Zod. Gated on `desks.hris.comp` by the shell.

- [ ] **Step 1: Implement** — three areas:
1. **Employee + comp history**: pick an employee (Select from profiles); show their `hris_compensation` ordered by `effective_date desc`. "Add compensation record" dialog (effective_date, comp_type select salary/hourly, annual_salary OR hourly_rate, currency, pay_frequency, change_reason) → **insert only** (append-only; no edit/delete UI). On success `logActivity(EventTypes.HRIS_COMP_RECORDED)` + invalidate `["hris"]`. Mask salary/rate via `useDemoMode`.
```tsx
const addComp = useMutation({
  mutationFn: async (v: any) => {
    const { error } = await db.from("hris_compensation").insert({ ...v, employee_id: empId, created_by: user.id });
    if (error) throw error;
  },
  onSuccess: () => { logActivity(EventTypes.HRIS_COMP_RECORDED, "Recorded compensation"); qc.invalidateQueries({ queryKey: ["hris"] }); },
  onError: () => toast.error("Failed to record compensation."),
});
```
2. **Benefit plans** catalog: list/create/edit `hris_benefit_plans` (name, type select, provider, is_active) → `logActivity(HRIS_BENEFIT_PLAN_UPDATED)`.
3. **Enrollments** for the selected employee: list `hris_benefit_enrollments` (join plan name); add/edit enrollment (plan select, status, coverage_level, effective_date, employee_cost, employer_cost) → upsert (clean payload, no `id` in update body); `logActivity(HRIS_BENEFIT_ENROLLED)`. Mask cost figures.

- [ ] **Step 2: Verify** — `npm run build` succeeds; vitest green.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/CompBenefitsTab.tsx
git -C linkedalliance commit -m "feat(hris): comp & benefits tab"
```

---

### Task 9: My HR comp/benefits cards

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/MyHrHome.tsx`

**Interfaces:**
- Consumes: `db`, `useAuth`, `useDemoMode`. Self-scoped reads.

- [ ] **Step 1: Implement** — add two read-only cards (self only), masked under demo mode:
- **My Compensation**: query own `hris_compensation` ordered `effective_date desc`; show latest (comp_type, salary/rate, currency, effective_date) + collapsible history. No write controls.
```tsx
const { data: comp = [] } = useQuery({
  queryKey: ["hris", "comp", user?.id],
  queryFn: async () => (await db.from("hris_compensation").select("*").eq("employee_id", user.id).order("effective_date", { ascending: false })).data ?? [],
  enabled: !!user?.id,
});
```
- **My Benefits**: query own `hris_benefit_enrollments` joined to plan name (`select("*, hris_benefit_plans(name,type)")` — plans are readable by all authenticated, so this join works for the employee); show plan, status, coverage, effective_date. No costs editing.

- [ ] **Step 2: Verify** — `npm run build` succeeds; vitest green.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/MyHrHome.tsx
git -C linkedalliance commit -m "feat(hris): My HR comp + benefits read-only cards"
```

---

### Task 10: Verification + permission grants

**Files:** none (commands + admin UI; DB-dependent steps deferred to deploy).

- [ ] **Step 1: Build/lint/tests (DB-independent, runnable now)**

Run: `cd C:/Users/aksha/Dev/linkedalliance && npm run build && npx vitest run`
Expected: build clean; all tests pass (Phase 1's 6 + Task 5's 5 + any prior). Lint debt note from Phase 1 (`no-explicit-any` in HRIS files) is expected and consistent.

- [ ] **Step 2: Post-deploy (DB) — deferred, document in report**

After migrations apply via deploy and types regenerate:
- `node scripts/check-supabase-security.mjs` — passes for the 5 new tables; confirm `hris_compensation` has SELECT+INSERT only.
- Grant `desks.hris.comp` to HR/finance roles via Admin → Roles.

- [ ] **Step 3: Manual E2E (post-deploy)**

- **HR (`manage`)**: create an onboarding template with one item of each role; Start a checklist for a new hire → in `public.tasks`, verify 4 rows with `source_type='hris_onboarding'`, `source_reference_id`=checklist id, due dates = start+offset, and assignees: new_hire→employee, manager→employee's manager, hr/it→unassigned. Progress reflects task completion.
- **Employee**: sees own onboarding tasks in normal task views; sees own comp + benefits read-only in My HR; cannot write comp; cannot see others'.
- **Manager**: NO Comp & Benefits tab; comp/enrollment queries denied.
- **HR (`comp`)**: add a comp record (confirm append-only — no edit/delete); manage a plan; enroll a benefit.

- [ ] **Step 4: Demo mode** — comp figures/salaries masked across Comp & Benefits tab and My HR cards.

---

## Self-Review

- **Spec coverage:** source-type extension + checklist tables + RLS (T1); start RPC with role-resolved assignees, hr/it unassigned (T2); append-only comp + benefits + RLS, managers excluded, all-auth plan catalog (T3); activity events (T4); helpers (T5); two tabs wired (T6); Checklists UI incl. RPC call + progress (T7); Comp & Benefits UI, insert-only comp (T8); My HR self cards (T9); verification + grants (T10). All spec sections map to a task.
- **Placeholders:** none — migrations, RPC, and helpers are complete; frontend tabs give concrete query/mutation/RPC shapes + per-area responsibilities, following the Phase-1 tabs (which exist in-repo).
- **Type consistency:** `source_type` `'hris_'||type` yields `hris_onboarding`/`hris_offboarding` matching the validator (T1) and the progress query's `.in([...])` (T7); RPC params `p_template_id/p_employee_id/p_start_date` match the `db.rpc("hris_start_checklist", {...})` call (T2↔T7); `desks.hris.comp` consistent across T3 RLS, T6 gating, T8; `checklistProgress`/`dueDateFromOffset` signatures match T5↔T7. comp insert uses `created_by` + `employee_id` per T3 columns.
- **DB-deferred** items (apply/regen/audit/E2E) clearly marked, consistent with Phase 1.

## Notes
- Branch off the integrated `main` before executing (e.g. `hris-phase-2`). Reconcile the stale local `main` vs `origin/main` first if not yet done.
- After approval, this plan already lives in `docs/hris/` per the user's docs-location preference.
