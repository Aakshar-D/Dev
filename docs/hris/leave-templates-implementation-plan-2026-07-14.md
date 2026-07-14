# HRIS Leave Structure Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Named leave-allotment templates (days per leave type) that HR applies to many employees at once to seed `hris_leave_balances` for a year.

**Architecture:** Two new tables (`hris_leave_templates`, `hris_leave_template_items`) gated by manage/admin RLS; one SECURITY DEFINER RPC `hris_apply_leave_template` doing the atomic days→hours upsert; one new HRIS desk tab (`LeaveTemplatesTab`) with template CRUD + apply dialog, patterned on `ChecklistsTab`.

**Tech Stack:** React 18 + Vite SPA, TanStack React Query, shadcn/ui, react-hook-form + zod, Supabase (Postgres RLS + plpgsql RPC), vitest.

**Spec:** `C:\Users\aksha\Dev\docs\hris\leave-templates-design-2026-07-14.md`

## Global Constraints

- Repo: `C:\Users\aksha\Dev\linkedalliance` (submodule). Work on branch `hris-leave-templates` off `main`. Main requires PRs — never push to main.
- Path alias `@/` → `src/`. TypeScript strict mode OFF. Use `db` from `@/lib/db` for tables/RPCs not in generated types (these new ones will not be).
- Units: template items store **days**; balances store **hours**; conversion `days * hours_per_day` (template-level factor, default 8).
- Access: everything (read + write + apply) requires `desks.hris.manage` OR `admin.access`.
- The migration is NOT applied to prod by the implementer — file only. Prod apply is a separate user-approved step.
- `npm run test` and `npx eslint <changed files>` must pass before each commit (18 pre-existing eslint `any` errors exist in OTHER files; do not add new ones).

---

### Task 1: Migration — tables, RLS, RPC

**Files:**
- Create: `supabase/migrations/20260714120000_hris_leave_templates.sql`

**Interfaces:**
- Produces: tables `hris_leave_templates(id, name, description, hours_per_day, is_active, created_at, updated_at)`, `hris_leave_template_items(id, template_id, leave_type_id, days)`; RPC `hris_apply_leave_template(_template_id uuid, _employee_ids uuid[], _year int, _overwrite boolean) returns jsonb {created, updated, skipped}`. Task 4 calls the RPC via `db.rpc("hris_apply_leave_template", {...})`.

- [ ] **Step 1: Write the migration file**

```sql
-- Leave structure templates: named per-leave-type annual allotments (days),
-- applied to employees to seed hris_leave_balances (hours).
-- Spec: Dev docs/hris/leave-templates-design-2026-07-14.md

create table public.hris_leave_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  hours_per_day numeric not null default 8 check (hours_per_day > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.hris_leave_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.hris_leave_templates(id) on delete cascade,
  leave_type_id uuid not null references public.hris_leave_types(id) on delete cascade,
  days numeric not null check (days >= 0),
  unique (template_id, leave_type_id)
);

alter table public.hris_leave_templates enable row level security;
alter table public.hris_leave_template_items enable row level security;

create policy "hris leave tmpl read" on public.hris_leave_templates
  for select using (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  );
create policy "hris leave tmpl write" on public.hris_leave_templates
  for all using (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  ) with check (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  );

create policy "hris leave tmpl item read" on public.hris_leave_template_items
  for select using (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  );
create policy "hris leave tmpl item write" on public.hris_leave_template_items
  for all using (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  ) with check (
    has_permission(auth.uid(), 'desks.hris.manage')
    or has_permission(auth.uid(), 'admin.access')
  );

create or replace function public.hris_apply_leave_template(
  _template_id uuid,
  _employee_ids uuid[],
  _year int,
  _overwrite boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  _tpl record;
  _item record;
  _emp uuid;
  _hours numeric;
  _created int := 0;
  _updated int := 0;
  _skipped int := 0;
begin
  if not (has_permission(auth.uid(), 'desks.hris.manage')
          or has_permission(auth.uid(), 'admin.access')) then
    raise exception 'Not authorized to apply leave templates';
  end if;

  select * into _tpl
  from hris_leave_templates
  where id = _template_id and is_active;
  if not found then
    raise exception 'Leave template not found or inactive';
  end if;

  if _employee_ids is null or array_length(_employee_ids, 1) is null then
    raise exception 'No employees selected';
  end if;

  for _item in
    select i.leave_type_id, i.days, lt.is_active as type_active
    from hris_leave_template_items i
    join hris_leave_types lt on lt.id = i.leave_type_id
    where i.template_id = _template_id
  loop
    -- inactive leave types: count one skip per selected employee
    if not _item.type_active then
      _skipped := _skipped + array_length(_employee_ids, 1);
      continue;
    end if;

    _hours := _item.days * _tpl.hours_per_day;

    foreach _emp in array _employee_ids loop
      insert into hris_leave_balances
        (employee_id, leave_type_id, year, allotted_hours, used_hours, carryover_hours)
      values (_emp, _item.leave_type_id, _year, _hours, 0, 0)
      on conflict (employee_id, leave_type_id, year) do nothing;

      if found then
        _created := _created + 1;
      elsif _overwrite then
        update hris_leave_balances
           set allotted_hours = _hours, updated_at = now()
         where employee_id = _emp
           and leave_type_id = _item.leave_type_id
           and year = _year;
        _updated := _updated + 1;
      else
        _skipped := _skipped + 1;
      end if;
    end loop;
  end loop;

  return jsonb_build_object('created', _created, 'updated', _updated, 'skipped', _skipped);
end;
$$;
```

- [ ] **Step 2: Sanity-check the SQL locally**

Run (from `linkedalliance/`): `node -e "const s=require('fs').readFileSync('supabase/migrations/20260714120000_hris_leave_templates.sql','utf8'); console.log(s.includes('security definer') && s.includes('on conflict') ? 'OK' : 'MISSING PIECES')"`
Expected: `OK`
(No local Postgres; real verification happens at prod-apply time — see Task 6.)

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260714120000_hris_leave_templates.sql
git commit -m "feat(hris): leave template tables, RLS, apply RPC"
```

---

### Task 2: Pure helpers (TDD)

**Files:**
- Create: `src/components/desks/hris/leaveTemplates.ts`
- Test: `src/components/desks/hris/leaveTemplates.test.ts`

**Interfaces:**
- Produces: `daysToHours(days: number, hoursPerDay: number): number` (2-decimal rounding); `summarizeApplyResult(r: { created: number; updated: number; skipped: number }): string` returning e.g. `"Created 12, updated 0, skipped 3"`. Task 4 imports both.

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "vitest";
import { daysToHours, summarizeApplyResult } from "./leaveTemplates";

describe("daysToHours", () => {
  it("multiplies days by hours per day", () => {
    expect(daysToHours(15, 8)).toBe(120);
  });
  it("rounds to 2 decimals", () => {
    expect(daysToHours(1.333, 7.5)).toBe(10);
    expect(daysToHours(0.1, 7.5)).toBe(0.75);
  });
  it("handles zero days", () => {
    expect(daysToHours(0, 8)).toBe(0);
  });
});

describe("summarizeApplyResult", () => {
  it("formats counts", () => {
    expect(summarizeApplyResult({ created: 12, updated: 0, skipped: 3 })).toBe(
      "Created 12, updated 0, skipped 3"
    );
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run src/components/desks/hris/leaveTemplates.test.ts`
Expected: FAIL — cannot resolve `./leaveTemplates`

- [ ] **Step 3: Write minimal implementation**

```ts
export function daysToHours(days: number, hoursPerDay: number): number {
  return Math.round(days * hoursPerDay * 100) / 100;
}

export function summarizeApplyResult(r: {
  created: number;
  updated: number;
  skipped: number;
}): string {
  return `Created ${r.created}, updated ${r.updated}, skipped ${r.skipped}`;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run src/components/desks/hris/leaveTemplates.test.ts`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add src/components/desks/hris/leaveTemplates.ts src/components/desks/hris/leaveTemplates.test.ts
git commit -m "feat(hris): leave template day/hour helpers"
```

---

### Task 3: LeaveTemplatesTab — template CRUD

**Files:**
- Create: `src/components/desks/hris/LeaveTemplatesTab.tsx`
- Modify: `src/lib/activityLogger.ts` (EventTypes block, after line 120 `HRIS_BENEFIT_ENROLLED`)

**Interfaces:**
- Consumes: `daysToHours` from Task 2.
- Produces: `export function LeaveTemplatesTab()` (no props) rendering template CRUD; an `Apply` button per template card calling `setApplyTemplate(t)` — dialog itself lands in Task 4 (Task 3 leaves a `{/* Apply dialog mounts here (Task 4) */}` comment and unused state). New event types `HRIS_LEAVE_TEMPLATE_UPDATED: "hris.leave_template_updated"`, `HRIS_LEAVE_TEMPLATE_APPLIED: "hris.leave_template_applied"`.

- [ ] **Step 1: Add event types to `src/lib/activityLogger.ts`**

After `HRIS_BENEFIT_ENROLLED: "hris.benefit_enrolled",` add:

```ts
  HRIS_LEAVE_TEMPLATE_UPDATED: "hris.leave_template_updated",
  HRIS_LEAVE_TEMPLATE_APPLIED: "hris.leave_template_applied",
```

- [ ] **Step 2: Create `LeaveTemplatesTab.tsx`**

```tsx
import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { toast } from "sonner";
import { ChevronDown, ChevronRight, Loader2, Pencil, Plus, Send, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { db } from "@/lib/db";
import { logActivity, EventTypes } from "@/lib/activityLogger";
import { daysToHours } from "./leaveTemplates";
import { ApplyLeaveTemplateDialog } from "./ApplyLeaveTemplateDialog";

const templateSchema = z.object({
  name: z.string().min(1, "Name is required"),
  description: z.string().optional(),
  hours_per_day: z.coerce.number().positive("Must be > 0"),
});
type TemplateForm = z.infer<typeof templateSchema>;

const itemSchema = z.object({
  leave_type_id: z.string().min(1, "Pick a leave type"),
  days: z.coerce.number().min(0, "Days must be ≥ 0"),
});
type ItemForm = z.infer<typeof itemSchema>;

export function LeaveTemplatesTab() {
  const qc = useQueryClient();
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [editTemplate, setEditTemplate] = useState<any | null>(null);
  const [templateDialogOpen, setTemplateDialogOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<any | null>(null);
  const [itemTemplate, setItemTemplate] = useState<any | null>(null);
  const [applyTemplate, setApplyTemplate] = useState<any | null>(null);

  const { data: templates = [], isLoading } = useQuery({
    queryKey: ["hris", "leave-templates"],
    queryFn: async () =>
      (await db.from("hris_leave_templates").select("*").order("name")).data ?? [],
  });

  const { data: items = [] } = useQuery({
    queryKey: ["hris", "leave-template-items"],
    queryFn: async () =>
      (await db.from("hris_leave_template_items").select("*")).data ?? [],
  });

  const { data: leaveTypes = [] } = useQuery({
    queryKey: ["hris", "leave-types"],
    queryFn: async () =>
      (await db.from("hris_leave_types").select("id,name,is_active").order("name")).data ?? [],
  });

  const templateForm = useForm<TemplateForm>({
    resolver: zodResolver(templateSchema),
    defaultValues: { name: "", description: "", hours_per_day: 8 },
  });

  const itemForm = useForm<ItemForm>({
    resolver: zodResolver(itemSchema),
    defaultValues: { leave_type_id: "", days: 0 },
  });

  const saveTemplate = useMutation({
    mutationFn: async (data: TemplateForm) => {
      if (editTemplate?.id) {
        const { error } = await db
          .from("hris_leave_templates")
          .update({ ...data, updated_at: new Date().toISOString() })
          .eq("id", editTemplate.id);
        if (error) throw error;
      } else {
        const { error } = await db.from("hris_leave_templates").insert(data);
        if (error) throw error;
      }
    },
    onSuccess: () => {
      logActivity(EventTypes.HRIS_LEAVE_TEMPLATE_UPDATED, editTemplate?.id ? "Updated leave template" : "Created leave template");
      qc.invalidateQueries({ queryKey: ["hris", "leave-templates"] });
      setTemplateDialogOpen(false);
      setEditTemplate(null);
      templateForm.reset({ name: "", description: "", hours_per_day: 8 });
    },
    onError: () => toast.error("Failed to save template."),
  });

  const deleteTemplate = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await db.from("hris_leave_templates").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      logActivity(EventTypes.HRIS_LEAVE_TEMPLATE_UPDATED, "Deleted leave template");
      qc.invalidateQueries({ queryKey: ["hris", "leave-templates"] });
      qc.invalidateQueries({ queryKey: ["hris", "leave-template-items"] });
      setDeleteTarget(null);
    },
    onError: () => toast.error("Failed to delete template."),
  });

  const addItem = useMutation({
    mutationFn: async (data: ItemForm) => {
      const { error } = await db.from("hris_leave_template_items").insert({
        template_id: itemTemplate!.id,
        leave_type_id: data.leave_type_id,
        days: data.days,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      logActivity(EventTypes.HRIS_LEAVE_TEMPLATE_UPDATED, "Added leave template item");
      qc.invalidateQueries({ queryKey: ["hris", "leave-template-items"] });
      setItemTemplate(null);
      itemForm.reset({ leave_type_id: "", days: 0 });
    },
    onError: () => toast.error("Failed to add item (duplicate leave type?)."),
  });

  const removeItem = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await db.from("hris_leave_template_items").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => {
      logActivity(EventTypes.HRIS_LEAVE_TEMPLATE_UPDATED, "Removed leave template item");
      qc.invalidateQueries({ queryKey: ["hris", "leave-template-items"] });
    },
    onError: () => toast.error("Failed to remove item."),
  });

  const typeName = (id: string) =>
    (leaveTypes as any[]).find((t) => t.id === id)?.name ?? "—";

  const openNew = () => {
    setEditTemplate(null);
    templateForm.reset({ name: "", description: "", hours_per_day: 8 });
    setTemplateDialogOpen(true);
  };

  const openEdit = (t: any) => {
    setEditTemplate(t);
    templateForm.reset({
      name: t.name,
      description: t.description ?? "",
      hours_per_day: Number(t.hours_per_day),
    });
    setTemplateDialogOpen(true);
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-48">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">Leave Templates</h2>
        <Button size="sm" onClick={openNew}>
          <Plus className="h-4 w-4 mr-1" /> New Template
        </Button>
      </div>

      {(templates as any[]).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No leave templates yet. Create one to seed employee leave balances in bulk.
        </p>
      ) : (
        <div className="space-y-2">
          {(templates as any[]).map((t) => {
            const tItems = (items as any[]).filter((i) => i.template_id === t.id);
            const isOpen = !!expanded[t.id];
            return (
              <div key={t.id} className="rounded-lg border bg-card">
                <div className="flex items-center gap-2 p-3">
                  <button
                    onClick={() => setExpanded((e) => ({ ...e, [t.id]: !isOpen }))}
                    className="text-muted-foreground"
                  >
                    {isOpen ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
                  </button>
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-sm">{t.name}</p>
                    {t.description && (
                      <p className="text-xs text-muted-foreground truncate">{t.description}</p>
                    )}
                  </div>
                  <Badge variant={t.is_active ? "success" : "secondary"}>
                    {t.is_active ? "Active" : "Inactive"}
                  </Badge>
                  <span className="text-xs text-muted-foreground whitespace-nowrap">
                    {Number(t.hours_per_day)} h/day · {tItems.length} types
                  </span>
                  <Button size="sm" variant="outline" className="h-7 text-xs" onClick={() => setApplyTemplate(t)}>
                    <Send className="h-3 w-3 mr-1" /> Apply
                  </Button>
                  <Button size="icon" variant="ghost" className="h-7 w-7" onClick={() => openEdit(t)}>
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  <Button size="icon" variant="ghost" className="h-7 w-7 text-destructive" onClick={() => setDeleteTarget(t)}>
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>

                {isOpen && (
                  <div className="border-t px-4 py-3 space-y-2">
                    <div className="flex items-center justify-between">
                      <p className="text-xs uppercase tracking-wider text-muted-foreground">
                        Allotments ({tItems.length})
                      </p>
                      <Button size="sm" variant="outline" className="h-7 text-xs" onClick={() => setItemTemplate(t)}>
                        <Plus className="h-3 w-3 mr-1" /> Add Leave Type
                      </Button>
                    </div>
                    {tItems.length === 0 ? (
                      <p className="text-sm text-muted-foreground">No leave types yet.</p>
                    ) : (
                      <table className="w-full text-sm">
                        <thead>
                          <tr className="text-left text-muted-foreground">
                            <th className="py-1 font-medium">Leave Type</th>
                            <th className="py-1 font-medium text-right">Days</th>
                            <th className="py-1 font-medium text-right">Hours</th>
                            <th className="py-1" />
                          </tr>
                        </thead>
                        <tbody>
                          {tItems.map((i) => (
                            <tr key={i.id} className="border-t">
                              <td className="py-1.5">{typeName(i.leave_type_id)}</td>
                              <td className="py-1.5 text-right">{Number(i.days)}</td>
                              <td className="py-1.5 text-right text-muted-foreground">
                                {daysToHours(Number(i.days), Number(t.hours_per_day))}
                              </td>
                              <td className="py-1.5 text-right">
                                <Button
                                  size="icon"
                                  variant="ghost"
                                  className="h-6 w-6 text-destructive"
                                  onClick={() => removeItem.mutate(i.id)}
                                >
                                  <Trash2 className="h-3 w-3" />
                                </Button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* New/Edit template dialog */}
      <Dialog
        open={templateDialogOpen}
        onOpenChange={(open) => {
          if (!open) { setTemplateDialogOpen(false); setEditTemplate(null); }
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{editTemplate ? "Edit Leave Template" : "New Leave Template"}</DialogTitle>
          </DialogHeader>
          <form onSubmit={templateForm.handleSubmit((d) => saveTemplate.mutate(d))} className="space-y-4">
            <div className="space-y-1">
              <Label>Name *</Label>
              <Input placeholder="e.g. Full-time US" {...templateForm.register("name")} />
              {templateForm.formState.errors.name && (
                <p className="text-xs text-destructive">{templateForm.formState.errors.name.message}</p>
              )}
            </div>
            <div className="space-y-1">
              <Label>Description</Label>
              <Textarea rows={2} placeholder="Optional details…" {...templateForm.register("description")} />
            </div>
            <div className="space-y-1">
              <Label>Hours per day *</Label>
              <Input type="number" step="0.5" {...templateForm.register("hours_per_day")} />
              {templateForm.formState.errors.hours_per_day && (
                <p className="text-xs text-destructive">{templateForm.formState.errors.hours_per_day.message}</p>
              )}
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setTemplateDialogOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={saveTemplate.isPending}>
                {saveTemplate.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : "Save"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Add item dialog */}
      <Dialog open={!!itemTemplate} onOpenChange={(open) => { if (!open) setItemTemplate(null); }}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Add Leave Type — {itemTemplate?.name}</DialogTitle>
          </DialogHeader>
          <form onSubmit={itemForm.handleSubmit((d) => addItem.mutate(d))} className="space-y-4">
            <div className="space-y-1">
              <Label>Leave Type *</Label>
              <Select
                value={itemForm.watch("leave_type_id")}
                onValueChange={(v) => itemForm.setValue("leave_type_id", v, { shouldValidate: true })}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Select leave type…" />
                </SelectTrigger>
                <SelectContent>
                  {(leaveTypes as any[]).filter((lt) => lt.is_active).map((lt) => (
                    <SelectItem key={lt.id} value={lt.id}>{lt.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {itemForm.formState.errors.leave_type_id && (
                <p className="text-xs text-destructive">{itemForm.formState.errors.leave_type_id.message}</p>
              )}
            </div>
            <div className="space-y-1">
              <Label>Days per year *</Label>
              <Input type="number" step="0.5" {...itemForm.register("days")} />
              {itemForm.formState.errors.days && (
                <p className="text-xs text-destructive">{itemForm.formState.errors.days.message}</p>
              )}
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setItemTemplate(null)}>Cancel</Button>
              <Button type="submit" disabled={addItem.isPending}>
                {addItem.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : "Add"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Delete confirm */}
      <AlertDialog open={!!deleteTarget} onOpenChange={(open) => { if (!open) setDeleteTarget(null); }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete "{deleteTarget?.name}"?</AlertDialogTitle>
            <AlertDialogDescription>
              Removes the template and its allotments. Existing employee balances are not affected.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => deleteTemplate.mutate(deleteTarget!.id)}>
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      {/* Apply dialog (Task 4) */}
      <ApplyLeaveTemplateDialog template={applyTemplate} onClose={() => setApplyTemplate(null)} />
    </div>
  );
}
```

Note: this imports `ApplyLeaveTemplateDialog` (Task 4). To keep Task 3 independently compilable, Task 3 creates a stub file `src/components/desks/hris/ApplyLeaveTemplateDialog.tsx`:

```tsx
export function ApplyLeaveTemplateDialog({
  template,
  onClose,
}: {
  template: any | null;
  onClose: () => void;
}) {
  void template; void onClose;
  return null;
}
```

Task 4 replaces the stub body.

- [ ] **Step 3: Verify compile + lint**

Run: `npx eslint src/components/desks/hris/LeaveTemplatesTab.tsx src/components/desks/hris/ApplyLeaveTemplateDialog.tsx src/lib/activityLogger.ts`
Expected: only `@typescript-eslint/no-explicit-any` errors of the same kind other HRIS tabs already have (repo convention with strict mode off); no other rule failures.
Run: `npx vitest run src/components/desks/hris/leaveTemplates.test.ts`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/components/desks/hris/LeaveTemplatesTab.tsx src/components/desks/hris/ApplyLeaveTemplateDialog.tsx src/lib/activityLogger.ts
git commit -m "feat(hris): leave templates tab with template CRUD"
```

---

### Task 4: ApplyLeaveTemplateDialog

**Files:**
- Modify: `src/components/desks/hris/ApplyLeaveTemplateDialog.tsx` (replace stub)

**Interfaces:**
- Consumes: `summarizeApplyResult` from Task 2; RPC `hris_apply_leave_template` from Task 1; props `{ template: any | null; onClose: () => void }` from Task 3.
- Produces: working apply flow — employee multi-select, year, skip/overwrite toggle, RPC call, toast, activity log.

- [ ] **Step 1: Replace stub with implementation**

```tsx
import { useMemo, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2, Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import {
  Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { db } from "@/lib/db";
import { logActivity, EventTypes } from "@/lib/activityLogger";
import { useDemoMode } from "@/hooks/useDemoMode";
import { personDisplayName } from "@/lib/sortByName";
import { summarizeApplyResult } from "./leaveTemplates";

export function ApplyLeaveTemplateDialog({
  template,
  onClose,
}: {
  template: any | null;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const { mask } = useDemoMode();
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Record<string, boolean>>({});
  const [year, setYear] = useState<number>(new Date().getFullYear());
  const [overwrite, setOverwrite] = useState(false);

  const { data: profiles = [] } = useQuery({
    queryKey: ["hris", "all-profiles"],
    queryFn: async () =>
      (await db.from("profiles").select("id,preferred_name,full_name").order("full_name")).data ?? [],
    enabled: !!template,
  });

  const filtered = useMemo(
    () =>
      (profiles as any[]).filter((p) =>
        (personDisplayName(p) ?? "").toLowerCase().includes(search.toLowerCase())
      ),
    [profiles, search]
  );

  const selectedIds = Object.keys(selected).filter((id) => selected[id]);

  const apply = useMutation({
    mutationFn: async () => {
      const { data, error } = await db.rpc("hris_apply_leave_template", {
        _template_id: template!.id,
        _employee_ids: selectedIds,
        _year: year,
        _overwrite: overwrite,
      });
      if (error) throw error;
      return data as { created: number; updated: number; skipped: number };
    },
    onSuccess: (result) => {
      logActivity(EventTypes.HRIS_LEAVE_TEMPLATE_APPLIED, "Applied leave template", {
        metadata: {
          template_id: template!.id,
          employees: selectedIds.length,
          year,
          overwrite,
          ...result,
        },
      });
      qc.invalidateQueries({ queryKey: ["hris"] });
      toast.success(summarizeApplyResult(result));
      handleClose();
    },
    onError: (e: any) => toast.error(e?.message ?? "Failed to apply template."),
  });

  function handleClose() {
    setSearch("");
    setSelected({});
    setOverwrite(false);
    setYear(new Date().getFullYear());
    onClose();
  }

  const allFilteredSelected = filtered.length > 0 && filtered.every((p) => selected[p.id]);

  return (
    <Dialog open={!!template} onOpenChange={(open) => { if (!open) handleClose(); }}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Apply "{template?.name}"</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="flex items-end gap-4">
            <div className="space-y-1">
              <Label>Year</Label>
              <Input
                type="number"
                className="w-28"
                value={year}
                onChange={(e) => setYear(Number(e.target.value))}
              />
            </div>
            <div className="flex items-center gap-2 pb-2">
              <Switch checked={overwrite} onCheckedChange={setOverwrite} id="overwrite-toggle" />
              <Label htmlFor="overwrite-toggle" className="text-sm font-normal">
                Overwrite existing allotted amounts
              </Label>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            {overwrite
              ? "Existing balances get the template's allotted amount; used and carryover hours are untouched."
              : "Employees who already have a balance for a leave type this year are skipped."}
          </p>

          <div className="space-y-2">
            <div className="flex items-center gap-2">
              <div className="relative flex-1">
                <Search className="h-4 w-4 absolute left-2 top-2.5 text-muted-foreground" />
                <Input
                  className="pl-8"
                  placeholder="Search employees…"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  const next = { ...selected };
                  filtered.forEach((p) => { next[p.id] = !allFilteredSelected; });
                  setSelected(next);
                }}
              >
                {allFilteredSelected ? "Clear" : "Select all"}
              </Button>
            </div>
            <div className="max-h-56 overflow-y-auto rounded-md border p-2 space-y-1">
              {filtered.map((p) => (
                <label key={p.id} className="flex items-center gap-2 text-sm py-0.5 cursor-pointer">
                  <Checkbox
                    checked={!!selected[p.id]}
                    onCheckedChange={(v) => setSelected((s) => ({ ...s, [p.id]: !!v }))}
                  />
                  {mask.name(p.id, personDisplayName(p) ?? p.id)}
                </label>
              ))}
              {filtered.length === 0 && (
                <p className="text-sm text-muted-foreground p-2">No matches.</p>
              )}
            </div>
            <p className="text-xs text-muted-foreground">{selectedIds.length} selected</p>
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={handleClose}>Cancel</Button>
          <Button
            onClick={() => apply.mutate()}
            disabled={apply.isPending || selectedIds.length === 0}
          >
            {apply.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : `Apply to ${selectedIds.length}`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

(`personDisplayName` import verified: same as ChecklistsTab — `@/lib/sortByName`.)

- [ ] **Step 2: Verify compile + lint**

Run: `npx eslint src/components/desks/hris/ApplyLeaveTemplateDialog.tsx`
Expected: only repo-conventional `no-explicit-any` errors, nothing else.

- [ ] **Step 3: Commit**

```bash
git add src/components/desks/hris/ApplyLeaveTemplateDialog.tsx
git commit -m "feat(hris): apply leave template dialog with skip/overwrite"
```

---

### Task 5: Wire tab into HRIS desk + PR

**Files:**
- Modify: `src/components/desks/hris/HrisDeskContent.tsx`

**Interfaces:**
- Consumes: `LeaveTemplatesTab` from Task 3.
- Produces: "Leave Templates" tab visible to `desks.hris.manage` / admin.

- [ ] **Step 1: Add tab**

In `HrisDeskContent.tsx`:
- Add import: `import { LeaveTemplatesTab } from "./LeaveTemplatesTab";`
- Add icon to the lucide import: `CalendarPlus`
- Extend `TabKey`: `type TabKey = "my-hr" | "time-off" | "directory" | "checklists" | "comp" | "leave-templates";`
- Add to `tabs` array after the checklists entry:

```tsx
    { key: "leave-templates", label: "Leave Templates", icon: CalendarPlus, show: canManage },
```

- Add render line after the checklists line:

```tsx
      {tab === "leave-templates" && canManage && <LeaveTemplatesTab />}
```

- [ ] **Step 2: Full verification**

Run: `npx vitest run src/components/desks/hris/`
Expected: PASS (existing csv tests + new leaveTemplates tests)
Run: `npx eslint src/components/desks/hris/HrisDeskContent.tsx`
Expected: no new errors
Run: `npm run build`
Expected: build succeeds

- [ ] **Step 3: Commit + PR**

```bash
git add src/components/desks/hris/HrisDeskContent.tsx
git commit -m "feat(hris): wire Leave Templates tab into HRIS desk"
git push -u origin hris-leave-templates
gh pr create --title "feat(hris): leave structure templates" --body "Per spec docs/hris/leave-templates-design-2026-07-14.md (Dev repo). Tables + RLS + apply RPC (migration NOT yet applied to prod), Leave Templates tab (manage/admin), apply dialog with skip/overwrite. Employees unaffected until a template is applied."
```

---

### Task 6: Prod verification (after user approves migration apply)

**Files:** none (SQL against prod via Supabase MCP)

**Interfaces:**
- Consumes: migration from Task 1 applied to prod (USER-GATED — do not apply without explicit user approval).

- [ ] **Step 1: Apply migration** (user-approved) via `mcp__supabase__apply_migration`, name `hris_leave_templates`, query = Task 1 SQL.

- [ ] **Step 2: Verify RPC end-to-end with disposable data**

```sql
-- create test template
insert into hris_leave_templates (name, hours_per_day) values ('__test_tpl', 8) returning id;
-- add item (use an active leave type id from: select id from hris_leave_types where is_active limit 1)
insert into hris_leave_template_items (template_id, leave_type_id, days) values ('<tpl_id>', '<type_id>', 15);
-- apply to one employee (akshar id 087240c8-95c2-4e90-aa74-c3f35688fa8d), year 2099 to avoid touching real data
select hris_apply_leave_template('<tpl_id>', array['087240c8-95c2-4e90-aa74-c3f35688fa8d']::uuid[], 2099, false);
-- expect {"created":1,"updated":0,"skipped":0}
select allotted_hours from hris_leave_balances where employee_id='087240c8-95c2-4e90-aa74-c3f35688fa8d' and year=2099;
-- expect 120
-- re-apply without overwrite: expect skipped 1
select hris_apply_leave_template('<tpl_id>', array['087240c8-95c2-4e90-aa74-c3f35688fa8d']::uuid[], 2099, false);
-- cleanup
delete from hris_leave_balances where year = 2099;
delete from hris_leave_templates where name = '__test_tpl';
```

- [ ] **Step 3: Browser walkthrough** — HRIS → Leave Templates: create template, add items, apply to a test employee for current year, confirm toast counts and Directory balances.
