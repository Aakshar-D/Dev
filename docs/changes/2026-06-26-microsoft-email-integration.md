# Change Log — Microsoft (Outlook) Email Integration

**Date:** 2026-06-26
**Area:** Email connections (`email_connections`), BDR draft creation, Supabase Edge Functions
**Related doc:** [05-integrations.md → Microsoft Outlook + Microsoft Calendar](../05-integrations.md)

---

## Problem

The frontend already advertised "Connect Outlook" (`EmailConnectionCard`) and the
BDR desk advertised pushing drafts, but the Microsoft path was never built:

- `EmailConnectionCard` called edge function `outlook-oauth-start` and listened for
  an `outlook-connected` window message — **neither the function nor a callback existed**.
- `email_connections` recognized `provider = 'microsoft'` but no code wrote or read
  Microsoft connections.
- Draft creation (`gmail-create-draft`) was hard-wired to `provider = 'google'`.

Net effect: clicking "Connect Outlook" failed (no such function), and a Microsoft
connection could do nothing.

Separately, `gmail-create-draft` was already **broken against the live schema**: it
selected columns `encrypted_refresh_token` / `email_address` (which do not exist —
the real columns are `refresh_token_encrypted` / `google_email`) and imported from
`./_shared/...` instead of `../_shared/...`.

---

## What changed

### New — Microsoft OAuth flow

| File | Purpose |
|------|---------|
| `supabase/functions/outlook-oauth-start/index.ts` | Self-authenticates the caller, signs a state token (HMAC via `gmail-crypto`), returns the Microsoft authorize URL. |
| `supabase/functions/outlook-oauth-callback/index.ts` | GET redirect target. Verifies state, exchanges the code at the MS token endpoint, fetches `/me` from Graph for the address, AES-256-GCM-encrypts the refresh token, upserts `email_connections` with `provider = 'microsoft'`, posts `outlook-connected` to the opener. |

Authorize endpoint: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize`
Token endpoint: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`
Graph profile: `https://graph.microsoft.com/v1.0/me` (`mail || userPrincipalName`)

Scopes: `offline_access openid email profile` + `Mail.ReadWrite`, `Mail.Send`, `Calendars.Read`.

### New — shared Microsoft Graph helper

`supabase/functions/_shared/ms-graph.ts`:

- `getMsAccessToken(refreshToken)` — refresh-token grant. **Microsoft rotates refresh
  tokens**; returns `newRefreshToken` (or `null`) so callers can persist the rotated value.
- `createOutlookDraft(accessToken, { to, subject, html })` — `POST /me/messages`
  (creating a message without sending = a draft). Requires `Mail.ReadWrite`. Returns
  `{ id, webLink }`.
- `listOutlookCalendarEvents(accessToken, startIso, endIso)` — `calendarView` (expands
  recurrences), paged via `@odata.nextLink`, requested in UTC. Requires `Calendars.Read`.

### Changed — provider-aware BDR draft

`supabase/functions/gmail-create-draft/index.ts` rewritten:

- Selects the user's **most recent active connection of either provider** (was
  `.eq("provider", "google")`).
- Branches: Google path (RFC-2822 → base64url → Gmail drafts API, unchanged behavior)
  vs Microsoft path (`getMsAccessToken` → re-persist rotated token → `createOutlookDraft`).
- **Fixed the pre-existing schema bug** — now reads `refresh_token_encrypted` /
  `refresh_token_iv` / `google_email` and imports from `../_shared/...`.
- Response field renamed `gmail_url` → `draft_url` (provider-neutral).

### Changed — config registration

`supabase/config.toml`: registered `outlook-oauth-start` and `outlook-oauth-callback`
with `verify_jwt = false` (the callback receives a redirect from Microsoft carrying no
Supabase JWT; the start function self-authenticates via `getUser()`).

### Changed — frontend (BDR desk)

`src/components/desks/bdr/ProspectFocusView.tsx`:

- Swapped `useGmailConnection` (Google-only) → `useEmailConnection` (provider-agnostic),
  so the "push draft" button appears for an Outlook-only user too.
- Relabeled UI: "Push to Gmail" → "Push to draft", "Connect Gmail" → "Connect email",
  reads `data.draft_url` instead of `data.gmail_url`.

(`EmailConnectionCard` needed no change — it was already wired for `outlook-oauth-start`
and the `outlook-connected` / `outlook-error` messages.)

---

## Data model notes

`email_connections.google_email` is **NOT NULL**, so Microsoft connections write the
Outlook address to both `google_email` and `account_email`. Readers use
`account_email || google_email`. `email_activity_log.gmail_draft_id` stores the draft id
for both providers (column name is Gmail-era; not renamed).

---

## Deployment / configuration

1. **Azure app registration** (Entra ID → App registrations):
   - Redirect URI (Web): `https://<project-ref>.supabase.co/functions/v1/outlook-oauth-callback`
   - Delegated Graph permissions: `Mail.ReadWrite`, `Mail.Send`, `Calendars.Read`,
     `offline_access`, `openid`, `email`, `profile` (admin consent if the org requires it)
   - Create a client secret
2. **Supabase secrets:** `MS_CLIENT_ID`, `MS_CLIENT_SECRET`, optional `MS_TENANT`
   (default `common`). `GMAIL_ENCRYPTION_KEY` is reused for state signing + token encryption.
3. **Deploy:**
   ```
   supabase functions deploy outlook-oauth-start
   supabase functions deploy outlook-oauth-callback
   supabase functions deploy gmail-create-draft
   ```

---

## Verification status

- Frontend `npm run build` — **passes** (only pre-existing warnings).
- Edge functions — **not** locally type-checked (Deno not installed in this environment);
  they mirror the working Gmail functions and use the verified live schema.
- End-to-end OAuth — **not** exercised (requires the Azure app + deploy).

---

## Remaining parity gaps (not built)

| Capability | Google | Microsoft |
|-----------|--------|-----------|
| Connect / disconnect | ✅ | ✅ |
| BDR draft (`gmail-create-draft`) | ✅ | ✅ |
| Client Expansion draft (`gmail-create-draft-expansion`) | ✅ | ❌ Google-only (likely same stale-column bug; unverified) |
| SSG status draft (`gmail-create-draft-ssg-status`) | ✅ | ❌ Google-only |
| Calendar sync (`ssg-sync-calendar`) | ✅ | ❌ helper ready, not wired into SSG rollup |
| Email sync (`ssg-sync-email`) | ✅ | ❌ Google-only |
