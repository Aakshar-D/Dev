# Intake Widget — Design Spec

**Date:** 2026-07-20
**Status:** Approved (brainstorm session)
**Repo:** linkedalliance (submodule)

## Summary

Rebuild the floating "Share feedback" widget (`src/components/FeedbackWidget.tsx`)
into a general **intake widget** with three paths:

1. **Share feedback** — existing 3-step flow, unchanged (task in feedback project,
   assigned to Jacob).
2. **Helpdesk ticket** — embeds the existing `SubmitTicketForm`, creating a real
   ticket in the `/tickets` system.
3. **Request new project** — new flow: full request form → `project_requests` row →
   designated approver approves/rejects → real project created on approval.

## 1. Widget UX

- Floating action button unchanged (bottom-20 right-6 bubble).
- Click → dialog opens on **Step 0: type picker** — three cards:
  - 💬 Share feedback → existing StepOne/StepTwo/StepThree flow, untouched.
  - 🎟️ Helpdesk ticket → renders `SubmitTicketForm` inside the dialog.
    `onSuccess` shows a success view with a link to `/tickets`.
  - 📁 Request new project → new `ProjectRequestForm` (section 2).
- Component renamed `FeedbackWidget` → `IntakeWidget`
  (file `src/components/IntakeWidget.tsx`, usage in `App.tsx` updated).
- FAB hover label updated from "Share feedback" to broader wording
  (e.g. "Get help / share ideas" — final copy at build time).
- Back navigation from any path returns to the type picker.

## 2. Project request form

Requester fills the **full** shape (approver confirms/adjusts later):

| Field | Required | Source |
|---|---|---|
| Project name | yes | text input |
| Description / reason | yes | textarea |
| Template | no ("none" allowed) | `project_templates` |
| Assign to | yes (org **or** user) | `organizations` / `profiles` |
| Members | no | `profiles` multi-select |

Submit → insert into `project_requests` (status `pending`) → notify approver
(section 5). Success view: "Request sent for approval."

**RLS prerequisite:** requester (member role) must be able to read
`project_templates`, `organizations`, and `profiles` lists. Verify during build;
add read policies if missing.

## 3. Data model

New table `project_requests` (migration + RLS):

```sql
create table project_requests (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null,
  template_id uuid references project_templates(id),
  assigned_to_org uuid references organizations(id),
  assigned_to_user uuid references profiles(id),
  requested_members uuid[] default '{}',
  requested_by uuid not null references profiles(id),
  status text not null default 'pending', -- pending | approved | rejected
  rejection_reason text,
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  created_project_id uuid references projects(id),
  created_at timestamptz not null default now()
);
```

RLS:
- INSERT: any authenticated user, `requested_by = auth.uid()`.
- SELECT: requester sees own rows; designated approver + admins see all.
- UPDATE: designated approver + admins only (status transitions).

**Approver designation:** `app_settings` key `project_request_approver_id`
(single user id). Editable in Admin → Projects tab. When unset, approval falls
back to admins only. Approver does **not** need the admin role.

Nothing touches the `projects` table until approval — no `pending` project
status, no leak into project lists (`Work.tsx` query unchanged).

## 4. Approval flow

Location: Work/Projects page (`src/pages/Work.tsx` area).

- **Pending requests** section rendered only for the designated approver and
  admins. Requesters see their own requests' status inline (small badge/list).
- **Approve:** opens a dialog prefilled with the requested values (name,
  description, template, assignment, members). Approver can adjust anything,
  then confirms. Confirmation:
  1. Creates the real project via a shared creation function.
  2. Marks the request `approved`, sets `reviewed_by`, `reviewed_at`,
     `created_project_id`.
  3. In-app notification to the requester.
- **Reject:** reason dialog (required). Sets status `rejected` +
  `rejection_reason` + review fields. In-app notification to the requester with
  the reason.

**Refactor:** extract the project-creation side-effect logic from
`ProjectsAdminTab.createProject` (projects insert, creator-owner member,
Partner-role auto-add, template section/task instantiation) into
`src/lib/projects/createProject.ts`. Admin tab and the approval dialog both call
this one function — one code path.

## 5. Notifications

- **New request → approver:** in-app `notifications` insert (type
  `project_request_submitted`, link to Work page pending section) **plus email**
  via new edge function `project-request-notify` (follows the `helpdesk-notify`
  pattern).
- **Approve/reject → requester:** in-app only (types `project_request_approved`
  / `project_request_rejected`; rejection includes reason in the title/body).

## 6. Out of scope

- Feedback flow changes (kept byte-for-byte except container refactor).
- Screenshot upload (existing placeholder stays).
- Ticket system changes — `SubmitTicketForm` consumed as-is.
- Email notifications to requester on approve/reject.

## 7. Testing

- Vitest: request payload validation; approver resolution
  (app_settings value → fallback admins); extracted `createProject` preserves
  admin-tab behavior (member insert, partner auto-add, template instantiation).
- Manual QA: all three widget paths end-to-end; approve (with adjustments) and
  reject (with reason) flows; notifications received; RLS — non-approver cannot
  see others' requests.

## 8. Hub-feature questions (addendum 2026-07-20, approved)

The request form gains a **request type toggle** — "Hub feature" (default) / "Other
project". When Hub feature is selected, five questions render between description
and template:

| Question | Field | Required |
|---|---|---|
| What problem does it solve? | textarea | yes |
| Who will use it? (roles/teams) | text | no |
| Where in the hub does it belong? | text | no |
| What does done look like? | textarea | no |
| Urgency | select Low/Medium/High/Urgent | no |

Storage: two columns on `project_requests` (same unapplied migration):
`request_type text NOT NULL DEFAULT 'other' CHECK (IN ('hub_feature','other'))`
and `feature_answers jsonb` (`{problem, users, location, success, urgency}`,
null for "other"). Validation: hub_feature requires `problem`.

Approver view: "Hub feature" badge + read-only answers list on the pending card
and in the ApproveDialog. Notify email appends problem + urgency lines
(escaped, truncated). Ships in PR #279.

## Key files

- `src/components/FeedbackWidget.tsx` → `src/components/IntakeWidget.tsx`
- `src/components/tickets/SubmitTicketForm.tsx` (reused, untouched)
- `src/components/admin/ProjectsAdminTab.tsx` (createProject extraction)
- `src/lib/projects/createProject.ts` (new)
- `src/pages/Work.tsx` (pending requests section)
- `supabase/functions/project-request-notify/` (new edge function)
- Migration: `project_requests` table + RLS + `app_settings` key
