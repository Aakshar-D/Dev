# HRIS — Leave Request Notifications + Email Approve/Reject (Design Spec)

**Date:** 2026-06-30
**Status:** Approved for planning
**Depends on:** HRIS Phase 1 (live) — `hris_leave_requests` (with `approver_id`, `status`,
`decided_by`, `decided_at`, the balance-decrement trigger), `profiles` (`manager_id`, `email`,
`full_name`). Existing email infra: Resend via Supabase edge functions, the `notifications` table
(+ Bell), and `user_notification_preferences`.

## Context

Today a leave request inserts silently (`TimeOffTab` `requestLeave`) — the manager learns of it only
by opening the desk. This adds: on submit, email + in-app-notify the manager with **one-click
Approve/Reject** buttons that act without logging in; and on any decision, email the requester the
outcome. It reuses the hub's existing send path (Resend), the `notifications` Bell, and
notification-preferences, adding one token table and three edge functions.

Locked decisions:
- Dedicated **edge functions** (not pure client-side), invoked from `TimeOffTab` after the
  insert/decision.
- Email Approve/Reject via a **single-use, 14-day-expiry token** (only the SHA-256 hash stored).
- **Prefetch-safe two-step**: the email button is a GET link to a read-only confirm page; a Confirm
  button POSTs to commit (so an email scanner prefetching the GET link can't auto-decide).
- `decided_by` on an email approval = the manager the token was issued to (no login).
- On submit: manager email **+** in-app Bell. On decision: requester email.

## Data model

### Migration `20260630140000_hris_leave_action_tokens.sql` (additive)
```sql
CREATE TABLE IF NOT EXISTS public.hris_leave_action_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  leave_request_id uuid NOT NULL REFERENCES public.hris_leave_requests(id) ON DELETE CASCADE,
  manager_id uuid NOT NULL REFERENCES public.profiles(id),   -- authorized approver; becomes decided_by
  token_hash text NOT NULL UNIQUE,                            -- sha256 hex of the emailed secret
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hlat_request ON public.hris_leave_action_tokens(leave_request_id);
ALTER TABLE public.hris_leave_action_tokens ENABLE ROW LEVEL SECURITY;
-- No policies: only service-role edge functions read/write this table. Clients never touch it.
```
One token row per (request, manager) created at submit; both Approve and Reject email links carry
the same secret with `&action=approve|deny`. The token authorizes "this manager may decide this
request once." `ON DELETE CASCADE` cleans tokens if a request is deleted.

## Edge functions (Deno, `supabase/functions/`)

All follow the existing structure (Resend POST to `https://api.resend.com/emails`, from
`Linked Accounting Alliance <hub@linkedalliance.co>`, `RESEND_API_KEY`; service-role Supabase client
via `SUPABASE_SERVICE_ROLE_KEY`). Reuse the branded HTML wrapper used by `send-notification-email`.

### A. `notify-manager-leave-request`
- **Invoked:** client-side from `TimeOffTab` submit `onSuccess`, body `{ leave_request_id }`. Auth:
  verify the caller (`Authorization` header → `getUser()`), confirm the request's `employee_id` is
  the caller (an employee can only trigger a notice for their own request) — else 403.
- **Steps:** load the request + employee profile + manager profile (`approver_id`, fall back to the
  employee's `profiles.manager_id`). If no manager or no manager email → return `{skipped:"no_manager"}`
  (no error). Generate a 32-byte random secret (`crypto.getRandomValues`), hex-encode; store its
  SHA-256 in `hris_leave_action_tokens` (`expires_at = now + 14 days`). Build the manager email:
  employee name, leave type, dates, hours, reason, and two buttons →
  `${PUBLIC_HUB_URL}/functions/v1/leave-action?token=<secret>&action=approve` and `...&action=deny`.
  POST to Resend. Insert an in-app `notifications` row (`user_id=manager`, `actor_id=employee`,
  `type="leave_request_submitted"`, `title`, `link="/desks/hris"`). Respect
  `user_notification_preferences` (`email_leave_request_submitted=false` → skip email, still Bell).
- Returns `{ ok: true }`; all failures are non-fatal to the caller (fire-and-forget).

### B. `leave-action` (public, token-gated, prefetch-safe)
- **GET** `?token&action`: validate token (hash lookup, `used_at IS NULL`, `expires_at > now`); if
  invalid/used/expired → branded page saying so (+ link to the app). If valid → render a read-only
  **confirmation page**: request summary + "Confirm Approve" / "Confirm Reject" button that POSTs
  back to this function with the token + action in the form body. **No DB write on GET.**
- **POST** (form submit from the confirm page): re-validate the token (single-use guard: re-check
  `used_at IS NULL` inside the update); set the request `status` (`approved`/`denied`),
  `decided_by = token.manager_id`, `decided_at = now()`, `decision_note = 'via email'`; set the
  token's `used_at = now()` (do this atomically — `UPDATE ... WHERE used_at IS NULL` and treat 0 rows
  as "already used"). The Phase-1 balance trigger fires on approve. Then invoke
  `notify-employee-leave-decision` (`{ leave_request_id }`). Render a branded result page
  ("Leave approved ✓" / "Leave rejected"). Service-role client (bypasses RLS, which is why the
  token check is the security boundary).
- CORS/headers per existing public functions; this one needs no `Authorization` (token IS the auth).

### C. `notify-employee-leave-decision`
- **Invoked** from BOTH decision paths: (1) `TimeOffTab` `decide` `onSuccess` (in-app approve/deny),
  (2) `leave-action` POST. Body `{ leave_request_id }`. Loads request + employee; emails the employee
  the outcome (approved/denied, by whom if available, dates) via Resend; inserts a `notifications`
  row for the employee (`type="leave_request_decided"`, `link="/desks/hris"`). Respects
  `user_notification_preferences` (`leave_request_decided`). Idempotency: safe to call once per
  decision; if called twice (e.g. both paths somehow fire) it just sends twice — acceptable, but the
  two paths are mutually exclusive per request.

## Frontend wiring (`src/components/desks/hris/TimeOffTab.tsx`)

- **Submit** (`requestLeave.onSuccess`, after the existing `logActivity` + invalidate): if a manager
  exists, `supabase.functions.invoke("notify-manager-leave-request", { body: { leave_request_id: row.id } }).catch(() => {})`
  — fire-and-forget; email failure never blocks the request.
- **Decision** (`decide.onSuccess`, the in-app approve/deny): `supabase.functions.invoke("notify-employee-leave-decision", { body: { leave_request_id: <id> } }).catch(() => {})`.
- No change to the insert/decision DB writes themselves; notifications are purely additive.

## Config / secrets (already present, verify)
`RESEND_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`. New: a `PUBLIC_HUB_URL` (or reuse the
existing public base URL the other emails use for links) for the action-button absolute URLs.

## Security notes
- Token: 32 random bytes, only SHA-256 hash persisted; single-use (atomic `used_at` guard); 14-day
  expiry. A leaked/forwarded link can decide the request once within 14 days — acceptable per the
  approve-by-email design; mitigated by single-use + expiry.
- GET is side-effect-free (prefetch-safe); only the explicit POST commits.
- `notify-manager-leave-request` verifies the caller owns the request (no spoofing another employee's
  submission notice).
- `leave-action` runs service-role; the token is the sole authorization — validated before any write.

## Verification
1. **Migration**: applies; `hris_leave_action_tokens` exists with RLS enabled and no policies;
   `node scripts/check-supabase-security.mjs` flags no anon access.
2. **Build/lint/tests**: `npm run build`, `npm run test` green. Unit-test any pure helper (e.g. the
   email-HTML builder or token hashing) if extracted; edge-fn logic is integration-tested manually.
3. **E2E** (against live, after deploy of functions + migration):
   - Employee submits leave → manager receives the email (Approve/Reject buttons) + a Bell entry;
     no manager set → no email, no error.
   - Click Approve link → confirm page (no change yet) → Confirm → request shows `approved`,
     `decided_by` = manager, balance decremented; employee gets the decision email. Re-click the link
     → "already decided." After 14 days → "expired."
   - Click Reject → `denied`, employee emailed.
   - In-app approve/deny in the queue → employee still gets the decision email (path 2).
   - Manager with `email_leave_request_submitted=false` pref → Bell only, no email.

## Out of scope
- Reminders/escalation if the manager doesn't act (could be a later cron).
- Editing/withdrawing a request after submit re-notifying.
- Multi-level approval chains (single manager only).
