-- Security fixes applied to prod (trltcyzskmcveuabypat) on 2026-07-08 via MCP apply_migration.
-- Trigger: Supabase security advisor email 2026-07-06 (rls_disabled_in_public: tas_import_logs).
-- Recorded in prod migration ledger as: tas_import_logs_enable_rls, tas_views_security_invoker.
-- Repo main migration layout is stale vs prod (see memory/branching plan) — this file is the record.

-- Migration 1: tas_import_logs_enable_rls
-- Fix: rls_disabled_in_public. Matches sibling tas_* table policy pattern.
ALTER TABLE public.tas_import_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated read tas_import_logs"
  ON public.tas_import_logs FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "authenticated write tas_import_logs"
  ON public.tas_import_logs FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Migration 2: tas_views_security_invoker
-- Fix: security_definer_view (ERROR level). Views now enforce caller's RLS.
-- Behavior change: tas_inmail_budget_view returns only caller's own rows
-- (tas_inmail_budget has per-user policies). No src/ references to any of
-- the three views as of 2026-07-08.
ALTER VIEW public.tas_pipeline_summary SET (security_invoker = true);
ALTER VIEW public.tas_inmail_budget_view SET (security_invoker = true);
ALTER VIEW public.tas_daily_action_queue SET (security_invoker = true);
