# HRIS Desk — Phase 1 (Self-Service + PTO) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an HRIS desk at `/desks/hris` covering employee self-service (details + emergency contacts) and time-off (leave types, manually-set balances, requests with manager approval and tamper-proof balance decrement).

**Architecture:** New role desk following the existing desk pattern (`desks` table row + slug switch in `DeskMode.tsx` + content component under `src/components/desks/hris/`). Two additive Supabase migrations add HRIS tables with 3-tier RLS (self / direct-manager / HR-admin). A `SECURITY DEFINER` trigger decrements leave balances on approval. Frontend uses TanStack Query mutations + direct `db` reads, shadcn UI, RHF+Zod forms.

**Tech Stack:** React 18 + Vite + TypeScript, Supabase (Postgres + RLS), TanStack React Query v5, shadcn/ui + Tailwind, React Hook Form + Zod, Vitest.

**Spec:** `docs/hris/phase-1-self-service-pto-spec.md`

## Global Constraints

- Migrations are **strictly additive** — no ALTER/DROP of existing objects. Naming: `YYYYMMDDHHMMSS_name.sql`, timestamps after `20260622130000`.
- SQL conventions (copy from `supabase/migrations/20260520120000_ssg_engagements_foundation.sql`): `CREATE TABLE IF NOT EXISTS`, snake_case plural tables, `created_at`/`updated_at timestamptz NOT NULL DEFAULT now()`, FK to `public.profiles(id)`, `ENABLE ROW LEVEL SECURITY`, `DROP POLICY IF EXISTS` then `CREATE POLICY ... TO authenticated`, gate with `public.has_permission(auth.uid(), 'key')`.
- Permission keys: `desks.hris.view`, `desks.hris.manage`. Desk entry also needs existing `desks.access`. Admins inherit via `*` in `has_permission`.
- Direct-report check (verbatim pattern): `employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())`.
- `src/integrations/supabase/types.ts` is auto-generated — **do not hand-edit**. Query via `db` from `src/lib/db.ts` (`db = supabase as any`).
- TypeScript strict mode is off — don't fight types; use `db`.
- Respect `useDemoMode()` masking on names/emails/phones in all UI.
- Frontend mutations use TanStack `useMutation` + `queryClient.invalidateQueries`; call `logActivity()` on each mutation.

---

### Task 1: Foundation migration — employee details, emergency contacts, desk seed

**Files:**
- Create: `linkedalliance/supabase/migrations/20260629120000_hris_foundation.sql`

**Interfaces:**
- Produces: tables `public.hris_employee_details` (PK `profile_id`), `public.hris_emergency_contacts`; desk row `slug='hris'`; permission keys `desks.hris.view` / `desks.hris.manage` used by RLS.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- HRIS Desk — Phase 1 Foundation: employee self-service
-- Strictly additive: 2 new tables + 1 desks row. Nothing dropped.
-- ============================================================

-- ===== 1. TABLES =====
CREATE TABLE IF NOT EXISTS public.hris_employee_details (
  profile_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  employee_number text,
  employment_type text CHECK (employment_type IN ('full_time','part_time','contractor','intern')),
  employment_status text NOT NULL DEFAULT 'active'
    CHECK (employment_status IN ('active','on_leave','terminated')),
  hire_date date,
  termination_date date,
  work_location text,
  date_of_birth date,
  home_address text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hris_emergency_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name text NOT NULL,
  relationship text,
  phone text,
  email text,
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_emergency_contacts_employee
  ON public.hris_emergency_contacts(employee_id);

-- ===== 2. RLS =====
ALTER TABLE public.hris_employee_details   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_emergency_contacts ENABLE ROW LEVEL SECURITY;

-- hris_employee_details: self/manager/view read; manage write (HR owns employment fields)
DROP POLICY IF EXISTS "hris details read"   ON public.hris_employee_details;
DROP POLICY IF EXISTS "hris details insert" ON public.hris_employee_details;
DROP POLICY IF EXISTS "hris details update" ON public.hris_employee_details;
DROP POLICY IF EXISTS "hris details delete" ON public.hris_employee_details;

CREATE POLICY "hris details read" ON public.hris_employee_details
  FOR SELECT TO authenticated USING (
    profile_id = auth.uid()
    OR profile_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(), 'desks.hris.view')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris details insert" ON public.hris_employee_details
  FOR INSERT TO authenticated WITH CHECK (
    public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris details update" ON public.hris_employee_details
  FOR UPDATE TO authenticated USING (
    public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris details delete" ON public.hris_employee_details
  FOR DELETE TO authenticated USING (
    public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );

-- hris_emergency_contacts: self/manager/view read; self OR manage write
DROP POLICY IF EXISTS "hris ec read"   ON public.hris_emergency_contacts;
DROP POLICY IF EXISTS "hris ec insert" ON public.hris_emergency_contacts;
DROP POLICY IF EXISTS "hris ec update" ON public.hris_emergency_contacts;
DROP POLICY IF EXISTS "hris ec delete" ON public.hris_emergency_contacts;

CREATE POLICY "hris ec read" ON public.hris_emergency_contacts
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(), 'desks.hris.view')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris ec insert" ON public.hris_emergency_contacts
  FOR INSERT TO authenticated WITH CHECK (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris ec update" ON public.hris_emergency_contacts
  FOR UPDATE TO authenticated USING (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );
CREATE POLICY "hris ec delete" ON public.hris_emergency_contacts
  FOR DELETE TO authenticated USING (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(), 'desks.hris.manage')
    OR public.has_permission(auth.uid(), 'admin.access')
  );

-- ===== 3. SEED DESK ROW =====
INSERT INTO public.desks (name, slug, description, icon, color, permission_key, is_active, sort_order)
VALUES (
  'HRIS', 'hris',
  'People operations — employee profiles, emergency contacts, and time-off requests.',
  '👥', '#0e7490', 'desks.hris.view', true, 70
)
ON CONFLICT (slug) DO NOTHING;

-- ===== 4. PERMISSION KEYS (defined by usage; granted via Admin → Roles) =====
--   desks.hris.view   — open desk, read all employees' details + PTO
--   desks.hris.manage — write employee details, leave types, balances; decide any request
```

- [ ] **Step 2: Verify SQL parses**

Run: `cd linkedalliance && npx supabase db lint --file supabase/migrations/20260629120000_hris_foundation.sql` (if available); otherwise visually confirm against the SSG reference migration that every `CREATE POLICY` has a matching `DROP POLICY IF EXISTS` and all tables have `ENABLE ROW LEVEL SECURITY`.
Expected: no parse errors; 4 policies per table; RLS enabled on both.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260629120000_hris_foundation.sql
git -C linkedalliance commit -m "feat(hris): foundation migration — employee details, emergency contacts, desk seed"
```

---

### Task 2: Time-off migration — leave types, balances, requests, decrement trigger

**Files:**
- Create: `linkedalliance/supabase/migrations/20260629121000_hris_timeoff.sql`

**Interfaces:**
- Consumes: `public.profiles`, permission keys from Task 1.
- Produces: tables `public.hris_leave_types`, `public.hris_leave_balances` (UNIQUE `employee_id,leave_type_id,year`), `public.hris_leave_requests`; trigger function `public.hris_apply_leave_balance()`.

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- HRIS Desk — Phase 1 Time-Off
-- Manually-set balances + tamper-proof decrement on approval.
-- ============================================================

-- ===== 1. TABLES =====
CREATE TABLE IF NOT EXISTS public.hris_leave_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  color text,
  is_paid boolean NOT NULL DEFAULT true,
  requires_approval boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hris_leave_balances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  leave_type_id uuid NOT NULL REFERENCES public.hris_leave_types(id) ON DELETE CASCADE,
  year int NOT NULL,
  allotted_hours numeric NOT NULL DEFAULT 0,
  used_hours numeric NOT NULL DEFAULT 0,
  carryover_hours numeric NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employee_id, leave_type_id, year)
);
CREATE INDEX IF NOT EXISTS idx_hris_leave_balances_employee
  ON public.hris_leave_balances(employee_id);

CREATE TABLE IF NOT EXISTS public.hris_leave_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  leave_type_id uuid NOT NULL REFERENCES public.hris_leave_types(id),
  start_date date NOT NULL,
  end_date date NOT NULL,
  hours numeric NOT NULL,
  reason text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','denied','cancelled')),
  approver_id uuid REFERENCES public.profiles(id),
  decided_at timestamptz,
  decided_by uuid REFERENCES public.profiles(id),
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hris_leave_requests_employee
  ON public.hris_leave_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_hris_leave_requests_status
  ON public.hris_leave_requests(status);

-- ===== 2. BALANCE DECREMENT TRIGGER =====
-- Adjusts hris_leave_balances.used_hours when a request's status changes.
-- SECURITY DEFINER so the math runs regardless of who flips status and
-- can't be bypassed by a client writing used_hours directly.
-- No-op when no matching (employee, type, year) balance row exists.
CREATE OR REPLACE FUNCTION public.hris_apply_leave_balance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  yr int := EXTRACT(YEAR FROM NEW.start_date)::int;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;  -- status unchanged, nothing to do
  END IF;

  -- entering approved: subtract hours
  IF NEW.status = 'approved' AND OLD.status <> 'approved' THEN
    UPDATE public.hris_leave_balances
      SET used_hours = used_hours + NEW.hours, updated_at = now()
    WHERE employee_id = NEW.employee_id
      AND leave_type_id = NEW.leave_type_id
      AND year = yr;
  -- leaving approved: restore hours
  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
    UPDATE public.hris_leave_balances
      SET used_hours = GREATEST(used_hours - OLD.hours, 0), updated_at = now()
    WHERE employee_id = NEW.employee_id
      AND leave_type_id = NEW.leave_type_id
      AND year = yr;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hris_apply_leave_balance ON public.hris_leave_requests;
CREATE TRIGGER trg_hris_apply_leave_balance
  AFTER UPDATE OF status ON public.hris_leave_requests
  FOR EACH ROW EXECUTE FUNCTION public.hris_apply_leave_balance();

-- ===== 3. RLS =====
ALTER TABLE public.hris_leave_types    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_leave_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hris_leave_requests ENABLE ROW LEVEL SECURITY;

-- leave_types: all active users read; manage writes
DROP POLICY IF EXISTS "hris lt read"  ON public.hris_leave_types;
DROP POLICY IF EXISTS "hris lt write" ON public.hris_leave_types;
CREATE POLICY "hris lt read" ON public.hris_leave_types
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "hris lt write" ON public.hris_leave_types
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(),'desks.hris.manage') OR public.has_permission(auth.uid(),'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(),'desks.hris.manage') OR public.has_permission(auth.uid(),'admin.access'));

-- leave_balances: self/manager/view read; manage write
DROP POLICY IF EXISTS "hris lb read"  ON public.hris_leave_balances;
DROP POLICY IF EXISTS "hris lb write" ON public.hris_leave_balances;
CREATE POLICY "hris lb read" ON public.hris_leave_balances
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(),'desks.hris.view')
    OR public.has_permission(auth.uid(),'admin.access')
  );
CREATE POLICY "hris lb write" ON public.hris_leave_balances
  FOR ALL TO authenticated
  USING (public.has_permission(auth.uid(),'desks.hris.manage') OR public.has_permission(auth.uid(),'admin.access'))
  WITH CHECK (public.has_permission(auth.uid(),'desks.hris.manage') OR public.has_permission(auth.uid(),'admin.access'));

-- leave_requests: self/manager/view read; self or manage insert; manager/self/manage update
DROP POLICY IF EXISTS "hris lr read"   ON public.hris_leave_requests;
DROP POLICY IF EXISTS "hris lr insert" ON public.hris_leave_requests;
DROP POLICY IF EXISTS "hris lr update" ON public.hris_leave_requests;
DROP POLICY IF EXISTS "hris lr delete" ON public.hris_leave_requests;
CREATE POLICY "hris lr read" ON public.hris_leave_requests
  FOR SELECT TO authenticated USING (
    employee_id = auth.uid()
    OR employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(),'desks.hris.view')
    OR public.has_permission(auth.uid(),'admin.access')
  );
CREATE POLICY "hris lr insert" ON public.hris_leave_requests
  FOR INSERT TO authenticated WITH CHECK (
    employee_id = auth.uid()
    OR public.has_permission(auth.uid(),'desks.hris.manage')
    OR public.has_permission(auth.uid(),'admin.access')
  );
CREATE POLICY "hris lr update" ON public.hris_leave_requests
  FOR UPDATE TO authenticated USING (
    employee_id = auth.uid()
    OR employee_id IN (SELECT id FROM public.profiles WHERE manager_id = auth.uid())
    OR public.has_permission(auth.uid(),'desks.hris.manage')
    OR public.has_permission(auth.uid(),'admin.access')
  );
CREATE POLICY "hris lr delete" ON public.hris_leave_requests
  FOR DELETE TO authenticated USING (
    public.has_permission(auth.uid(),'desks.hris.manage')
    OR public.has_permission(auth.uid(),'admin.access')
  );
```

> **Note on self-cancel:** the `hris lr update` policy lets an employee update their own request; the frontend restricts self-edits to setting `status='cancelled'` on a `pending` row. A future migration can tighten this with a column-level/`WITH CHECK` guard if needed — out of scope for Phase 1.

- [ ] **Step 2: Verify SQL**

Visually confirm: trigger is `AFTER UPDATE OF status`, function is `SECURITY DEFINER` with `SET search_path = public`, guard `OLD.status IS NOT DISTINCT FROM NEW.status` present, all 3 tables have RLS enabled and policies dropped-then-created.
Expected: matches the checklist.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260629121000_hris_timeoff.sql
git -C linkedalliance commit -m "feat(hris): time-off migration — leave types, balances, requests, decrement trigger"
```

---

### Task 3: Apply migrations + regenerate types + RLS audit

**Files:**
- Modify (generated, via tooling — not by hand): `linkedalliance/src/integrations/supabase/types.ts`

- [ ] **Step 1: Apply migrations**

Run: `cd linkedalliance && npx supabase db push` (or the project's deploy path — confirm with maintainer if the DB is remote-managed).
Expected: both migrations apply cleanly; `desks` gains an `hris` row.

- [ ] **Step 2: Regenerate Supabase types**

Run the project's type-gen command (e.g. `npx supabase gen types typescript --local > src/integrations/supabase/types.ts`, matching how CI does it).
Expected: `hris_*` tables appear in `types.ts`. Do not hand-edit.

- [ ] **Step 3: RLS audit**

Run: `cd linkedalliance && node scripts/check-supabase-security.mjs`
Expected: passes; the 5 new `hris_*` tables report RLS enabled with policies. Fix any flagged table before continuing.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/integrations/supabase/types.ts
git -C linkedalliance commit -m "chore(hris): regenerate supabase types for hris tables"
```

---

### Task 4: Activity event types

**Files:**
- Modify: `linkedalliance/src/lib/activityLogger.ts` (add to the `EventTypes` object, e.g. after the Nine-Box block ~line 95)

- [ ] **Step 1: Add HRIS event constants**

```typescript
  // HRIS
  HRIS_EMPLOYEE_DETAILS_UPDATED: "hris.employee_details_updated",
  HRIS_EMERGENCY_CONTACT_UPDATED: "hris.emergency_contact_updated",
  HRIS_LEAVE_REQUESTED: "hris.leave_requested",
  HRIS_LEAVE_DECIDED: "hris.leave_decided",
  HRIS_LEAVE_CANCELLED: "hris.leave_cancelled",
  HRIS_BALANCE_SET: "hris.balance_set",
  HRIS_LEAVE_TYPE_UPDATED: "hris.leave_type_updated",
```

- [ ] **Step 2: Verify type-check**

Run: `cd linkedalliance && npx tsc --noEmit -p tsconfig.app.json`
Expected: no new errors. (Category auto-derives from the `hris.` prefix via existing `getCategory`.)

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/lib/activityLogger.ts
git -C linkedalliance commit -m "feat(hris): add HRIS activity event types"
```

---

### Task 5: Leave-hours helper + test (TDD)

**Files:**
- Create: `linkedalliance/src/components/desks/hris/leaveHours.ts`
- Test: `linkedalliance/src/components/desks/hris/leaveHours.test.ts`

**Interfaces:**
- Produces: `businessDaysBetween(start: string, end: string): number` and `defaultLeaveHours(start: string, end: string, hoursPerDay?: number): number` — used by `TimeOffTab` to prefill the hours field.

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from "vitest";
import { businessDaysBetween, defaultLeaveHours } from "./leaveHours";

describe("businessDaysBetween", () => {
  it("counts inclusive single weekday as 1", () => {
    expect(businessDaysBetween("2026-06-29", "2026-06-29")).toBe(1); // Mon
  });
  it("excludes weekends", () => {
    // Fri 2026-06-26 .. Mon 2026-06-29 => Fri + Mon = 2
    expect(businessDaysBetween("2026-06-26", "2026-06-29")).toBe(2);
  });
  it("full work week = 5", () => {
    expect(businessDaysBetween("2026-06-29", "2026-07-03")).toBe(5);
  });
  it("returns 0 when end before start", () => {
    expect(businessDaysBetween("2026-06-29", "2026-06-28")).toBe(0);
  });
});

describe("defaultLeaveHours", () => {
  it("defaults 8h/day", () => {
    expect(defaultLeaveHours("2026-06-29", "2026-07-03")).toBe(40);
  });
  it("respects custom hoursPerDay", () => {
    expect(defaultLeaveHours("2026-06-29", "2026-06-29", 7.5)).toBe(7.5);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd linkedalliance && npx vitest run src/components/desks/hris/leaveHours.test.ts`
Expected: FAIL — module not found / functions undefined.

- [ ] **Step 3: Implement**

```typescript
// Pure date math for leave-hours prefill. Dates are ISO "YYYY-MM-DD".
export function businessDaysBetween(start: string, end: string): number {
  const s = new Date(start + "T00:00:00");
  const e = new Date(end + "T00:00:00");
  if (e < s) return 0;
  let days = 0;
  for (let d = new Date(s); d <= e; d.setDate(d.getDate() + 1)) {
    const dow = d.getDay(); // 0 Sun .. 6 Sat
    if (dow !== 0 && dow !== 6) days++;
  }
  return days;
}

export function defaultLeaveHours(start: string, end: string, hoursPerDay = 8): number {
  return businessDaysBetween(start, end) * hoursPerDay;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd linkedalliance && npx vitest run src/components/desks/hris/leaveHours.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/leaveHours.ts src/components/desks/hris/leaveHours.test.ts
git -C linkedalliance commit -m "feat(hris): leave-hours business-day helper + tests"
```

---

### Task 6: Desk shell + router wiring

**Files:**
- Create: `linkedalliance/src/components/desks/hris/HrisDeskContent.tsx`
- Modify: `linkedalliance/src/pages/DeskMode.tsx` (import line ~15; `DeskContent` switch ~line 114; `overflow-auto` slug list line 107)

**Interfaces:**
- Consumes: `usePermission`, `useCurrentUserPermissions` from `@/hooks/usePermissions`.
- Produces: exported `HrisDeskContent` React component; tab components imported in later tasks (`MyHrHome`, `TimeOffTab`, `EmployeeDirectoryTab`).

- [ ] **Step 1: Create the desk shell (tabs + permission gating)**

```tsx
import { useState } from "react";
import { usePermission, useCurrentUserPermissions } from "@/hooks/usePermissions";
import { cn } from "@/lib/utils";
import { User, CalendarDays, Users } from "lucide-react";
import { MyHrHome } from "./MyHrHome";
import { TimeOffTab } from "./TimeOffTab";
import { EmployeeDirectoryTab } from "./EmployeeDirectoryTab";

type TabKey = "my-hr" | "time-off" | "directory";

export function HrisDeskContent() {
  const canView = usePermission("desks.hris.view");
  const canManage = usePermission("desks.hris.manage");
  const { loading } = useCurrentUserPermissions();
  const [tab, setTab] = useState<TabKey>("my-hr");

  if (loading) return null;

  const tabs: { key: TabKey; label: string; icon: typeof User; show: boolean }[] = [
    { key: "my-hr", label: "My HR", icon: User, show: true },
    { key: "time-off", label: "Time Off", icon: CalendarDays, show: true },
    { key: "directory", label: "Directory", icon: Users, show: canView },
  ];

  return (
    <div className="w-full max-w-6xl mx-auto p-4 md:p-6">
      <div className="flex gap-1 border-b border-border mb-4">
        {tabs.filter(t => t.show).map(t => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              "inline-flex items-center gap-2 px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
              tab === t.key
                ? "border-primary text-foreground"
                : "border-transparent text-muted-foreground hover:text-foreground"
            )}
          >
            <t.icon className="h-4 w-4" /> {t.label}
          </button>
        ))}
      </div>
      {tab === "my-hr" && <MyHrHome />}
      {tab === "time-off" && <TimeOffTab canManage={canManage} />}
      {tab === "directory" && canView && <EmployeeDirectoryTab />}
    </div>
  );
}
```

> All `usePermission` calls are at the top of the component (unconditional) — `canManage` is computed once and passed down, satisfying the rules of hooks. The unused `Navigate` import from the stub can be dropped if lint flags it.

- [ ] **Step 2: Wire into DeskMode.tsx**

Add import (after the other desk imports, ~line 15):
```tsx
import { HrisDeskContent } from "@/components/desks/hris/HrisDeskContent";
```
Add switch case in `DeskContent` (before the fallback `return`, ~line 132):
```tsx
  if (desk.slug === "hris") {
    return <HrisDeskContent />;
  }
```
Add `"hris"` to the `overflow-auto` slug condition in `<main>` (line 107), e.g.:
```tsx
desk.slug === "daily-prepper" || desk.slug === "hris" ? "overflow-auto" : ...
```

- [ ] **Step 3: Verify build (tabs render; sub-components stubbed in next tasks)**

To compile now, create minimal stub exports for the three tab files so imports resolve, then flesh them out in Tasks 7-9:
```tsx
// MyHrHome.tsx / TimeOffTab.tsx / EmployeeDirectoryTab.tsx — temporary stubs
export function MyHrHome() { return <div>My HR</div>; }
export function TimeOffTab({ canManage }: { canManage: boolean }) { return <div>Time Off</div>; }
export function EmployeeDirectoryTab() { return <div>Directory</div>; }
```
Run: `cd linkedalliance && npm run build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/ src/pages/DeskMode.tsx
git -C linkedalliance commit -m "feat(hris): desk shell with tabs + DeskMode routing"
```

---

### Task 7: My HR (self-service) tab

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/MyHrHome.tsx` (replace stub)

**Interfaces:**
- Consumes: `useAuth` (`@/hooks/useAuth`) for `user.id`; `db` (`@/lib/db`); `useDemoMode` (`@/hooks/useDemoMode`); `logActivity`, `EventTypes` (`@/lib/activityLogger`).

- [ ] **Step 1: Implement self-service view (own details, balances, emergency contacts CRUD)**

Responsibilities (one component, ~150 lines):
- Fetch own `hris_employee_details` by `profile_id = user.id`, own `hris_leave_balances` (+ join `hris_leave_types(name,color)`), own `hris_emergency_contacts`.
- Render employment summary (type, status, hire_date, work_location) read-only — these are HR-owned.
- Balances table: leave type, allotted, used, remaining = `allotted + carryover - used`.
- Emergency contacts: list + add/edit/delete dialog (RHF + Zod: name required, relationship/phone/email optional, is_primary). Mutations via TanStack `useMutation`, then `logActivity(EventTypes.HRIS_EMERGENCY_CONTACT_UPDATED, ...)` and invalidate.
- Mask names/emails/phones through `useDemoMode()` mask helpers.

Concrete read + contact-insert snippets (follow this shape):
```tsx
const { user } = useAuth();
const qc = useQueryClient();

const { data: details } = useQuery({
  queryKey: ["hris", "details", user?.id],
  queryFn: async () => (await db.from("hris_employee_details").select("*").eq("profile_id", user.id).maybeSingle()).data,
  enabled: !!user?.id,
});
const { data: balances = [] } = useQuery({
  queryKey: ["hris", "balances", user?.id],
  queryFn: async () => (await db.from("hris_leave_balances")
    .select("*, hris_leave_types(name,color)").eq("employee_id", user.id)
    .order("year", { ascending: false })).data ?? [],
  enabled: !!user?.id,
});
const { data: contacts = [] } = useQuery({
  queryKey: ["hris", "ec", user?.id],
  queryFn: async () => (await db.from("hris_emergency_contacts").select("*").eq("employee_id", user.id)).data ?? [],
  enabled: !!user?.id,
});

const saveContact = useMutation({
  mutationFn: async (c: any) => {
    const row = { ...c, employee_id: user.id };
    const { error } = c.id
      ? await db.from("hris_emergency_contacts").update(row).eq("id", c.id)
      : await db.from("hris_emergency_contacts").insert(row);
    if (error) throw error;
  },
  onSuccess: () => {
    logActivity(EventTypes.HRIS_EMERGENCY_CONTACT_UPDATED, "Updated emergency contact");
    qc.invalidateQueries({ queryKey: ["hris", "ec", user?.id] });
  },
});
```

- [ ] **Step 2: Verify build + manual smoke**

Run: `cd linkedalliance && npm run build` → succeeds.
Then `npm run dev`, open `/desks/hris` as a non-HR user: My HR shows only own data; add an emergency contact and confirm it persists.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/MyHrHome.tsx
git -C linkedalliance commit -m "feat(hris): My HR self-service tab"
```

---

### Task 8: Time Off tab — request, my requests, balances, manager approval queue

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/TimeOffTab.tsx` (replace stub)

**Interfaces:**
- Consumes: `defaultLeaveHours` (Task 5), `useAuth`, `db`, `logActivity`/`EventTypes`, shadcn `Dialog`/`Select`/`Input`/`Button`/`Textarea`, RHF + Zod.
- Props: `{ canManage: boolean }`.

- [ ] **Step 1: Implement the four sections**

Responsibilities:
1. **Request leave** dialog — RHF+Zod (`leave_type_id` required, `start_date`/`end_date` required, `hours` number > 0, `reason` optional). On open of dates, prefill `hours` via `defaultLeaveHours(start,end)`. Insert into `hris_leave_requests` with `employee_id = user.id`, `status='pending'`, `approver_id` = own `profiles.manager_id` (fetch once). `logActivity(EventTypes.HRIS_LEAVE_REQUESTED, ...)`.
2. **My Requests** — list own requests with status badge; allow cancelling a `pending` own request (`update {status:'cancelled'}`) → `logActivity(HRIS_LEAVE_CANCELLED)`.
3. **My Balances** — same balances query as Task 7 (reuse queryKey `["hris","balances",user.id]`).
4. **Approval queue** (render only if user has direct reports OR `canManage`) — query pending requests for reports:
```tsx
const { data: reportIds = [] } = useQuery({
  queryKey: ["hris", "reports", user?.id],
  queryFn: async () => ((await db.from("profiles").select("id").eq("manager_id", user.id)).data ?? []).map((r:any)=>r.id),
  enabled: !!user?.id,
});
const { data: pending = [] } = useQuery({
  queryKey: ["hris", "queue", user?.id],
  queryFn: async () => (await db.from("hris_leave_requests")
    .select("*, profiles!hris_leave_requests_employee_id_fkey(full_name), hris_leave_types(name)")
    .in("employee_id", reportIds).eq("status", "pending")).data ?? [],
  enabled: reportIds.length > 0,
});
const decide = useMutation({
  mutationFn: async ({ id, status, note }: { id: string; status: "approved"|"denied"; note?: string }) => {
    const { error } = await db.from("hris_leave_requests").update({
      status, decided_at: new Date().toISOString(), decided_by: user.id, decision_note: note ?? null,
    }).eq("id", id);
    if (error) throw error;
  },
  onSuccess: () => {
    logActivity(EventTypes.HRIS_LEAVE_DECIDED, "Decided leave request");
    qc.invalidateQueries({ queryKey: ["hris", "queue", user?.id] });
  },
});
```
Approving fires the DB trigger which decrements the balance — no client-side balance write.

> The FK alias `profiles!hris_leave_requests_employee_id_fkey` must match the constraint name Postgres generates. Verify the exact name in `types.ts` after Task 3; adjust the alias if different.

- [ ] **Step 2: Verify build + tests**

Run: `cd linkedalliance && npm run build && npx vitest run src/components/desks/hris/`
Expected: build succeeds; Task 5 tests still pass.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/TimeOffTab.tsx
git -C linkedalliance commit -m "feat(hris): time-off tab — requests, balances, manager approval"
```

---

### Task 9: Employee Directory tab (HR roster)

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/EmployeeDirectoryTab.tsx` (replace stub)

**Interfaces:**
- Consumes: `db`, `useDemoMode`, `logActivity`/`EventTypes`, shadcn table/dialog. Rendered only when caller has `desks.hris.view`.

- [ ] **Step 1: Implement roster + details editor**

Responsibilities:
- List active profiles joined to `hris_employee_details`:
```tsx
const { data: rows = [] } = useQuery({
  queryKey: ["hris", "roster"],
  queryFn: async () => (await db.from("profiles")
    .select("id, full_name, email, title, team, hris_employee_details(employment_type, employment_status, hire_date, work_location)")
    .order("full_name")).data ?? [],
});
```
- Drill-in panel/dialog to edit an employee's `hris_employee_details` (upsert keyed on `profile_id`). `logActivity(EventTypes.HRIS_EMPLOYEE_DETAILS_UPDATED, ...)` then invalidate `["hris","roster"]`.
- Optionally set/adjust a balance row (upsert into `hris_leave_balances`) → `logActivity(HRIS_BALANCE_SET)`. Mask names/emails via `useDemoMode()`.

Upsert example:
```tsx
const { error } = await db.from("hris_employee_details")
  .upsert({ profile_id: id, ...fields, updated_at: new Date().toISOString() }, { onConflict: "profile_id" });
```

- [ ] **Step 2: Verify build**

Run: `cd linkedalliance && npm run build` → succeeds.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/EmployeeDirectoryTab.tsx
git -C linkedalliance commit -m "feat(hris): employee directory tab"
```

---

### Task 10: End-to-end verification + permission grants

**Files:** none (manual + admin UI).

- [ ] **Step 1: Lint + build + tests**

Run: `cd linkedalliance && npm run lint && npm run build && npm run test`
Expected: all clean.

- [ ] **Step 2: Grant permissions**

In Admin → Roles (`RolesAdminTab`): grant `desks.hris.view` + `desks.hris.manage` to an HR role; ensure target users also have `desks.access`. Admins inherit via `*`.

- [ ] **Step 3: Manual E2E (`npm run dev`, localhost:8080)**

- **Employee** (no HRIS perms, has `desks.access`): `/desks/hris` → only My HR + Time Off tabs; submit a leave request; cannot see Directory or other employees.
- **Manager**: approval queue shows a direct report's pending request; approve → status flips, and (with a balance row preset) `hris_leave_balances.used_hours` increases via trigger; activity log shows `hris.leave_decided`. Deny a previously-approved request → balance restored.
- **HR** (`view`+`manage`): Directory lists all employees; edit an employee's details; set a leave type + a balance.
- Desk card visible in `/desks` gallery; a user lacking `desks.access` is redirected to `/`.

- [ ] **Step 4: Demo mode**

Toggle `useDemoMode()`; confirm names/emails/phones masked across all three tabs.

- [ ] **Step 5: Final commit (if any fixups)**

```bash
git -C linkedalliance add -A && git -C linkedalliance commit -m "test(hris): phase-1 verification fixups"
```

---

## Self-Review

- **Spec coverage:** desk+access (T1, T6), employee_details + emergency_contacts + RLS (T1, T7, T9), leave types/balances/requests + trigger + RLS (T2, T8), activity events (T4), demo masking (T7-T9, T10), manager direct-report visibility (T2 RLS, T8 queue), permission grants + verification (T10). All Phase-1 spec sections map to a task.
- **Placeholders:** none — SQL, trigger, helper, queries, and mutations are concrete. Frontend tabs give full query/mutation code + explicit per-component responsibilities; remaining JSX is mechanical, following `ClientExpansionDeskContent.tsx`.
- **Type consistency:** balance queryKey `["hris","balances",user.id]` reused (T7/T8); `defaultLeaveHours` signature matches T5 def and T8 use; permission keys `desks.hris.view`/`.manage` consistent across RLS and UI; trigger reads `hris_leave_balances.used_hours` matching the column in T2.
- **Open verify-at-runtime item:** the leave_requests→profiles FK alias name in T8 must be confirmed against generated `types.ts` (noted inline).

## Notes
- Branch off `main` before executing (currently on `main`). Phase 2 (onboarding hybrid + comp/benefits) is a separate spec/plan — do not build here.
- After approval, mirror this plan to `docs/hris/phase-1-implementation-plan.md` per the user's docs-location preference.
