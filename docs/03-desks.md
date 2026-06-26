# 03 — Desks

Desks are bespoke, role-specific daily workspaces. Instead of navigating the generic sidebar, a desk user gets a curated, focused environment for their specific role workflow.

## Mechanics

**Routing:** `/desks` → `src/pages/Desks.tsx` (list of accessible desks) → `/desks/:slug` → `src/pages/DeskMode.tsx` → renders the specific desk component.

**Gating:** Two-level permission check:
1. `desks.access` — must hold this key to reach any desk.
2. Per-desk `permission_key` (e.g. `desks.bdr`, `desks.sdr`) — must hold the desk's specific key to see it in the list and open it.

Desk slugs and their `permission_key`s are admin-managed in the `desks` table (`/admin/desks`).

**Common patterns across all desks:**
- URL-param-driven navigation (`useSearchParams`) — tab and focus-view state in the URL.
- List → Focus View pattern: a list of records; clicking one opens a full-detail view that replaces the tab UI.
- Supabase data via `@/lib/db` and TanStack Query.
- shadcn components for all UI.

---

## BDR — Business Development Rep

**Component:** `src/components/desks/bdr/BdrDeskContent.tsx`
**Permission:** `desks.bdr`

**Purpose:** Outbound business-development workflow for BDR partners. Partners claim "batches" of ~10 prospects pulled from a shared pool, then action each (claim / skip / flag). Prospects are pre-enriched and filtered by verdict (`approve`/`verify`).

**Sub-views (tabs):**

| Tab | Component | What it does |
|-----|-----------|-------------|
| My Queue | `BatchReview` (focus view) | Active batch progress + past batches; request / release batches |
| My Prospects | `MyProspects` | Prospects the partner has claimed |
| Pool Explorer | `PoolExplorer` | Browse the full prospect pool, build new batches |
| Map | `BdrBusinessesMap` | Geographic view of businesses (geocoded) |
| Stats | `PartnerStats` | Partner activity stats |
| Preferences | `BdrEmailTemplates` | Email template configuration |
| Enrichment | `CrawlDashboard` | Web-crawl / enrichment pipeline dashboard |

**Focus views:** `BatchReview` (from URL param) and `ProspectFocusView` (prospect detail) bypass the tab UI.

**Key tables:** `bdr_batches`, `bdr_prospects`
**Key RPCs:** `release_bdr_batch`
**Integrations:** Web-crawl enrichment pipeline; geocoding for map view.

---

## SDR — Sales Development Rep

**Component:** `src/components/desks/sdr/SdrDeskContent.tsx`
**Permission:** `desks.sdr`

**Purpose:** Firm-prospecting workflow — the most complex desk and the canonical reference implementation. SDRs build queues of CPA firms from a shared pool, research them, and draft outreach. Includes a **"View As"** feature: managers with multiple partner reports can view another partner's desk read-only (write actions disabled, amber banner).

**Sub-views (tabs):**

| Tab | Component | What it does |
|-----|-----------|-------------|
| Queues | `MyQueues` / `QueueReview` | Work queues of firms; action firms within a queue |
| My Firms | `MyFirms` | Firms the SDR has claimed |
| Follow-Up | `FollowUpQueue` | Firms needing follow-up |
| Pool | `FirmPool` | Browse the full firm pool; build new queues |
| Skipped | `SkippedFirms` | Firms the SDR skipped |
| Map | `FirmsMap` | Geographic firm view |
| Sessions | `ResearchSessions` | Research sessions (legacy contact/batch research flow) |
| Research Dashboard | `ResearchDashboard` | Research activity overview |
| User Preferences | `SdrEmailTemplates` | Email template configuration |

**Focus views:** `FirmFocusView` (full firm detail).

**Key tables:** `sdr_batches`, `sdr_contacts`, firm/queue tables
**Integrations:** Knowledge Base links (`KbPageKey` per tab); email template drafting; research/enrichment pipeline.

---

## Client Expansion

**Component:** `src/components/desks/client-expansion/ClientExpansionDeskContent.tsx`
**Permission:** `desks.client-expansion`

**Purpose:** Identifies upsell/cross-sell opportunities within existing client books. Focused on **CFO Advisory** service expansion. Opportunities are AI-scored and tier-ranked (Tier 1–3) with fit summaries and scoring rationale. Tracks the full sales funnel.

**Status funnel:** Not Contacted → Contacted → Meeting Set → Proposal Sent → Converted / Declined / Deferred

**Sub-views (tabs):**

| Tab | Component | What it does |
|-----|-----------|-------------|
| Opportunities | (inline) | Filterable/scored opportunity grid. Filters: firm (Linked Accounting / FJ Clients / Vantage Clients), tier, status, email-draft state, research freshness (stale flag for >90 days). Paginated, 30/page. |
| Sessions | `ExpansionSessions` | Research sessions |
| Templates | `ExpansionEmailTemplates` | Email template configuration |

**Focus views:** `OpportunityDetailView`, `FirmView`

**Key tables:** `expansion_opportunities`
**Integrations:** AI scoring and fit summaries (research pipeline); AI email drafting (`email_status`: ready/drafted); research-freshness tracking (periodic re-research jobs implied).

---

## Daily Prepper

**Component:** `src/components/desks/daily-prepper/DailyPrepperDeskContent.tsx`
**Permission:** `desks.daily-prepper`

**Purpose:** Pre-meeting briefing tool. Shows the user's Google Calendar meetings for a selected day, each enriched with CRM/system context and an AI-generated meeting brief.

**Sub-views (tabs):**

| Tab | Component | What it does |
|-----|-----------|-------------|
| Today | (inline) | Per-day meeting list; navigate ±days within synced window (today−30d to today+7d). Expandable rows: join link + `MeetingBrief` (AI). |
| Settings | `PrepReminderSettings` | Prep reminder config |

**Meeting kind resolution:** Each meeting's counterparty is resolved into one of: SSG client / Member firm / CRM contact / Internal / External.

**Entry gate:** If Google Calendar is not connected (`hasCalendarScope = false`), shows a `EmailConnectionCard` CTA before the tab UI.

**Key tables:** `prep_calendar_events`
**Integrations:**
- **Google Calendar** — requires `calendar.readonly` scope via `useEmailConnection`; sync via `prep-sync-calendar` edge function.
- **HubSpot CRM** — attendee resolution against CRM contacts.
- **AI meeting briefs** — `MeetingBrief` component (edge function or LLM call).

---

## SSG Engagements

**Component:** `src/components/desks/ssg-engagements/SsgEngagementsDeskContent.tsx` _(~5,100 lines — most complex desk)_
**Permission:** `desks.ssg-engagements`

**Purpose:** Full client-engagement management workspace for SSG (Strategic Services Group) advisors. Manages ongoing advisory engagements across service lines, tracking meetings, tasks, emails, contacts, calendar events, and AI-extracted signals.

**Top-level filters:**
- **Service lanes:** All Lanes / CFO Advisory / Cost Segregation / R&D Tax Credit / Other (`ssg_engagements.service_line`)
- **Status tabs:** All / Active / Pipeline / Paused
- **Sort:** Next call / Last meeting / Client A–Z / Partner A–Z
- **Team / "View As":** Admins and managers can view another advisor's portfolio (uses `useEffectiveUser`)

**Sub-views:**
- Portfolio dashboard (stat cards, engagement list)
- Engagement detail view: contacts, upcoming meetings, email threads, task list, recent recordings, AI signals
- `MeetingDetailDialog` — full meeting transcript + action items
- `UploadGeminiNotesDialog` — ingest Gemini `.docx` meeting notes
- "What's new" announcement panel

**Key tables:** `ssg_engagements`, `ssg_calendar_events`, `ssg_emails`, `ssg_meetings`

**Integrations (extensive):**

| Integration | How used |
|-------------|---------|
| **Google Calendar** | `ssg-sync-calendar` edge function syncs −30d to +60d, matches attendees to engagement contacts. Requires `calendar.readonly` scope. |
| **Gmail** | `ssg-sync-email` walks Gmail threads by `gmail_thread_id`. `gmail-create-draft-ssg-status` creates status-update drafts in the advisor's Gmail Drafts (requires compose scope). |
| **Fathom** (call recorder) | `ssg-fathom-webhook` + `ssg-fathom-backfill` import transcripts; new calls auto-extract via webhook. Recordings in `ssg_meetings.recording_url`. |
| **Gemini** | `UploadGeminiNotesDialog` parses `.docx` exports from "Notes by Gemini" via `src/lib/geminiNotes.ts` (mammoth, no API call) → same structure as Fathom utterances. |
| **Claude AI** | `ssg-portfolio-ask` (Q&A across portfolio), `ssg-engagement-ask` (Q&A over single engagement: transcripts + emails + tasks + outcomes), `ssg-extract-signals` (re-scan transcripts for actionable signals). |
| **Canopy** | Contact source; some contacts marked `source: 'canopy'` (practice management system). |

Routing key across integrations: client contact email.

---

## Marketing Website (Design Desk)

**Component:** `src/components/desks/marketing-website/MarketingWebsiteDeskContent.tsx`
**Permission:** `desks.marketing-website`

**Purpose:** Workflow tool for managing the LinkedAlliance marketing site and onboarding CPA-firm marketing sites. The current implemented surface is a **firm intake / scraper → SQL generation → site preview** pipeline that captures a firm's full profile into a standardized schema so a single Astro template can render any firm's website.

**Sub-views (tabs):**

| Tab | Component | What it does |
|-----|-----------|-------------|
| Firm Intake & Scraper | `FirmIntakeForm` + `ScraperPane` + `SourcePreview` | Paste a firm URL → scrape → review/edit structured data → create candidate record |
| SQL Generator | `SQLGeneratorPanel` | Generate SQL from a candidate record |
| Site Designer & Preview | `SiteDesignerPanel` | Preview firm site in the Astro template |
| Traffic & SEO | (placeholder) | "Coming Soon" |
| Schema Reference | `SchemaReferencePanel` | Reference for the firm schema |

**Data model (two-stage):**
1. **Stage 1 — `firm_candidates`** staging table: all data stored as JSON lists (`team_members`, `firm_services`, `firm_locations`, `firm_industries` as JSON fields). Written by the scraper/intake via delete-then-reinsert.
2. **Stage 2 — live tables**: `organizations` + child tables (`team_members`, `firm_services`, `firm_locations`, `firm_industries` as relational rows). `promote-firm-candidate` edge function fans a staged row into live tables.

**Integrations:**
- **Web scraping** — browser-side (`runScraper`): CORS proxy + cheerio HTML parsing + optional Ollama (local LLM) for extraction. Production path: `scrape-firm` Supabase edge function.
- **Sandbox Supabase** — separate Supabase project (`sandboxClient`, configured via `VITE_SUPABASE_SANDBOX_URL` / `VITE_SUPABASE_SANDBOX_ANON_KEY`) so writes don't touch production. Falls back to in-memory if env vars aren't set.

**Isolation model (important):**

This desk is developed by an external collaborator ("Trey") with no direct Supabase access. All constraints are enforced:

| Constraint | Mechanism |
|-----------|-----------|
| Code isolation | Files only under `src/components/desks/marketing-website/` |
| Branch protection | `desk-marketing-website` branch; CODEOWNERS blocks Trey from touching anything outside the desk folder |
| DB changes | Trey writes DB/edge-function requests to `SPEC.md` → pings Jacob (the admin) → Jacob implements via Supabase MCP |
| DB access | Sandbox Supabase for development; production tables only after Jacob's review |
| Go-live | PR: `desk-marketing-website` → `main`; Jacob reviews and merges |

Reference desks for pattern (read, never modify): SDR (complex), Client Expansion (simpler tab UI), BDR (middle ground).

Source docs:
- `src/components/desks/marketing-website/CLAUDE.md` — working context for Claude Code
- `src/components/desks/marketing-website/SPEC.md` — DB/backend request queue (Trey → Jacob)
- `src/components/desks/marketing-website/HOW-TO.md` — git workflow onboarding for Trey
