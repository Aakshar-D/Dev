# 04 — Data Model

## Migration tracks

Two parallel tracks exist:

| Track | Location | How run |
|-------|----------|---------|
| Hand-run SQL | `linkedalliance/docs/*.sql` | Run manually in Supabase SQL Editor by the admin |
| Versioned migrations | `linkedalliance/supabase/migrations/*.sql` | Managed via Supabase CLI (`supabase db push`) |

The `docs/` track predates the versioned migrations; both are authoritative for their respective schema areas.

---

## RLS patterns (consistent across tables)

Every table that holds user or org data follows this policy pattern:

```sql
-- Read: active users only
USING (is_active_user(auth.uid()))

-- Writes: admin-only (or specific permission)
WITH CHECK (has_role(auth.uid(), 'admin'::app_role))

-- Block pending users (RESTRICTIVE — applied on top of all other policies)
AS RESTRICTIVE FOR ALL TO authenticated
USING (is_active_user(auth.uid()))
WITH CHECK (is_active_user(auth.uid()))
```

The RESTRICTIVE "block pending users" policy is present on every significant table. It acts as a hard gate regardless of any permissive policies — a `status = 'pending'` user passes no RLS checks.

Helper functions (from legacy RBAC migration, still in use for RLS):
- `is_active_user(uid)` — returns true if `profiles.status = 'active'`
- `has_role(uid, app_role)` — checks legacy role enum
- `has_permission(uid, key)` — checks legacy permissions table

---

## Entity catalog by domain

### Identity & Auth

| Table / Object | Key columns | Notes |
|----------------|------------|-------|
| `profiles` | `id` (= auth.uid()), `role_id` (legacy), `manager_id`, `secondary_email`, `tags[]`, `status` (`pending`/`active`/`inactive`), `mcp_api_token*` | Extended by multiple migrations; `role_id` is legacy FK (not yet dropped) |
| `custom_roles` | `id`, `name`, `description`, `color`, `is_system` | Seeded with 10 fixed-UUID roles |
| `role_permissions` | `role_id` → `custom_roles`, `permission_key` text | String-keyed; UNIQUE(role_id, permission_key) |
| `user_role_assignments` | `user_id` → `profiles`, `role_id` → `custom_roles`, `assigned_by`, `assigned_at` | One role per user — UNIQUE(user_id) |
| `roles` | (legacy) | Old FK-based roles table; `app_role` enum: Admin/Member/Viewer; not yet dropped |
| `permissions` | (legacy) | Old FK-based permissions; not yet dropped |

**Invite / onboarding:**

| Table | Purpose |
|-------|---------|
| `invite_tokens` | Stores invite tokens; claimed via `claim-invite` edge function |
| `pending_users` / `pending_no_role` | Tracks users awaiting admin approval; managed in `/admin/users → PendingUsersQueue` |

### OAuth (MCP connector)

Managed by `supabase/migrations/20260610130000_oauth_as.sql`:

| Table | Purpose |
|-------|---------|
| `oauth_clients` | Registered OAuth client apps (DCR RFC 7591) |
| `oauth_access_tokens` | Issued access tokens; SHA-256 hash stored; includes expiry, scopes |
| `oauth_refresh_tokens` | Refresh tokens |
| (auth codes) | Short-lived; issued by `hub-oauth`, consumed immediately |

---

### Projects & Tasks

| Table | Key columns / Notes |
|-------|---------------------|
| `projects` | `id`, `name`, `status`, `org_id`, `template_id`, members via `project_members` |
| `project_members` | `project_id`, `user_id`, `role` |
| `tasks` | `id`, `project_id`, `title`, `status`, `priority`, `assignee_id`, `due_date`, `sync_source` (`ninety`/null), `ninety_id`, `_sync_lock` (prevents Ninety.io sync loops) |
| `subtasks` | `task_id`, `title`, `completed` |
| `task_comments` | `task_id`, `user_id`, `content`, `mentions` |
| `task_attachments` | `task_id`, file metadata |
| `task_automations` | Automation rules (trigger → action) per project or global |
| `recurring_tasks` | Recurrence rules; generates task instances via `src/lib/recurrence.ts` |
| `task_saved_views` | `user_id`, filters/grouping/sort config |
| Project templates | Admin-managed; `projects.create_from_template` permission |
| Checklists | `checklist_assignments`, checklist templates; synced to tasks via `src/lib/checklistTaskSync.ts` |

---

### Check-ins & Performance

| Table | Key columns / Notes |
|-------|---------------------|
| `checkins` | `id`, `user_id`, `assignment_id`, `responses` (JSON), `mood` (presence head), `status` (draft/submitted), `submitted_at` |
| `checkin_edit_log` | Append-only log of edits to submitted check-ins |
| `nine_box_scores` | `id`, `subject_user_id`, `placed_by`, `x_axis` (performance), `y_axis` (potential), `cell_label`, `created_at` — **no UPDATE or DELETE RLS policy** (immutable by design) |

---

### Documents

| Table / Area | Notes |
|--------------|-------|
| `documents` | `id`, `name`, `folder_id`, `visibility` (alliance/org/private), `created_by`, `org_id`, file storage reference |
| Folder tables | Hierarchical folder structure |
| Sharing/visibility | Explicit per-user grants beyond tier-based visibility; `documentPermissions.ts` computes effective access |
| Recycle bin | Soft-delete pattern; restore available |
| Storage | Supabase Storage; policies in `fix-storage-policies.sql` |

---

### Tickets & SSG

| Table | Notes |
|-------|-------|
| `tickets` | `id`, `ticket_number` (`LAA-#`), `category_id`, `status`, `priority`, `assignee_id`, `created_by` |
| `ticket_messages` | Threaded messages; `is_internal` flag for internal notes |
| `ticket_categories` | Admin-managed categories |
| SSG tables | Capacity status, services, team assignments |

---

### Vendors, RFP & Agreements

| Table | Notes |
|-------|-------|
| `vendors` | `id`, `name`, contacts, tags, notes |
| `rfp_posts` | RFP listings with service type and status |
| `laa_recipient_rules` | Profession-based referral compliance rules (rules engine data) |
| `agreements` | Generated referral agreements; status lifecycle (draft → pending → approved/rejected) |
| `agreement_log` | Audit log of agreement lifecycle events, term changes |

---

### Notifications & Inbox

| Table | Notes |
|-------|-------|
| `notifications` | `id`, `user_id`, `type`, `read`, `payload` JSON — expanded by `notification-types-expansion-migration.sql` |
| `inbox_items` | Inbox/action items |
| Comment mentions | `task_comments` triggers generate `notifications` for `@mention`ed users |

---

### Activity / Audit Log

| Table | Notes |
|-------|-------|
| `activity_logs` | `id`, `user_id`, `action` (string key), `target_type`, `target_id`, `metadata` JSON, `created_at` |

Written via `src/lib/activityLogger.ts` → `logActivity()`. Surfaced in Admin → Activity Log. Insert policy fixed by `fix-activity-logs-insert-policy.sql`.

---

### Email Connections

| Table | Notes |
|-------|-------|
| `email_connections` | `id`, `user_id`, `provider` (google/microsoft), `scopes[]`, `google_email`/`account_email`, `is_active`, encrypted token fields |

One row per user per provider. Scopes determine what the connection can do (calendar.readonly, gmail.readonly, compose). Tokens encrypted via `_shared/gmail-crypto.ts` edge-function util.

---

### Desks (BDR / SDR / Client Expansion / SSG)

| Table | Notes |
|-------|-------|
| `bdr_batches` | BDR prospect batches |
| `bdr_prospects` | Individual prospects in the pool |
| `sdr_batches` | SDR firm batches/queues |
| `sdr_contacts` | SDR contact records |
| `expansion_opportunities` | Client expansion opportunities with scoring, tier, status, email_status, research freshness |
| `ssg_engagements` | SSG engagement records (client, service_line, status, assigned advisor) |
| `ssg_calendar_events` | Synced Google Calendar events matched to engagements |
| `ssg_emails` | Synced Gmail threads (by `gmail_thread_id`) |
| `ssg_meetings` | Meetings with transcripts/recordings (`recording_url`, AI-generated signals) |

---

### Marketing Website Desk (staging)

| Table | Notes |
|-------|-------|
| `firm_candidates` | Staging table: all firm data + JSON arrays for team/services/locations/industries. Written by scraper/intake. |
| `organizations` (live) | Production firm records (promoted from candidates) |
| `team_members` (live) | Relational; normalized from candidate JSON |
| `firm_services` (live) | Normalized services |
| `firm_locations` (live) | Normalized locations |
| `firm_industries` (live) | Normalized industries |

The `promote-firm-candidate` edge function fans a staged candidate row into the live tables.

---

### Platform primitives

| Feature | Tables / Notes |
|---------|----------------|
| **Desks registry** | `desks` table — slug, label, `permission_key`, description; managed in `/admin/desks` |
| **Custom fields** | `custom_field_definitions`, `custom_field_values` — per-entity extensible fields |
| **Service catalog** | `service_catalog` — alliance service definitions |
| **Data registry** | Reference data managed by admins |
| **Quick links** | Admin-curated shortcuts surfaced in the sidebar |
| **Pins / favorites** | User-scoped pins on any pinnable entity |
| **Kanban board** | Board configurations per project |
| **User home layouts** | `user_home_layouts` — widget order/visibility per user |
| **Saved views** | `task_saved_views` — filter/sort/group configs |
| **Nine-box** | `nine_box_scores` — see Performance above |
| **W9 uploads** | `w9-upload-migration.sql` — document storage for W9 forms |
