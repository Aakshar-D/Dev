# 05 — Integrations

All real integration logic lives in **Supabase Edge Functions** (`linkedalliance/supabase/functions/`). Client-side wrappers are thin — they build URLs, read connection status, or trigger edge functions.

---

## HubSpot (CRM)

**Client-side:** `src/lib/hubspot.ts`
- Builds deep-link URLs only: `hubspotCompanyUrl(portalId, companyId)`, `hubspotContactUrl(...)`. No API calls from the browser.
- Portal ID: `VITE_HUBSPOT_PORTAL_ID` env var.

**Edge functions (server-side sync):**

| Function | What it does |
|----------|-------------|
| `hubspot-sync-deals` | Pull deal pipeline into local DB for reporting dashboards |
| `hubspot-sync-engagements` / `-full` | Sync engagement records (calls, emails, meetings) |
| `hubspot-sync-ownership` | Sync deal/contact owner assignments |
| `hubspot-check-contact` | Look up whether a contact exists in HubSpot |
| `hubspot-list-sequences` | List enrollment sequences |
| `hubspot-owner-stats` | Owner activity stats for reporting |
| `hubspot-push-firm` | Push a firm/company record to HubSpot |

**Used by:** Wealth reporting (AUM/pipeline data), Reporting dashboards, Daily Prepper (contact resolution), Admin integrations tab.

---

## Google Gmail + Google Calendar

**Connection model:** OAuth 2.0 via Supabase; tokens stored encrypted in `email_connections` table. One connection per user per provider (`provider = 'google'`).

**Scopes:**
- `gmail.readonly` — read email threads
- `calendar.readonly` — read calendar events
- compose scope — create Gmail drafts (SSG only)

**Client hooks:**
- `src/hooks/useEmailConnection.ts` — reads `email_connections`, exposes `hasCalendarScope`, `hasGmailScope`, `isConnected`.
- `src/hooks/useGmailConnection.ts` — Gmail-specific connection state.

**Edge functions:**

| Function | What it does |
|----------|-------------|
| `gmail-oauth-start` | Initiates OAuth flow (returns redirect URL) |
| `gmail-oauth-callback` | Handles OAuth callback; stores encrypted tokens in `email_connections` |
| `gmail-disconnect` | Revokes token and removes `email_connections` row |
| `gmail-create-draft` | Creates a draft in user's Gmail Drafts |
| `gmail-create-draft-expansion` | Client Expansion desk — creates outreach draft |
| `gmail-create-draft-ssg-status` | SSG desk — creates status-update draft |
| `prep-sync-calendar` | Syncs Google Calendar for Daily Prepper (−30d to +7d window) → `prep_calendar_events` |
| `ssg-sync-calendar` | Syncs Google Calendar for SSG Engagements (−30d to +60d) → `ssg_calendar_events`; matches attendees to engagement contacts |
| `ssg-sync-email` | Walks Gmail threads; stores in `ssg_emails` by `gmail_thread_id` |

**Token security:** Encrypted/decrypted in `supabase/functions/_shared/gmail-crypto.ts`. Tokens never exposed to the browser.

---

## Google Gemini (meeting notes)

**Client-side:** `src/lib/geminiNotes.ts`

Not an API integration — a **deterministic parser** for `.docx` exports from "Notes by Gemini" (Google Meet's AI note-taker). Uses `mammoth` (in-browser DOCX parser) to extract structured content: summary / details / next steps / transcript utterances.

Output matches the Fathom utterance shape, so both Gemini and Fathom notes feed the same SSG AI pipeline (`ssg-engagement-ask`, `ssg-extract-signals`).

Entry point: `UploadGeminiNotesDialog` in the SSG Engagements desk. `ingest_source` set to `'gemini'`.

---

## Fathom (AI call recorder)

Fathom is a third-party AI meeting recorder. The integration is entirely server-side.

| Function | What it does |
|----------|-------------|
| `ssg-fathom-webhook` | Receives Fathom webhook on new call completion; stores transcript → triggers AI extraction |
| `ssg-fathom-backfill` | One-time backfill of historical Fathom recordings into `ssg_meetings` |
| `ssg-sync-fathom` | Incremental sync of Fathom recordings |

Recording URLs stored in `ssg_meetings.recording_url`. Transcripts are the input to the Claude AI analysis edge functions.

---

## Ninety.io (EOS task sync)

**Client-side:** `src/lib/ninetyOutbound.ts`

Ninety.io is an EOS (Entrepreneurial Operating System) management tool. Tasks with `sync_source = 'ninety'` and a `ninety_id` are synced bidirectionally.

**Outbound (Hub → Ninety):**
- When a synced task changes, `ninetyOutbound.ts` fires a POST to the `clever-actionninety-outbound` edge function.
- A `_sync_lock` boolean on `tasks` prevents outbound loops when the change originated from Ninety.

**Inbound (Ninety → Hub):** Handled by the edge function; sets `_sync_lock = true` during processing.

The integration uses the task assignee's email as the routing key to look up the Ninety user.

---

## Email delivery & utility edge functions

| Function | What it does |
|----------|-------------|
| `send-notification-email` | Transactional email for in-app notification events |
| `send-welcome-email` | Welcome email on account setup |
| `notify-document-share` | Notifies user when a document is shared with them |
| `notify-rfp-event` | Notifies relevant users on RFP status changes |
| `notify-ssg-manager` | Notifies SSG managers on ticket/engagement events |
| `email-tracking-pixel` | 1×1 pixel endpoint for email open tracking |
| `geocode-firms` | Geocodes firm addresses for map views (BDR/SDR desks) |
| `claim-invite` | Processes invite token claim; sets user status to pending |

---

## AI / LLM usage map

| AI system | Where used | How |
|-----------|-----------|-----|
| **Claude (Anthropic)** | SSG Engagements desk | `ssg-portfolio-ask` — Q&A across full portfolio; `ssg-engagement-ask` — Q&A over single engagement (aggregates transcripts + emails + tasks); `ssg-extract-signals` — scans transcripts for advisor-reviewable signals |
| **Claude** | Client Expansion desk | Opportunity scoring, fit summaries, research (implied by `ai_generated_by` fields) |
| **Claude** | Daily Prepper desk | `MeetingBrief` component (meeting briefing generation) |
| **Claude** | SDR / BDR desks | AI email draft generation |
| **Claude** | Hub MCP server | Exposes Hub data/actions to Claude via MCP — see [06-mcp-and-ai.md](06-mcp-and-ai.md) |
| **Gemini (Google)** | SSG Engagements | `.docx` note parser (`geminiNotes.ts`) — not an API call; parses Google Meet AI notes locally |
| **Ollama** (local) | Marketing Website desk | Optional LLM for firm data extraction during web scraping; designed to be swapped for a Supabase edge function in production |
| **Fathom** (AI recorder) | SSG Engagements | Third-party AI meeting recorder; transcripts ingested server-side |

---

## Microsoft (email/auth)

Microsoft is supported as an OAuth provider in two contexts:

1. **SSO login** — `provider = 'microsoft'` in Supabase Auth (configured in `/auth`).
2. **Email connection** — `email_connections.provider = 'microsoft'` is recognized (same table as Google); Microsoft-specific OAuth flow not yet fully implemented (Google is the active path).

---

## Canopy (practice management)

Canopy is a CPA practice management system. Referenced in SSG Engagements as a contact source (`source: 'canopy'`). No direct API integration documented — contacts appear to be imported/synced by an external process.
