# Intake Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `FeedbackWidget` into `IntakeWidget` with three paths — feedback (unchanged), helpdesk ticket (embeds `SubmitTicketForm`), and new-project request with an approval workflow backed by a new `project_requests` table.

**Architecture:** Widget gains a type-picker step 0. Project requests are stored in a new `project_requests` table (never touching `projects` until approval). A designated approver (app_settings key, admin fallback) approves via a prefilled dialog on the Work/Projects page, which calls a shared `createProjectWithSideEffects` function extracted from `ProjectsAdminTab`. Notifications: in-app + email (new edge function) to approver on submit; in-app to requester on approve/reject.

**Tech Stack:** React 18 + Vite + TS (strict off), Supabase (RLS, edge functions/Deno, Resend), TanStack not required (widget uses direct db calls like existing code), shadcn/ui, vitest.

**Spec:** `C:\Users\aksha\Dev\docs\intake\intake-widget-design-2026-07-20.md`

## Global Constraints

- All app code lives in the **linkedalliance submodule**: `C:\Users\aksha\Dev\linkedalliance`. All paths below are relative to that root.
- linkedalliance `main` requires PRs — **branch first** (`feat/intake-widget`), never push main. Squash-merge via bypass only after self-QA (CLAUDE.md §Team PR workflow).
- PR body MUST contain the tier checkbox block (this is **Tier 2** — new table + widget rework, no destructive change to existing data) and a rollback plan.
- Migration file is committed to the repo but **applied to prod only post-merge** via `mcp__supabase__apply_migration` (workflow step 7). `supabase db push` is broken (stale history) — do not use it.
- Use `db` from `@/lib/db` for tables missing from generated types (`project_requests` will be missing until types regen).
- Every significant user action calls `logActivity()`.
- shadcn components from `src/components/ui/` only; no new primitives.
- Feedback flow behavior must remain byte-for-byte identical (same insert payload, same copy).
- Run `npm run lint && npm run test && npm run build` in linkedalliance before each commit.

---

### Task 1: Migration — `project_requests` table, approver functions, RLS

**Files:**
- Create: `supabase/migrations/20260724120000_project_requests.sql`

**Interfaces:**
- Produces: table `public.project_requests`; SQL functions `is_project_request_approver(_user_id uuid) → boolean` (also used from the client via `db.rpc("is_project_request_approver", { _user_id })`) and `get_project_request_approver_ids() → SETOF uuid` (used by the edge function). app_settings key convention: `project_request_approver_id` holding a user uuid as text.

- [ ] **Step 1: Verify role-table shape used by `has_role`**

Run (Supabase MCP, prod ref `trltcyzskmcveuabypat` — read-only query):
```sql
select pg_get_functiondef(oid) from pg_proc where proname = 'has_role';
select column_name from information_schema.columns where table_name = 'user_role_assignments';
select column_name from information_schema.columns where table_name = 'app_settings';
```
Expected: `has_role` reads a roles table with a `user_id` column and an `app_role` enum. Note the exact table/columns; if the admin-fallback query in Step 2 doesn't match (`user_roles(user_id, role)`), adjust it to mirror `has_role`'s source table before committing. Also confirm `app_settings` has `key`/`value` text columns.

- [ ] **Step 2: Write the migration file**

```sql
-- Project intake requests: submitted from the IntakeWidget, reviewed by a
-- designated approver (app_settings key 'project_request_approver_id', falling
-- back to admins). Nothing touches the projects table until approval — the
-- approval dialog creates the real project and stamps created_project_id here.

CREATE TABLE public.project_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text NOT NULL,
  template_id uuid REFERENCES public.project_templates(id) ON DELETE SET NULL,
  assigned_to_org uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
  assigned_to_user uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  requested_members uuid[] NOT NULL DEFAULT '{}',
  requested_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_project_id uuid REFERENCES public.projects(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_project_requests_status ON public.project_requests (status);
CREATE INDEX idx_project_requests_requested_by ON public.project_requests (requested_by);

-- Single source of truth for "who may review project requests".
-- SECURITY DEFINER so RLS policies and client rpc() can evaluate it without
-- the caller needing read access to app_settings.
CREATE OR REPLACE FUNCTION public.is_project_request_approver(_user_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value FROM app_settings WHERE key = 'project_request_approver_id') = _user_id::text,
    false
  ) OR has_role(_user_id, 'admin'::app_role);
$$;

-- Who should be notified of a new request: the designated approver if set,
-- otherwise every admin. Used by the project-request-notify edge function.
-- NOTE: admin-fallback table must mirror has_role's source (verified in Step 1).
CREATE OR REPLACE FUNCTION public.get_project_request_approver_ids()
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH designated AS (
    SELECT value::uuid AS id FROM app_settings
    WHERE key = 'project_request_approver_id'
      AND value ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  )
  SELECT id FROM designated
  UNION
  SELECT user_id FROM user_roles
  WHERE role = 'admin'::app_role
    AND NOT EXISTS (SELECT 1 FROM designated);
$$;

ALTER TABLE public.project_requests ENABLE ROW LEVEL SECURITY;

-- Per-command policies (NOT the permissive FOR-ALL antipattern — see
-- 20260716150000_fix_block_pending_rls.sql).
CREATE POLICY "Requesters and approvers read project_requests"
  ON public.project_requests FOR SELECT TO authenticated
  USING (
    is_active_user(auth.uid())
    AND (requested_by = auth.uid() OR is_project_request_approver(auth.uid()))
  );

CREATE POLICY "Active users submit project_requests"
  ON public.project_requests FOR INSERT TO authenticated
  WITH CHECK (is_active_user(auth.uid()) AND requested_by = auth.uid());

CREATE POLICY "Approvers update project_requests"
  ON public.project_requests FOR UPDATE TO authenticated
  USING (is_active_user(auth.uid()) AND is_project_request_approver(auth.uid()))
  WITH CHECK (is_active_user(auth.uid()) AND is_project_request_approver(auth.uid()));

NOTIFY pgrst, 'reload schema';
```

- [ ] **Step 3: Sanity-check requester read access to form sources**

Run (Supabase MCP):
```sql
select polname, polcmd, pg_get_expr(polqual, polrelid)
from pg_policy
where polrelid in ('public.project_templates'::regclass,
                   'public.organizations'::regclass,
                   'public.profiles'::regclass)
  and polcmd = 'r';
```
Expected: SELECT policies allowing active authenticated users. If `project_templates` (or its sections/tasks/members tables) is admin-only, append read policies for active users **for project_templates only** (name/id listing is what the form needs) to the migration:
```sql
CREATE POLICY "Active users read project_templates"
  ON public.project_templates FOR SELECT TO authenticated
  USING (is_active_user(auth.uid()));
```

- [ ] **Step 4: Commit**

```bash
cd C:/Users/aksha/Dev/linkedalliance
git checkout -b feat/intake-widget
git add supabase/migrations/20260724120000_project_requests.sql
git commit -m "feat: project_requests table, approver functions, RLS"
```
(Migration is applied to prod post-merge, not now.)

---

### Task 2: Extract shared project creation into `src/lib/projects/createProject.ts`

**Files:**
- Create: `src/lib/projects/createProject.ts`
- Create: `src/lib/projects/createProject.test.ts`
- Modify: `src/components/admin/ProjectsAdminTab.tsx:81-260` (the `createProject` function body)

**Interfaces:**
- Consumes: nothing new (db, logActivity, date-fns — all existing).
- Produces:
```ts
export interface CreateProjectInput {
  name: string;
  description: string | null;
  templateId: string | null;          // null = no template
  assignType: "org" | "user";
  targetId: string;                   // org id or user id per assignType
  startDate: Date | null;
  extraMemberIds?: string[];          // approval flow: requested members
  actorId: string;                    // the admin/approver performing creation
}
export type CreateProjectResult =
  | { ok: true; projectId: string }
  | { ok: false; error: string };
export function computeTemplateTaskDueDate(startDate: Date | null, offsetDays: number | null): string | null;
export async function createProjectWithSideEffects(input: CreateProjectInput): Promise<CreateProjectResult>;
```

- [ ] **Step 1: Write failing test for the pure due-date helper**

`src/lib/projects/createProject.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { computeTemplateTaskDueDate } from "./createProject";

describe("computeTemplateTaskDueDate", () => {
  it("adds offset days to the start date as yyyy-MM-dd", () => {
    expect(computeTemplateTaskDueDate(new Date(2026, 6, 20), 3)).toBe("2026-07-23");
  });
  it("returns null when no start date", () => {
    expect(computeTemplateTaskDueDate(null, 3)).toBeNull();
  });
  it("returns null when offset is null", () => {
    expect(computeTemplateTaskDueDate(new Date(2026, 6, 20), null)).toBeNull();
  });
  it("offset 0 is the start date itself", () => {
    expect(computeTemplateTaskDueDate(new Date(2026, 6, 20), 0)).toBe("2026-07-20");
  });
});
```

- [ ] **Step 2: Run test — verify fail**

Run: `npm run test -- createProject`
Expected: FAIL — module/function not found.

- [ ] **Step 3: Implement `createProject.ts`**

Port the logic from `ProjectsAdminTab.tsx:81-260` verbatim, replacing component state with the input struct, `toast.*` with returned/collected errors, and fetching template data inside the function (the admin tab prefetches into state; the shared function must be self-contained). Full file:

```ts
// Shared project-creation orchestration: projects insert plus every side
// effect the hub expects (creator-owner membership, Partner auto-add, template
// default members, assigned-user membership, template section/task
// instantiation with task_project_memberships dual-write, default section).
// Called from ProjectsAdminTab (admin create) and the project-request approval
// dialog — one code path, per docs/intake spec.
import { format } from "date-fns";
import { db } from "@/lib/db";
import { logActivity } from "@/lib/activityLogger";

export interface CreateProjectInput {
  name: string;
  description: string | null;
  templateId: string | null;
  assignType: "org" | "user";
  targetId: string;
  startDate: Date | null;
  extraMemberIds?: string[];
  actorId: string;
}

export type CreateProjectResult =
  | { ok: true; projectId: string }
  | { ok: false; error: string };

export function computeTemplateTaskDueDate(
  startDate: Date | null,
  offsetDays: number | null
): string | null {
  if (!startDate || offsetDays == null) return null;
  return format(new Date(startDate.getTime() + offsetDays * 86400000), "yyyy-MM-dd");
}

async function addMemberIfMissing(
  projectId: string,
  userId: string,
  role: string,
  addedBy: string,
  source: string
) {
  const { data: existing } = await db
    .from("project_members" as any)
    .select("id")
    .eq("project_id", projectId)
    .eq("user_id", userId)
    .maybeSingle();
  if (existing) return;
  await db.from("project_members" as any).insert({
    project_id: projectId,
    user_id: userId,
    role,
    added_by: addedBy,
  } as any);
  logActivity("project.member_added", `Added project member (${source})`, {
    targetId: projectId,
    targetType: "project",
    metadata: { member_user_id: userId, role, source },
  });
}

export async function createProjectWithSideEffects(
  input: CreateProjectInput
): Promise<CreateProjectResult> {
  const { name, description, templateId, assignType, targetId, startDate, actorId } = input;
  const useTemplate = !!templateId && templateId !== "none";

  const payload: any = {
    name: name.trim(),
    description: description?.trim() || null,
    template_id: useTemplate ? templateId : null,
    created_by: actorId,
    owner_id: actorId,
    start_date: startDate ? format(startDate, "yyyy-MM-dd") : null,
  };
  if (assignType === "org") payload.assigned_to_org = targetId;
  else payload.assigned_to_user = targetId;

  const { data: project, error } = await db
    .from("projects" as any)
    .insert(payload as any)
    .select()
    .single();
  if (error || !project) return { ok: false, error: error?.message || "Insert failed" };
  const projectId = (project as any).id as string;

  // Creator as owner member
  await db.from("project_members" as any).insert({
    project_id: projectId, user_id: actorId, role: "owner", added_by: actorId,
  } as any);
  logActivity("project.member_added", "Added creator as owner", {
    targetId: projectId, targetType: "project",
    metadata: { member_user_id: actorId, role: "owner", source: "creator" },
  });

  // Partner-role users in the assigned org
  if (assignType === "org" && targetId) {
    const [{ data: partnerAssignments }, { data: orgProfiles }] = await Promise.all([
      db.from("user_role_assignments")
        .select("user_id, custom_roles(name)")
        .eq("custom_roles.name", "Partner"),
      db.from("profiles").select("id, organization_id").eq("organization_id", targetId),
    ]);
    const partnerUserIds = new Set(
      (partnerAssignments || [])
        .filter((a: any) => a.custom_roles?.name === "Partner")
        .map((a: any) => a.user_id)
    );
    for (const p of orgProfiles || []) {
      if (p.id === actorId || !partnerUserIds.has(p.id)) continue;
      await addMemberIfMissing(projectId, p.id, "member", actorId, "partner_role");
    }
  }

  // Template default members
  if (useTemplate) {
    const { data: tmplMembers } = await db
      .from("project_template_members" as any)
      .select("user_id, role")
      .eq("template_id", templateId);
    for (const tm of (tmplMembers as any[]) || []) {
      if (tm.user_id === actorId) continue;
      await addMemberIfMissing(projectId, tm.user_id, tm.role, actorId, "template_default");
    }
  }

  // Assigned user as member
  if (assignType === "user" && targetId && targetId !== actorId) {
    await addMemberIfMissing(projectId, targetId, "member", actorId, "assigned_user");
  }

  // Requested members (project-request approval flow)
  for (const mid of input.extraMemberIds || []) {
    if (mid === actorId) continue;
    await addMemberIfMissing(projectId, mid, "member", actorId, "project_request");
  }

  // Template sections + tasks (with task_project_memberships dual-write —
  // the project board renders a task only if it has a membership row; the
  // legacy project_id/section_id are back-compat only).
  if (useTemplate) {
    const [{ data: tmplSections }, { data: tmplTasks }] = await Promise.all([
      db.from("project_template_sections" as any)
        .select("*").eq("template_id", templateId).order("order_index"),
      db.from("project_template_tasks" as any)
        .select("*").order("order_index"),
    ]);
    const taskErrors: string[] = [];
    for (const sec of (tmplSections as any[]) || []) {
      const { data: newSec } = await db.from("project_sections" as any).insert({
        project_id: projectId, name: sec.name, order_index: sec.order_index,
      } as any).select().single();
      if (!newSec) continue;

      const secTasks = ((tmplTasks as any[]) || []).filter(
        (t: any) => t.template_section_id === sec.id
      );
      let position = 0;
      for (const tmplTask of secTasks) {
        const dueDate = computeTemplateTaskDueDate(startDate, tmplTask.due_date_offset_days);
        const assignedTo =
          tmplTask.default_assignee_role || (assignType === "user" ? targetId : actorId);

        const { data: newTask, error: taskErr } = await db.from("tasks" as any).insert({
          title: tmplTask.title,
          description: tmplTask.description || "",
          assigned_to: assignedTo,
          assigned_by: actorId,
          updated_by: actorId,
          priority: null,
          source_type: "project",
          source_reference_id: projectId,
          source_item_id: tmplTask.id,
          project_id: projectId,
          section_id: (newSec as any).id,
          due_date: dueDate,
        } as any).select("id").single();
        if (taskErr || !newTask) {
          taskErrors.push(`task "${tmplTask.title}": ${taskErr?.message ?? "unknown"}`);
          continue;
        }
        const { error: memErr } = await db.from("task_project_memberships" as any).insert({
          task_id: (newTask as any).id,
          project_id: projectId,
          section_id: (newSec as any).id,
          position,
          created_by: actorId,
        } as any);
        if (memErr) taskErrors.push(`board placement "${tmplTask.title}": ${memErr.message}`);
        position++;
      }
    }
    if (taskErrors.length > 0) {
      // Project exists; surface partial failures to the caller for a toast.
      return { ok: true, projectId };
    }
  } else {
    await db.from("project_sections" as any).insert({
      project_id: projectId, name: "General", order_index: 0,
    } as any);
  }

  return { ok: true, projectId };
}
```

- [ ] **Step 4: Run test — verify pass**

Run: `npm run test -- createProject`
Expected: 4 PASS.

- [ ] **Step 5: Refactor `ProjectsAdminTab.createProject` to call the shared function**

In `ProjectsAdminTab.tsx`, replace the body of `createProject` (lines 81-260, from validation through section/task creation) with:

```ts
const createProject = async () => {
  if (!createName.trim()) { toast.error("Project name is required"); return; }
  if (!createTargetId) { toast.error("Please select who to assign this project to"); return; }

  const result = await createProjectWithSideEffects({
    name: createName,
    description: createDesc || null,
    templateId: createTemplateId && createTemplateId !== "none" ? createTemplateId : null,
    assignType: createAssignType,
    targetId: createTargetId,
    startDate: createStartDate ?? null,
    actorId: user!.id,
  });
  if (!result.ok) { toast.error("Failed to create project: " + result.error); return; }
  // keep whatever follows the creation block today (success toast, logActivity
  // "project.created" if present, dialog close/reset, fetchData()) unchanged.
};
```
Add the import: `import { createProjectWithSideEffects } from "@/lib/projects/createProject";`
Keep the surrounding dialog/reset/refresh code exactly as it is today. Remove now-unused local template-instantiation code paths only if nothing else references them (`templateSections`/`templateTasks` state is also used elsewhere in the tab for template management — leave the state in place).

- [ ] **Step 6: Lint, test, build**

Run: `npm run lint && npm run test && npm run build`
Expected: all pass, no new lint errors in touched files.

- [ ] **Step 7: Commit**

```bash
git add src/lib/projects/createProject.ts src/lib/projects/createProject.test.ts src/components/admin/ProjectsAdminTab.tsx
git commit -m "refactor: extract createProjectWithSideEffects into shared lib"
```

---

### Task 3: `IntakeWidget` shell — type picker + feedback path moved over

**Files:**
- Create: `src/components/IntakeWidget.tsx`
- Modify: `src/App.tsx:7,97` (import + usage)
- Delete: `src/components/FeedbackWidget.tsx`

**Interfaces:**
- Consumes: existing feedback step components (moved verbatim).
- Produces: `export function IntakeWidget()`; internal state `path: "picker" | "feedback" | "ticket" | "project"`. Tasks 4-5 add the `ticket` and `project` branches into the switch this task creates (each branch renders a placeholder `null` until then — acceptable inside a task chain, both branches land in the same PR).

- [ ] **Step 1: Create `IntakeWidget.tsx`**

Copy `FeedbackWidget.tsx` in full, then rework the top-level component (keep `StepOne`, `StepTwo`, `StepThree`, `SuccessView`, `IMPACT_OPTIONS`, `FREQUENCY_OPTIONS`, `FEEDBACK_PROJECT_ID`, `FEEDBACK_ASSIGNEE_ID` and the whole submit flow **verbatim** — the feedback insert payload and copy must not change):

```tsx
// Top-level additions/changes relative to FeedbackWidget:
import { MessageCircle, MessageSquare, Ticket, FolderPlus, ChevronLeft } from "lucide-react";

type IntakePath = "picker" | "feedback" | "ticket" | "project";

export function IntakeWidget() {
  const { user } = useAuth();
  const [open, setOpen] = useState(false);
  const [path, setPath] = useState<IntakePath>("picker");
  // ...all existing feedback state stays...

  const handleOpen = () => {
    setPagePath(window.location.pathname + window.location.search);
    setPath("picker");
    setOpen(true);
  };

  const handleClose = () => {
    setOpen(false);
    if (autoCloseRef.current) clearTimeout(autoCloseRef.current);
    setTimeout(() => { reset(); setPath("picker"); }, 300);
  };

  // FAB unchanged except the hover label:
  //   "Share feedback" → "Get help / share ideas"
  //   aria-label "Share feedback" → "Get help or share ideas"

  return (
    <>
      {/* FAB block copied verbatim, label swapped */}
      <Dialog open={open} onOpenChange={v => { if (!v) handleClose(); }}>
        <DialogContent className="sm:max-w-[460px] p-0 gap-0 overflow-hidden">
          {path === "picker" && (
            <div className="p-6 space-y-3">
              <h3 className="text-base font-semibold text-foreground">What do you need?</h3>
              <PickerCard
                icon={<MessageSquare className="h-5 w-5" />}
                title="Share feedback"
                subtitle="An idea, bug, or improvement for the hub"
                onClick={() => setPath("feedback")}
              />
              <PickerCard
                icon={<Ticket className="h-5 w-5" />}
                title="Helpdesk ticket"
                subtitle="Something's broken or you need support"
                onClick={() => setPath("ticket")}
              />
              <PickerCard
                icon={<FolderPlus className="h-5 w-5" />}
                title="Request a new project"
                subtitle="Propose a project for approval"
                onClick={() => setPath("project")}
              />
            </div>
          )}
          {path === "feedback" && (
            /* existing step-indicator + StepOne/StepTwo/StepThree/SuccessView
               block verbatim, plus a back-to-picker button on step 1
               (StepOne gains optional prop onBackToPicker rendering a
               ghost "Back" button on the left of its footer) */
          )}
          {path === "ticket" && null /* Task 4 */}
          {path === "project" && null /* Task 5 */}
        </DialogContent>
      </Dialog>
    </>
  );
}

function PickerCard({ icon, title, subtitle, onClick }: {
  icon: React.ReactNode; title: string; subtitle: string; onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-3 p-4 rounded-lg border border-border hover:bg-muted/50 hover:border-primary/40 transition-colors text-left"
    >
      <span className="flex items-center justify-center w-10 h-10 rounded-full bg-primary/10 text-primary shrink-0">
        {icon}
      </span>
      <span className="flex-1 min-w-0">
        <span className="block text-sm font-medium text-foreground">{title}</span>
        <span className="block text-xs text-muted-foreground">{subtitle}</span>
      </span>
      <ChevronRight className="h-4 w-4 text-muted-foreground shrink-0" />
    </button>
  );
}
```

- [ ] **Step 2: Update `App.tsx` and delete the old file**

`src/App.tsx:7`: `import { IntakeWidget } from "@/components/IntakeWidget";`
`src/App.tsx:97`: `<IntakeWidget />`
Update the comment at `App.tsx:85` mentioning FeedbackWidget.
`git rm src/components/FeedbackWidget.tsx`

- [ ] **Step 3: Verify no dangling references**

Run: `grep -rn "FeedbackWidget" src/`
Expected: no matches.

- [ ] **Step 4: Lint, test, build; manual smoke**

Run: `npm run lint && npm run test && npm run build`
Then `npm run dev`, open localhost:8080, click FAB → picker shows 3 cards → "Share feedback" → complete the 3-step flow → success view → verify a task row lands in the feedback project (same as before).

- [ ] **Step 5: Commit**

```bash
git add src/components/IntakeWidget.tsx src/App.tsx
git rm src/components/FeedbackWidget.tsx
git commit -m "feat: IntakeWidget shell with type picker; feedback path unchanged"
```

---

### Task 4: Helpdesk path — embed `SubmitTicketForm`

**Files:**
- Modify: `src/components/IntakeWidget.tsx` (the `path === "ticket"` branch)

**Interfaces:**
- Consumes: `SubmitTicketForm({ onSuccess: () => void })` from `src/components/tickets/SubmitTicketForm.tsx` (unchanged).
- Produces: ticket branch UI with its own success view.

- [ ] **Step 1: Implement the ticket branch**

```tsx
// new state near the top of IntakeWidget:
const [ticketSubmitted, setTicketSubmitted] = useState(false);
// reset() additionally does setTicketSubmitted(false)

{path === "ticket" && (
  <div className="p-6 max-h-[70vh] overflow-y-auto">
    {ticketSubmitted ? (
      <div className="flex flex-col items-center justify-center py-10 text-center gap-4">
        <span className="flex items-center justify-center w-14 h-14 rounded-full bg-green-100 dark:bg-green-900/30">
          <Check className="h-7 w-7 text-green-600 dark:text-green-400" />
        </span>
        <h3 className="text-lg font-semibold text-foreground">Ticket submitted</h3>
        <p className="text-sm text-muted-foreground max-w-[300px]">
          You'll get email updates as it progresses.
        </p>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" asChild>
            <a href="/tickets">View my tickets</a>
          </Button>
          <Button size="sm" onClick={handleClose}>Close</Button>
        </div>
      </div>
    ) : (
      <>
        <button
          onClick={() => setPath("picker")}
          className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground mb-2"
        >
          <ChevronLeft className="h-3.5 w-3.5" /> Back
        </button>
        <h3 className="text-base font-semibold text-foreground">Submit a helpdesk ticket</h3>
        <SubmitTicketForm onSuccess={() => setTicketSubmitted(true)} />
      </>
    )}
  </div>
)}
```
Import: `import { SubmitTicketForm } from "@/components/tickets/SubmitTicketForm";`

- [ ] **Step 2: Lint, build; manual verify**

Run: `npm run lint && npm run build`
Manual: FAB → Helpdesk ticket → category/title/description → submit → success view → ticket visible on `/tickets` with correct category/status and the confirmation email fires (helpdesk-notify already invoked inside the form).

- [ ] **Step 3: Commit**

```bash
git add src/components/IntakeWidget.tsx
git commit -m "feat: helpdesk ticket path in IntakeWidget via SubmitTicketForm"
```

---

### Task 5: Project request path — lib + form + submit/notify

**Files:**
- Create: `src/lib/projectRequests.ts`
- Create: `src/lib/projectRequests.test.ts`
- Create: `src/components/intake/ProjectRequestForm.tsx`
- Modify: `src/components/IntakeWidget.tsx` (the `path === "project"` branch)
- Modify: `src/lib/activityLogger.ts` (EventTypes additions)

**Interfaces:**
- Consumes: `project_requests` table (Task 1), edge function `project-request-notify` (Task 6 — invoke is fire-and-forget, safe to land first).
- Produces:
```ts
export interface ProjectRequestDraft {
  name: string;
  description: string;
  templateId: string | null;
  assignType: "org" | "user";
  targetId: string;
  memberIds: string[];
}
export function validateProjectRequest(d: ProjectRequestDraft): string | null; // null = valid, else message
export async function submitProjectRequest(d: ProjectRequestDraft, userId: string): Promise<{ ok: true; id: string } | { ok: false; error: string }>;
```
`ProjectRequestForm({ onSuccess: () => void; onBack: () => void })`.

- [ ] **Step 1: Write failing tests for `validateProjectRequest`**

`src/lib/projectRequests.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { validateProjectRequest, type ProjectRequestDraft } from "./projectRequests";

const base: ProjectRequestDraft = {
  name: "Q3 Website Refresh",
  description: "Marketing site needs new case studies section",
  templateId: null,
  assignType: "org",
  targetId: "org-1",
  memberIds: [],
};

describe("validateProjectRequest", () => {
  it("accepts a complete draft", () => {
    expect(validateProjectRequest(base)).toBeNull();
  });
  it("rejects empty name", () => {
    expect(validateProjectRequest({ ...base, name: "  " })).toMatch(/name/i);
  });
  it("rejects empty description", () => {
    expect(validateProjectRequest({ ...base, description: "" })).toMatch(/description/i);
  });
  it("rejects missing assignment target", () => {
    expect(validateProjectRequest({ ...base, targetId: "" })).toMatch(/assign/i);
  });
});
```

- [ ] **Step 2: Run tests — verify fail**

Run: `npm run test -- projectRequests`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/lib/projectRequests.ts`**

```ts
// Project intake requests: validation + submission. The notify edge function
// resolves the approver server-side (app_settings key with admin fallback) so
// the client never needs read access to app_settings.
import { db } from "@/lib/db";
import { supabase } from "@/integrations/supabase/client";
import { logActivity, EventTypes } from "@/lib/activityLogger";

export interface ProjectRequestDraft {
  name: string;
  description: string;
  templateId: string | null;
  assignType: "org" | "user";
  targetId: string;
  memberIds: string[];
}

export function validateProjectRequest(d: ProjectRequestDraft): string | null {
  if (!d.name.trim()) return "Project name is required.";
  if (d.name.length > 255) return "Project name must be under 255 characters.";
  if (!d.description.trim()) return "Description is required.";
  if (d.description.length > 5000) return "Description must be under 5000 characters.";
  if (!d.targetId) return "Choose who the project should be assigned to.";
  return null;
}

export async function submitProjectRequest(
  d: ProjectRequestDraft,
  userId: string
): Promise<{ ok: true; id: string } | { ok: false; error: string }> {
  const invalid = validateProjectRequest(d);
  if (invalid) return { ok: false, error: invalid };

  const { data, error } = await db
    .from("project_requests" as any)
    .insert({
      name: d.name.trim(),
      description: d.description.trim(),
      template_id: d.templateId,
      assigned_to_org: d.assignType === "org" ? d.targetId : null,
      assigned_to_user: d.assignType === "user" ? d.targetId : null,
      requested_members: d.memberIds,
      requested_by: userId,
    } as any)
    .select("id")
    .single();
  if (error || !data) return { ok: false, error: error?.message || "Submit failed" };

  logActivity(EventTypes.PROJECT_REQUEST_SUBMITTED, `Requested project "${d.name.trim()}"`, {
    targetId: (data as any).id,
    targetType: "project_request",
    metadata: { template_id: d.templateId, assign_type: d.assignType },
  });

  // Approver notification (in-app + email) — fire and forget.
  supabase.functions
    .invoke("project-request-notify", { body: { request_id: (data as any).id, event: "submitted" } })
    .catch(() => {});

  return { ok: true, id: (data as any).id };
}
```

- [ ] **Step 4: Add EventTypes**

In `src/lib/activityLogger.ts`, find the `EventTypes` map (it contains `FEEDBACK_SUBMITTED` and `TICKET_CREATED`) and add three entries following the file's exact naming style:
```ts
PROJECT_REQUEST_SUBMITTED: "project_request.submitted",
PROJECT_REQUEST_APPROVED: "project_request.approved",
PROJECT_REQUEST_REJECTED: "project_request.rejected",
```

- [ ] **Step 5: Run tests — verify pass**

Run: `npm run test -- projectRequests`
Expected: 4 PASS.

- [ ] **Step 6: Implement `ProjectRequestForm.tsx`**

```tsx
// Project request form inside the IntakeWidget. Requester fills the full
// shape (template/assignment/members); the approver confirms or adjusts in
// the approval dialog on the Work page.
import { useEffect, useState } from "react";
import { ChevronLeft, Check } from "lucide-react";
import { db } from "@/lib/db";
import { useAuth } from "@/hooks/useAuth";
import { personDisplayName } from "@/lib/sortByName";
import { submitProjectRequest, validateProjectRequest } from "@/lib/projectRequests";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";

export function ProjectRequestForm({ onBack, onClose }: { onBack: () => void; onClose: () => void }) {
  const { user } = useAuth();
  const [templates, setTemplates] = useState<any[]>([]);
  const [orgs, setOrgs] = useState<any[]>([]);
  const [profiles, setProfiles] = useState<any[]>([]);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [templateId, setTemplateId] = useState<string>("none");
  const [assignType, setAssignType] = useState<"org" | "user">("org");
  const [targetId, setTargetId] = useState("");
  const [memberIds, setMemberIds] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [submitted, setSubmitted] = useState(false);

  useEffect(() => {
    (async () => {
      const [tRes, oRes, pRes] = await Promise.all([
        db.from("project_templates" as any).select("id, name").order("name"),
        db.from("organizations").select("id, name").is("archived_at", null).order("name"),
        db.from("profiles").select("id, preferred_name, full_name").neq("status", "pending").order("full_name"),
      ]);
      setTemplates((tRes.data as any) || []);
      setOrgs(oRes.data || []);
      setProfiles(pRes.data || []);
    })();
  }, []);

  const toggleMember = (id: string) =>
    setMemberIds(m => (m.includes(id) ? m.filter(x => x !== id) : [...m, id]));

  const handleSubmit = async () => {
    if (!user) return;
    const draft = {
      name, description,
      templateId: templateId === "none" ? null : templateId,
      assignType, targetId, memberIds,
    };
    const invalid = validateProjectRequest(draft);
    if (invalid) { setError(invalid); return; }
    setError("");
    setSubmitting(true);
    const result = await submitProjectRequest(draft, user.id);
    setSubmitting(false);
    if (!result.ok) { setError(result.error); return; }
    setSubmitted(true);
  };

  if (submitted) {
    return (
      <div className="flex flex-col items-center justify-center py-10 text-center gap-4">
        <span className="flex items-center justify-center w-14 h-14 rounded-full bg-green-100 dark:bg-green-900/30">
          <Check className="h-7 w-7 text-green-600 dark:text-green-400" />
        </span>
        <h3 className="text-lg font-semibold text-foreground">Request sent for approval</h3>
        <p className="text-sm text-muted-foreground max-w-[300px]">
          You'll be notified when it's approved or if more information is needed.
        </p>
        <Button size="sm" onClick={onClose}>Close</Button>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <button
        onClick={onBack}
        className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
      >
        <ChevronLeft className="h-3.5 w-3.5" /> Back
      </button>
      <h3 className="text-base font-semibold text-foreground">Request a new project</h3>

      <div className="space-y-1.5">
        <Label htmlFor="pr-name">Project name *</Label>
        <Input id="pr-name" value={name} onChange={e => setName(e.target.value)}
          placeholder="What should it be called?" maxLength={255} disabled={submitting} />
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="pr-desc">What's it for? *</Label>
        <Textarea id="pr-desc" value={description} onChange={e => setDescription(e.target.value)}
          rows={3} maxLength={5000} placeholder="Goal and business reason…" disabled={submitting} />
      </div>

      <div className="space-y-1.5">
        <Label>Template</Label>
        <Select value={templateId} onValueChange={setTemplateId} disabled={submitting}>
          <SelectTrigger><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value="none">No template</SelectItem>
            {templates.map(t => <SelectItem key={t.id} value={t.id}>{t.name}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>

      <div className="space-y-1.5">
        <Label>Assign to *</Label>
        <div className="flex gap-2">
          <Select value={assignType} onValueChange={(v: "org" | "user") => { setAssignType(v); setTargetId(""); }} disabled={submitting}>
            <SelectTrigger className="w-[140px]"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="org">Organization</SelectItem>
              <SelectItem value="user">Person</SelectItem>
            </SelectContent>
          </Select>
          <Select value={targetId} onValueChange={setTargetId} disabled={submitting}>
            <SelectTrigger className="flex-1"><SelectValue placeholder="Select…" /></SelectTrigger>
            <SelectContent>
              {(assignType === "org" ? orgs : profiles).map((x: any) => (
                <SelectItem key={x.id} value={x.id}>
                  {assignType === "org" ? x.name : personDisplayName(x)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="space-y-1.5">
        <Label>Members <span className="text-muted-foreground font-normal">(optional)</span></Label>
        <ScrollArea className="h-32 rounded-md border p-2">
          {profiles.map((p: any) => (
            <label key={p.id} className="flex items-center gap-2 py-1 text-sm cursor-pointer">
              <Checkbox checked={memberIds.includes(p.id)} onCheckedChange={() => toggleMember(p.id)} disabled={submitting} />
              {personDisplayName(p)}
            </label>
          ))}
        </ScrollArea>
      </div>

      {error && <div className="text-sm text-destructive bg-destructive/10 rounded-md p-3">{error}</div>}

      <div className="flex justify-end">
        <Button onClick={handleSubmit} disabled={submitting} size="sm">
          {submitting ? "Submitting…" : "Submit for approval"}
        </Button>
      </div>
    </div>
  );
}
```

- [ ] **Step 7: Wire into `IntakeWidget`**

```tsx
{path === "project" && (
  <div className="p-6 max-h-[70vh] overflow-y-auto">
    <ProjectRequestForm onBack={() => setPath("picker")} onClose={handleClose} />
  </div>
)}
```
Import: `import { ProjectRequestForm } from "@/components/intake/ProjectRequestForm";`

- [ ] **Step 8: Lint, test, build; manual verify**

Run: `npm run lint && npm run test && npm run build`
Manual (needs Task 1 migration applied — on prod this happens post-merge, so this manual check runs during post-merge QA; pre-merge, verify the form renders and validation messages fire): FAB → Request a new project → fill → submit → row in `project_requests` with status `pending`.

- [ ] **Step 9: Commit**

```bash
git add src/lib/projectRequests.ts src/lib/projectRequests.test.ts src/components/intake/ProjectRequestForm.tsx src/components/IntakeWidget.tsx src/lib/activityLogger.ts
git commit -m "feat: project request path in IntakeWidget"
```

---

### Task 6: Edge function `project-request-notify`

**Files:**
- Create: `supabase/functions/project-request-notify/index.ts`

**Interfaces:**
- Consumes: `get_project_request_approver_ids()` (Task 1), `project_requests`, `profiles`, `notifications` tables, `RESEND_API_KEY` env (already configured for helpdesk-notify).
- Produces: POST endpoint `{ request_id: string, event: "submitted" }` → in-app notification rows for each approver + one email per approver.

- [ ] **Step 1: Implement the function**

```ts
// New project-request notifications: when a request is submitted, notify the
// designated approver (app_settings 'project_request_approver_id', falling
// back to all admins via get_project_request_approver_ids) with an in-app
// notification row plus a Resend email. Follows the helpdesk-notify shape:
// authenticated hub callers only, service-role client for the writes.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PORTAL_URL = "https://portal.linkedalliance.co";
const FROM_ADDRESS = "Linked Accounting Alliance <hub@linkedalliance.co>";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
  }
  const callerClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  let body: { request_id?: string; event?: string };
  try { body = await req.json(); } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400, headers: corsHeaders });
  }
  if (!body.request_id || body.event !== "submitted") {
    return new Response(JSON.stringify({ error: "request_id and event='submitted' required" }), { status: 400, headers: corsHeaders });
  }

  const { data: request } = await supabase
    .from("project_requests")
    .select("id, name, description, requested_by")
    .eq("id", body.request_id)
    .maybeSingle();
  if (!request) {
    return new Response(JSON.stringify({ error: "Request not found" }), { status: 404, headers: corsHeaders });
  }
  // Only the requester may trigger notifications for their own request.
  if (request.requested_by !== caller.id) {
    return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403, headers: corsHeaders });
  }

  const { data: requesterProfile } = await supabase
    .from("profiles")
    .select("preferred_name, full_name, email")
    .eq("id", request.requested_by)
    .maybeSingle();
  const requesterName =
    requesterProfile?.preferred_name || requesterProfile?.full_name || requesterProfile?.email || "Someone";

  const { data: approverIds, error: apprErr } = await supabase.rpc("get_project_request_approver_ids");
  if (apprErr || !approverIds || approverIds.length === 0) {
    return new Response(JSON.stringify({ error: apprErr?.message || "No approver configured" }), { status: 500, headers: corsHeaders });
  }
  const ids: string[] = (approverIds as any[]).map((r) => (typeof r === "string" ? r : r.get_project_request_approver_ids ?? r.id));

  // In-app notifications
  await supabase.from("notifications").insert(
    ids.map((uid) => ({
      user_id: uid,
      actor_id: request.requested_by,
      type: "project_request_submitted",
      title: `${requesterName} requested a new project: "${request.name}"`,
      link: "/work",
    })),
  );

  // Emails
  const { data: approverProfiles } = await supabase
    .from("profiles")
    .select("id, email, preferred_name, full_name")
    .in("id", ids);

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  let sent = 0;
  if (RESEND_API_KEY) {
    for (const ap of approverProfiles || []) {
      if (!ap.email) continue;
      const first = (ap.preferred_name || ap.full_name || "there").split(" ")[0];
      const html = `<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f0f4f8;font-family:-apple-system,Segoe UI,Roboto,sans-serif;">
  <table cellpadding="0" cellspacing="0" width="100%" style="background:#f0f4f8;padding:32px 16px;"><tr><td align="center">
    <table cellpadding="0" cellspacing="0" width="560" style="background:#ffffff;border-radius:12px;overflow:hidden;">
      <tr><td style="background:#1a2e4a;padding:28px 40px;">
        <p style="margin:0 0 4px 0;color:#7ec8e8;font-size:11px;font-weight:600;letter-spacing:3px;text-transform:uppercase;">Linked Hub</p>
        <h1 style="margin:0;color:#ffffff;font-size:22px;font-weight:700;">New project request</h1>
      </td></tr>
      <tr><td style="padding:40px;">
        <h2 style="margin:0 0 16px 0;color:#1a2e4a;font-size:18px;">Hi ${esc(first)},</h2>
        <p style="margin:0 0 20px 0;color:#4a5568;font-size:15px;line-height:1.7;">${esc(requesterName)} submitted a project request that needs your review.</p>
        <div style="background:#f7fafc;border:1px solid #e2e8f0;border-radius:8px;padding:20px;margin-bottom:24px;">
          <p style="margin:0 0 8px 0;color:#1a2e4a;font-size:16px;font-weight:600;">${esc(request.name)}</p>
          <p style="margin:0;color:#4a5568;font-size:14px;line-height:1.6;">${esc(request.description).slice(0, 500)}</p>
        </div>
        <table cellpadding="0" cellspacing="0" width="100%"><tr><td align="center">
          <a href="${PORTAL_URL}/work" style="display:inline-block;background:linear-gradient(135deg,#53c3ec,#2d9cc7);color:#ffffff;font-size:15px;font-weight:600;text-decoration:none;padding:14px 36px;border-radius:8px;">Review request →</a>
        </td></tr></table>
      </td></tr>
    </table>
  </td></tr></table>
</body></html>`;
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: FROM_ADDRESS,
          to: [ap.email],
          subject: `New project request: ${request.name}`,
          html,
        }),
      });
      if (res.ok) sent++;
    }
  }

  return new Response(JSON.stringify({ success: true, notified: ids.length, emails_sent: sent }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
```

- [ ] **Step 2: Confirm RPC result shape**

`supabase.rpc` on a `RETURNS SETOF uuid` function returns a flat array of strings in supabase-js v2. The defensive `ids` mapping above handles both flat strings and object rows — leave it in.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/project-request-notify/index.ts
git commit -m "feat: project-request-notify edge function (approver in-app + email)"
```
(Deploy post-merge alongside the migration: `mcp__supabase__deploy_edge_function` or `supabase functions deploy project-request-notify`.)

---

### Task 7: Pending requests section + approve/reject on the Work page

**Files:**
- Create: `src/components/intake/PendingProjectRequests.tsx`
- Modify: `src/components/projects/ProjectsOverview.tsx:37-50` (render the section above the card grid)
- Modify: `src/pages/Work.tsx` (pass a refresh callback so approval refreshes the projects list)

**Interfaces:**
- Consumes: `createProjectWithSideEffects` + `CreateProjectInput` (Task 2); `db.rpc("is_project_request_approver", { _user_id })` (Task 1); `EventTypes.PROJECT_REQUEST_APPROVED/REJECTED` (Task 5).
- Produces: `PendingProjectRequests({ onProjectCreated: () => void })` — self-fetching; renders nothing when there's nothing to show. Approvers/admins see all pending with Approve/Reject; requesters see their own requests with status badges.

- [ ] **Step 1: Implement `PendingProjectRequests.tsx`**

```tsx
// Pending project requests on the Work/Projects page. Approvers (designated
// via app_settings + admins) see the review queue with Approve/Reject;
// requesters see their own requests' status. RLS already scopes the SELECT,
// so one query serves both audiences — is_project_request_approver() only
// decides whether action buttons render.
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { FolderPlus } from "lucide-react";
import { db } from "@/lib/db";
import { useAuth } from "@/hooks/useAuth";
import { personDisplayName } from "@/lib/sortByName";
import { logActivity, EventTypes } from "@/lib/activityLogger";
import { createProjectWithSideEffects } from "@/lib/projects/createProject";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";

export function PendingProjectRequests({ onProjectCreated }: { onProjectCreated: () => void }) {
  const { user } = useAuth();
  const [isApprover, setIsApprover] = useState(false);
  const [requests, setRequests] = useState<any[]>([]);
  const [profiles, setProfiles] = useState<any[]>([]);
  const [orgs, setOrgs] = useState<any[]>([]);
  const [templates, setTemplates] = useState<any[]>([]);
  const [approveTarget, setApproveTarget] = useState<any | null>(null);
  const [rejectTarget, setRejectTarget] = useState<any | null>(null);

  const load = useCallback(async () => {
    if (!user) return;
    const [{ data: appr }, reqRes, pRes, oRes, tRes] = await Promise.all([
      db.rpc("is_project_request_approver", { _user_id: user.id }),
      db.from("project_requests" as any).select("*").order("created_at", { ascending: false }),
      db.from("profiles").select("id, preferred_name, full_name").neq("status", "pending").order("full_name"),
      db.from("organizations").select("id, name").is("archived_at", null).order("name"),
      db.from("project_templates" as any).select("id, name").order("name"),
    ]);
    setIsApprover(!!appr);
    setRequests((reqRes.data as any) || []);
    setProfiles(pRes.data || []);
    setOrgs(oRes.data || []);
    setTemplates((tRes.data as any) || []);
  }, [user]);

  useEffect(() => { load(); }, [load]);

  if (!user) return null;
  const pending = requests.filter((r) => r.status === "pending");
  const mine = requests.filter((r) => r.requested_by === user.id);
  // Approvers: show queue when non-empty. Requesters: show own recent requests.
  const visible = isApprover ? pending : mine.slice(0, 5);
  if (visible.length === 0) return null;

  const nameOf = (id: string | null) =>
    personDisplayName(profiles.find((p: any) => p.id === id)) || "Unknown";

  return (
    <Card className="mb-6 border-primary/30">
      <CardContent className="p-4 space-y-3">
        <div className="flex items-center gap-2">
          <FolderPlus className="h-4 w-4 text-primary" />
          <h3 className="text-sm font-semibold">
            {isApprover ? `Pending project requests (${pending.length})` : "My project requests"}
          </h3>
        </div>
        {visible.map((r) => (
          <div key={r.id} className="flex items-start justify-between gap-3 rounded-lg border p-3">
            <div className="min-w-0">
              <p className="text-sm font-medium truncate">{r.name}</p>
              <p className="text-xs text-muted-foreground line-clamp-2">{r.description}</p>
              <p className="text-[11px] text-muted-foreground mt-1">
                Requested by {nameOf(r.requested_by)} · {new Date(r.created_at).toLocaleDateString()}
              </p>
              {r.status === "rejected" && r.rejection_reason && (
                <p className="text-xs text-destructive mt-1">Reason: {r.rejection_reason}</p>
              )}
            </div>
            {isApprover && r.status === "pending" ? (
              <div className="flex gap-2 shrink-0">
                <Button size="sm" variant="outline" onClick={() => setRejectTarget(r)}>Reject</Button>
                <Button size="sm" onClick={() => setApproveTarget(r)}>Review & approve</Button>
              </div>
            ) : (
              <Badge
                variant={r.status === "approved" ? "default" : r.status === "rejected" ? "destructive" : "secondary"}
                className="shrink-0"
              >
                {r.status}
              </Badge>
            )}
          </div>
        ))}
      </CardContent>

      {approveTarget && (
        <ApproveDialog
          request={approveTarget}
          profiles={profiles}
          orgs={orgs}
          templates={templates}
          actorId={user.id}
          onDone={(created) => {
            setApproveTarget(null);
            load();
            if (created) onProjectCreated();
          }}
        />
      )}
      {rejectTarget && (
        <RejectDialog
          request={rejectTarget}
          actorId={user.id}
          onDone={() => { setRejectTarget(null); load(); }}
        />
      )}
    </Card>
  );
}

function ApproveDialog({ request, profiles, orgs, templates, actorId, onDone }: {
  request: any; profiles: any[]; orgs: any[]; templates: any[]; actorId: string;
  onDone: (created: boolean) => void;
}) {
  const [name, setName] = useState(request.name);
  const [description, setDescription] = useState(request.description);
  const [templateId, setTemplateId] = useState<string>(request.template_id || "none");
  const [assignType, setAssignType] = useState<"org" | "user">(request.assigned_to_user ? "user" : "org");
  const [targetId, setTargetId] = useState<string>(request.assigned_to_user || request.assigned_to_org || "");
  const [working, setWorking] = useState(false);

  const approve = async () => {
    if (!name.trim() || !targetId) { toast.error("Name and assignment are required"); return; }
    setWorking(true);
    const result = await createProjectWithSideEffects({
      name,
      description,
      templateId: templateId === "none" ? null : templateId,
      assignType,
      targetId,
      startDate: new Date(),
      extraMemberIds: [...(request.requested_members || []), request.requested_by],
      actorId,
    });
    if (!result.ok) { setWorking(false); toast.error("Approval failed: " + result.error); return; }

    const { error: updErr } = await db.from("project_requests" as any).update({
      status: "approved",
      reviewed_by: actorId,
      reviewed_at: new Date().toISOString(),
      created_project_id: result.projectId,
    } as any).eq("id", request.id);
    if (updErr) toast.error("Project created but request update failed: " + updErr.message);

    await db.from("notifications").insert({
      user_id: request.requested_by,
      actor_id: actorId,
      type: "project_request_approved",
      title: `Your project request "${name.trim()}" was approved`,
      link: "/work",
    });
    logActivity(EventTypes.PROJECT_REQUEST_APPROVED, `Approved project request "${name.trim()}"`, {
      targetId: request.id, targetType: "project_request",
      metadata: { created_project_id: result.projectId },
    });
    toast.success("Project created");
    setWorking(false);
    onDone(true);
  };

  return (
    <Dialog open onOpenChange={(v) => { if (!v && !working) onDone(false); }}>
      <DialogContent className="sm:max-w-[480px]">
        <DialogHeader><DialogTitle>Approve project request</DialogTitle></DialogHeader>
        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label>Project name</Label>
            <Input value={name} onChange={(e) => setName(e.target.value)} disabled={working} />
          </div>
          <div className="space-y-1.5">
            <Label>Description</Label>
            <Textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={3} disabled={working} />
          </div>
          <div className="space-y-1.5">
            <Label>Template</Label>
            <Select value={templateId} onValueChange={setTemplateId} disabled={working}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="none">No template</SelectItem>
                {templates.map((t: any) => <SelectItem key={t.id} value={t.id}>{t.name}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label>Assign to</Label>
            <div className="flex gap-2">
              <Select value={assignType} onValueChange={(v: "org" | "user") => { setAssignType(v); setTargetId(""); }} disabled={working}>
                <SelectTrigger className="w-[140px]"><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="org">Organization</SelectItem>
                  <SelectItem value="user">Person</SelectItem>
                </SelectContent>
              </Select>
              <Select value={targetId} onValueChange={setTargetId} disabled={working}>
                <SelectTrigger className="flex-1"><SelectValue placeholder="Select…" /></SelectTrigger>
                <SelectContent>
                  {(assignType === "org" ? orgs : profiles).map((x: any) => (
                    <SelectItem key={x.id} value={x.id}>
                      {assignType === "org" ? x.name : personDisplayName(x)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            Requested members ({(request.requested_members || []).length}) and the requester will be added to the project.
          </p>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => onDone(false)} disabled={working}>Cancel</Button>
            <Button onClick={approve} disabled={working}>
              {working ? "Creating…" : "Approve & create project"}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function RejectDialog({ request, actorId, onDone }: {
  request: any; actorId: string; onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const [working, setWorking] = useState(false);

  const reject = async () => {
    if (!reason.trim()) { toast.error("A reason is required"); return; }
    setWorking(true);
    const { error } = await db.from("project_requests" as any).update({
      status: "rejected",
      rejection_reason: reason.trim(),
      reviewed_by: actorId,
      reviewed_at: new Date().toISOString(),
    } as any).eq("id", request.id);
    if (error) { setWorking(false); toast.error("Reject failed: " + error.message); return; }

    await db.from("notifications").insert({
      user_id: request.requested_by,
      actor_id: actorId,
      type: "project_request_rejected",
      title: `Your project request "${request.name}" was declined: ${reason.trim()}`,
      link: "/work",
    });
    logActivity(EventTypes.PROJECT_REQUEST_REJECTED, `Rejected project request "${request.name}"`, {
      targetId: request.id, targetType: "project_request",
      metadata: { reason: reason.trim() },
    });
    setWorking(false);
    onDone();
  };

  return (
    <Dialog open onOpenChange={(v) => { if (!v && !working) onDone(); }}>
      <DialogContent className="sm:max-w-[420px]">
        <DialogHeader><DialogTitle>Reject "{request.name}"</DialogTitle></DialogHeader>
        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label>Reason (shared with the requester)</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} autoFocus disabled={working} />
          </div>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={onDone} disabled={working}>Cancel</Button>
            <Button variant="destructive" onClick={reject} disabled={working}>
              {working ? "Rejecting…" : "Reject request"}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Render inside `ProjectsOverview`**

In `src/components/projects/ProjectsOverview.tsx`, add a prop `onProjectsChanged: () => void` to `ProjectsOverviewProps`, and render at the top of the returned JSX (before the card grid):
```tsx
<PendingProjectRequests onProjectCreated={onProjectsChanged} />
```
Import: `import { PendingProjectRequests } from "@/components/intake/PendingProjectRequests";`

In `src/pages/Work.tsx`, at the `<ProjectsOverview …>` call site inside `renderProjectsList()` (around line 864), pass the existing data-refresh function (the one that repopulates `projects` — the fetch called on mount, around line 236's enclosing function): `onProjectsChanged={fetchData}` (use the actual name found in the file).

- [ ] **Step 3: Lint, test, build**

Run: `npm run lint && npm run test && npm run build`
Expected: pass. (`is_project_request_approver` rpc + table only exist after post-merge migration; UI must no-op gracefully — `load()` failures leave `requests` empty and the component renders null.)

- [ ] **Step 4: Commit**

```bash
git add src/components/intake/PendingProjectRequests.tsx src/components/projects/ProjectsOverview.tsx src/pages/Work.tsx
git commit -m "feat: pending project request queue with approve/reject on Work page"
```

---

### Task 8: Admin setting — designated approver

**Files:**
- Modify: `src/components/admin/ProjectsAdminTab.tsx` (add a small settings block at the top of the tab)

**Interfaces:**
- Consumes: `app_settings` upsert pattern (same as `IntegrationsTab.tsx:56-89`), `profiles` already loaded in the tab's state.
- Produces: app_settings row `key='project_request_approver_id'`, `value=<user uuid as text>` (empty string = unset → admin fallback).

- [ ] **Step 1: Add the approver setting UI**

Inside `ProjectsAdminTab`, add state + load + save (below existing state declarations):

```tsx
const APPROVER_SETTING_KEY = "project_request_approver_id";
const [approverId, setApproverId] = useState<string>("");
const [approverLoaded, setApproverLoaded] = useState(false);

useEffect(() => {
  db.from("app_settings")
    .select("value")
    .eq("key", APPROVER_SETTING_KEY)
    .maybeSingle()
    .then(({ data }: any) => { setApproverId(data?.value ?? ""); setApproverLoaded(true); });
}, []);

const saveApprover = async (value: string) => {
  setApproverId(value === "admins" ? "" : value);
  const { error } = await db.from("app_settings").upsert(
    { key: APPROVER_SETTING_KEY, value: value === "admins" ? "" : value, updated_at: new Date().toISOString() } as any,
    { onConflict: "key" }
  );
  if (error) toast.error("Failed to save approver: " + error.message);
  else toast.success("Project request approver updated");
};
```

Render near the top of the tab's JSX (above the projects table):
```tsx
{approverLoaded && (
  <div className="flex items-center gap-3 rounded-lg border p-3 mb-4">
    <div className="flex-1">
      <p className="text-sm font-medium">Project request approver</p>
      <p className="text-xs text-muted-foreground">
        Who reviews new-project requests from the intake widget. Unset = all admins.
      </p>
    </div>
    <Select value={approverId || "admins"} onValueChange={saveApprover}>
      <SelectTrigger className="w-[220px]"><SelectValue /></SelectTrigger>
      <SelectContent>
        <SelectItem value="admins">All admins (default)</SelectItem>
        {profiles.map((p: any) => (
          <SelectItem key={p.id} value={p.id}>{personDisplayName(p)}</SelectItem>
        ))}
      </SelectContent>
    </Select>
  </div>
)}
```
(`Select` imports and `profiles` state already exist in this file; add any missing imports.)

- [ ] **Step 2: Lint, build**

Run: `npm run lint && npm run build`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add src/components/admin/ProjectsAdminTab.tsx
git commit -m "feat: designated project-request approver setting in admin"
```

---

### Task 9: PR, self-QA, merge, post-merge apply

**Files:** none (process)

- [ ] **Step 1: Full local gate**

Run in linkedalliance: `npm run lint && npm run test && npm run build && node scripts/check-supabase-security.mjs`
Expected: all pass; security check flags nothing new (project_requests policies are per-command).

- [ ] **Step 2: Push branch + open PR**

PR body must include (per CLAUDE.md §Team PR workflow):
```markdown
## Tier

- [ ] Tier 1
- [x] Tier 2
- [ ] Tier 3

New intake widget + project_requests table; additive schema, no changes to existing rows or destructive migrations.

## Rollback plan

- Revert the squash commit (UI is fully additive; FeedbackWidget behavior lives on inside IntakeWidget).
- DB: `DROP TABLE public.project_requests; DROP FUNCTION public.is_project_request_approver(uuid); DROP FUNCTION public.get_project_request_approver_ids();` — no existing tables were altered.
- Edge function: delete `project-request-notify` (nothing else calls it).
```

- [ ] **Step 3: Generate the self-QA kickoff prompt** (automatic per workflow — flag if it doesn't fire), run the review session, act on findings, reply on the PR.

- [ ] **Step 4: Squash-merge via bypass, then post-merge:**
1. `mcp__supabase__apply_migration` with `supabase/migrations/20260724120000_project_requests.sql` contents.
2. Deploy edge function `project-request-notify`.
3. `mcp__supabase__get_advisors` (security) — confirm no new findings.
4. Prod QA: all three widget paths; approver setting; approve (check project + members + template tasks on the board) and reject (check requester notification carries the reason); RLS spot-check — a non-approver must not see others' requests.
5. Delete the branch.

---

### Task 10 (addendum 2026-07-20): hub-feature questions

**Files:**
- Modify: `supabase/migrations/20260726120000_project_requests.sql` (add `request_type` + `feature_answers` columns to the CREATE TABLE — migration still unapplied)
- Modify: `src/lib/projectRequests.ts` + `src/lib/projectRequests.test.ts` (draft gains `requestType`/`featureAnswers`; hub_feature requires `problem`; payload maps `request_type` + `feature_answers`)
- Modify: `src/components/intake/ProjectRequestForm.tsx` (type toggle default hub_feature + 5 conditional inputs per spec §8)
- Modify: `src/components/intake/PendingProjectRequests.tsx` (badge + read-only answers on card and ApproveDialog)
- Modify: `supabase/functions/project-request-notify/index.ts` (append escaped/truncated problem + urgency lines to email body for hub_feature)

**Interfaces:**
- `ProjectRequestDraft` gains `requestType: "hub_feature" | "other"` and `featureAnswers: { problem: string; users: string; location: string; success: string; urgency: string } | null`.
- TDD: extend projectRequests tests — hub_feature missing problem → rejected; hub_feature with problem → valid; other → feature fields ignored.
- Gate: lint + test + build; commit on feat/intake-widget; PR #279 reply comment.

## Self-review notes

- **Spec coverage:** widget UX + rename (T3), ticket embed (T4), request form + full fields (T5), `project_requests` + RLS + approver functions (T1), approval/reject dialogs + shared createProject (T2, T7), admin approver setting (T8), notifications in-app+email approver / in-app requester (T5-T7), testing + QA (T2/T5 vitest, T9 prod QA). Out-of-scope items untouched.
- **Type consistency:** `CreateProjectInput.extraMemberIds` consumed in T7 approve; `validateProjectRequest`/`submitProjectRequest` signatures match between T5 lib and form; rpc name `is_project_request_approver(_user_id)` consistent across T1/T7; setting key `project_request_approver_id` consistent across T1/T6/T8.
- **Known verify-at-build points (explicit steps, not placeholders):** has_role source table (T1 S1), template read RLS (T1 S3), Work.tsx refresh function name (T7 S2), EventTypes map style (T5 S4).
