# Live Demo Script — Hub Presentation (Friday, June 26)

Context: Live Claude Code demo in front of Jacob, James, Trey, Trevis.
Goal: Show that Claude Code can answer real architectural questions about the codebase
      by actually reading it, not from a memorized answer.
Duration: ~5–7 minutes including narration.

---

## Setup (before the meeting)

1. Open a terminal in `C:\Users\aksha\Dev\linkedalliance\`
2. Have Claude Code ready (`claude` in the terminal, or the desktop app)
3. Optional: have `src/pages/Tasks.tsx` open in an editor so you can show the exact line when Claude finds it

---

## Primary prompt

Paste this into Claude Code verbatim:

```
Trace how creating a new task is authorized in this codebase.
Start from the button a user clicks in the UI and follow it
all the way down to the database. Show me file paths and line
numbers at each step.
```

---

## What Claude should find (expected answer)

Claude should surface these in order:

| Layer | Expected finding | File:line |
|-------|-----------------|-----------|
| UI entry | "New Task" button, `onClick=handleCreateNewTask` | `src/pages/Tasks.tsx:1215` |
| Permission check | No `usePermission("tasks.create")` call — the permission key is defined in the catalog but not enforced here | `src/components/admin/RolesAdminTab.tsx:69` |
| Data mutation | `db.from("tasks").insert(...)` sets `assigned_by = effectiveUserId` | `src/pages/Tasks.tsx:681` |
| RLS INSERT policy | `"Active users can create tasks"` WITH CHECK `is_active_user AND assigned_by = auth.uid()` | `docs/tasks-migration.sql:96-103` |
| RESTRICTIVE block-pending | `AS RESTRICTIVE FOR ALL` `USING (is_active_user(auth.uid()))` | `supabase/migrations/20260609120000_tasks_rls_shared_access_model.sql:262-267` |

---

## Narration notes (what to say while Claude works)

- "I'm not telling Claude anything — it's reading the codebase right now."
- When Claude finds the button: "That's the exact line. The New Task button in Tasks.tsx."
- When it notes no permission gate: "This is actually interesting — the permission key exists in the RBAC catalog but isn't checked at the UI layer. The real gate is the database."
- When it surfaces the RLS policy: "This is what actually authorizes the insert. The rule requires `assigned_by = auth.uid()` — which is why the client code sets `assigned_by = self` before inserting."
- When it finds the RESTRICTIVE policy: "That second policy is why the block-pending gate works. It was PERMISSIVE before — and that caused the incident I covered in the Feature Trace slide."

**The punchline to deliver:** "The Hub's security model is DB-first. The React components are presentation. The database enforces the rules."

---

## Backup prompts (if Claude wanders)

If the primary query produces noise or Claude starts hallucinating:

**Backup A:** Narrow to the permission question:
```
Where is the tasks.create permission key enforced in this codebase?
Search for usePermission("tasks.create") or PermissionGate with tasks.create.
```

**Backup B:** Go straight to the DB layer:
```
Show me the RLS INSERT policy on the public.tasks table.
Look in supabase/migrations/ and docs/tasks-migration.sql.
```

**Backup C:** If you just want to show Claude reading code:
```
What are the seeded RBAC roles in this codebase, and which one
gets the "*" wildcard for all permissions? Show me the table name
and how the get_user_permissions function works.
```
Expected answer: `custom_roles` table, `is_system = true` roles (Admin) → RPC returns `["*"]`, resolved in `usePermissions.tsx`.

---

## After the demo

Segue to slide 24 (My First Feature):
> "That's what Claude Code does on day one. Now let me show you what building something would look like using everything we just covered."
