# 02 — Feature Modules

Each section: **Route → Page file | Problem | Who | Workflow | Key tables/notes**

---

## Dashboard / Home

**Route:** `/` → `src/pages/Dashboard.tsx`

**Problem:** Members need a personalized landing page showing what matters to them, not a generic home screen.

**Who:** All authenticated members.

**Workflow:** On load, fetches the user's `user_home_layouts` record (or creates default). Renders a customizable widget stack from the widget registry (`src/lib/home/registry.ts`). A "Customize" panel (`HomeCustomizePanel`) lets users add, remove, and reorder widgets. Widget examples include task counts, recent projects, announcements, check-in status.

**Key tables:** `user_home_layouts`

---

## CRM & Directory

### Members
**Route:** `/members` → `src/pages/Members.tsx`

**Problem:** No shared view of who works across all alliance firms.

**Who:** All members (viewer: read-only).

**Workflow:** Browse/search people by name, org, or type → profile cards showing title, firm, contact info, SSG assignments → click through to user detail.

### Companies
**Route:** `/companies` → `src/pages/Companies.tsx`

**Problem:** No shared directory of member firms and organizations.

**Who:** All members.

**Workflow:** Browse firm cards → firm detail view: contacts, services offered, HQ, revenue, people → shortcuts to org chart and software stack.

### Org Chart
**Route:** `/org-chart` → `src/pages/OrgChart.tsx`

**Problem:** Alliance org hierarchy isn't visible across firms.

**Who:** All members (`orgchart.view`); admins manage (`orgchart.manage`).

**Workflow:** Hierarchical chart view of people and reporting lines across organizations. Admin tab for managing relationships.

### Vendors
**Route:** `/vendors` → `src/pages/Vendors.tsx`

**Problem:** External supplier contacts aren't centralized.

**Who:** All members read (`vendors.view`); permissioned users create/edit/delete.

**Workflow:** Vendor list with contacts, tags, notes. Permission-gated edits.

**Key tables:** `vendors`

---

## Work & Project Management

### Work (primary hub)
**Route:** `/work` → `src/pages/Work.tsx` _(56KB — edit carefully)_

**Problem:** Alliance needs shared project/task tracking across firms and engagement types.

**Who:** Members and partners with project/task permissions.

**Workflow:** Main work hub. Supports project board (list or kanban view per project), task list, inbox panel, and an onboarding/overdue dashboard. Deep-links: `/work?panel=<projectId>` opens a project board directly; `?taskId=` opens a task detail. Projects have members, checklists, status, templates. Tasks have status, priority, assignee, due date, subtasks, comments, attachments, automations, and recurrence rules.

**Key tables:** `projects`, `project_members`, `tasks`, `subtasks`, `task_comments`, `task_attachments`, `task_automations`, `recurring_tasks`, `task_saved_views`

### Tasks (My Tasks)
**Route:** `/tasks` → `src/pages/Tasks.tsx`

**Who:** All members.

**Workflow:** Personal task view: list or kanban grouped by status/project/due date. Saved views (filters + grouping persisted per user). Bulk actions. Task automations.

### Projects (legacy redirect)
**Route:** `/projects` → `src/pages/Projects.tsx`

Redirects to `/work`, preserving `?id` and `?taskId` deep-link params for backward compatibility.

### Shared Project (external)
**Route:** `/shared/project/:token` → `src/pages/SharedProject.tsx`

**Who:** Non-members (no login required).

**Workflow:** Read-only view of a project's tasks and comments, accessed via a share token. Allows external clients to view progress without an account.

---

## Performance / Talent

### My Check-Ins
**Route:** `/my-check-ins` → `src/pages/MyCheckIns.tsx` _(59KB — edit carefully)_

**Problem:** No structured mechanism for recurring 1:1s and performance documentation.

**Who:** Members (submit check-ins); managers/leaders (review).

**Workflow:** Assignments define: template (structured question set), cadence (weekly/biweekly/monthly), and assigned manager. Assignee submits periodic check-ins: fill out template responses, set a "presence head" mood signal, save as draft or submit. Previous submissions are viewable.

**Key tables:** `checkins`, `checkin_edit_log`

### Leader / 9-Box
**Route:** `/leader` → `src/pages/Leader.tsx`

**Who:** Managers and leadership (`performance.view_own_team`, `performance.view_org`).

**Workflow:** Shows team members' submitted check-ins for review. Includes the **9-box talent grid** — a two-axis (performance × potential) matrix. Leaders place reports into one of 9 cells (Star, Potential Gem, High Performer, Core Player, etc.). Scores are append-only/immutable for audit integrity.

**Key tables:** `nine_box_scores` (immutable — no UPDATE/DELETE policy by design)

---

## Help Desk & Shared Services

### Tickets
**Route:** `/tickets` → `src/pages/Tickets.tsx`; `/tickets/:id` → `src/pages/TicketDetail.tsx`

**Problem:** Member firms need a formal channel to request support from the alliance.

**Who:** All members submit (`tickets.view_own`, `tickets.create`); SSG Members manage (`tickets.view_all`, `tickets.assign`, etc.).

**Workflow:** Submit a ticket with category, priority, and description → ticket assigned a `LAA-#` number → SSG staff triage (assign, change status: open → in-progress → resolved → closed) → threaded messages in detail view → notifications on status changes and new messages.

**Key tables:** `tickets`, `ticket_messages`

### Shared Services (SSG Marketplace)
**Route:** `/shared-services` → `src/pages/SharedServices.tsx`

**Problem:** Members don't know what shared services are available, at what capacity, and at what cost.

**Who:** All members (`ssg.view`); SSG team manages (`ssg.manage_team`, `ssg.view_rates`).

**Workflow:** Browse SSG functions (advisory, accounting, technology, etc.) → each shows capacity status (Accepting / Limited / Full) and blended rates → submit a ticket to engage a service. Admins manage via `/admin/ssg`.

---

## Knowledge & Content

### Knowledge Base
**Route:** `/knowledge-base` → `src/pages/KnowledgeBase.tsx`

**Problem:** Alliance policies, guides, and how-tos are scattered.

**Who:** All members read (`kb.view`); Content Editors and above write.

**Workflow:** Articles organized by category. Rich-text editor (TipTap). Archive/restore. Page-key anchors for deep links from other modules (e.g. desks link to relevant KB pages via `KbPageKey`).

**Key tables:** `kb_articles` (inferred from migrations)

### Announcements
**Route:** `/announcements` → `src/pages/Announcements.tsx`

**Who:** All members read; Content Editors and above create/edit/delete.

**Workflow:** Feed of org-wide announcements. Rich-text content. Archive/restore.

### Documents
**Route:** `/documents` → `src/pages/Documents.tsx`

**Problem:** No centralized, permission-controlled document library.

**Who:** Read access tiered by visibility (alliance / org / private). Upload: all members. Manage: permissioned roles.

**Workflow:** Folder tree navigation → upload files → set visibility tier (alliance-wide / org-scoped / private) → share with specific users → recycle bin for soft deletes → favorites. Effective visibility is computed per user based on their org and explicit grants.

**Key tables:** `documents`, folder structure tables, visibility/sharing tables

---

## Software Spend Management

**Route:** `/software` → `src/pages/Software.tsx`

**Problem:** Firms can't benchmark SaaS tools and pricing across the alliance.

**Who:** Members with `software.view`; pricing data is permission-gated for sensitivity.

**Workflow:**
1. **Comparison matrix** — see which tools are used by which firms.
2. **Per-firm stacks** — view or manage a firm's full SaaS stack.
3. **Spend dashboard** — aggregate and per-firm spend visualization.
4. **Insights** — cost optimization observations.
5. **Catalog management** — admin creates/manages the software catalog.
6. **Onboarding checklist** — steps for evaluating and adopting a new tool.

---

## Referral Partner Compliance & Compensation

### Referral Partner Program (Compliance)
**Route:** `/referral-partner-program` → `src/pages/Compliance.tsx` _(imported as `ReferralPartnerProgram`)_

**Problem:** CPA referral arrangements have legal and ethical rules that vary by the partner's profession. Firms need compliant agreements and documented research.

**Who:** Admins/compliance staff configure rules; members generate agreements.

**Workflow:** Select partner's profession (attorney, banker, RIA, real-estate agent, etc.) → rules engine queries `laa_recipient_rules` → returns verdict (compliant / conditionally compliant / prohibited) with rationale and research sources → generate agreement document → track payout status.

**Key tables:** `laa_recipient_rules`, agreement tables (`agreement_status`, `agreement_log`)

### Referral Compensation Settings
**Route:** `/referral-compensation-settings` → `src/pages/ReferralCompensationSettings.tsx`

**Who:** Admins only.

**Workflow:** Define compensation tiers, percentage rates, and revenue-share rules applied when generating referral agreements.

---

## RFP Marketplace

**Route:** `/rfp-board` → `src/pages/RfpBoard.tsx`

**Problem:** Client work needing a specific service type has no structured way to reach the right firm.

**Who:** Members post and respond; admins oversee.

**Workflow:** Post an RFP (service type: tax, audit, CFO advisory, R&D, etc. + description) → board view with statuses (open → in-review → awarded → closed) → detail drawer for responses → award to a firm.

---

## Wealth Management Reporting

**Route:** `/wealth` → `src/pages/Wealth.tsx` (gated: `wealth.view`)

**Problem:** Wealth practices have no consolidated view of AUM, pipeline, and client accounts.

**Who:** Members with `wealth.view`; `wealth.view_all` to see across firms; sync access for data administrators.

**Workflow:** Sync status indicator → tabs: AUM report / opportunities / contacts / accounts → client detail sheet → firm-level settings (e.g. CRM connection). Data sourced from a CRM sync (HubSpot).

---

## Reporting & Analytics

### Reporting Hub
**Route:** `/reporting` → `src/pages/Reporting.tsx`

**Who:** Permissioned members/admins.

**Workflow:** Lists available dashboards as database-driven rows (each row has a title and route). Users navigate to specific dashboards.

### Member Firm Pipeline
**Route:** `/reporting/member-firm-pipeline` → `src/pages/ReportingMemberFirmPipeline.tsx`

HubSpot deal pipeline broken down by member firm: stages, sources, dollar amounts.

### Sales Performance
**Route:** `/reporting/sales-performance` → `src/pages/ReportingSalesPerformance.tsx`

Weekly sales activity tiles and deal metrics sourced from HubSpot.

---

## Platform & Admin

### Admin Console
**Routes:** `/admin`, `/admin/:section` → `src/pages/Admin.tsx` _(98KB — edit carefully; each tab is a component in `src/components/admin/`)_

Multi-tab hub with four nav groups (from `AdminLayout.tsx`):

**People:**
- Users (`/admin/users`) — invite, approve, deactivate, assign roles, manage org membership, impersonation, pending users queue, merge users
- Companies (`/admin/companies`) — firm records, HQ, services, revenue
- Org Chart (`/org-chart`) — links out to the org chart page

**Work:**
- Projects (`/admin/projects`) — project templates, assignments
- Checklists (`/admin/checklists`) — checklist templates and assignments
- Tickets (`/admin/tickets`) — all tickets, categories, SLA
- SSG (`/admin/ssg`) — SSG team management, capacity, services

**Content:**
- Documents (`/admin/documents`) — folder admin, visibility controls
- Quick Links (`/admin/quick-links`) — admin-managed shortcuts surfaced in the sidebar
- Announcements (`/admin/announcements`) — announcement management

**System:**
- Roles & Permissions (`/admin/roles`) — custom role CRUD, permission assignment
- Desks (`/admin/desks`) — register desk slugs, assign permission keys
- Service Catalog (`/admin/service-catalog`) — alliance service definitions
- Custom Fields (`/admin/custom-fields`) — per-entity custom field definitions
- Data Registry (`/admin/data-registry`) — reference data management
- Integrations (`/admin/integrations`) — HubSpot, Google, Ninety.io connection status
- MCP Connections (`/admin/mcp-connections`) — view active AI connector sessions, revoke
- Activity Log (`/admin/activity`) — audit trail of all `logActivity()` events

### Profile
**Route:** `/profile` → `src/pages/Profile.tsx`

Tabs: personal info, notification preferences, appearance (theme), security (password change), API access (personal MCP token), email connection (Gmail/Google Calendar OAuth).

### Release Notes
**Route:** `/release-notes` → `src/pages/ReleaseNotes.tsx`

Auto-generated changelog from commits/PRs. Shows tiers, SHAs, summaries. Managed via `.github/workflows/release-notes.yml`.

### Claude OAuth Consent
**Route:** `/authorize` → `src/pages/ConnectClaude.tsx`

OAuth 2.1 authorization consent page. When a Claude AI client initiates connection, this page presents the consent prompt, the user approves, and the hub issues a single-use auth code via the `hub-oauth` edge function. See [06-mcp-and-ai.md](06-mcp-and-ai.md).

---

## Public / Pre-auth Pages

| Route | Page | Notes |
|-------|------|-------|
| `/auth` | `Auth.tsx` | Login (email + Google + Microsoft) |
| `/auth/callback` | `AuthCallback.tsx` | OAuth redirect handler |
| `/reset-password` | `ResetPassword.tsx` | Password reset |
| `/setup-account` | `SetupAccount.tsx` | First-time password set |
| `/claim` | `ClaimInvite.tsx` | Invite token claim |
| `/shared/project/:token` | `SharedProject.tsx` | External project view (no login) |
| `*` | `NotFound.tsx` | 404 |
