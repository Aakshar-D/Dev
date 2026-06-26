# 06 — MCP & AI Connector

The LinkedAlliance Hub acts as both an **OAuth 2.1 Authorization Server** and an **MCP (Model Context Protocol) server**, allowing Claude AI clients (claude.ai, Claude Desktop, Claude Code) to connect to and operate within the Hub on behalf of authenticated members.

---

## Architecture overview

```
Claude client (claude.ai / Claude Code)
    ↓ OAuth 2.1 discovery + PKCE
hub-oauth (Supabase Edge Function)  ←→  oauth_clients / oauth_access_tokens / oauth_refresh_tokens
    ↓ access token
hub-mcp (Supabase Edge Function)  →  Hub DB (tasks, projects, desk data, etc.)
    ↑ member identity + role
    ↑ Bearer token or legacy personal token
```

---

## OAuth 2.1 Authorization Server

**Source:** `supabase/migrations/20260610130000_oauth_as.sql` + edge function `supabase/functions/hub-oauth/`

### DB tables

| Table | Purpose |
|-------|---------|
| `oauth_clients` | Registered client apps (supports DCR — Dynamic Client Registration, RFC 7591) |
| `oauth_access_tokens` | Issued tokens; stored as SHA-256 hash; includes expiry, scopes, `user_id` |
| `oauth_refresh_tokens` | Refresh tokens for long-lived sessions |

### Standards implemented

- **RFC 8414** — `/.well-known/oauth-authorization-server` discovery
- **RFC 8707** — `/.well-known/oauth-protected-resource`
- **RFC 7591** — Dynamic Client Registration (DCR)
- **PKCE S256** — required for all authorization code flows
- Supported grants: `authorization_code`, `refresh_token`

### Flow

1. Claude client discovers the Hub via `/.well-known/oauth-protected-resource` → finds the authorization server URL.
2. Claude initiates authorization with PKCE; Hub redirects to `/authorize` (the consent page).
3. User logs in (or is already logged in) → reviews consent screen (`ConnectClaude.tsx`).
4. User approves → `/issue-code` endpoint (verifies member's Supabase JWT) → issues single-use auth code.
5. Claude exchanges auth code for access + refresh tokens via `hub-oauth`.
6. Claude calls `hub-mcp` with `Authorization: Bearer <token>`.

### Security note — `oauthReturn.ts`

`src/lib/oauthReturn.ts` stashes and restores the `/authorize` path across login round-trips (user may need to log in before seeing the consent screen). Only relative paths starting with `/authorize` are honored — open-redirect protection.

---

## Legacy personal tokens

Before OAuth 2.1, each user could generate a personal MCP API token stored in `profiles.mcp_api_token` (SHA-256 hashed, with `_preview` display copy and `_created_at`). Validated by the `validate-mcp-token` edge function. Still supported as a fallback authentication path in `hub-mcp`.

Managed in the user's Profile page (`/profile` → API Access tab).

---

## MCP Server (`hub-mcp`)

**Source:** `supabase/functions/hub-mcp/index.ts`
**Deploy:** `verify_jwt = false` — the function does its own token authentication (platform JWT gate would break the MCP handshake).

### Authentication in `authenticate()`

1. Read `Authorization: Bearer <token>` header (or legacy `?token=` query param).
2. SHA-256 hash the bearer token → look up in `oauth_access_tokens` (must be unexpired).
3. Confirm `profiles.status = 'active'` for the token's `user_id`.
4. On failure → returns `401` with `WWW-Authenticate` header → Claude discovers the OAuth server and initiates the flow.
5. Fallback: if no Bearer token, try `validate-mcp-token` with the legacy personal token.

Returns `{ user_id, role }` on success.

### MCP tools (~50+, scoped by role/permissions)

**Task tools:**
- `get_my_tasks` — list the user's assigned tasks
- `create_task` — create a task in a project
- `complete_task` — mark a task complete
- `add_task_comment` — add a comment to a task
- `get_subtasks`, `create_subtask`, `complete_subtask`

**Project tools:**
- `get_projects` — list accessible projects
- `create_project` — create a new project
- `add_project_member` — add a member to a project
- Project template tools

**Desk tools (BDR, SDR, Client Expansion):**
- `bdr_*` — batch management, prospect actioning
- `sdr_*` — queue management, firm actioning
- `expansion_*` — opportunity management
- `push_gmail_draft` — push a draft to the advisor's Gmail Drafts

All tools check the user's role/permissions before executing. A `Read Only` user cannot create or edit.

---

## Admin management

**UI:** `src/components/admin/MCPConnectionsTab.tsx` → `/admin/mcp-connections`

**Source:** `supabase/migrations/20260611130000_mcp_admin_connections.sql`

**RPCs:**
- `admin_list_mcp_connections()` — returns all members with active OAuth sessions (user, active_sessions count, connected_at, last_token_at)
- `admin_revoke_mcp_connection(target_user_id)` — revokes all sessions for a user immediately; logs `ADMIN_MCP_DISCONNECTED` to `activity_logs`

**Activity logging:** MCP connection/disconnection events are tracked in `activity_logs` via `logActivity()`.

---

## MCP permission keys (by role)

| Role | `mcp.*` permissions |
|------|---------------------|
| Admin | `*` (all via system role) |
| Executives | `mcp.access`, `mcp.read`, `mcp.write`, `mcp.delete` |
| Board Member | `mcp.access`, `mcp.read` |
| Partner | `mcp.access`, `mcp.read`, `mcp.write` |
| Manager | `mcp.access`, `mcp.read`, `mcp.write` |
| Member | `mcp.access`, `mcp.read`, `mcp.write` |
| SSG Member | `mcp.access`, `mcp.read`, `mcp.write` |
| Content Editor | `mcp.access`, `mcp.read`, `mcp.write` |
| Read Only | _(none)_ |
| External | _(none)_ |

---

## Deployment

**Script:** `linkedalliance/.claude/scratch/deploy_hub_mcp.py`

Deploys `supabase/functions/hub-mcp/index.ts` to Supabase project ref `trltcyzskmcveuabypat` via the Supabase Management API multipart deploy endpoint.

Key flag: `verify_jwt=False` — necessary because `hub-mcp` performs its own auth; the Supabase platform JWT gate would reject the MCP client's Bearer token before the function could process it.

Requires: `SUPABASE_ACCESS_TOKEN` env var.

After deploy, run the edge function locally with:
```bash
supabase functions serve hub-mcp --no-verify-jwt
```
