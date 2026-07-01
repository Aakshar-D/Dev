# HRIS Leave Notifications + Email Approve/Reject — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On leave submit, email + in-app-notify the manager with one-click Approve/Reject; on any decision, email the requester — reusing the hub's Resend edge-function infra.

**Architecture:** A single-use, hashed, 14-day token table backs prefetch-safe email actions. Three Deno edge functions: `notify-manager-leave-request` (submit → manager email+Bell), `leave-action` (token-gated GET confirm page → POST commits the decision), `notify-employee-leave-decision` (decision → requester email). `TimeOffTab` invokes them fire-and-forget.

**Tech Stack:** Supabase edge functions (Deno), Resend HTTP API, Postgres + RLS, React/TanStack (client wiring). No vitest for edge fns — verified by manual E2E.

**Spec:** `docs/hris/leave-notifications-spec.md`

## Global Constraints

- Edge-fn structure mirrors `supabase/functions/notify-ssg-manager/index.ts`: `import { createClient } from "https://esm.sh/@supabase/supabase-js@2";`, `corsHeaders` (`Access-Control-Allow-Origin: *`), `Deno.serve`, OPTIONS→ok. Service-role client via `SUPABASE_SERVICE_ROLE_KEY`; caller verification via `SUPABASE_ANON_KEY` + `Authorization` header → `auth.getUser()`.
- Email: POST `https://api.resend.com/emails`, `Authorization: Bearer ${RESEND_API_KEY}`, from `"Linked Accounting Alliance <hub@linkedalliance.co>"`. Reuse the branded HTML table structure from `notify-ssg-manager`.
- In-app: `supabase.from("notifications").insert({ user_id, actor_id, type, title, link })` (the `MyCheckIns` shape). `link` = `/desks/hris`.
- Notification types: `leave_request_submitted` (manager), `leave_request_decided` (employee). Respect `user_notification_preferences.preferences[\`email_${type}\`] === false` → skip email (still insert Bell).
- Tokens: 32 random bytes (hex secret); store only SHA-256 hex in `hris_leave_action_tokens.token_hash`; single-use (atomic `used_at` claim); `expires_at = now + 14 days`.
- Action link base = `${SUPABASE_URL}/functions/v1/leave-action`. GET = read-only confirm page; POST = commit (so prefetch can't decide).
- `decided_by` on email approval = the token's `manager_id`; `decision_note = 'via email'`.
- Migration additive; naming after `20260630130000`. Migration applied via dashboard/Management API (auto-mode blocks Bash prod DDL); edge functions deployed via `supabase functions deploy` (user/CI).
- Resolve employee/manager with separate `profiles` queries by id (avoid FK-alias uncertainty).

---

### Task 1: Token table migration

**Files:**
- Create: `linkedalliance/supabase/migrations/20260630140000_hris_leave_action_tokens.sql`

**Interfaces:**
- Produces: `public.hris_leave_action_tokens` (RLS on, no policies — service-role only).

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================
-- HRIS — single-use tokens for email Approve/Reject of leave requests.
-- Service-role only (RLS enabled, no policies). Additive.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.hris_leave_action_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  leave_request_id uuid NOT NULL REFERENCES public.hris_leave_requests(id) ON DELETE CASCADE,
  manager_id uuid NOT NULL REFERENCES public.profiles(id),
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_hlat_request ON public.hris_leave_action_tokens(leave_request_id);

ALTER TABLE public.hris_leave_action_tokens ENABLE ROW LEVEL SECURITY;
-- No policies: only service-role edge functions touch this table; authenticated/anon get nothing.
```

- [ ] **Step 2: Verify** — visual: FK to hris_leave_requests (CASCADE) + profiles; token_hash UNIQUE; expires_at/used_at present; RLS enabled; NO `CREATE POLICY` (intentional). `npx supabase db lint` if available.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/migrations/20260630140000_hris_leave_action_tokens.sql
git -C linkedalliance commit -m "feat(hris): leave-action token table (single-use email approve/reject)"
```

---

### Task 2: `notify-employee-leave-decision` edge function

**Files:**
- Create: `linkedalliance/supabase/functions/notify-employee-leave-decision/index.ts`

**Interfaces:**
- Invoked with body `{ leave_request_id }`. Emails the requester + inserts a Bell row. Idempotent enough to call once per decision.

- [ ] **Step 1: Implement**

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { leave_request_id } = await req.json();
  if (!leave_request_id) {
    return new Response(JSON.stringify({ error: "leave_request_id required" }), { status: 400, headers: corsHeaders });
  }

  const { data: reqRow } = await supabase
    .from("hris_leave_requests")
    .select("id, employee_id, status, start_date, end_date, hours, leave_type_id")
    .eq("id", leave_request_id).single();
  if (!reqRow) return new Response(JSON.stringify({ error: "request not found" }), { status: 404, headers: corsHeaders });

  const { data: emp } = await supabase
    .from("profiles").select("id, full_name, first_name, email").eq("id", reqRow.employee_id).single();
  if (!emp?.email) return new Response(JSON.stringify({ skipped: "no employee email" }), { headers: corsHeaders });

  // In-app bell
  await supabase.from("notifications").insert({
    user_id: emp.id, actor_id: null, type: "leave_request_decided",
    title: `Your leave request was ${reqRow.status}`, link: "/desks/hris",
  });

  // Email pref check
  const { data: prefRow } = await supabase
    .from("user_notification_preferences").select("preferences").eq("user_id", emp.id).maybeSingle();
  const prefs = (prefRow?.preferences ?? {}) as Record<string, boolean>;
  if (prefs["email_leave_request_decided"] === false) {
    return new Response(JSON.stringify({ success: true, skipped: "email disabled" }), { headers: corsHeaders });
  }

  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) return new Response(JSON.stringify({ error: "RESEND_API_KEY not set" }), { status: 500, headers: corsHeaders });

  const firstName = emp.first_name || emp.full_name?.split(" ")[0] || "there";
  const decided = reqRow.status === "approved" ? "approved" : "rejected";
  const subject = `Your leave request was ${decided}`;
  const html = `<!DOCTYPE html><html><body style="margin:0;padding:24px;background:#f4f6f9;font-family:Helvetica,Arial,sans-serif;">
    <table width="600" align="center" cellpadding="0" cellspacing="0" style="max-width:600px;background:#fff;border-radius:12px;padding:32px;">
      <tr><td>
        <h2 style="margin:0 0 12px;color:#1a2e4a;">Hi ${firstName},</h2>
        <p style="color:#4a5568;font-size:15px;">Your leave request (${reqRow.start_date} to ${reqRow.end_date}, ${reqRow.hours}h) was <strong>${decided}</strong>.</p>
        <p style="margin-top:24px;"><a href="${Deno.env.get("SUPABASE_URL")}" style="color:#2d9cc7;">Open the HRIS desk</a></p>
      </td></tr>
    </table></body></html>`;

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: "Linked Accounting Alliance <hub@linkedalliance.co>", to: [emp.email], subject, html }),
  });
  if (!r.ok) { console.error("Resend error", await r.text()); return new Response(JSON.stringify({ error: "email failed" }), { status: 500, headers: corsHeaders }); }

  return new Response(JSON.stringify({ success: true }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
});
```

- [ ] **Step 2: Verify** — visual: service-role client; loads request + employee by id (no FK alias); bell insert; pref check on `email_leave_request_decided`; Resend POST with the standard from-address; graceful skips (no email → skip, no error). No `npm` build (Deno fn; the app `npm run build` ignores supabase/functions).

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/functions/notify-employee-leave-decision/index.ts
git -C linkedalliance commit -m "feat(hris): notify-employee-leave-decision edge function"
```

---

### Task 3: `notify-manager-leave-request` edge function

**Files:**
- Create: `linkedalliance/supabase/functions/notify-manager-leave-request/index.ts`

**Interfaces:**
- Invoked (authenticated) with body `{ leave_request_id }`. Verifies the caller owns the request; generates a token; emails the manager Approve/Reject links; inserts the manager's Bell row.

- [ ] **Step 1: Implement**

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
  const callerClient = createClient(
    Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user: caller } } = await callerClient.auth.getUser();
  if (!caller) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { leave_request_id } = await req.json();
  if (!leave_request_id) return new Response(JSON.stringify({ error: "leave_request_id required" }), { status: 400, headers: corsHeaders });

  const { data: reqRow } = await supabase
    .from("hris_leave_requests")
    .select("id, employee_id, approver_id, start_date, end_date, hours, reason, leave_type_id")
    .eq("id", leave_request_id).single();
  if (!reqRow) return new Response(JSON.stringify({ error: "request not found" }), { status: 404, headers: corsHeaders });
  // Caller must own the request (no spoofing another employee's submission notice).
  if (reqRow.employee_id !== caller.id) return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: corsHeaders });

  // Resolve manager: approver_id, else the employee's profiles.manager_id.
  let managerId: string | null = reqRow.approver_id ?? null;
  if (!managerId) {
    const { data: empProfile } = await supabase.from("profiles").select("manager_id").eq("id", reqRow.employee_id).single();
    managerId = empProfile?.manager_id ?? null;
  }
  if (!managerId) return new Response(JSON.stringify({ skipped: "no manager" }), { headers: corsHeaders });

  const { data: manager } = await supabase.from("profiles").select("id, full_name, first_name, email").eq("id", managerId).single();
  const { data: emp } = await supabase.from("profiles").select("full_name").eq("id", reqRow.employee_id).single();
  const employeeName = emp?.full_name || "An employee";

  // In-app bell (always, even if email is off / no email).
  await supabase.from("notifications").insert({
    user_id: managerId, actor_id: reqRow.employee_id, type: "leave_request_submitted",
    title: `${employeeName} submitted a leave request`, link: "/desks/hris",
  });

  if (!manager?.email) return new Response(JSON.stringify({ skipped: "manager no email", belled: true }), { headers: corsHeaders });

  const { data: prefRow } = await supabase.from("user_notification_preferences").select("preferences").eq("user_id", managerId).maybeSingle();
  const prefs = (prefRow?.preferences ?? {}) as Record<string, boolean>;
  if (prefs["email_leave_request_submitted"] === false) {
    return new Response(JSON.stringify({ success: true, skipped: "email disabled", belled: true }), { headers: corsHeaders });
  }

  // Generate + store single-use token (14-day expiry).
  const secret = Array.from(crypto.getRandomValues(new Uint8Array(32))).map((b) => b.toString(16).padStart(2, "0")).join("");
  const tokenHash = await sha256Hex(secret);
  const expires = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString();
  const { error: tokErr } = await supabase.from("hris_leave_action_tokens").insert({
    leave_request_id, manager_id: managerId, token_hash: tokenHash, expires_at: expires,
  });
  if (tokErr) { console.error("token insert failed", tokErr); return new Response(JSON.stringify({ error: "token error" }), { status: 500, headers: corsHeaders }); }

  const base = `${Deno.env.get("SUPABASE_URL")}/functions/v1/leave-action`;
  const approveUrl = `${base}?token=${secret}&action=approve`;
  const rejectUrl = `${base}?token=${secret}&action=deny`;
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) return new Response(JSON.stringify({ error: "RESEND_API_KEY not set" }), { status: 500, headers: corsHeaders });

  const mgrFirst = manager.first_name || manager.full_name?.split(" ")[0] || "there";
  const subject = `Leave request from ${employeeName}`;
  const html = `<!DOCTYPE html><html><body style="margin:0;padding:24px;background:#f4f6f9;font-family:Helvetica,Arial,sans-serif;">
    <table width="600" align="center" cellpadding="0" cellspacing="0" style="max-width:600px;background:#fff;border-radius:12px;padding:32px;">
      <tr><td>
        <h2 style="margin:0 0 12px;color:#1a2e4a;">Hi ${mgrFirst},</h2>
        <p style="color:#4a5568;font-size:15px;"><strong>${employeeName}</strong> submitted a leave request:</p>
        <div style="background:#f7fafc;border:1px solid #e2e8f0;border-radius:8px;padding:16px;margin:16px 0;color:#4a5568;font-size:14px;">
          <p style="margin:0 0 4px;">Dates: <strong>${reqRow.start_date} → ${reqRow.end_date}</strong></p>
          <p style="margin:0 0 4px;">Hours: <strong>${reqRow.hours}</strong></p>
          ${reqRow.reason ? `<p style="margin:0;">Reason: ${reqRow.reason}</p>` : ""}
        </div>
        <table cellpadding="0" cellspacing="0"><tr>
          <td style="padding-right:12px;"><a href="${approveUrl}" style="display:inline-block;background:#16a34a;color:#fff;font-weight:600;text-decoration:none;padding:12px 28px;border-radius:8px;">Approve</a></td>
          <td><a href="${rejectUrl}" style="display:inline-block;background:#dc2626;color:#fff;font-weight:600;text-decoration:none;padding:12px 28px;border-radius:8px;">Reject</a></td>
        </tr></table>
        <p style="color:#a0aec0;font-size:12px;margin-top:20px;">These buttons open a confirmation page. Link expires in 14 days.</p>
      </td></tr>
    </table></body></html>`;

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: "Linked Accounting Alliance <hub@linkedalliance.co>", to: [manager.email], subject, html }),
  });
  if (!r.ok) { console.error("Resend error", await r.text()); return new Response(JSON.stringify({ error: "email failed", belled: true }), { status: 500, headers: corsHeaders }); }

  return new Response(JSON.stringify({ success: true, notified: manager.email }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
});
```

- [ ] **Step 2: Verify** — visual: caller-owns-request 403 guard; manager resolution (approver_id → manager_id); Bell inserted before email-pref short-circuits; token secret generated + only hash stored; approve/reject URLs point at `leave-action`; Resend POST. Graceful skips return 200 with `skipped`.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/functions/notify-manager-leave-request/index.ts
git -C linkedalliance commit -m "feat(hris): notify-manager-leave-request edge function (email approve/reject + bell)"
```

---

### Task 4: `leave-action` edge function (token-gated, prefetch-safe)

**Files:**
- Create: `linkedalliance/supabase/functions/leave-action/index.ts`

**Interfaces:**
- Public (no `Authorization`; token is the auth). GET → confirm page; POST → commit decision + invoke `notify-employee-leave-decision`.

- [ ] **Step 1: Implement**

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
const page = (title: string, body: string) =>
  `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"/><title>${title}</title></head>
   <body style="margin:0;padding:40px;background:#f4f6f9;font-family:Helvetica,Arial,sans-serif;text-align:center;">
   <table width="480" align="center" style="max-width:480px;background:#fff;border-radius:12px;padding:36px;"><tr><td>${body}</td></tr></table></body></html>`;
const html = (s: string, status = 200) => new Response(s, { status, headers: { "Content-Type": "text/html; charset=utf-8" } });

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Read token+action from query (GET) or form body (POST).
  let token = url.searchParams.get("token") || "";
  let action = url.searchParams.get("action") || "";
  if (req.method === "POST") {
    const form = await req.formData();
    token = String(form.get("token") || token);
    action = String(form.get("action") || action);
  }
  if (!token || (action !== "approve" && action !== "deny")) {
    return html(page("Invalid", `<h2 style="color:#dc2626;">Invalid link</h2><p>Missing or bad parameters.</p>`), 400);
  }

  const tokenHash = await sha256Hex(token);
  const { data: tok } = await supabase
    .from("hris_leave_action_tokens")
    .select("id, leave_request_id, manager_id, expires_at, used_at")
    .eq("token_hash", tokenHash).maybeSingle();

  if (!tok) return html(page("Invalid", `<h2 style="color:#dc2626;">Invalid or unknown link</h2>`), 404);
  if (tok.used_at) return html(page("Already decided", `<h2 style="color:#1a2e4a;">Already decided</h2><p>This request was already actioned.</p>`));
  if (new Date(tok.expires_at) < new Date()) return html(page("Expired", `<h2 style="color:#1a2e4a;">Link expired</h2><p>Open the HRIS desk to decide.</p>`));

  const decided = action === "approve" ? "approved" : "denied";

  // GET: read-only confirmation page (no DB write — prefetch-safe).
  if (req.method === "GET") {
    const { data: r } = await supabase.from("hris_leave_requests").select("start_date, end_date, hours, employee_id").eq("id", tok.leave_request_id).maybeSingle();
    let who = "this employee";
    if (r) { const { data: e } = await supabase.from("profiles").select("full_name").eq("id", r.employee_id).maybeSingle(); who = e?.full_name || who; }
    return html(page("Confirm", `
      <h2 style="color:#1a2e4a;">Confirm ${action === "approve" ? "approval" : "rejection"}</h2>
      <p style="color:#4a5568;">${who}'s leave${r ? ` (${r.start_date} → ${r.end_date}, ${r.hours}h)` : ""}.</p>
      <form method="POST" action="${url.origin}${url.pathname}">
        <input type="hidden" name="token" value="${token}" />
        <input type="hidden" name="action" value="${action}" />
        <button type="submit" style="background:${action === "approve" ? "#16a34a" : "#dc2626"};color:#fff;border:0;font-size:15px;font-weight:600;padding:12px 32px;border-radius:8px;cursor:pointer;">
          Confirm ${action === "approve" ? "Approve" : "Reject"}
        </button>
      </form>`));
  }

  // POST: claim the token atomically (single-use), then apply the decision.
  const { data: claimed } = await supabase
    .from("hris_leave_action_tokens").update({ used_at: new Date().toISOString() })
    .eq("id", tok.id).is("used_at", null).select("id").maybeSingle();
  if (!claimed) return html(page("Already decided", `<h2 style="color:#1a2e4a;">Already decided</h2>`));

  const { error: updErr } = await supabase.from("hris_leave_requests").update({
    status: decided, decided_by: tok.manager_id, decided_at: new Date().toISOString(), decision_note: "via email",
  }).eq("id", tok.leave_request_id);
  if (updErr) { console.error("decision update failed", updErr); return html(page("Error", `<h2 style="color:#dc2626;">Something went wrong</h2>`), 500); }

  // Notify the employee (fire-and-forget).
  supabase.functions.invoke("notify-employee-leave-decision", { body: { leave_request_id: tok.leave_request_id } }).catch(() => {});

  return html(page("Done", `<h2 style="color:${decided === "approved" ? "#16a34a" : "#dc2626"};">Leave ${decided}</h2><p>The employee has been notified.</p>`));
});
```

- [ ] **Step 2: Verify** — visual: GET path performs NO write (only renders confirm form); POST claims the token via `update ... is("used_at", null)` and treats missing row as already-used; sets status/decided_by/decided_at/decision_note; invokes employee notify; invalid/expired/used all render friendly pages; no `Authorization` required (token is auth). Confirm the form POSTs to the same function URL.

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add supabase/functions/leave-action/index.ts
git -C linkedalliance commit -m "feat(hris): leave-action edge function (prefetch-safe token approve/reject)"
```

---

### Task 5: Wire TimeOffTab invocations

**Files:**
- Modify: `linkedalliance/src/components/desks/hris/TimeOffTab.tsx`

**Interfaces:**
- Consumes: `supabase` from `@/integrations/supabase/client` (for `functions.invoke`).

- [ ] **Step 1: Implement.** READ `TimeOffTab.tsx` first. Ensure `supabase` is imported (`import { supabase } from "@/integrations/supabase/client";`) — add if missing (the file uses `db`; `functions.invoke` needs the typed client).
  - In `requestLeave.onSuccess(row)`, AFTER the existing `logActivity` + invalidate, add:
    ```tsx
    supabase.functions.invoke("notify-manager-leave-request", { body: { leave_request_id: row.id } }).catch(() => {});
    ```
  - In `decide.onSuccess` (the in-app approve/deny mutation), AFTER its existing logActivity + invalidate, add (use the decided request's id available in that mutation — it updates by `id`):
    ```tsx
    supabase.functions.invoke("notify-employee-leave-decision", { body: { leave_request_id: <decidedRequestId> } }).catch(() => {});
    ```
    If the `decide` mutationFn doesn't currently expose the id in `onSuccess`, return it from `mutationFn` (e.g. `return id;`) and read it as the `onSuccess` arg — minimal change.
  - Both are fire-and-forget (`.catch(()=>{})`) so email/edge failures never block the UI action.

- [ ] **Step 2: Verify** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build` succeeds AND `npx vitest run src/components/desks/hris/` green (existing HRIS tests unaffected).

- [ ] **Step 3: Commit**

```bash
git -C linkedalliance add src/components/desks/hris/TimeOffTab.tsx
git -C linkedalliance commit -m "feat(hris): notify manager on leave submit + employee on decision"
```

---

### Task 6: Deploy + verification

**Files:** none (deploy + manual).

- [ ] **Step 1: Build/tests** — `cd C:/Users/aksha/Dev/linkedalliance && npm run build && npx vitest run` green.

- [ ] **Step 2: Apply migration + deploy functions** (user / CI — auto-mode blocks Bash prod ops):
  - Run `supabase/migrations/20260630140000_hris_leave_action_tokens.sql` in the Supabase SQL editor.
  - Deploy the three functions: `supabase functions deploy notify-manager-leave-request notify-employee-leave-decision leave-action`.
  - Confirm `RESEND_API_KEY` is set in the project's function secrets.
  - `node scripts/check-supabase-security.mjs` — confirm `hris_leave_action_tokens` has RLS on, no anon access.

- [ ] **Step 3: Manual E2E**:
  - As an employee with a manager set, submit a leave request → manager receives email (Approve/Reject) + Bell entry. Employee with no manager → no email, no error.
  - Click **Approve** → confirm page (request still pending) → **Confirm** → request `approved`, `decided_by` = manager, balance decremented; employee gets the decision email + Bell. Re-open the link → "Already decided." (Simulate expiry by setting `expires_at` in the past → "Link expired.")
  - Click **Reject** → `denied`, employee emailed.
  - In-app approve/deny in the queue → employee still emailed (path 2).
  - Manager with `email_leave_request_submitted=false` → Bell only, no email.

---

## Self-Review

- **Spec coverage:** token table + RLS-no-policies (T1); employee-decision email/bell (T2); manager submit email+bell + token gen + caller-owns guard (T3); prefetch-safe GET-confirm/POST-commit token endpoint + single-use claim + employee-notify invoke (T4); TimeOffTab wiring both paths (T5); deploy + E2E incl. used/expired/pref/no-manager (T6). All spec sections map to a task.
- **Placeholder scan:** none — full edge-fn code, migration SQL, and wiring snippets are concrete; the only bracketed bit is `<decidedRequestId>` in T5 with an explicit instruction to return the id from the existing mutationFn.
- **Type/contract consistency:** all three functions take `{ leave_request_id }`; action values `approve`/`deny` map to status `approved`/`denied` consistently (T3 email links ↔ T4 handler); token secret hashed with the same `sha256Hex` in T3 (store) and T4 (lookup); decision columns (`status`, `decided_by`, `decided_at`, `decision_note`) match the Phase-1 `hris_leave_requests` schema; notification types `leave_request_submitted`/`leave_request_decided` consistent across functions + pref keys (`email_<type>`).

## Notes
- Branch off integrated `main` (e.g. `hris-leave-notify`). Migration + function deploy happen out-of-band (auto-mode blocks Bash prod ops); the app build/tests don't depend on them.
- Edge functions aren't covered by vitest; they're verified by the manual E2E in T6.
