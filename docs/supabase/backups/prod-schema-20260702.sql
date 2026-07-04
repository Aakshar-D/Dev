


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."app_role" AS ENUM (
    'admin',
    'member',
    'viewer'
);


ALTER TYPE "public"."app_role" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_user_ref_columns"() RETURNS TABLE("reloid" "oid", "tbl" "text", "col" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select cl.oid, format('%I.%I', np.nspname, cl.relname), a.attname
  from pg_attribute a
  join pg_class cl     on cl.oid = a.attrelid
  join pg_namespace np on np.oid = cl.relnamespace
  where np.nspname = 'public'
    and cl.relkind = 'r'
    and a.attnum > 0
    and not a.attisdropped
    and a.atttypid = 'uuid'::regtype
    and a.attname <> 'id'
    and format('%I.%I', np.nspname, cl.relname) not in ('public.user_roles', 'public.user_role_assignments')
    and not exists (
      select 1 from pg_constraint k
      where k.contype = 'f'
        and k.conrelid = cl.oid
        and a.attnum = any (k.conkey)
        and k.confrelid not in ('auth.users'::regclass, 'public.profiles'::regclass)
    )
$$;


ALTER FUNCTION "public"."_user_ref_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."action_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid", "p_action" "text", "p_flag_reason" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_firm record;
  v_queue_id uuid;
  v_now timestamptz := now();
BEGIN
  IF p_action NOT IN ('CLAIMED', 'SKIPPED', 'FLAGGED') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid action');
  END IF;

  SELECT id, queue_id, partner_action INTO v_firm
  FROM public.sdr_firms WHERE id = p_firm_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm not found');
  END IF;
  v_queue_id := v_firm.queue_id;

  UPDATE public.sdr_firms
  SET partner_action = p_action,
      partner_action_at = v_now,
      partner_user_id = p_user_id,
      flag_reason = CASE WHEN p_action = 'FLAGGED' THEN p_flag_reason ELSE NULL END,
      partner_notes = COALESCE(p_notes, partner_notes),
      claimed_at = CASE WHEN p_action = 'CLAIMED' THEN v_now ELSE NULL END,
      is_available = CASE WHEN p_action = 'SKIPPED' THEN true ELSE false END,
      queue_id = CASE WHEN p_action = 'SKIPPED' THEN NULL ELSE queue_id END,
      outreach_status = CASE WHEN p_action = 'CLAIMED' THEN COALESCE(outreach_status, 'Not Started') ELSE outreach_status END
  WHERE id = p_firm_id;

  IF v_queue_id IS NOT NULL THEN
    UPDATE public.sdr_prospect_queues q
    SET firm_count     = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id),
        claimed_count  = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'CLAIMED'),
        skipped_count  = q.skipped_count + CASE WHEN p_action = 'SKIPPED' THEN 1 ELSE 0 END,
        flagged_count  = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'FLAGGED')
    WHERE q.id = v_queue_id;

    UPDATE public.sdr_prospect_queues q
    SET status = 'COMPLETED', completed_at = v_now
    WHERE q.id = v_queue_id
      AND q.firm_count > 0
      AND (q.claimed_count + q.flagged_count) >= q.firm_count
      AND q.status = 'ACTIVE';
  END IF;

  RETURN jsonb_build_object('success', true);
END $$;


ALTER FUNCTION "public"."action_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid", "p_action" "text", "p_flag_reason" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_mcp_connections"() RETURNS TABLE("user_id" "uuid", "full_name" "text", "email" "text", "connected_at" timestamp with time zone, "active_sessions" bigint, "last_token_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT public.has_permission(auth.uid(), 'admin.access') THEN
    RAISE EXCEPTION 'Not authorized: admin.access required'
      USING ERRCODE = '42501';  -- insufficient_privilege -> PostgREST 403
  END IF;

  RETURN QUERY
  WITH per_user AS (
    SELECT
      rt.user_id                                                                  AS uid,
      MIN(rt.created_at)                                                          AS connected_at,
      MAX(rt.created_at)                                                          AS last_token_at,
      COUNT(*) FILTER (WHERE rt.revoked_at IS NULL AND rt.expires_at > now())     AS active_sessions
    FROM public.oauth_refresh_tokens rt
    GROUP BY rt.user_id
  )
  SELECT
    pu.uid,
    p.full_name,
    COALESCE(p.email, u.email)        AS email,
    pu.connected_at,
    pu.active_sessions,
    pu.last_token_at
  FROM per_user pu
  LEFT JOIN public.profiles p ON p.id = pu.uid
  LEFT JOIN auth.users     u  ON u.id = pu.uid
  WHERE pu.active_sessions > 0
  ORDER BY pu.connected_at;
END;
$$;


ALTER FUNCTION "public"."admin_list_mcp_connections"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_list_mcp_connections"() IS 'Admin-only: one row per member with >=1 live MCP refresh token. connected_at = MIN(created_at) across the member''s refresh tokens (rotation-aware). Reads the service-role-only oauth_* tables via SECURITY DEFINER; gated on has_permission(auth.uid(), ''admin.access'').';



CREATE OR REPLACE FUNCTION "public"."admin_merge_user_data"("p_primary" "uuid", "p_secondary" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  fk        record;
  uc        record;
  moved     jsonb := '{}'::jsonb;
  conflicts jsonb := '[]'::jsonb;
  leftover  jsonb := '[]'::jsonb;
  n         bigint;
begin
  if p_primary is null or p_secondary is null or p_primary = p_secondary then
    raise exception 'admin_merge_user_data: invalid user ids';
  end if;

  -- A merge is a rare admin op that scans many tables; don't let a default
  -- statement timeout abort one partway through.
  perform set_config('statement_timeout', '0', true);

  for fk in select reloid, tbl, col from public._user_ref_columns()
  loop
    -- Precise, lossless dedup against every unique/PK constraint that includes
    -- this column: drop the secondary's rows that would collide with an existing
    -- primary row (matching on the constraint's other key columns). A secondary
    -- row is only removed when an equivalent primary row already exists.
    for uc in
      select (
        select string_agg(format('t.%I is not distinct from s.%I', kc.attname, kc.attname), ' and ')
        from unnest(u.conkey) k
        join pg_attribute kc on kc.attrelid = u.conrelid and kc.attnum = k
        where kc.attname <> fk.col
      ) as other_cond
      from pg_constraint u
      where u.conrelid = fk.reloid
        and u.contype in ('p', 'u')
        and fk.col = any (
          select ka.attname
          from unnest(u.conkey) k2
          join pg_attribute ka on ka.attrelid = u.conrelid and ka.attnum = k2
        )
    loop
      execute format(
        'delete from %s s where s.%I = $2 and exists (select 1 from %s t where t.%I = $1%s)',
        fk.tbl, fk.col, fk.tbl, fk.col,
        case when coalesce(uc.other_cond, '') = '' then '' else ' and ' || uc.other_cond end
      ) using p_primary, p_secondary;
    end loop;

    -- Reassign. Any residual unique violation (e.g. a partial unique index such
    -- as sdr_rule_sets_one_active_per_user, whose predicate can't be applied
    -- generically) is captured rather than aborting the merge: the rows are left
    -- on the secondary and reported in `conflicts` for manual follow-up.
    begin
      execute format('update %s set %I = $1 where %I = $2', fk.tbl, fk.col, fk.col)
        using p_primary, p_secondary;
      get diagnostics n = row_count;
      if n > 0 then
        moved := moved || jsonb_build_object(fk.tbl || '.' || fk.col, n);
      end if;
    exception when unique_violation then
      conflicts := conflicts || jsonb_build_array(jsonb_build_object('ref', fk.tbl || '.' || fk.col));
    end;
  end loop;

  -- Role grants are not merged onto the primary; discard the secondary's.
  delete from public.user_role_assignments where user_id = p_secondary;
  delete from public.user_roles            where user_id = p_secondary;

  -- Safety net: re-scan the SAME complete column set for anything still
  -- pointing at the secondary (captures skipped conflicts and is naming-
  -- independent, so it can't falsely report "lossless").
  for fk in select tbl, col from public._user_ref_columns()
  loop
    execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col)
      using p_secondary into n;
    if n > 0 then
      leftover := leftover || jsonb_build_array(jsonb_build_object('ref', fk.tbl || '.' || fk.col, 'n', n));
    end if;
  end loop;

  return jsonb_build_object('moved', moved, 'conflicts', conflicts, 'leftover', leftover);
end;
$_$;


ALTER FUNCTION "public"."admin_merge_user_data"("p_primary" "uuid", "p_secondary" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_revoked integer;
BEGIN
  IF NOT public.has_permission(auth.uid(), 'admin.access') THEN
    RAISE EXCEPTION 'Not authorized: admin.access required'
      USING ERRCODE = '42501';  -- insufficient_privilege -> PostgREST 403
  END IF;

  -- Revoke every non-revoked refresh token for the member (the durable
  -- connection) -- including any expired-but-unrevoked rows, so nothing live
  -- can survive. Mirrors revokeFamily()'s refresh-token revoke, but scoped to
  -- the user across all clients (a full admin disconnect, not one token family).
  -- Return the count of rows that were LIVE (revoked_at IS NULL AND
  -- expires_at > now()) so it matches the "active sessions" the admin saw in
  -- admin_list_mcp_connections; already-expired rows are cleaned up too but not
  -- counted (an expired refresh token is already unusable -- /token requires
  -- expires_at > now() -- so revoking it is housekeeping, not a killed session).
  WITH revoked AS (
    UPDATE public.oauth_refresh_tokens
    SET revoked_at = now()
    WHERE user_id = target_user_id
      AND revoked_at IS NULL
    RETURNING expires_at
  )
  SELECT COUNT(*) FILTER (WHERE expires_at > now())
  INTO v_revoked
  FROM revoked;

  -- Delete the member's access tokens so the disconnect is immediate; otherwise
  -- an already-issued Bearer token keeps working until it expires (~1h).
  DELETE FROM public.oauth_access_tokens
  WHERE user_id = target_user_id;

  RETURN v_revoked;
END;
$$;


ALTER FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") IS 'Admin-only: disconnect a member from the MCP connector -- revoke their non-revoked refresh tokens and delete their access tokens (immediate). Returns the number of LIVE sessions revoked (matches active_sessions in admin_list_mcp_connections). SECURITY DEFINER over the service-role-only oauth_* tables; gated on has_permission(auth.uid(), ''admin.access'').';



CREATE OR REPLACE FUNCTION "public"."approve_pending_user"("target_user_id" "uuid", "target_role" "text" DEFAULT 'member'::"text", "target_organization_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _role_name text;
  _role_id uuid;
BEGIN
  -- Only admins can call this
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    JOIN public.roles r ON r.id = p.role_id
    WHERE p.id = auth.uid()
      AND p.status = 'active'
      AND r.name = 'Admin'
  ) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  -- Map role param to role name
  _role_name := CASE target_role
    WHEN 'admin' THEN 'Admin'
    WHEN 'viewer' THEN 'Viewer'
    ELSE 'Member'
  END;
  SELECT id INTO _role_id FROM public.roles WHERE name = _role_name LIMIT 1;
  UPDATE public.profiles
  SET
    status = 'active',
    role_id = COALESCE(_role_id, role_id),
    organization_id = COALESCE(target_organization_id, organization_id)
  WHERE id = target_user_id;
END;
$$;


ALTER FUNCTION "public"."approve_pending_user"("target_user_id" "uuid", "target_role" "text", "target_organization_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_add_reassigned_collaborator"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to AND NEW.assigned_to IS NOT NULL THEN
    INSERT INTO public.task_collaborators (task_id, user_id, added_by)
    VALUES (NEW.id, NEW.assigned_to, NEW.updated_by)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_add_reassigned_collaborator"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_add_task_collaborators"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Add assigned_to as collaborator
  IF NEW.assigned_to IS NOT NULL THEN
    INSERT INTO public.task_collaborators (task_id, user_id, added_by)
    VALUES (NEW.id, NEW.assigned_to, NEW.assigned_by)
    ON CONFLICT DO NOTHING;
  END IF;

  -- Add assigned_by as collaborator
  IF NEW.assigned_by IS NOT NULL THEN
    INSERT INTO public.task_collaborators (task_id, user_id, added_by)
    VALUES (NEW.id, NEW.assigned_by, NEW.assigned_by)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_add_task_collaborators"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_complete_batch"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  -- When a prospect's partner_action is set, check if all prospects in the batch are done
  IF NEW.partner_action IS NOT NULL AND NEW.batch_id IS NOT NULL THEN
    -- Count remaining un-actioned prospects in this batch
    IF NOT EXISTS (
      SELECT 1 FROM bdr_prospects 
      WHERE batch_id = NEW.batch_id 
      AND partner_action IS NULL
      AND id != NEW.id
    ) THEN
      -- All prospects actioned — auto-complete the batch
      UPDATE bdr_batches 
      SET status = 'COMPLETED', 
          completed_at = now(),
          claimed_count = (SELECT count(*) FROM bdr_prospects WHERE batch_id = NEW.batch_id AND partner_action = 'CLAIM'),
          skipped_count = (SELECT count(*) FROM bdr_prospects WHERE batch_id = NEW.batch_id AND partner_action = 'SKIP'),
          flagged_count = (SELECT count(*) FROM bdr_prospects WHERE batch_id = NEW.batch_id AND partner_action = 'FLAG')
      WHERE id = NEW.batch_id 
      AND status = 'ACTIVE';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_complete_batch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bdr_email_templates_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."bdr_email_templates_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_claim_sdr_firms"("p_user_id" "uuid", "p_firm_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_now timestamptz := now();
  v_claimed int := 0;
  v_skipped int := 0;
  v_already_mine int := 0;
  v_not_found int := 0;
  v_queue_ids uuid[];
  v_input_count int;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  IF p_firm_ids IS NULL OR array_length(p_firm_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('success', true, 'claimed', 0, 'skipped', 0, 'already_mine', 0, 'not_found', 0);
  END IF;

  v_input_count := array_length(p_firm_ids, 1);

  -- Snapshot queues that will be touched, before we mutate
  SELECT COALESCE(array_agg(DISTINCT queue_id), ARRAY[]::uuid[]) INTO v_queue_ids
  FROM public.sdr_firms
  WHERE id = ANY(p_firm_ids) AND queue_id IS NOT NULL;

  -- Already mine: count up front so we can report
  SELECT COUNT(*) INTO v_already_mine
  FROM public.sdr_firms
  WHERE id = ANY(p_firm_ids)
    AND partner_action = 'CLAIMED'
    AND partner_user_id = p_user_id;

  -- Skipped: claimed by someone else, flagged, or otherwise not eligible
  SELECT COUNT(*) INTO v_skipped
  FROM public.sdr_firms
  WHERE id = ANY(p_firm_ids)
    AND partner_action IS NOT NULL
    AND NOT (partner_action = 'CLAIMED' AND partner_user_id = p_user_id);

  -- Claim every firm that isn't already actioned
  WITH updated AS (
    UPDATE public.sdr_firms
    SET partner_action = 'CLAIMED',
        partner_action_at = v_now,
        partner_user_id = p_user_id,
        flag_reason = NULL,
        claimed_at = v_now,
        is_available = false,
        outreach_status = COALESCE(outreach_status, 'Not Started')
    WHERE id = ANY(p_firm_ids)
      AND partner_action IS NULL
    RETURNING id
  )
  SELECT COUNT(*) INTO v_claimed FROM updated;

  v_not_found := v_input_count - (v_claimed + v_skipped + v_already_mine);
  IF v_not_found < 0 THEN v_not_found := 0; END IF;

  -- Recompute queue rollups for any queues we touched
  IF array_length(v_queue_ids, 1) IS NOT NULL THEN
    UPDATE public.sdr_prospect_queues q
    SET firm_count    = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id),
        claimed_count = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'CLAIMED'),
        flagged_count = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'FLAGGED')
    WHERE q.id = ANY(v_queue_ids);

    UPDATE public.sdr_prospect_queues q
    SET status = 'COMPLETED', completed_at = v_now
    WHERE q.id = ANY(v_queue_ids)
      AND q.firm_count > 0
      AND (q.claimed_count + q.flagged_count) >= q.firm_count
      AND q.status = 'ACTIVE';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'claimed', v_claimed,
    'already_mine', v_already_mine,
    'skipped', v_skipped,
    'not_found', v_not_found
  );
END
$$;


ALTER FUNCTION "public"."bulk_claim_sdr_firms"("p_user_id" "uuid", "p_firm_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.tasks t
    LEFT JOIN public.profiles asg ON asg.id = t.assigned_to
    WHERE t.id = tid
      AND (
        t.assigned_to = uid
        OR t.assigned_by = uid
        OR asg.manager_id = uid
        OR public.has_permission(uid, 'admin.access')
      )
  );
$$;


ALTER FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") IS 'True when uid may EDIT task tid (assignee, assignor, assignee''s manager, or admin.access). Mirrors the task panel edit gate; used by task_custom_field_values write RLS.';



CREATE OR REPLACE FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    public.has_permission(auth.uid(), 'admin.access')
    OR public.has_permission(auth.uid(), 'job_descriptions.manage')
    OR public.is_manager_in_chain(p_profile_id);
$$;


ALTER FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") IS 'True when the current user may create/edit p_profile_id''s job description: admin.access, job_descriptions.manage, or a manager up the manager_id chain.';



CREATE OR REPLACE FUNCTION "public"."can_manage_project"("_user_id" "uuid", "_project_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT public.has_role(_user_id, 'admin'::app_role)
      OR EXISTS (
           SELECT 1 FROM public.projects p
           WHERE p.id = _project_id
             AND (p.owner_id = _user_id OR p.created_by = _user_id)
         )
$$;


ALTER FUNCTION "public"."can_manage_project"("_user_id" "uuid", "_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ SELECT EXISTS (SELECT 1 FROM public.task_project_memberships m
                     WHERE m.task_id = tid AND public.is_project_member(uid, m.project_id)); $$;


ALTER FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") IS 'True when task tid is multi-homed into at least one project uid is a member of (public.is_project_member). SECURITY DEFINER to bypass task_project_memberships RLS and avoid the tasks<->memberships recursion; returns only a boolean. Admins are covered by the existing "Users can read relevant tasks" policy and are intentionally not re-checked here. Used by the tasks SELECT policy "Members can read tasks in their projects".';



CREATE OR REPLACE FUNCTION "public"."can_view_rtl_contact"("p_contact_org_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  -- Admin: see all
  IF EXISTS (
    SELECT 1 FROM public.user_role_assignments ura
    JOIN public.custom_roles cr ON cr.id = ura.role_id
    WHERE ura.user_id = auth.uid() AND cr.is_system = true AND cr.name = 'Admin'
  ) THEN RETURN true; END IF;

  -- wealth.view_all: see all
  IF EXISTS (
    SELECT 1 FROM public.user_role_assignments ura
    JOIN public.role_permissions rp ON rp.role_id = ura.role_id
    WHERE ura.user_id = auth.uid() AND rp.permission_key = 'wealth.view_all'
  ) THEN RETURN true; END IF;

  -- wealth.view: see only own org
  IF p_contact_org_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.user_role_assignments ura
    JOIN public.role_permissions rp ON rp.role_id = ura.role_id
    WHERE ura.user_id = auth.uid() AND rp.permission_key = 'wealth.view'
  ) AND EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND organization_id = p_contact_org_id
  ) THEN RETURN true; END IF;

  RETURN false;
END;
$$;


ALTER FUNCTION "public"."can_view_rtl_contact"("p_contact_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clone_sdr_rule_set"("p_source_id" "uuid", "p_new_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
  v_new_id uuid;
BEGIN
  SELECT user_id INTO v_user_id
  FROM public.sdr_rule_sets
  WHERE id = p_source_id;

  IF v_user_id IS NULL OR v_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Rule set not found or not owned by caller';
  END IF;

  IF p_new_name IS NULL OR length(trim(p_new_name)) = 0 THEN
    RAISE EXCEPTION 'New name is required';
  END IF;

  INSERT INTO public.sdr_rule_sets (user_id, name, is_active)
  VALUES (auth.uid(), trim(p_new_name), false)
  RETURNING id INTO v_new_id;

  INSERT INTO public.sdr_email_templates (
    user_id, kind, label, content, sort_order, active, strength, rule_set_id
  )
  SELECT user_id, kind, label, content, sort_order, active, strength, v_new_id
  FROM public.sdr_email_templates
  WHERE rule_set_id = p_source_id;

  RETURN v_new_id;
END;
$$;


ALTER FUNCTION "public"."clone_sdr_rule_set"("p_source_id" "uuid", "p_new_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_filtered_batch"("p_user_id" "uuid", "p_user_name" "text", "p_title_categories" "text"[] DEFAULT NULL::"text"[], "p_states" "text"[] DEFAULT NULL::"text"[], "p_sectors" "text"[] DEFAULT NULL::"text"[], "p_re_flag" boolean DEFAULT NULL::boolean, "p_rd_flag" boolean DEFAULT NULL::boolean, "p_batch_size" integer DEFAULT 10) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_batch_id uuid;
  v_batch_number int;
  v_matched_count int;
  v_assigned_count int;
  v_prospect_ids uuid[];
BEGIN
  IF EXISTS (
    SELECT 1 FROM bdr_batches
    WHERE partner_user_id = p_user_id AND status = 'ACTIVE'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You already have an active batch. Complete it before requesting a new one.'
    );
  END IF;

  SELECT array_agg(p.id ORDER BY random())
  INTO v_prospect_ids
  FROM bdr_prospects p
  JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true
    AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL
    AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  v_matched_count := coalesce(array_length(v_prospect_ids, 1), 0);

  IF v_matched_count = 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'No available prospects match your filters. Try broadening your criteria.'
    );
  END IF;

  IF v_matched_count > p_batch_size THEN
    v_prospect_ids := v_prospect_ids[1:p_batch_size];
  END IF;

  v_assigned_count := array_length(v_prospect_ids, 1);

  SELECT coalesce(max(batch_number), 0) + 1 INTO v_batch_number
  FROM bdr_batches
  WHERE partner_user_id = p_user_id;

  INSERT INTO bdr_batches (id, batch_number, partner_user_id, partner_name, prospect_count, claimed_count, skipped_count, flagged_count, status, created_at)
  VALUES (gen_random_uuid(), v_batch_number, p_user_id, p_user_name, v_assigned_count, 0, 0, 0, 'ACTIVE', now())
  RETURNING id INTO v_batch_id;

  -- Reset partner_action for re-batched skipped prospects
  UPDATE bdr_prospects
  SET batch_id = v_batch_id, is_available = false, partner_action = NULL, partner_action_at = NULL, flag_reason = NULL
  WHERE id = ANY(v_prospect_ids);

  RETURN jsonb_build_object(
    'success', true,
    'batch_id', v_batch_id,
    'batch_number', v_batch_number,
    'prospect_count', v_assigned_count,
    'matched_available', v_matched_count
  );
END;
$$;


ALTER FUNCTION "public"."create_filtered_batch"("p_user_id" "uuid", "p_user_name" "text", "p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean, "p_batch_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_sdr_queue"("p_user_id" "uuid", "p_user_name" "text", "p_queue_name" "text", "p_queue_size" integer, "p_states" "text"[] DEFAULT NULL::"text"[], "p_min_staff" integer DEFAULT NULL::integer, "p_max_staff" integer DEFAULT NULL::integer, "p_min_partners" integer DEFAULT NULL::integer, "p_max_partners" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_queue_id uuid;
  v_queue_number int;
  v_firm_count int;
  v_filters jsonb;
BEGIN
  v_filters := jsonb_build_object(
    'states', p_states,
    'min_staff', p_min_staff,
    'max_staff', p_max_staff,
    'min_partners', p_min_partners,
    'max_partners', p_max_partners,
    'requested_size', p_queue_size
  );

  SELECT COALESCE(MAX(queue_number), 0) + 1 INTO v_queue_number
  FROM public.sdr_prospect_queues WHERE partner_user_id = p_user_id;

  INSERT INTO public.sdr_prospect_queues (
    partner_user_id, partner_name, queue_number, queue_name, status,
    firm_count, filters
  ) VALUES (
    p_user_id, p_user_name, v_queue_number, p_queue_name, 'ACTIVE', 0, v_filters
  )
  RETURNING id INTO v_queue_id;

  WITH picked AS (
    SELECT f.id,
      (
        (CASE WHEN f.strategic_direction IS NOT NULL AND length(f.strategic_direction) >= 50 THEN 40 ELSE 0 END)
      + (CASE WHEN f.specialty IS NOT NULL AND length(f.specialty) >= 20 THEN 15 ELSE 0 END)
      + (CASE WHEN f.services_offered IS NOT NULL AND jsonb_array_length(f.services_offered) >= 1 THEN 15 ELSE 0 END)
      + (CASE WHEN f.niches IS NOT NULL AND array_length(f.niches, 1) >= 1 THEN 10 ELSE 0 END)
      + (CASE WHEN (f.known_team_members IS NOT NULL AND length(f.known_team_members) >= 20)
              OR EXISTS (SELECT 1 FROM public.sdr_firm_staff s WHERE s.firm_id = f.id) THEN 10 ELSE 0 END)
      + (CASE WHEN f.icp_revenue_fit IS NOT NULL
              AND f.icp_revenue_fit NOT LIKE 'VERIFY - Auto-imported%'
              AND f.icp_revenue_fit NOT LIKE 'VERIFY (Seamless:%' THEN 10 ELSE 0 END)
      ) AS score
    FROM public.sdr_firms f
    WHERE f.is_available IS TRUE
      AND f.partner_action IS NULL
      AND f.hubspot_owner_email IS NULL
      -- Tight gate: fully researched only.
      AND f.strategic_direction IS NOT NULL
      AND length(f.strategic_direction) >= 50
      AND f.icp_revenue_fit IS NOT NULL
      AND f.icp_revenue_fit NOT LIKE 'VERIFY - Auto-imported%'
      AND f.icp_revenue_fit NOT LIKE 'VERIFY (Seamless:%'
      AND f.icp_revenue_fit NOT LIKE '%SKIP%'
      AND f.icp_revenue_fit NOT LIKE '❌%'
      AND f.icp_revenue_fit NOT ILIKE '%acquired%'
      AND f.icp_revenue_fit NOT LIKE 'OUT OF GEO%'
      AND f.icp_revenue_fit NOT LIKE 'WRONG INDUSTRY%'
      AND f.icp_revenue_fit NOT LIKE 'BELOW ICP%'
      AND f.icp_revenue_fit NOT LIKE 'Below ICP%'
      AND f.icp_revenue_fit NOT LIKE 'Above ICP%'
      AND NOT public.is_seamless_default_revenue(f.est_revenue)
      AND NOT public.is_seamless_default_staff(f.staff_est)
      AND f.partner_count IS NOT NULL
      AND (
        (f.known_team_members IS NOT NULL AND length(f.known_team_members) >= 20)
        OR EXISTS (SELECT 1 FROM public.sdr_firm_staff s WHERE s.firm_id = f.id)
      )
      -- Geography/staff/partner filters from caller
      AND (p_states IS NULL OR f.state = ANY(p_states))
      AND (p_min_staff IS NULL OR public.parse_staff_count(f.staff_est) >= p_min_staff)
      AND (p_max_staff IS NULL OR public.parse_staff_count(f.staff_est) <= p_max_staff)
      AND (p_min_partners IS NULL OR COALESCE(f.partner_count, 0) >= p_min_partners)
      AND (p_max_partners IS NULL OR COALESCE(f.partner_count, 0) <= p_max_partners)
    ORDER BY score DESC, f.created_at DESC
    LIMIT p_queue_size
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.sdr_firms f
  SET queue_id = v_queue_id, is_available = false
  FROM picked
  WHERE f.id = picked.id;

  GET DIAGNOSTICS v_firm_count = ROW_COUNT;

  UPDATE public.sdr_prospect_queues
  SET firm_count = v_firm_count
  WHERE id = v_queue_id;

  RETURN jsonb_build_object(
    'success', true,
    'queue_id', v_queue_id,
    'queue_number', v_queue_number,
    'firm_count', v_firm_count
  );
END $$;


ALTER FUNCTION "public"."create_sdr_queue"("p_user_id" "uuid", "p_user_name" "text", "p_queue_name" "text", "p_queue_size" integer, "p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_sdr_rule_set"("p_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_new_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Name is required';
  END IF;

  INSERT INTO public.sdr_rule_sets (user_id, name, is_active)
  VALUES (auth.uid(), trim(p_name), false)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;


ALTER FUNCTION "public"."create_sdr_rule_set"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_sdr_rule_set"("p_rule_set_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
  v_is_active boolean;
  v_total integer;
BEGIN
  SELECT user_id, is_active INTO v_user_id, v_is_active
  FROM public.sdr_rule_sets
  WHERE id = p_rule_set_id;

  IF v_user_id IS NULL OR v_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Rule set not found or not owned by caller';
  END IF;

  IF v_is_active THEN
    RAISE EXCEPTION 'Cannot delete the active rule set. Set another rule set as active first.';
  END IF;

  SELECT COUNT(*) INTO v_total FROM public.sdr_rule_sets WHERE user_id = auth.uid();
  IF v_total <= 1 THEN
    RAISE EXCEPTION 'Cannot delete the last rule set.';
  END IF;

  DELETE FROM public.sdr_rule_sets WHERE id = p_rule_set_id;
END;
$$;


ALTER FUNCTION "public"."delete_sdr_rule_set"("p_rule_set_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Engagement-derived tasks (Fathom action items + desk-created), shared table.
  -- tasks.source_reference_id is a uuid column, so compare uuid-to-uuid.
  DELETE FROM public.tasks
   WHERE source_type = 'ssg_engagement'
     AND source_reference_id = _engagement_id;

  -- Cascades to ssg_outcomes / ssg_meetings / ssg_engagement_contacts /
  -- ssg_calendar_events / ssg_emails / ssg_insights via ON DELETE CASCADE.
  DELETE FROM public.ssg_engagements WHERE id = _engagement_id;
END;
$$;


ALTER FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bdr_crawl_stats"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'total_prospects', count(*),
    'fully_crawled', count(*) FILTER (WHERE verified_title IS NOT NULL AND bio_background IS NOT NULL),
    'uncrawled', count(*) FILTER (WHERE verified_title IS NULL OR bio_background IS NULL),
    'approved', count(*) FILTER (WHERE verdict = 'approve'),
    'skipped', count(*) FILTER (WHERE verdict = 'skip'),
    'verify', count(*) FILTER (WHERE verdict = 'verify'),
    'existing_client', count(*) FILTER (WHERE verdict = 'existing_client'),
    'no_verdict', count(*) FILTER (WHERE verdict IS NULL),
    'has_email_draft', count(*) FILTER (WHERE draft_email_long IS NOT NULL AND draft_email_long != ''),
    'has_hook', count(*) FILTER (WHERE personalization_hook IS NOT NULL AND personalization_hook != ''),
    'has_photo', count(*) FILTER (WHERE photo_url IS NOT NULL AND photo_url != ''),
    'has_biz_type', count(*) FILTER (WHERE business_model_type IS NOT NULL AND business_model_type != ''),
    'has_tags', count(*) FILTER (WHERE accounting_complexity_tags IS NOT NULL AND array_length(accounting_complexity_tags, 1) > 0),
    'pool_ready', count(*) FILTER (WHERE verdict IN ('approve', 'verify') AND verified_title IS NOT NULL AND bio_background IS NOT NULL AND is_available = true AND partner_action IS NULL AND batch_id IS NULL),
    'in_batches', count(*) FILTER (WHERE batch_id IS NOT NULL),
    'actioned', count(*) FILTER (WHERE partner_action IS NOT NULL),
    'staging_pending', (SELECT count(*) FROM bdr_seamless_staging WHERE processed IS NOT TRUE),
    'staging_total', (SELECT count(*) FROM bdr_seamless_staging)
  ) INTO result
  FROM bdr_prospects;

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_bdr_crawl_stats"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."bdr_email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "label" "text",
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "strength" "text" DEFAULT 'suggested'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bdr_email_templates_kind_check" CHECK (("kind" = ANY (ARRAY['example'::"text", 'instruction'::"text"]))),
    CONSTRAINT "bdr_email_templates_strength_check" CHECK (("strength" = ANY (ARRAY['required'::"text", 'suggested'::"text", 'context'::"text"])))
);


ALTER TABLE "public"."bdr_email_templates" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bdr_email_templates_for"("p_user_id" "uuid") RETURNS SETOF "public"."bdr_email_templates"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT *
  FROM public.bdr_email_templates
  WHERE user_id = p_user_id
  ORDER BY kind, sort_order, created_at
$$;


ALTER FUNCTION "public"."get_bdr_email_templates_for"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bdr_geocode_coverage"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM public.bdr_businesses),
    'geocoded', (SELECT COUNT(*) FROM public.bdr_businesses WHERE latitude IS NOT NULL AND longitude IS NOT NULL),
    'pending', (SELECT COUNT(*) FROM public.bdr_businesses
                WHERE (latitude IS NULL OR longitude IS NULL)
                  AND (location_city IS NOT NULL OR location_state IS NOT NULL)),
    'no_address', (SELECT COUNT(*) FROM public.bdr_businesses
                   WHERE (latitude IS NULL OR longitude IS NULL)
                     AND location_city IS NULL AND location_state IS NULL)
  )
$$;


ALTER FUNCTION "public"."get_bdr_geocode_coverage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_effective_folder_visibility"("_folder_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _current_id uuid := _folder_id;
  _vis text;
  _parent uuid;
BEGIN
  WHILE _current_id IS NOT NULL LOOP
    SELECT default_visibility, parent_id INTO _vis, _parent
    FROM public.document_folders WHERE id = _current_id;
    IF NOT FOUND THEN EXIT; END IF;
    IF _vis = 'private' THEN RETURN 'private'; END IF;
    _current_id := _parent;
  END LOOP;
  RETURN 'alliance';
END;
$$;


ALTER FUNCTION "public"."get_effective_folder_visibility"("_folder_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_filtered_prospect_count"("p_title_categories" "text"[] DEFAULT NULL::"text"[], "p_states" "text"[] DEFAULT NULL::"text"[], "p_sectors" "text"[] DEFAULT NULL::"text"[], "p_re_flag" boolean DEFAULT NULL::boolean, "p_rd_flag" boolean DEFAULT NULL::boolean) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM bdr_prospects p
  JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true
    AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL
    AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."get_filtered_prospect_count"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_api_token_info"() RETURNS TABLE("mcp_api_token_preview" "text", "mcp_api_token_created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT p.mcp_api_token_preview, p.mcp_api_token_created_at
  FROM public.profiles p
  WHERE p.id = auth.uid()
$$;


ALTER FUNCTION "public"."get_my_api_token_info"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_claimed_firms"("p_user_id" "uuid") RETURNS TABLE("id" "uuid", "firm_name" "text", "website" "text", "state" "text", "location" "text", "est_revenue" "text", "staff_est" "text", "partner_count" integer, "specialty" "text", "firm_status" "text", "outreach_status" "text", "outreach_status_updated_at" timestamp with time zone, "claimed_at" timestamp with time zone, "days_since_update" integer, "hubspot_company_id" "text", "hubspot_owner_email" "text", "source" "text", "contact_count" integer, "queue_number" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT f.id, f.firm_name, f.website, f.state, f.location, f.est_revenue,
         f.staff_est, f.partner_count, f.specialty, f.firm_status,
         COALESCE(f.outreach_status, 'Not Started') AS outreach_status,
         f.outreach_status_updated_at,
         f.claimed_at,
         EXTRACT(DAY FROM now() - COALESCE(f.outreach_status_updated_at, f.claimed_at))::int AS days_since_update,
         f.hubspot_company_id,
         f.hubspot_owner_email,
         'claimed'::text AS source,
         (SELECT COUNT(*)::int FROM public.sdr_contacts c WHERE c.firm_id = f.id) AS contact_count,
         q.queue_number
  FROM public.sdr_firms f
  LEFT JOIN public.sdr_prospect_queues q ON q.id = f.queue_id
  WHERE f.partner_action = 'CLAIMED' AND f.partner_user_id = p_user_id
  ORDER BY
    COALESCE(f.outreach_status_updated_at, f.claimed_at) DESC NULLS LAST
$$;


ALTER FUNCTION "public"."get_my_claimed_firms"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_claimed_prospects"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(row ORDER BY row.days_since_update DESC NULLS LAST), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      p.id,
      p.contact_name,
      p.verified_title,
      p.email,
      p.phone,
      p.linkedin_url,
      p.website,
      p.verdict,
      p.personalization_hook,
      p.bio_background,
      p.business_model_type,
      p.accounting_complexity_tags,
      p.draft_email_short,
      p.draft_email_long,
      p.partner_notes,
      p.partner_action_at,
      p.outreach_status,
      p.outreach_status_updated_at,
      p.photo_url,
      p.batch_id,
      b2.batch_number,
      biz.business_name,
      biz.logo_url,
      biz.location_city,
      biz.location_state,
      biz.est_revenue_researched,
      biz.staff_estimate_researched,
      biz.website as biz_website,
      -- Staleness: days since last outreach status update (or claim date if never updated)
      EXTRACT(DAY FROM now() - coalesce(p.outreach_status_updated_at, p.partner_action_at))::int as days_since_update,
      -- Email activity summary
      (SELECT count(*) FROM email_activity_log eal WHERE eal.prospect_id = p.id) as email_activity_count,
      (SELECT max(eal.created_at) FROM email_activity_log eal WHERE eal.prospect_id = p.id) as last_email_activity
    FROM bdr_prospects p
    JOIN bdr_batches b2 ON b2.id = p.batch_id
    LEFT JOIN bdr_businesses biz ON biz.id = p.business_id
    WHERE p.partner_action = 'CLAIMED'
      AND b2.partner_user_id = p_user_id
    ORDER BY
      CASE p.outreach_status
        WHEN 'Not Started' THEN 1
        WHEN 'Email Sent' THEN 2
        WHEN 'Follow-Up Sent' THEN 3
        WHEN 'No Response' THEN 4
        WHEN 'Meeting Scheduled' THEN 5
        WHEN 'Converted' THEN 6
        WHEN 'Declined' THEN 7
        ELSE 0
      END,
      p.partner_action_at DESC
  ) row;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_my_claimed_prospects"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_onboarding_overdue_summary"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _result jsonb;
BEGIN
  WITH onb AS (
    -- Active projects created from the "Firm Onboarding" template.
    SELECT
      p.id   AS project_id,
      p.name AS project_name,
      p.assigned_to_org AS org_id,
      COALESCE(o.name, 'Unassigned') AS org_name,
      p.start_date
    FROM projects p
    JOIN project_templates pt ON pt.id = p.template_id
    LEFT JOIN organizations o ON o.id = p.assigned_to_org
    WHERE pt.name = 'Firm Onboarding'
      AND p.status = 'active'
  ),
  task_stats AS (
    -- Per-project task rollups. LEFT JOIN so projects with no tasks still
    -- report zeros rather than dropping out.
    SELECT
      onb.project_id,
      COUNT(t.id) AS total_tasks,
      COUNT(t.id) FILTER (WHERE t.status = 'complete') AS completed_tasks,
      COUNT(t.id) FILTER (
        WHERE t.due_date < CURRENT_DATE
          AND t.status != 'complete'
          AND t.completed_at IS NULL
      ) AS overdue_count
    FROM onb
    LEFT JOIN tasks t
      ON t.project_id = onb.project_id
     AND t.source_type = 'project'
    GROUP BY onb.project_id
  ),
  overdue_tasks AS (
    -- One row per overdue task, with its owner resolved.
    SELECT
      onb.project_id,
      t.assigned_to,
      COALESCE(pr.full_name, pr.email, 'Unassigned') AS assignee_name,
      pr.avatar_url
    FROM onb
    JOIN tasks t
      ON t.project_id = onb.project_id
     AND t.source_type = 'project'
     AND t.due_date < CURRENT_DATE
     AND t.status != 'complete'
     AND t.completed_at IS NULL
    LEFT JOIN profiles pr ON pr.id = t.assigned_to
  ),
  per_project_owners AS (
    -- Who is behind on each checklist (overdue count by owner, per project).
    SELECT
      project_id,
      jsonb_agg(
        jsonb_build_object(
          'assignee_id', assigned_to,
          'assignee_name', assignee_name,
          'overdue_count', cnt
        ) ORDER BY cnt DESC, assignee_name
      ) AS owners
    FROM (
      SELECT project_id, assigned_to, assignee_name, COUNT(*)::int AS cnt
      FROM overdue_tasks
      GROUP BY project_id, assigned_to, assignee_name
    ) ppo
    GROUP BY project_id
  ),
  global_owners AS (
    -- Who owns overdue tasks across all active onboardings.
    SELECT jsonb_agg(
      jsonb_build_object(
        'assignee_id', assigned_to,
        'assignee_name', assignee_name,
        'avatar_url', avatar_url,
        'overdue_count', cnt
      ) ORDER BY cnt DESC, assignee_name
    ) AS owner_breakdown
    FROM (
      SELECT assigned_to, assignee_name, MAX(avatar_url) AS avatar_url, COUNT(*)::int AS cnt
      FROM overdue_tasks
      GROUP BY assigned_to, assignee_name
    ) go
  ),
  projects_json AS (
    SELECT jsonb_agg(
      jsonb_build_object(
        'project_id', onb.project_id,
        'project_name', onb.project_name,
        'org_id', onb.org_id,
        'org_name', onb.org_name,
        'start_date', onb.start_date,
        'overdue_count', ts.overdue_count::int,
        'total_tasks', ts.total_tasks::int,
        'completed_tasks', ts.completed_tasks::int,
        'open_tasks', (ts.total_tasks - ts.completed_tasks)::int,
        'owners', COALESCE(ppo.owners, '[]'::jsonb)
      ) ORDER BY ts.overdue_count DESC, onb.project_name
    ) AS project_breakdown
    FROM onb
    JOIN task_stats ts ON ts.project_id = onb.project_id
    LEFT JOIN per_project_owners ppo ON ppo.project_id = onb.project_id
  )
  SELECT jsonb_build_object(
    'total_overdue', COALESCE((SELECT SUM(overdue_count) FROM task_stats), 0)::int,
    'active_onboardings', (SELECT COUNT(*) FROM onb)::int,
    'firms_with_overdue', (SELECT COUNT(*) FROM task_stats WHERE overdue_count > 0)::int,
    'owner_breakdown', COALESCE((SELECT owner_breakdown FROM global_owners), '[]'::jsonb),
    'project_breakdown', COALESCE((SELECT project_breakdown FROM projects_json), '[]'::jsonb)
  )
  INTO _result;

  RETURN _result;
END;
$$;


ALTER FUNCTION "public"."get_onboarding_overdue_summary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_user_tokens"("p_user_id" "uuid") RETURNS TABLE("invite_token" "text", "invite_token_expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT p.invite_token, p.invite_token_expires_at
  FROM public.profiles p
  WHERE p.id = p_user_id
    AND EXISTS (
      SELECT 1 FROM public.user_role_assignments ura
      JOIN public.custom_roles cr ON cr.id = ura.role_id
      WHERE ura.user_id = auth.uid()
        AND cr.name = 'Admin'
        AND cr.is_system = true
    )
$$;


ALTER FUNCTION "public"."get_pending_user_tokens"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pool_stats"("p_title_categories" "text"[] DEFAULT NULL::"text"[], "p_states" "text"[] DEFAULT NULL::"text"[], "p_sectors" "text"[] DEFAULT NULL::"text"[], "p_re_flag" boolean DEFAULT NULL::boolean, "p_rd_flag" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  result jsonb;
  v_total int;
  v_by_title jsonb;
  v_by_state jsonb;
  v_by_city jsonb;
  v_by_sector jsonb;
  v_by_size jsonb;
  v_re_count int;
  v_rd_count int;
  v_vc_count int;
  v_nonprofit_count int;
  v_has_email int;
  v_has_draft int;
BEGIN
  -- Base WHERE condition used throughout:
  -- p.is_available = true AND p.verdict IN ('approve','verify') AND verified_title/bio NOT NULL
  -- AND (partner_action IS NULL OR partner_action = 'SKIPPED')
  -- AND (batch_id IS NULL OR partner_action = 'SKIPPED')

  -- Total available
  SELECT count(*) INTO v_total
  FROM bdr_prospects p
  LEFT JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true
    AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  -- By title category
  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.cnt DESC), '[]'::jsonb) INTO v_by_title
  FROM (
    SELECT p.title_category as label, count(*) as cnt
    FROM bdr_prospects p
    LEFT JOIN bdr_businesses b ON b.id = p.business_id
    WHERE p.is_available = true
      AND p.verdict IN ('approve', 'verify')
      AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
      AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
      AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
      AND p.title_category IS NOT NULL AND p.title_category != ''
      AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
      AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
      AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
      AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag)
    GROUP BY p.title_category
  ) t;

  -- By state
  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.cnt DESC), '[]'::jsonb) INTO v_by_state
  FROM (
    SELECT p.location_state as label, count(*) as cnt
    FROM bdr_prospects p
    LEFT JOIN bdr_businesses b ON b.id = p.business_id
    WHERE p.is_available = true
      AND p.verdict IN ('approve', 'verify')
      AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
      AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
      AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
      AND p.location_state IS NOT NULL AND p.location_state != ''
      AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
      AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
      AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
      AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag)
    GROUP BY p.location_state
  ) t;

  -- By city (top 15)
  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.cnt DESC), '[]'::jsonb) INTO v_by_city
  FROM (
    SELECT b.location_city || ', ' || b.location_state as label, count(*) as cnt
    FROM bdr_prospects p
    JOIN bdr_businesses b ON b.id = p.business_id
    WHERE p.is_available = true
      AND p.verdict IN ('approve', 'verify')
      AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
      AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
      AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
      AND b.location_city IS NOT NULL AND b.location_city != ''
      AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
      AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
      AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
      AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag)
    GROUP BY b.location_city, b.location_state
    ORDER BY count(*) DESC
    LIMIT 15
  ) t;

  -- By sector
  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.cnt DESC), '[]'::jsonb) INTO v_by_sector
  FROM (
    SELECT b.sector as label, count(*) as cnt
    FROM bdr_prospects p
    JOIN bdr_businesses b ON b.id = p.business_id
    WHERE p.is_available = true
      AND p.verdict IN ('approve', 'verify')
      AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
      AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
      AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
      AND b.sector IS NOT NULL AND b.sector != ''
      AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
      AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
      AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
      AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag)
    GROUP BY b.sector
  ) t;

  -- By company size
  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.sort_order), '[]'::jsonb) INTO v_by_size
  FROM (
    SELECT 
      CASE 
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 10 THEN '1-10'
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 50 THEN '11-50'
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 200 THEN '51-200'
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 500 THEN '201-500'
        ELSE '500+'
      END as label,
      CASE 
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 10 THEN 1
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 50 THEN 2
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 200 THEN 3
        WHEN cast(regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') as integer) <= 500 THEN 4
        ELSE 5
      END as sort_order,
      count(*) as cnt
    FROM bdr_prospects p
    JOIN bdr_businesses b ON b.id = p.business_id
    WHERE p.is_available = true
      AND p.verdict IN ('approve', 'verify')
      AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
      AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
      AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
      AND b.staff_estimate_researched IS NOT NULL AND b.staff_estimate_researched != ''
      AND regexp_replace(b.staff_estimate_researched, '[^0-9]', '', 'g') != ''
      AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
      AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
      AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
      AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
      AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag)
    GROUP BY 1, 2
  ) t;

  -- Flag counts
  SELECT count(*) INTO v_re_count FROM bdr_prospects p LEFT JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND p.real_estate_flag = true
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  SELECT count(*) INTO v_rd_count FROM bdr_prospects p LEFT JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND p.rd_flag = true
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag);

  SELECT count(*) INTO v_vc_count FROM bdr_prospects p JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND b.vc_backed_flag = true
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  SELECT count(*) INTO v_nonprofit_count FROM bdr_prospects p JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND b.nonprofit_flag = true
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  SELECT count(*) INTO v_has_email FROM bdr_prospects p LEFT JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND p.email IS NOT NULL AND p.email != ''
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  SELECT count(*) INTO v_has_draft FROM bdr_prospects p LEFT JOIN bdr_businesses b ON b.id = p.business_id
  WHERE p.is_available = true AND p.verdict IN ('approve', 'verify')
    AND p.verified_title IS NOT NULL AND p.bio_background IS NOT NULL
    AND (p.partner_action IS NULL OR p.partner_action = 'SKIPPED')
    AND (p.batch_id IS NULL OR p.partner_action = 'SKIPPED')
    AND p.draft_email_long IS NOT NULL AND p.draft_email_long != ''
    AND (p_title_categories IS NULL OR array_length(p_title_categories, 1) IS NULL OR p.title_category = ANY(p_title_categories))
    AND (p_states IS NULL OR array_length(p_states, 1) IS NULL OR p.location_state = ANY(p_states))
    AND (p_sectors IS NULL OR array_length(p_sectors, 1) IS NULL OR b.sector = ANY(p_sectors))
    AND (p_re_flag IS NULL OR p.real_estate_flag = p_re_flag)
    AND (p_rd_flag IS NULL OR p.rd_flag = p_rd_flag);

  result := jsonb_build_object(
    'total_available', v_total,
    'by_title_category', v_by_title,
    'by_state', v_by_state,
    'by_city', v_by_city,
    'by_sector', v_by_sector,
    'by_company_size', v_by_size,
    'by_re_flag', v_re_count,
    'by_rd_flag', v_rd_count,
    'by_vc_flag', v_vc_count,
    'by_nonprofit_flag', v_nonprofit_count,
    'has_email', v_has_email,
    'has_draft', v_has_draft
  );

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_pool_stats"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_eligible_gap_count"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  with eligible as (
    select f.*
      from public.sdr_firms f
     where f.is_available is true
       and f.partner_action is null
       and f.hubspot_owner_email is null
       and f.strategic_direction is not null
       and length(f.strategic_direction) >= 50
       and (f.icp_revenue_fit is null
            or (f.icp_revenue_fit not like 'VERIFY - Auto-imported%'
                and f.icp_revenue_fit not like 'VERIFY (Seamless:%'))
       and (f.icp_revenue_fit is null
            or (f.icp_revenue_fit not like '%SKIP%'
                and f.icp_revenue_fit not like '❌%'
                and f.icp_revenue_fit not ilike '%acquired%'
                and f.icp_revenue_fit not like 'OUT OF GEO%'
                and f.icp_revenue_fit not like 'WRONG INDUSTRY%'
                and f.icp_revenue_fit not like 'BELOW ICP%'
                and f.icp_revenue_fit not like 'Below ICP%'
                and f.icp_revenue_fit not like 'Above ICP%'))
  )
  select jsonb_build_object(
    'total_eligible', count(*),
    'with_gaps', count(*) filter (
      where public.is_seamless_default_revenue(est_revenue)
         or public.is_seamless_default_staff(staff_est)
         or partner_count is null
    )
  )
  from eligible;
$$;


ALTER FUNCTION "public"."get_sdr_eligible_gap_count"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "label" "text",
    "content" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "strength" "text" DEFAULT 'suggested'::"text" NOT NULL,
    "rule_set_id" "uuid" NOT NULL,
    CONSTRAINT "sdr_email_templates_kind_check" CHECK (("kind" = ANY (ARRAY['example'::"text", 'instruction'::"text", 'followup-example'::"text", 'followup-instruction'::"text"]))),
    CONSTRAINT "sdr_email_templates_strength_check" CHECK (("strength" = ANY (ARRAY['required'::"text", 'suggested'::"text", 'context'::"text"])))
);


ALTER TABLE "public"."sdr_email_templates" OWNER TO "postgres";


COMMENT ON TABLE "public"."sdr_email_templates" IS 'Per-user email examples and drafting instructions used by MCP email tools.';



COMMENT ON COLUMN "public"."sdr_email_templates"."strength" IS 'How strictly Claude should apply this template/instruction when drafting. required=must follow, suggested=should try to follow (default), context=awareness only.';



CREATE OR REPLACE FUNCTION "public"."get_sdr_email_templates_for"("p_user_id" "uuid") RETURNS SETOF "public"."sdr_email_templates"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT t.*
  FROM public.sdr_email_templates t
  JOIN public.sdr_rule_sets rs ON rs.id = t.rule_set_id
  WHERE rs.user_id = p_user_id
    AND rs.is_active = true
  ORDER BY t.kind, t.sort_order, t.created_at;
$$;


ALTER FUNCTION "public"."get_sdr_email_templates_for"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_firm_pool_count"("p_states" "text"[] DEFAULT NULL::"text"[], "p_min_staff" integer DEFAULT NULL::integer, "p_max_staff" integer DEFAULT NULL::integer, "p_min_partners" integer DEFAULT NULL::integer, "p_max_partners" integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT count(*)::int
  FROM public.sdr_firms f
  WHERE f.is_available IS TRUE
    AND f.partner_action IS NULL
    AND f.hubspot_owner_email IS NULL
    AND f.strategic_direction IS NOT NULL
    AND length(f.strategic_direction) >= 50
    AND (f.icp_revenue_fit IS NULL
         OR (f.icp_revenue_fit NOT LIKE 'VERIFY - Auto-imported%'
             AND f.icp_revenue_fit NOT LIKE 'VERIFY (Seamless:%'))
    AND (f.icp_revenue_fit IS NULL
         OR (f.icp_revenue_fit NOT LIKE '%SKIP%'
             AND f.icp_revenue_fit NOT LIKE '❌%'
             AND f.icp_revenue_fit NOT ILIKE '%acquired%'
             AND f.icp_revenue_fit NOT LIKE 'OUT OF GEO%'
             AND f.icp_revenue_fit NOT LIKE 'WRONG INDUSTRY%'
             AND f.icp_revenue_fit NOT LIKE 'BELOW ICP%'
             AND f.icp_revenue_fit NOT LIKE 'Below ICP%'
             AND f.icp_revenue_fit NOT LIKE 'Above ICP%'))
    AND (p_states IS NULL OR f.state = ANY(p_states))
    AND (p_min_staff IS NULL OR public.parse_staff_count(f.staff_est) >= p_min_staff)
    AND (p_max_staff IS NULL OR public.parse_staff_count(f.staff_est) <= p_max_staff)
    AND (p_min_partners IS NULL OR COALESCE(f.partner_count, 0) >= p_min_partners)
    AND (p_max_partners IS NULL OR COALESCE(f.partner_count, 0) <= p_max_partners)
$$;


ALTER FUNCTION "public"."get_sdr_firm_pool_count"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_firm_pool_stats"("p_states" "text"[] DEFAULT NULL::"text"[], "p_min_staff" integer DEFAULT NULL::integer, "p_max_staff" integer DEFAULT NULL::integer, "p_min_partners" integer DEFAULT NULL::integer, "p_max_partners" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  WITH eligible AS (
    SELECT f.*
    FROM public.sdr_firms f
    WHERE f.is_available IS TRUE
      AND f.partner_action IS NULL
      AND f.hubspot_owner_email IS NULL
      AND f.strategic_direction IS NOT NULL
      AND length(f.strategic_direction) >= 50
      AND (f.icp_revenue_fit IS NULL
           OR (f.icp_revenue_fit NOT LIKE 'VERIFY - Auto-imported%'
               AND f.icp_revenue_fit NOT LIKE 'VERIFY (Seamless:%'))
      AND (f.icp_revenue_fit IS NULL
           OR (f.icp_revenue_fit NOT LIKE '%SKIP%'
               AND f.icp_revenue_fit NOT LIKE '❌%'
               AND f.icp_revenue_fit NOT ILIKE '%acquired%'
               AND f.icp_revenue_fit NOT LIKE 'OUT OF GEO%'
               AND f.icp_revenue_fit NOT LIKE 'WRONG INDUSTRY%'
               AND f.icp_revenue_fit NOT LIKE 'BELOW ICP%'
               AND f.icp_revenue_fit NOT LIKE 'Below ICP%'
               AND f.icp_revenue_fit NOT LIKE 'Above ICP%'))
      AND (p_states IS NULL OR f.state = ANY(p_states))
      AND (p_min_staff IS NULL OR public.parse_staff_count(f.staff_est) >= p_min_staff)
      AND (p_max_staff IS NULL OR public.parse_staff_count(f.staff_est) <= p_max_staff)
      AND (p_min_partners IS NULL OR COALESCE(f.partner_count, 0) >= p_min_partners)
      AND (p_max_partners IS NULL OR COALESCE(f.partner_count, 0) <= p_max_partners)
  ),
  by_state AS (
    SELECT state AS label, count(*)::int AS value
    FROM eligible
    WHERE state IS NOT NULL AND state <> ''
    GROUP BY state
  ),
  staff_bucket AS (
    SELECT CASE
      WHEN public.parse_staff_count(staff_est) IS NULL THEN 'Unknown'
      WHEN public.parse_staff_count(staff_est) <= 10 THEN '1-10'
      WHEN public.parse_staff_count(staff_est) <= 50 THEN '11-50'
      WHEN public.parse_staff_count(staff_est) <= 200 THEN '51-200'
      ELSE '200+'
    END AS label, count(*)::int AS value
    FROM eligible GROUP BY 1
  ),
  partner_bucket AS (
    SELECT CASE
      WHEN partner_count IS NULL THEN 'Unknown'
      WHEN partner_count <= 2 THEN '1-2'
      WHEN partner_count <= 5 THEN '3-5'
      WHEN partner_count <= 10 THEN '6-10'
      ELSE '10+'
    END AS label, count(*)::int AS value
    FROM eligible GROUP BY 1
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM eligible),
    'by_state', (SELECT jsonb_agg(jsonb_build_object('label', label, 'value', value) ORDER BY value DESC) FROM by_state),
    'by_staff', (SELECT jsonb_agg(jsonb_build_object('label', label, 'value', value)) FROM staff_bucket),
    'by_partners', (SELECT jsonb_agg(jsonb_build_object('label', label, 'value', value)) FROM partner_bucket)
  )
$$;


ALTER FUNCTION "public"."get_sdr_firm_pool_stats"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_firms_for_map"("p_user_id" "uuid") RETURNS TABLE("id" "uuid", "firm_name" "text", "latitude" double precision, "longitude" double precision, "state" "text", "location" "text", "website" "text", "est_revenue" "text", "staff_est" "text", "partner_count" integer, "specialty" "text", "firm_status" "text", "icp_revenue_fit" "text", "logo_url" "text", "niches" "text"[], "partner_action" "text", "outreach_status" "text", "hubspot_company_id" "text", "hubspot_owner_email" "text", "contact_count" integer, "is_mine" boolean, "status_tier" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH me AS (
    SELECT COALESCE(p.hubspot_owner_email, u.email) AS hs_email
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    WHERE u.id = p_user_id
  ),
  firm_with_contacts AS (
    SELECT f.*,
           (SELECT COUNT(*)::int FROM public.sdr_contacts c WHERE c.firm_id = f.id) AS contact_count
    FROM public.sdr_firms f
    WHERE f.latitude IS NOT NULL AND f.longitude IS NOT NULL
  )
  SELECT
    f.id,
    f.firm_name,
    f.latitude,
    f.longitude,
    f.state,
    f.location,
    f.website,
    f.est_revenue,
    f.staff_est,
    f.partner_count,
    f.specialty,
    f.firm_status,
    f.icp_revenue_fit,
    f.logo_url,
    f.niches,
    f.partner_action,
    f.outreach_status,
    f.hubspot_company_id,
    f.hubspot_owner_email,
    f.contact_count,
    (f.partner_user_id = p_user_id OR f.hubspot_owner_email = (SELECT hs_email FROM me)) AS is_mine,
    CASE
      WHEN f.outreach_status IS NOT NULL AND f.outreach_status <> 'Not Started' THEN 'reached_out'
      WHEN f.hubspot_company_id IS NOT NULL OR f.hubspot_owner_email IS NOT NULL THEN 'in_hubspot'
      WHEN f.partner_action = 'CLAIMED' THEN 'claimed'
      WHEN f.contact_count > 0 THEN 'researched'
      ELSE 'not_researched'
    END AS status_tier
  FROM firm_with_contacts f
$$;


ALTER FUNCTION "public"."get_sdr_firms_for_map"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_geocode_coverage"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM public.sdr_firms),
    'geocoded', (SELECT COUNT(*) FROM public.sdr_firms WHERE latitude IS NOT NULL AND longitude IS NOT NULL),
    'pending', (SELECT COUNT(*) FROM public.sdr_firms WHERE (latitude IS NULL OR longitude IS NULL)
                  AND (location IS NOT NULL OR state IS NOT NULL)),
    'no_address', (SELECT COUNT(*) FROM public.sdr_firms WHERE (latitude IS NULL OR longitude IS NULL)
                   AND location IS NULL AND state IS NULL)
  )
$$;


ALTER FUNCTION "public"."get_sdr_geocode_coverage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_hubspot_coverage"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH me AS (
    SELECT COALESCE(p.hubspot_owner_email, u.email) AS hs_email
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    WHERE u.id = p_user_id
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM public.sdr_firms),
    'checked', (SELECT COUNT(*) FROM public.sdr_firms WHERE hubspot_checked_at IS NOT NULL),
    'unchecked', (SELECT COUNT(*) FROM public.sdr_firms WHERE hubspot_checked_at IS NULL),
    'owned_by_me', (SELECT COUNT(*) FROM public.sdr_firms WHERE hubspot_owner_email = (SELECT hs_email FROM me)),
    'owned_by_anyone', (SELECT COUNT(*) FROM public.sdr_firms WHERE hubspot_owner_email IS NOT NULL)
  )
$$;


ALTER FUNCTION "public"."get_sdr_hubspot_coverage"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_queue_firms"("p_queue_id" "uuid") RETURNS TABLE("id" "uuid", "firm_name" "text", "website" "text", "state" "text", "location" "text", "est_revenue" "text", "staff_est" "text", "partner_count" integer, "specialty" "text", "firm_status" "text", "partner_action" "text", "partner_action_at" timestamp with time zone, "outreach_status" "text", "hubspot_company_id" "text", "contact_count" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT f.id, f.firm_name, f.website, f.state, f.location, f.est_revenue,
         f.staff_est, f.partner_count, f.specialty, f.firm_status,
         f.partner_action, f.partner_action_at, f.outreach_status,
         f.hubspot_company_id,
         (SELECT COUNT(*)::int FROM public.sdr_contacts c WHERE c.firm_id = f.id) AS contact_count
  FROM public.sdr_firms f
  WHERE f.queue_id = p_queue_id
  ORDER BY f.firm_name
$$;


ALTER FUNCTION "public"."get_sdr_queue_firms"("p_queue_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_skipped_firms"() RETURNS TABLE("id" "uuid", "firm_name" "text", "website" "text", "state" "text", "location" "text", "est_revenue" "text", "staff_est" "text", "partner_count" integer, "specialty" "text", "hubspot_company_id" "text", "hubspot_owner_email" "text", "skipped_at" timestamp with time zone, "skipped_by_user_id" "uuid", "skipped_by_name" "text", "skipped_by_email" "text", "skipped_by_is_self" boolean, "skip_notes" "text", "queue_id" "uuid", "queue_number" integer, "queue_name" "text", "contact_count" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT
    f.id,
    f.firm_name,
    f.website,
    f.state,
    f.location,
    f.est_revenue,
    f.staff_est,
    f.partner_count,
    f.specialty,
    f.hubspot_company_id,
    f.hubspot_owner_email,
    f.partner_action_at AS skipped_at,
    f.partner_user_id   AS skipped_by_user_id,
    NULLIF(TRIM(BOTH FROM COALESCE(p.full_name, CONCAT_WS(' ', p.first_name, p.last_name))), '') AS skipped_by_name,
    p.email             AS skipped_by_email,
    (f.partner_user_id = auth.uid()) AS skipped_by_is_self,
    f.partner_notes     AS skip_notes,
    f.queue_id,
    q.queue_number,
    q.queue_name,
    (SELECT COUNT(*)::int FROM public.sdr_contacts c WHERE c.firm_id = f.id) AS contact_count
  FROM public.sdr_firms f
  LEFT JOIN public.profiles p ON p.id = f.partner_user_id
  LEFT JOIN public.sdr_prospect_queues q ON q.id = f.queue_id
  WHERE f.partner_action = 'SKIPPED'
  ORDER BY f.partner_action_at DESC NULLS LAST, f.firm_name ASC;
$$;


ALTER FUNCTION "public"."get_sdr_skipped_firms"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sdr_templates_for_rule_set"("p_rule_set_id" "uuid") RETURNS SETOF "public"."sdr_email_templates"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT t.*
  FROM public.sdr_email_templates t
  WHERE t.rule_set_id = p_rule_set_id
  ORDER BY t.kind, t.sort_order, t.created_at;
$$;


ALTER FUNCTION "public"."get_sdr_templates_for_rule_set"("p_rule_set_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_permissions"("p_user_id" "uuid") RETURNS SETOF "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    CASE
      WHEN cr.is_system = true AND cr.name = 'Admin' THEN '*'
      ELSE rp.permission_key
    END
  FROM public.user_role_assignments ura
  JOIN public.custom_roles cr ON cr.id = ura.role_id
  LEFT JOIN public.role_permissions rp ON rp.role_id = cr.id
  WHERE ura.user_id = p_user_id
    AND (
      (cr.is_system = true AND cr.name = 'Admin')
      OR rp.permission_key IS NOT NULL
    )
  GROUP BY cr.is_system, cr.name, rp.permission_key
  UNION
  SELECT perm
  FROM unnest(ARRAY[
    'desks.access',
    'desks.ssg-engagements.view',
    'desks.ssg-engagements.manage'
  ]::text[]) AS perm
  WHERE public.is_ssg_advisor(p_user_id);
$$;


ALTER FUNCTION "public"."get_user_permissions"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role_name"("_user_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT r.name
  FROM public.profiles p
  JOIN public.roles r ON r.id = p.role_id
  WHERE p.id = _user_id
$$;


ALTER FUNCTION "public"."get_user_role_name"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, status, role_id)
  VALUES (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    'pending',
    NULL
  );

  RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_document_permission"("_user_id" "uuid", "_document_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _folder_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.document_permissions dp
    WHERE dp.document_id = _document_id
    AND (
      dp.granted_to_user_id = _user_id
      OR dp.granted_to_org_id IN (SELECT organization_id FROM public.profiles WHERE id = _user_id)
      OR dp.granted_to_tag = ANY(SELECT unnest(COALESCE(tags, '{}')) FROM public.profiles WHERE id = _user_id)
    )
  ) THEN
    RETURN TRUE;
  END IF;

  SELECT folder_id INTO _folder_id FROM public.documents WHERE id = _document_id;
  IF _folder_id IS NOT NULL THEN
    RETURN public.has_folder_permission(_user_id, _folder_id);
  END IF;

  RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."has_document_permission"("_user_id" "uuid", "_document_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_folder_permission"("_user_id" "uuid", "_folder_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _current_id uuid := _folder_id;
BEGIN
  WHILE _current_id IS NOT NULL LOOP
    IF EXISTS (
      SELECT 1 FROM public.document_permissions dp
      WHERE dp.folder_id = _current_id
      AND (
        dp.granted_to_user_id = _user_id
        OR dp.granted_to_org_id IN (SELECT organization_id FROM public.profiles WHERE id = _user_id)
        OR dp.granted_to_tag = ANY(SELECT unnest(COALESCE(tags, '{}')) FROM public.profiles WHERE id = _user_id)
      )
    ) THEN
      RETURN true;
    END IF;
    SELECT parent_id INTO _current_id FROM public.document_folders WHERE id = _current_id;
  END LOOP;
  RETURN false;
END;
$$;


ALTER FUNCTION "public"."has_folder_permission"("_user_id" "uuid", "_folder_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_permission"("_user_id" "uuid", "_permission_key" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_role_assignments ura
    JOIN public.custom_roles cr ON cr.id = ura.role_id
    LEFT JOIN public.role_permissions rp ON rp.role_id = cr.id
    WHERE ura.user_id = _user_id
      AND (
        (cr.is_system = true AND cr.name = 'Admin')
        OR rp.permission_key = _permission_key
      )
  )
$$;


ALTER FUNCTION "public"."has_permission"("_user_id" "uuid", "_permission_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_role_assignments ura
    JOIN public.custom_roles cr ON cr.id = ura.role_id
    WHERE ura.user_id = _user_id
      AND CASE _role
        WHEN 'admin' THEN (cr.is_system = true AND cr.name = 'Admin')
        WHEN 'viewer' THEN (cr.name IN ('Read Only', 'External'))
        WHEN 'member' THEN (cr.is_system = false AND cr.name NOT IN ('Read Only', 'External'))
      END
  )
$$;


ALTER FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hris_apply_leave_balance"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  yr int := EXTRACT(YEAR FROM NEW.start_date)::int;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;  -- status unchanged, nothing to do
  END IF;

  -- entering approved: subtract hours
  IF NEW.status = 'approved' AND OLD.status <> 'approved' THEN
    UPDATE public.hris_leave_balances
      SET used_hours = used_hours + NEW.hours, updated_at = now()
    WHERE employee_id = NEW.employee_id
      AND leave_type_id = NEW.leave_type_id
      AND year = yr;
  -- leaving approved: restore hours
  ELSIF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
    UPDATE public.hris_leave_balances
      SET used_hours = GREATEST(used_hours - OLD.hours, 0), updated_at = now()
    WHERE employee_id = NEW.employee_id
      AND leave_type_id = NEW.leave_type_id
      AND year = yr;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."hris_apply_leave_balance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hris_default_employee_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.employee_number IS NULL OR NEW.employee_number = '' THEN
    NEW.employee_number := NEW.profile_id::text;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."hris_default_employee_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hris_start_checklist"("p_template_id" "uuid", "p_employee_id" "uuid", "p_start_date" "date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_type text;
  v_checklist_id uuid;
  v_manager_id uuid;
  r RECORD;
  v_assignee uuid;
BEGIN
  -- Authorize: only HR (manage) or admin may start checklists.
  IF NOT (public.has_permission(v_caller, 'desks.hris.manage')
          OR public.has_permission(v_caller, 'admin.access')) THEN
    RAISE EXCEPTION 'not authorized to start checklists';
  END IF;

  SELECT type INTO v_type FROM public.hris_checklist_templates WHERE id = p_template_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'template % not found', p_template_id;
  END IF;

  SELECT manager_id INTO v_manager_id FROM public.profiles WHERE id = p_employee_id;

  INSERT INTO public.hris_employee_checklists
    (employee_id, template_id, type, status, start_date, started_by, started_at)
  VALUES
    (p_employee_id, p_template_id, v_type, 'in_progress', p_start_date, v_caller, now())
  RETURNING id INTO v_checklist_id;

  FOR r IN
    SELECT * FROM public.hris_checklist_template_items
    WHERE template_id = p_template_id
    ORDER BY sort_order
  LOOP
    v_assignee := CASE r.assignee_role
      WHEN 'new_hire' THEN p_employee_id
      WHEN 'manager'  THEN v_manager_id
      ELSE NULL            -- 'hr' / 'it' start unassigned
    END;

    -- priority is intentionally omitted (NULL). The validate_task_fields()
    -- trigger's `priority NOT IN (...)` check evaluates to NULL (not TRUE)
    -- for a NULL priority, so the insert passes. Do not re-add a NOT NULL
    -- priority constraint without updating this RPC.
    INSERT INTO public.tasks
      (title, description, source_type, source_reference_id, due_date,
       assigned_to, assigned_by, updated_by, status)
    VALUES
      (r.title, r.description, 'hris_' || v_type, v_checklist_id,
       p_start_date + (r.due_offset_days || ' days')::interval,
       v_assignee, v_caller, v_caller, 'not_started');
  END LOOP;

  RETURN v_checklist_id;
END;
$$;


ALTER FUNCTION "public"."hris_start_checklist"("p_template_id" "uuid", "p_employee_id" "uuid", "p_start_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hydrate_sdr_from_seamless"("p_industries" "text"[] DEFAULT ARRAY['Accounting'::"text", 'Financial Services'::"text", 'Management Consulting'::"text"], "p_states" "text"[] DEFAULT ARRAY['AL'::"text", 'AK'::"text", 'AZ'::"text", 'AR'::"text", 'CA'::"text", 'CO'::"text", 'CT'::"text", 'DE'::"text", 'DC'::"text", 'FL'::"text", 'GA'::"text", 'HI'::"text", 'ID'::"text", 'IL'::"text", 'IN'::"text", 'IA'::"text", 'KS'::"text", 'KY'::"text", 'LA'::"text", 'ME'::"text", 'MD'::"text", 'MA'::"text", 'MI'::"text", 'MN'::"text", 'MS'::"text", 'MO'::"text", 'MT'::"text", 'NE'::"text", 'NV'::"text", 'NH'::"text", 'NJ'::"text", 'NM'::"text", 'NY'::"text", 'NC'::"text", 'ND'::"text", 'OH'::"text", 'OK'::"text", 'OR'::"text", 'PA'::"text", 'RI'::"text", 'SC'::"text", 'SD'::"text", 'TN'::"text", 'TX'::"text", 'UT'::"text", 'VT'::"text", 'VA'::"text", 'WA'::"text", 'WV'::"text", 'WI'::"text", 'WY'::"text"]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_firms_created int := 0;
  v_contacts_created int := 0;
BEGIN
  -- Insert missing firms (one per unique company name in scope)
  WITH raw_companies AS (
    SELECT
      lower(trim("Company Name")) AS norm_name,
      MAX("Company Name") AS display_name,
      MAX("Company Name - Cleaned") AS cleaned_name,
      MAX("Company State Abbr") AS state,
      MAX("Company City") AS city,
      MAX("Company Website Domain") AS website,
      MAX("Company Industry") AS industry,
      MAX(NULLIF("Company Revenue Range", '')) AS revenue_range,
      MAX(NULLIF("Company Staff Count Range", '')) AS staff_range
    FROM public.sdr_seamless_imports
    WHERE "Company Name" IS NOT NULL AND "Company Name" <> ''
      AND "Company Industry" = ANY(p_industries)
      AND "Company State Abbr" = ANY(p_states)
    GROUP BY 1
  ),
  to_insert AS (
    SELECT rc.*
    FROM raw_companies rc
    WHERE NOT EXISTS (
      SELECT 1 FROM public.sdr_firms f
      WHERE lower(trim(f.firm_name)) = rc.norm_name
    )
  ),
  inserted AS (
    INSERT INTO public.sdr_firms (
      firm_name, website, state, location, icp_revenue_fit, firm_status,
      est_revenue, staff_est, is_available, source_notes, created_at, updated_at
    )
    SELECT
      COALESCE(display_name, cleaned_name),
      website,
      state,
      CASE WHEN city IS NOT NULL AND city <> '' THEN city || ', ' || state ELSE state END,
      'VERIFY - Auto-imported',
      'Unknown',
      revenue_range,
      staff_range,
      TRUE,
      '[' || to_char(now(), 'YYYY-MM-DD') || '] Auto-hydrated from sdr_seamless_imports (industry=' || industry || ')',
      now(), now()
    FROM to_insert
    RETURNING 1
  )
  SELECT count(*) INTO v_firms_created FROM inserted;

  -- Insert contacts for any firm that currently has ZERO contacts.
  WITH candidate_contacts AS (
    SELECT DISTINCT ON (f.id, lower(trim(COALESCE(i."Contact Full Name", TRIM(CONCAT_WS(' ', i."First Name", i."Last Name"))))))
      f.id AS firm_id,
      f.firm_name AS firm_name,
      f.website AS website,
      f.state AS state,
      COALESCE(i."Contact Full Name", TRIM(CONCAT_WS(' ', i."First Name", i."Last Name"))) AS contact_name,
      i."Title" AS title,
      COALESCE(NULLIF(i."Primary Email", ''), NULLIF(i."Email 1", ''), NULLIF(i."Email 2", '')) AS email,
      COALESCE(NULLIF(i."Contact Mobile Phone", ''), NULLIF(i."Contact Phone", ''), NULLIF(i."Contact Phone 1", '')) AS phone
    FROM public.sdr_seamless_imports i
    JOIN public.sdr_firms f ON lower(trim(i."Company Name")) = lower(trim(f.firm_name))
    WHERE i."Company Industry" = ANY(p_industries)
      AND i."Company State Abbr" = ANY(p_states)
      AND COALESCE(i."Contact Full Name", TRIM(CONCAT_WS(' ', i."First Name", i."Last Name"))) <> ''
      AND NOT EXISTS (SELECT 1 FROM public.sdr_contacts c WHERE c.firm_id = f.id)
  ),
  inserted_contacts AS (
    INSERT INTO public.sdr_contacts (
      firm_id, name, title, email, direct_phone, firm_name, website, state,
      verdict, notes_flags
    )
    SELECT
      firm_id, contact_name, title, email, phone, firm_name, website, state,
      '⚠️ VERIFY',
      'Not crawled - Auto-hydrated ' || to_char(now(), 'YYYY-MM-DD')
    FROM candidate_contacts
    RETURNING 1
  )
  SELECT count(*) INTO v_contacts_created FROM inserted_contacts;

  RETURN jsonb_build_object(
    'firms_created', v_firms_created,
    'contacts_created', v_contacts_created,
    'industries', p_industries,
    'states', p_states
  );
END $$;


ALTER FUNCTION "public"."hydrate_sdr_from_seamless"("p_industries" "text"[], "p_states" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_on_comment_mention"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _comment RECORD;
  _task RECORD;
  _actor_name text;
BEGIN
  -- Load the comment
  SELECT * INTO _comment FROM public.task_comments WHERE id = NEW.comment_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  -- Load the task the comment belongs to
  SELECT * INTO _task FROM public.tasks WHERE id = _comment.task_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT COALESCE(full_name, email, 'Someone') INTO _actor_name
  FROM public.profiles WHERE id = _comment.author_id;

  PERFORM insert_inbox_item(
    NEW.mentioned_user_id, _comment.author_id, 'task', _task.id::text, _task.title,
    'mentioned',
    _actor_name || ' mentioned you in a comment',
    jsonb_build_object('comment_preview', LEFT(_comment.body, 160), 'comment_id', _comment.id),
    '/tasks?task=' || _task.id::text
  );

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."inbox_on_comment_mention"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_on_project_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _member RECORD;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    FOR _member IN
      SELECT user_id FROM public.project_members WHERE project_id = NEW.id
    LOOP
      PERFORM insert_inbox_item(
        _member.user_id, NEW.owner_id, 'project', NEW.id::text, NEW.name,
        'project_status_changed',
        'Project status changed to ' || NEW.status,
        jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
        '/work?panel=' || NEW.id::text
      );
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."inbox_on_project_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_on_task_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _actor uuid;
  _actor_name text;
  _recipient uuid;
  _collab RECORD;
BEGIN
  _actor := COALESCE(NEW.updated_by, NEW.assigned_by);

  SELECT COALESCE(full_name, email, 'Someone') INTO _actor_name
  FROM public.profiles WHERE id = _actor;

  -- TASK ASSIGNED (INSERT or reassignment)
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.assigned_to IS DISTINCT FROM NEW.assigned_to) THEN
    IF NEW.assigned_to IS NOT NULL THEN
      PERFORM insert_inbox_item(
        NEW.assigned_to, _actor, 'task', NEW.id::text, NEW.title,
        'task_assigned',
        _actor_name || ' assigned you a task',
        jsonb_build_object('task_title', NEW.title),
        '/tasks?task=' || NEW.id::text
      );
    END IF;
  END IF;

  -- STATUS CHANGED — notify assignee, assigner, and all collaborators
  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    -- Assignee
    IF NEW.assigned_to IS NOT NULL AND NEW.assigned_to <> _actor THEN
      PERFORM insert_inbox_item(
        NEW.assigned_to, _actor, 'task', NEW.id::text, NEW.title,
        CASE WHEN NEW.status = 'complete' THEN 'task_completed' ELSE 'status_changed' END,
        _actor_name || CASE WHEN NEW.status = 'complete' THEN ' completed this task' ELSE ' changed status to ' || REPLACE(NEW.status, '_', ' ') END,
        jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
        '/tasks?task=' || NEW.id::text
      );
    END IF;
    -- Assigner
    IF NEW.assigned_by IS NOT NULL AND NEW.assigned_by IS DISTINCT FROM NEW.assigned_to AND NEW.assigned_by <> _actor THEN
      PERFORM insert_inbox_item(
        NEW.assigned_by, _actor, 'task', NEW.id::text, NEW.title,
        CASE WHEN NEW.status = 'complete' THEN 'task_completed' ELSE 'status_changed' END,
        _actor_name || CASE WHEN NEW.status = 'complete' THEN ' completed this task' ELSE ' changed status to ' || REPLACE(NEW.status, '_', ' ') END,
        jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
        '/tasks?task=' || NEW.id::text
      );
    END IF;
    -- Collaborators (excluding actor, assignee, assigner to avoid dupes)
    FOR _collab IN
      SELECT user_id FROM public.task_collaborators
      WHERE task_id = NEW.id
        AND user_id <> _actor
        AND user_id IS DISTINCT FROM NEW.assigned_to
        AND user_id IS DISTINCT FROM NEW.assigned_by
    LOOP
      PERFORM insert_inbox_item(
        _collab.user_id, _actor, 'task', NEW.id::text, NEW.title,
        CASE WHEN NEW.status = 'complete' THEN 'task_completed' ELSE 'status_changed' END,
        _actor_name || CASE WHEN NEW.status = 'complete' THEN ' completed this task' ELSE ' changed status to ' || REPLACE(NEW.status, '_', ' ') END,
        jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status),
        '/tasks?task=' || NEW.id::text
      );
    END LOOP;
  END IF;

  -- PRIORITY CHANGED
  IF TG_OP = 'UPDATE' AND OLD.priority IS DISTINCT FROM NEW.priority THEN
    IF NEW.assigned_to IS NOT NULL THEN
      PERFORM insert_inbox_item(
        NEW.assigned_to, _actor, 'task', NEW.id::text, NEW.title,
        'priority_changed',
        _actor_name || ' changed priority to ' || NEW.priority,
        jsonb_build_object('old_priority', OLD.priority, 'new_priority', NEW.priority),
        '/tasks?task=' || NEW.id::text
      );
    END IF;
  END IF;

  -- DUE DATE CHANGED
  IF TG_OP = 'UPDATE' AND OLD.due_date IS DISTINCT FROM NEW.due_date THEN
    IF NEW.assigned_to IS NOT NULL THEN
      PERFORM insert_inbox_item(
        NEW.assigned_to, _actor, 'task', NEW.id::text, NEW.title,
        'due_date_changed',
        _actor_name || ' changed due date to ' || COALESCE(NEW.due_date::text, 'none'),
        jsonb_build_object('old_due', OLD.due_date, 'new_due', NEW.due_date),
        '/tasks?task=' || NEW.id::text
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."inbox_on_task_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inbox_on_task_comment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _task RECORD;
  _actor_name text;
  _collab RECORD;
  _mention RECORD;
  _notified uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT * INTO _task FROM public.tasks WHERE id = NEW.task_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT COALESCE(full_name, email, 'Someone') INTO _actor_name
  FROM public.profiles WHERE id = NEW.author_id;

  -- Assignee
  IF _task.assigned_to IS NOT NULL AND _task.assigned_to <> NEW.author_id THEN
    PERFORM insert_inbox_item(
      _task.assigned_to, NEW.author_id, 'task', _task.id::text, _task.title,
      'comment_added',
      _actor_name || ' commented on this task',
      jsonb_build_object('comment_preview', LEFT(NEW.body, 160), 'comment_id', NEW.id),
      '/tasks?task=' || _task.id::text
    );
    _notified := array_append(_notified, _task.assigned_to);
  END IF;

  -- Assigner
  IF _task.assigned_by IS NOT NULL
     AND _task.assigned_by <> NEW.author_id
     AND NOT (_task.assigned_by = ANY(_notified)) THEN
    PERFORM insert_inbox_item(
      _task.assigned_by, NEW.author_id, 'task', _task.id::text, _task.title,
      'comment_added',
      _actor_name || ' commented on this task',
      jsonb_build_object('comment_preview', LEFT(NEW.body, 160), 'comment_id', NEW.id),
      '/tasks?task=' || _task.id::text
    );
    _notified := array_append(_notified, _task.assigned_by);
  END IF;

  -- Collaborators
  FOR _collab IN
    SELECT user_id FROM public.task_collaborators
    WHERE task_id = NEW.task_id
      AND user_id <> NEW.author_id
      AND NOT (user_id = ANY(_notified))
  LOOP
    PERFORM insert_inbox_item(
      _collab.user_id, NEW.author_id, 'task', _task.id::text, _task.title,
      'comment_added',
      _actor_name || ' commented on this task',
      jsonb_build_object('comment_preview', LEFT(NEW.body, 160), 'comment_id', NEW.id),
      '/tasks?task=' || _task.id::text
    );
    _notified := array_append(_notified, _collab.user_id);
  END LOOP;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."inbox_on_task_comment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_inbox_item"("_user_id" "uuid", "_actor_id" "uuid" DEFAULT NULL::"uuid", "_target_type" "text" DEFAULT 'task'::"text", "_target_id" "text" DEFAULT ''::"text", "_target_name" "text" DEFAULT ''::"text", "_event_type" "text" DEFAULT 'task_assigned'::"text", "_summary" "text" DEFAULT ''::"text", "_detail" "jsonb" DEFAULT '{}'::"jsonb", "_link" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _id uuid;
BEGIN
  -- Don't create inbox item if actor is the same as recipient
  IF _actor_id IS NOT NULL AND _actor_id = _user_id THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.inbox_items (user_id, actor_id, target_type, target_id, target_name, event_type, summary, detail, link)
  VALUES (_user_id, _actor_id, _target_type, _target_id, _target_name, _event_type, _summary, _detail, _link)
  RETURNING id INTO _id;
  RETURN _id;
END;
$$;


ALTER FUNCTION "public"."insert_inbox_item"("_user_id" "uuid", "_actor_id" "uuid", "_target_type" "text", "_target_id" "text", "_target_name" "text", "_event_type" "text", "_summary" "text", "_detail" "jsonb", "_link" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_notification"("_user_id" "uuid", "_actor_id" "uuid" DEFAULT NULL::"uuid", "_type" "text" DEFAULT 'mention'::"text", "_title" "text" DEFAULT ''::"text", "_body" "text" DEFAULT NULL::"text", "_link" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _id uuid;
BEGIN
  INSERT INTO public.notifications (user_id, actor_id, type, title, body, link)
  VALUES (_user_id, _actor_id, _type, _title, _body, _link)
  RETURNING id INTO _id;
  RETURN _id;
END;
$$;


ALTER FUNCTION "public"."insert_notification"("_user_id" "uuid", "_actor_id" "uuid", "_type" "text", "_title" "text", "_body" "text", "_link" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_active_user"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where id = _user_id and status not in ('pending', 'merged')
  )
$$;


ALTER FUNCTION "public"."is_active_user"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_in_manager_chain"("_viewer_id" "uuid", "_assignee_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH RECURSIVE chain AS (
    SELECT manager_id FROM public.profiles WHERE id = _assignee_id
    UNION ALL
    SELECT p.manager_id FROM public.profiles p JOIN chain c ON p.id = c.manager_id
    WHERE c.manager_id IS NOT NULL
  )
  SELECT EXISTS (SELECT 1 FROM chain WHERE manager_id = _viewer_id)
$$;


ALTER FUNCTION "public"."is_in_manager_chain"("_viewer_id" "uuid", "_assignee_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH RECURSIVE chain AS (
    SELECT p.id, p.manager_id, 1 AS depth
    FROM public.profiles p
    WHERE p.id = p_employee
    UNION
    SELECT p.id, p.manager_id, c.depth + 1
    FROM public.profiles p
    JOIN chain c ON p.id = c.manager_id
    WHERE c.depth < 20            -- guard against manager_id cycles / runaway
  )
  SELECT EXISTS (
    SELECT 1 FROM chain WHERE manager_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") IS 'True when the current user (auth.uid()) sits anywhere above p_employee in the profiles.manager_id chain (skip-level included). Roles & Responsibilities edit gate.';



CREATE OR REPLACE FUNCTION "public"."is_project_member"("_user_id" "uuid", "_project_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.project_members
    WHERE user_id = _user_id AND project_id = _project_id
  )
$$;


ALTER FUNCTION "public"."is_project_member"("_user_id" "uuid", "_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_project_owner"("_user_id" "uuid", "_project_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.project_members
    WHERE user_id = _user_id AND project_id = _project_id AND role = 'owner'
  )
$$;


ALTER FUNCTION "public"."is_project_owner"("_user_id" "uuid", "_project_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_firms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid",
    "state" "text",
    "firm_name" "text" NOT NULL,
    "website" "text",
    "firm_status" "text",
    "est_revenue" "text",
    "staff_est" "text",
    "icp_revenue_fit" "text",
    "location" "text",
    "specialty" "text",
    "known_team_members" "text",
    "source_notes" "text",
    "strategic_direction" "text",
    "last_researched_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "services_offered" "jsonb" DEFAULT '[]'::"jsonb",
    "tech_stack" "jsonb" DEFAULT '{}'::"jsonb",
    "brand_primary_color" "text",
    "brand_secondary_color" "text",
    "partner_count" integer,
    "niches" "text"[],
    "logo_url" "text",
    "latitude" double precision,
    "longitude" double precision,
    "hubspot_company_id" "text",
    "hubspot_synced_at" timestamp with time zone,
    "partner_user_id" "uuid",
    "queue_id" "uuid",
    "partner_action" "text",
    "partner_action_at" timestamp with time zone,
    "partner_notes" "text",
    "flag_reason" "text",
    "outreach_status" "text" DEFAULT 'Not Started'::"text",
    "outreach_status_updated_at" timestamp with time zone,
    "claimed_at" timestamp with time zone,
    "is_available" boolean DEFAULT true,
    "hubspot_owner_email" "text",
    "hubspot_checked_at" timestamp with time zone,
    "hubspot_engagements_synced_at" timestamp with time zone,
    "followup_research_queued_at" timestamp with time zone,
    "followup_research_completed_at" timestamp with time zone,
    "followup_research_notes" "text",
    "staff_roster_complete" boolean DEFAULT false NOT NULL,
    "staff_roster_complete_at" timestamp with time zone,
    "staff_roster_complete_notes" "text"
);


ALTER TABLE "public"."sdr_firms" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sdr_firms"."services_offered" IS 'Array of {name, pct} objects. name matches SERVICE_LINES in the deck: Tax Preparation, Audit & Assurance, Bookkeeping, CFO Advisory, Payroll, Wealth Management, Business Valuation, Consulting, Estate Planning, Forensic Accounting, Litigation Support';



COMMENT ON COLUMN "public"."sdr_firms"."tech_stack" IS 'Object with keys: taxSoftware, practiceManagement, aiTools, other. Values are strings.';



COMMENT ON COLUMN "public"."sdr_firms"."brand_primary_color" IS 'Hex color code from firm website, e.g. #2A5DB0';



COMMENT ON COLUMN "public"."sdr_firms"."brand_secondary_color" IS 'Hex color code, secondary brand color';



COMMENT ON COLUMN "public"."sdr_firms"."partner_count" IS 'Number of partners/owners at the firm';



COMMENT ON COLUMN "public"."sdr_firms"."niches" IS 'Array of industry niches, e.g. {Construction,Dental,Nonprofit}';



COMMENT ON COLUMN "public"."sdr_firms"."hubspot_company_id" IS 'HubSpot Company record ID after push. Null means not yet synced.';



COMMENT ON COLUMN "public"."sdr_firms"."hubspot_synced_at" IS 'Last time this firm was successfully pushed to HubSpot.';



COMMENT ON COLUMN "public"."sdr_firms"."partner_action" IS 'CLAIMED | SKIPPED | FLAGGED';



COMMENT ON COLUMN "public"."sdr_firms"."outreach_status" IS 'Not Started | Email Sent | Follow-Up Sent | Meeting Scheduled | Converted | No Response | Declined';



COMMENT ON COLUMN "public"."sdr_firms"."hubspot_owner_email" IS 'Cached HubSpot owner email. Non-null means the firm is already owned in HubSpot and should be excluded from queue builds.';



COMMENT ON COLUMN "public"."sdr_firms"."followup_research_queued_at" IS 'When the SDR checked this firm for follow-up research. NULL = not queued.';



COMMENT ON COLUMN "public"."sdr_firms"."followup_research_completed_at" IS 'When Claude last wrote follow-up research back. Used to enforce a 60-day re-research cooldown.';



COMMENT ON COLUMN "public"."sdr_firms"."followup_research_notes" IS 'Markdown output from the most recent follow-up research pass — signals, recommended angle, sources.';



COMMENT ON COLUMN "public"."sdr_firms"."staff_roster_complete" IS 'Researcher has verified the roster captures everything publicly available about the team. When TRUE, the dashboard suppresses the "roster under staff_est" gap.';



CREATE OR REPLACE FUNCTION "public"."is_sdr_firm_fully_researched"("f" "public"."sdr_firms") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT
    f.strategic_direction IS NOT NULL
    AND length(f.strategic_direction) >= 50
    AND f.icp_revenue_fit IS NOT NULL
    AND f.icp_revenue_fit NOT LIKE 'VERIFY - Auto-imported%'
    AND f.icp_revenue_fit NOT LIKE 'VERIFY (Seamless:%'
    AND NOT public.is_seamless_default_revenue(f.est_revenue)
    AND NOT public.is_seamless_default_staff(f.staff_est)
    AND f.partner_count IS NOT NULL
    AND (
      (f.known_team_members IS NOT NULL AND length(f.known_team_members) >= 20)
      OR EXISTS (SELECT 1 FROM public.sdr_firm_staff s WHERE s.firm_id = f.id)
    );
$$;


ALTER FUNCTION "public"."is_sdr_firm_fully_researched"("f" "public"."sdr_firms") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_seamless_default_revenue"("s" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
  SELECT s IS NOT NULL AND s IN (
    '$0 - $100K',
    '$100K - $1M',
    '$1M - $5M',
    '$5M - $20M',
    '$20M - $50M',
    '$50M - $100M',
    '$100M - $200M',
    '$200M+',
    'Below $1M'
  );
$_$;


ALTER FUNCTION "public"."is_seamless_default_revenue"("s" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_seamless_default_staff"("s" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT s IS NOT NULL AND s ILIKE '% - % employees';
$$;


ALTER FUNCTION "public"."is_seamless_default_staff"("s" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_ssg_advisor"("_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM public.ssg_advisors WHERE user_id = _user_id);
$$;


ALTER FUNCTION "public"."is_ssg_advisor"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_sdr_rule_sets_for"("p_user_id" "uuid") RETURNS TABLE("id" "uuid", "user_id" "uuid", "name" "text", "is_active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "template_count" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    rs.id,
    rs.user_id,
    rs.name,
    rs.is_active,
    rs.created_at,
    rs.updated_at,
    (SELECT COUNT(*)::integer FROM public.sdr_email_templates t WHERE t.rule_set_id = rs.id) AS template_count
  FROM public.sdr_rule_sets rs
  WHERE rs.user_id = p_user_id
  ORDER BY rs.created_at;
$$;


ALTER FUNCTION "public"."list_sdr_rule_sets_for"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_dataset_sync_failure"("p_sync_function_name" "text", "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_should_alert boolean;
  v_secret text;
  v_url text;
  v_recipient_count integer := 0;
  v_recipient record;
BEGIN
  -- Debounce: skip if every affected dataset was alerted within the last hour.
  SELECT bool_or(last_alerted_at IS NULL OR last_alerted_at < now() - interval '1 hour')
    INTO v_should_alert
  FROM public.datasets
  WHERE sync_function_name = p_sync_function_name;

  IF NOT COALESCE(v_should_alert, false) THEN RETURN; END IF;

  -- Stamp last_alerted_at so we don't re-fire within the debounce window.
  UPDATE public.datasets
  SET last_alerted_at = now()
  WHERE sync_function_name = p_sync_function_name;

  -- Need the same cron secret to call the email function over pg_net.
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'geocode_cron_secret'
  LIMIT 1;

  v_url := 'https://trltcyzskmcveuabypat.supabase.co/functions/v1/send-notification-email';

  -- Loop over admins/registry viewers and fire one email each. We
  -- iterate (rather than batch) because send-notification-email is
  -- per-user today — switching to a batch endpoint is a future
  -- optimization.
  FOR v_recipient IN
    SELECT DISTINCT p.id, p.email
    FROM public.profiles p
    WHERE p.email IS NOT NULL
      AND p.status = 'active'
      AND (
        public.has_permission(p.id, 'reporting.registry.view')
        OR public.has_permission(p.id, 'admin.access')
      )
  LOOP
    IF v_secret IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'Content-Type',  'application/json',
          'Authorization', 'Bearer ' || v_secret
        ),
        body := jsonb_build_object(
          'to', v_recipient.email,
          'subject', 'Reporting sync failure: ' || p_sync_function_name,
          'notification_type', 'reporting_sync_failure',
          'html', '<p>The reporting sync <code>' || p_sync_function_name
                  || '</code> failed.</p><p><b>Error:</b> '
                  || COALESCE(p_error, '(no message)')
                  || '</p><p>See <a href="https://hub.linkedalliance.com/admin/data-registry">Data Registry</a> for details.</p>'
        ),
        timeout_milliseconds := 30000
      );
    END IF;
    v_recipient_count := v_recipient_count + 1;
  END LOOP;

  INSERT INTO public.reporting_sync_alerts
    (sync_function_name, error_message, recipient_count)
  VALUES
    (p_sync_function_name, p_error, v_recipient_count);
END;
$$;


ALTER FUNCTION "public"."notify_dataset_sync_failure"("p_sync_function_name" "text", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_task_assigned"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Only fire when assigned_to changes to a non-null value
  IF NEW.assigned_to IS NULL THEN
    RETURN NEW;
  END IF;
  -- On INSERT: always fire (old assigned_to doesn't exist)
  -- On UPDATE: only fire when assigned_to actually changed
  IF TG_OP = 'UPDATE' AND OLD.assigned_to IS NOT DISTINCT FROM NEW.assigned_to THEN
    RETURN NEW;
  END IF;
  -- Don't notify if the user assigned the task to themselves
  IF NEW.updated_by IS NOT NULL AND NEW.assigned_to = NEW.updated_by THEN
    RETURN NEW;
  END IF;
  -- For INSERT, also check assigned_by (updated_by may not be set on initial insert)
  IF TG_OP = 'INSERT' AND NEW.updated_by IS NULL AND NEW.assigned_to = NEW.assigned_by THEN
    RETURN NEW;
  END IF;
  -- Create notification
  PERFORM insert_notification(
    NEW.assigned_to,
    COALESCE(NEW.updated_by, NEW.assigned_by),
    'task_assigned',
    'New task assigned to you',
    NEW.title,
    '/tasks/' || NEW.id::text
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_task_assigned"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_ticket_assigned"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Only fire when assigned_to changes to a non-null value
  IF NEW.assigned_to IS NULL THEN
    RETURN NEW;
  END IF;
  IF OLD.assigned_to IS NOT DISTINCT FROM NEW.assigned_to THEN
    RETURN NEW;
  END IF;
  PERFORM insert_notification(
    NEW.assigned_to,
    NULL,
    'ticket_assigned',
    'A ticket has been assigned to you',
    NEW.title,
    '/admin/tickets/' || NEW.id::text
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_ticket_assigned"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_ticket_created"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  _admin RECORD;
BEGIN
  -- Confirmation to the creator
  PERFORM insert_notification(
    NEW.submitted_by,
    NULL,
    'ticket_created',
    'Your ticket has been received',
    NEW.title,
    '/tickets/' || NEW.id::text
  );

  -- Heads-up to all admins (skip the creator and the assignee — assignee gets a separate ticket_assigned notification)
  FOR _admin IN
    SELECT ur.user_id
    FROM public.user_roles ur
    WHERE ur.role = 'admin'
      AND ur.user_id <> NEW.submitted_by
      AND (NEW.assigned_to IS NULL OR ur.user_id <> NEW.assigned_to)
  LOOP
    PERFORM insert_notification(
      _admin.user_id,
      NEW.submitted_by,
      'ticket_created',
      'New support ticket submitted',
      NEW.title,
      '/admin/tickets/' || NEW.id::text
    );
  END LOOP;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_ticket_created"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_ticket_owner_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.owner_id IS NULL THEN RETURN NEW; END IF;
  IF OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN RETURN NEW; END IF;
  IF NEW.owner_id = auth.uid() THEN RETURN NEW; END IF;

  PERFORM insert_notification(
    NEW.owner_id,
    auth.uid(),
    'ticket_owner_changed',
    'You are now the owner of a ticket',
    NEW.title,
    '/tickets/' || NEW.id::text
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_ticket_owner_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_ticket_status_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  _status_name text;
  _is_closed boolean;
  _recipient uuid;
BEGIN
  IF OLD.status_id IS NOT DISTINCT FROM NEW.status_id THEN
    RETURN NEW;
  END IF;
  SELECT name, is_closed INTO _status_name, _is_closed
  FROM public.ticket_statuses WHERE id = NEW.status_id;

  _recipient := COALESCE(NEW.owner_id, NEW.submitted_by);
  IF _recipient IS NULL OR _recipient = auth.uid() THEN
    RETURN NEW;
  END IF;

  PERFORM insert_notification(
    _recipient,
    auth.uid(),
    'ticket_status_changed',
    CASE WHEN _is_closed THEN 'Your ticket has been closed' ELSE 'Your ticket status has been updated' END,
    'Ticket "' || NEW.title || '" is now ' || COALESCE(_status_name, 'updated'),
    '/tickets/' || NEW.id::text
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_ticket_status_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."parse_staff_count"("s" "text") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF s IS NULL OR trim(s) = '' THEN RETURN NULL; END IF;
  RETURN (regexp_match(s, '\d+'))[1]::int;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END $$;


ALTER FUNCTION "public"."parse_staff_count"("s" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prep_dispatch_due_digests"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_secret text;
  v_user   record;
  v_count  int := 0;
  v_tz     text;
BEGIN
  -- 'geocode_cron_secret' is the shared CRON_SECRET for all pg_cron HTTP calls.
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets WHERE name = 'geocode_cron_secret' LIMIT 1;
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'prep_dispatch_due_digests: CRON secret not found in vault (geocode_cron_secret)';
  END IF;

  FOR v_user IN
    SELECT pr.user_id,
           COALESCE(pr.timezone, p.timezone, 'America/New_York') AS tz
    FROM public.prep_reminder_preferences pr
    JOIN public.profiles p ON p.id = pr.user_id
    WHERE pr.enabled
      AND (now() AT TIME ZONE COALESCE(pr.timezone, p.timezone, 'America/New_York'))::time >= pr.send_time_local
      AND pr.last_sent_on IS DISTINCT FROM
          (now() AT TIME ZONE COALESCE(pr.timezone, p.timezone, 'America/New_York'))::date
  LOOP
    PERFORM net.http_post(
      url := 'https://trltcyzskmcveuabypat.supabase.co/functions/v1/prep-daily-digest',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_secret
      ),
      body := jsonb_build_object('target_user_id', v_user.user_id),
      timeout_milliseconds := 60000
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."prep_dispatch_due_digests"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prep_superiors"("_user" "uuid") RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH RECURSIVE chain AS (
    SELECT p.id, p.manager_id, 1 AS depth
    FROM public.profiles p
    WHERE p.id = _user
    UNION
    SELECT p.id, p.manager_id, c.depth + 1
    FROM public.profiles p
    JOIN chain c ON p.id = c.manager_id
    WHERE c.depth < 20            -- guard against manager_id cycles / runaway
  )
  SELECT id FROM chain WHERE id <> _user;   -- ancestors only, never the user
$$;


ALTER FUNCTION "public"."prep_superiors"("_user" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."prep_superiors"("_user" "uuid") IS 'Daily Prepper: the set of a user''s superiors (transitive managers up the profiles.manager_id chain). The context-pooling assembler excludes items contributed by anyone in this set ("everyone except my superiors").';



CREATE OR REPLACE FUNCTION "public"."prevent_tag_self_escalation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin'::app_role) THEN
    NEW.tags = OLD.tags;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_tag_self_escalation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_bdr_staging"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_processed int := 0;
  v_skipped int := 0;
  v_new_prospects int := 0;
  v_new_businesses int := 0;
  rec record;
  v_biz_id uuid;
  v_contact_name text;
  v_email text;
  v_phone text;
  v_title text;
  v_linkedin text;
  v_website text;
  v_city text;
  v_state text;
  v_company_name text;
  v_existing_prospect_id uuid;
BEGIN
  FOR rec IN
    SELECT * FROM bdr_seamless_staging
    WHERE processed IS NOT TRUE
    ORDER BY imported_at
  LOOP
    v_contact_name := coalesce(rec."Contact Full Name", trim(coalesce(rec."First Name",'') || ' ' || coalesce(rec."Last Name",'')));
    v_email := coalesce(nullif(rec."Email 1",''), nullif(rec."Primary Email",''), nullif(rec."Personal Email",''));
    v_phone := coalesce(nullif(rec."Contact Phone 1",''), nullif(rec."Contact Phone",''), nullif(rec."Contact Mobile Phone",''));
    v_title := rec."Title";
    v_linkedin := rec."Contact LI Profile URL";
    v_website := coalesce(nullif(rec."Company Website Domain",''), nullif(rec."Website",''));
    v_city := coalesce(nullif(rec."Contact Location - City",''), nullif(rec."Contact City",''), nullif(rec."Company City",''));
    v_state := coalesce(nullif(rec."Contact Location - State Abbreviation",''), nullif(rec."Contact State Abbr",''), nullif(rec."Company State Abbr",''));
    v_company_name := coalesce(nullif(rec."Company Name - Cleaned",''), rec."Company Name");

    IF v_contact_name IS NULL OR trim(v_contact_name) = '' OR v_email IS NULL OR trim(v_email) = '' THEN
      UPDATE bdr_seamless_staging SET processed = true, processed_at = now() WHERE id = rec.id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT id INTO v_existing_prospect_id
    FROM bdr_prospects
    WHERE lower(email) = lower(trim(v_email))
    LIMIT 1;

    IF v_existing_prospect_id IS NOT NULL THEN
      UPDATE bdr_seamless_staging SET processed = true, processed_at = now() WHERE id = rec.id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF v_company_name IS NOT NULL AND trim(v_company_name) != '' THEN
      SELECT id INTO v_biz_id
      FROM bdr_businesses
      WHERE lower(business_name) = lower(trim(v_company_name))
      LIMIT 1;

      IF v_biz_id IS NULL THEN
        INSERT INTO bdr_businesses (
          business_name, website, location_city, location_state,
          staff_estimate_researched, est_revenue_researched, industry
        ) VALUES (
          trim(v_company_name), v_website, v_city, v_state,
          nullif(rec."Company Staff Count",''), nullif(rec."Company Revenue Range",''), nullif(rec."Company Industry",'')
        )
        RETURNING id INTO v_biz_id;
        v_new_businesses := v_new_businesses + 1;
      END IF;
    END IF;

    INSERT INTO bdr_prospects (
      contact_name, email, phone, seamless_title, linkedin_url, website,
      location_city, location_state, business_id, is_available,
      seamless_raw
    ) VALUES (
      trim(v_contact_name), trim(v_email), v_phone, v_title, v_linkedin, v_website,
      v_city, v_state, v_biz_id, true,
      row_to_json(rec)::jsonb
    );
    v_new_prospects := v_new_prospects + 1;

    UPDATE bdr_seamless_staging SET processed = true, processed_at = now() WHERE id = rec.id;
    v_processed := v_processed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'skipped', v_skipped,
    'new_prospects', v_new_prospects,
    'new_businesses', v_new_businesses
  );
END;
$$;


ALTER FUNCTION "public"."process_bdr_staging"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  _current_owner uuid;
  _caller uuid := auth.uid();
BEGIN
  IF _caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_new_owner_id IS NULL THEN
    RAISE EXCEPTION 'new owner is required';
  END IF;

  SELECT owner_id INTO _current_owner FROM public.tickets WHERE id = p_ticket_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ticket not found';
  END IF;

  IF NOT public.has_role(_caller, 'admin'::app_role)
     AND _current_owner IS DISTINCT FROM _caller THEN
    RAISE EXCEPTION 'forbidden: only the ticket owner or an admin can reassign';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_new_owner_id) THEN
    RAISE EXCEPTION 'new owner not found';
  END IF;

  UPDATE public.tickets SET owner_id = p_new_owner_id WHERE id = p_ticket_id;
  RETURN p_new_owner_id;
END;
$$;


ALTER FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_firm record;
  v_now  timestamptz := now();
  v_uid  uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT id, partner_action INTO v_firm
  FROM public.sdr_firms WHERE id = p_firm_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm not found');
  END IF;

  IF v_firm.partner_action IS DISTINCT FROM 'SKIPPED' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm is not currently skipped');
  END IF;

  UPDATE public.sdr_firms
  SET partner_action     = 'CLAIMED',
      partner_action_at  = v_now,
      partner_user_id    = v_uid,
      claimed_at         = v_now,
      flag_reason        = NULL,
      partner_notes      = NULL,
      queue_id           = NULL,
      is_available       = FALSE,
      outreach_status    = COALESCE(outreach_status, 'Not Started'),
      outreach_status_updated_at = COALESCE(outreach_status_updated_at, v_now)
  WHERE id = p_firm_id;

  RETURN jsonb_build_object('success', true, 'firm_id', p_firm_id, 'claimed_at', v_now);
END $$;


ALTER FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_bdr_batch"("p_batch_id" "uuid", "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_batch record;
  v_released int;
BEGIN
  SELECT * INTO v_batch
  FROM public.bdr_batches
  WHERE id = p_batch_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Batch not found');
  END IF;

  IF v_batch.partner_user_id <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not your batch');
  END IF;

  IF v_batch.status <> 'ACTIVE' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Batch is not ACTIVE');
  END IF;

  -- Return unactioned prospects to the pool.
  UPDATE public.bdr_prospects
  SET batch_id = NULL,
      is_available = TRUE,
      partner_action = NULL,
      partner_action_at = NULL
  WHERE batch_id = p_batch_id
    AND partner_action IS NULL;
  GET DIAGNOSTICS v_released = ROW_COUNT;

  UPDATE public.bdr_batches
  SET status = 'RELEASED',
      completed_at = COALESCE(completed_at, now())
  WHERE id = p_batch_id;

  RETURN jsonb_build_object(
    'success', true,
    'released', v_released,
    'batch_id', p_batch_id
  );
END $$;


ALTER FUNCTION "public"."release_bdr_batch"("p_batch_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_firm record;
  v_queue_id uuid;
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT id, queue_id, partner_action, partner_user_id INTO v_firm
  FROM public.sdr_firms WHERE id = p_firm_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm not found');
  END IF;

  IF v_firm.partner_action IS DISTINCT FROM 'CLAIMED' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm is not currently claimed');
  END IF;

  IF v_firm.partner_user_id IS DISTINCT FROM p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not your firm');
  END IF;

  v_queue_id := v_firm.queue_id;

  UPDATE public.sdr_firms
  SET partner_action     = NULL,
      partner_action_at  = NULL,
      partner_user_id    = NULL,
      claimed_at         = NULL,
      flag_reason        = NULL,
      partner_notes      = NULL,
      queue_id           = NULL,
      outreach_status    = NULL,
      outreach_status_updated_at = NULL,
      is_available       = TRUE
  WHERE id = p_firm_id;

  IF v_queue_id IS NOT NULL THEN
    UPDATE public.sdr_prospect_queues q
    SET firm_count    = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id),
        claimed_count = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'CLAIMED'),
        flagged_count = (SELECT COUNT(*) FROM public.sdr_firms f WHERE f.queue_id = q.id AND f.partner_action = 'FLAGGED')
    WHERE q.id = v_queue_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'firm_id', p_firm_id, 'released_at', v_now);
END $$;


ALTER FUNCTION "public"."release_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_sdr_queue"("p_queue_id" "uuid", "p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_queue record;
  v_released int;
BEGIN
  SELECT * INTO v_queue
  FROM public.sdr_prospect_queues
  WHERE id = p_queue_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Queue not found');
  END IF;

  IF v_queue.partner_user_id <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not your queue');
  END IF;

  UPDATE public.sdr_firms
  SET queue_id = NULL,
      is_available = TRUE
  WHERE queue_id = p_queue_id
    AND partner_action IS NULL;
  GET DIAGNOSTICS v_released = ROW_COUNT;

  UPDATE public.sdr_prospect_queues
  SET status = 'RELEASED',
      completed_at = COALESCE(completed_at, now()),
      released_count = v_released
  WHERE id = p_queue_id;

  RETURN jsonb_build_object(
    'success', true,
    'released', v_released,
    'queue_id', p_queue_id
  );
END $$;


ALTER FUNCTION "public"."release_sdr_queue"("p_queue_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_firm record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT id, partner_action INTO v_firm
  FROM public.sdr_firms WHERE id = p_firm_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm not found');
  END IF;

  IF v_firm.partner_action IS DISTINCT FROM 'SKIPPED' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Firm is not currently skipped');
  END IF;

  UPDATE public.sdr_firms
  SET partner_action     = NULL,
      partner_action_at  = NULL,
      partner_user_id    = NULL,
      partner_notes      = NULL,
      flag_reason        = NULL,
      claimed_at         = NULL,
      queue_id           = NULL,
      outreach_status    = NULL,
      outreach_status_updated_at = NULL,
      is_available       = TRUE
  WHERE id = p_firm_id;

  RETURN jsonb_build_object('success', true, 'firm_id', p_firm_id);
END $$;


ALTER FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rename_sdr_rule_set"("p_rule_set_id" "uuid", "p_new_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT user_id INTO v_user_id
  FROM public.sdr_rule_sets
  WHERE id = p_rule_set_id;

  IF v_user_id IS NULL OR v_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Rule set not found or not owned by caller';
  END IF;

  IF p_new_name IS NULL OR length(trim(p_new_name)) = 0 THEN
    RAISE EXCEPTION 'New name is required';
  END IF;

  UPDATE public.sdr_rule_sets
  SET name = trim(p_new_name), updated_at = now()
  WHERE id = p_rule_set_id;
END;
$$;


ALTER FUNCTION "public"."rename_sdr_rule_set"("p_rule_set_id" "uuid", "p_new_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_sync_failure"("p_sync_function_name" "text", "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Mark every dataset that's served by this sync function as failed.
  -- Don't bump last_synced_at — admins want to see "last good sync was
  -- X hours ago" clearly. Back off next attempt by 15 minutes.
  UPDATE public.datasets
  SET
    last_sync_status = 'failure',
    last_sync_error = p_error,
    next_run_at = now() + interval '15 minutes'
  WHERE sync_function_name = p_sync_function_name
    AND status = 'active';

  -- Fire (debounced) alert.
  PERFORM public.notify_dataset_sync_failure(p_sync_function_name, p_error);
END;
$$;


ALTER FUNCTION "public"."report_sync_failure"("p_sync_function_name" "text", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_sync_success"("p_table_name" "text", "p_row_count" bigint) RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  UPDATE public.datasets
  SET
    last_synced_at = now(),
    last_sync_status = 'success',
    last_sync_error = NULL,
    last_alerted_at = NULL,        -- clear alert debounce so next failure re-fires
    row_count = p_row_count,
    next_run_at = now() + (COALESCE(refresh_interval_minutes, 60)::text || ' minutes')::interval
  WHERE table_name = p_table_name;
$$;


ALTER FUNCTION "public"."report_sync_success"("p_table_name" "text", "p_row_count" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reporting_dispatch_due_syncs"() RETURNS TABLE("sync_function_name" "text", "datasets_dispatched" integer, "request_id" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_secret text;
  v_function record;
  v_url text;
  v_request_id bigint;
BEGIN
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = 'geocode_cron_secret'
  LIMIT 1;

  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'reporting_dispatch_due_syncs: CRON secret not found in vault (geocode_cron_secret)';
  END IF;

  -- Find sync functions where AT LEAST ONE dataset is due. Skip
  -- functions whose datasets are still in-flight (last_run_started_at
  -- newer than last_synced_at AND younger than 15 minutes — older than
  -- that we treat as crashed and re-dispatch).
  FOR v_function IN
    SELECT
      ds.sync_function_name AS fn,
      count(*)::int AS due_count
    FROM public.datasets ds
    WHERE ds.status = 'active'
      AND ds.sync_function_name IS NOT NULL
      AND ds.next_run_at IS NOT NULL
      AND ds.next_run_at <= now()
      AND (
        ds.last_run_started_at IS NULL
        OR ds.last_run_started_at <= COALESCE(ds.last_synced_at, '-infinity'::timestamptz)
        OR ds.last_run_started_at < now() - interval '15 minutes'
      )
    GROUP BY ds.sync_function_name
  LOOP
    v_url := 'https://trltcyzskmcveuabypat.supabase.co/functions/v1/' || v_function.fn;

    -- Mark every dataset served by this function as in-flight so the
    -- next tick's "in-flight" check excludes them.
    UPDATE public.datasets
    SET last_run_started_at = now()
    WHERE datasets.sync_function_name = v_function.fn
      AND status = 'active';

    SELECT net.http_post(
      url := v_url,
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_secret
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 300000
    ) INTO v_request_id;

    sync_function_name   := v_function.fn;
    datasets_dispatched  := v_function.due_count;
    request_id           := v_request_id;
    RETURN NEXT;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."reporting_dispatch_due_syncs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reporting_owner_engagement_counts"("p_since" timestamp with time zone DEFAULT ("now"() - '30 days'::interval)) RETURNS TABLE("hubspot_owner_id" "text", "unique_contacts" bigint, "unique_firms" bigint, "emails_total" bigint, "calls_total" bigint, "meetings_total" bigint, "emails_in_window" bigint, "calls_in_window" bigint, "meetings_in_window" bigint)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  WITH engagement_counts AS (
    SELECT
      e.hubspot_owner_id,
      COUNT(*) FILTER (WHERE e.engagement_type = 'email')   AS emails_total,
      COUNT(*) FILTER (WHERE e.engagement_type = 'call')    AS calls_total,
      COUNT(*) FILTER (WHERE e.engagement_type = 'meeting') AS meetings_total,
      COUNT(*) FILTER (WHERE e.engagement_type = 'email'   AND e.hs_timestamp >= p_since) AS emails_in_window,
      COUNT(*) FILTER (WHERE e.engagement_type = 'call'    AND e.hs_timestamp >= p_since) AS calls_in_window,
      COUNT(*) FILTER (WHERE e.engagement_type = 'meeting' AND e.hs_timestamp >= p_since) AS meetings_in_window
    FROM public.hs_engagements e
    WHERE e.deleted = false
      AND e.hubspot_owner_id IS NOT NULL
    GROUP BY e.hubspot_owner_id
  ),
  contact_counts AS (
    SELECT
      e.hubspot_owner_id,
      COUNT(DISTINCT contact_id) AS unique_contacts
    FROM public.hs_engagements e
    CROSS JOIN LATERAL unnest(e.associated_contact_ids) AS contact_id
    WHERE e.deleted = false
      AND e.hubspot_owner_id IS NOT NULL
    GROUP BY e.hubspot_owner_id
  ),
  firm_counts AS (
    SELECT
      e.hubspot_owner_id,
      COUNT(DISTINCT company_id) AS unique_firms
    FROM public.hs_engagements e
    CROSS JOIN LATERAL unnest(e.associated_company_ids) AS company_id
    WHERE e.deleted = false
      AND e.hubspot_owner_id IS NOT NULL
    GROUP BY e.hubspot_owner_id
  )
  SELECT
    ec.hubspot_owner_id,
    COALESCE(cc.unique_contacts, 0) AS unique_contacts,
    COALESCE(fc.unique_firms, 0)    AS unique_firms,
    ec.emails_total,
    ec.calls_total,
    ec.meetings_total,
    ec.emails_in_window,
    ec.calls_in_window,
    ec.meetings_in_window
  FROM engagement_counts ec
  LEFT JOIN contact_counts cc ON cc.hubspot_owner_id = ec.hubspot_owner_id
  LEFT JOIN firm_counts   fc ON fc.hubspot_owner_id = ec.hubspot_owner_id;
$$;


ALTER FUNCTION "public"."reporting_owner_engagement_counts"("p_since" timestamp with time zone) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_descriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "methodology" "text" DEFAULT 'standard'::"text" NOT NULL,
    "methodology_label" "text",
    "structure" "jsonb" DEFAULT '{"sections": []}'::"jsonb" NOT NULL,
    "current_version" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "job_descriptions_methodology_check" CHECK (("methodology" = ANY (ARRAY['next_level_growth'::"text", 'arbinger'::"text", 'outward_mindset'::"text", 'standard'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."job_descriptions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."job_descriptions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org uuid;
  v_jd  public.job_descriptions;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.can_manage_job_description(p_profile_id) THEN
    RAISE EXCEPTION 'Not authorized to edit this job description';
  END IF;

  SELECT organization_id INTO v_org FROM public.profiles WHERE id = p_profile_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'Profile % has no organization', p_profile_id;
  END IF;

  INSERT INTO public.job_descriptions AS jd
    (profile_id, organization_id, methodology, methodology_label, structure,
     current_version, created_by, updated_by)
  VALUES
    (p_profile_id, v_org, p_methodology, p_methodology_label,
     COALESCE(p_structure, '{"sections":[]}'::jsonb), 1, v_uid, v_uid)
  ON CONFLICT (profile_id) DO UPDATE SET
    organization_id   = v_org,
    methodology       = EXCLUDED.methodology,
    methodology_label = EXCLUDED.methodology_label,
    structure         = EXCLUDED.structure,
    current_version   = jd.current_version + 1,
    updated_by        = v_uid,
    updated_at        = now()
  RETURNING * INTO v_jd;

  INSERT INTO public.job_description_versions
    (job_description_id, version, methodology, methodology_label, structure, note, created_by)
  VALUES
    (v_jd.id, v_jd.current_version, v_jd.methodology, v_jd.methodology_label,
     v_jd.structure, p_note, v_uid);

  RETURN v_jd;
END;
$$;


ALTER FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text") IS 'Upsert the current job description for p_profile_id, bump current_version, and write an immutable job_description_versions snapshot — atomically. Self-enforces can_manage_job_description().';



CREATE OR REPLACE FUNCTION "public"."sdr_contact_engagement_summary"("_firm_id" "uuid") RETURNS TABLE("contact_id" "uuid", "hubspot_contact_id" "text", "outbound_email_count" integer, "inbound_email_count" integer, "outbound_call_count" integer, "inbound_call_count" integer, "connected_call_count" integer, "meeting_count" integer, "last_outbound_at" timestamp with time zone, "last_response_at" timestamp with time zone, "last_meeting_at" timestamp with time zone, "ever_responded" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH firm_contacts AS (
    SELECT id, hubspot_contact_id
    FROM sdr_contacts
    WHERE firm_id = _firm_id AND hubspot_contact_id IS NOT NULL
  ),
  -- Pull every engagement linked to one of these contacts via the join table.
  contact_engagements AS (
    SELECT
      fc.id AS contact_id,
      fc.hubspot_contact_id,
      e.hubspot_object_type,
      e.direction,
      e.call_disposition,
      e.occurred_at
    FROM firm_contacts fc
    JOIN hubspot_engagement_contacts hec
      ON hec.hubspot_contact_id = fc.hubspot_contact_id
    JOIN hubspot_engagements e
      ON e.hubspot_engagement_id = hec.hubspot_engagement_id
  ),
  rolled AS (
    SELECT
      ce.contact_id,
      ce.hubspot_contact_id,
      COUNT(*) FILTER (WHERE ce.hubspot_object_type='email' AND ce.direction IN ('EMAIL','OUTBOUND'))::int AS outbound_email_count,
      COUNT(*) FILTER (WHERE ce.hubspot_object_type='email' AND ce.direction='INCOMING_EMAIL')::int     AS inbound_email_count,
      COUNT(*) FILTER (WHERE ce.hubspot_object_type='call'  AND ce.direction='OUTBOUND')::int          AS outbound_call_count,
      COUNT(*) FILTER (WHERE ce.hubspot_object_type='call'  AND ce.direction='INBOUND')::int           AS inbound_call_count,
      COUNT(*) FILTER (
        WHERE ce.hubspot_object_type='call'
        AND (ce.direction='INBOUND'
          OR ce.call_disposition IN ('CONNECTED','LEFT_LIVE_MESSAGE','f240bbac-87c9-4f6e-bf70-924b57d47db7'))
      )::int AS connected_call_count,
      COUNT(*) FILTER (WHERE ce.hubspot_object_type='meeting')::int AS meeting_count,
      MAX(ce.occurred_at) FILTER (
        WHERE (ce.hubspot_object_type='email' AND ce.direction IN ('EMAIL','OUTBOUND'))
           OR (ce.hubspot_object_type='call'  AND ce.direction='OUTBOUND')
      ) AS last_outbound_at,
      MAX(ce.occurred_at) FILTER (
        WHERE (ce.hubspot_object_type='email' AND ce.direction='INCOMING_EMAIL')
           OR (ce.hubspot_object_type='call'  AND ce.direction='INBOUND')
           OR (ce.hubspot_object_type='call' AND ce.call_disposition IN (
                 'CONNECTED','LEFT_LIVE_MESSAGE','f240bbac-87c9-4f6e-bf70-924b57d47db7'))
      ) AS last_response_at,
      MAX(ce.occurred_at) FILTER (WHERE ce.hubspot_object_type='meeting') AS last_meeting_at
    FROM contact_engagements ce
    GROUP BY ce.contact_id, ce.hubspot_contact_id
  )
  SELECT
    c.id,
    c.hubspot_contact_id,
    COALESCE(r.outbound_email_count, 0),
    COALESCE(r.inbound_email_count, 0),
    COALESCE(r.outbound_call_count, 0),
    COALESCE(r.inbound_call_count, 0),
    COALESCE(r.connected_call_count, 0),
    COALESCE(r.meeting_count, 0),
    r.last_outbound_at,
    r.last_response_at,
    r.last_meeting_at,
    (r.last_response_at IS NOT NULL)
  FROM firm_contacts c
  LEFT JOIN rolled r ON r.contact_id = c.id;
$$;


ALTER FUNCTION "public"."sdr_contact_engagement_summary"("_firm_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sdr_email_templates_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sdr_email_templates_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sdr_engagement_sync_stats"("_user_id" "uuid") RETURNS TABLE("total_firms" bigint, "synced_firms" bigint, "stale_firms" bigint, "never_synced" bigint, "total_engagements" bigint, "emails" bigint, "calls" bigint, "meetings" bigint, "notes" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH me AS (
    SELECT ARRAY_REMOVE(ARRAY[lower(hubspot_owner_email), lower(email), lower(secondary_email)], NULL) AS emails
    FROM profiles WHERE id = _user_id
  ),
  my_firms AS (
    SELECT f.id, f.hubspot_company_id, f.hubspot_engagements_synced_at
    FROM sdr_firms f, me
    WHERE f.hubspot_company_id IS NOT NULL
      AND lower(f.hubspot_owner_email) = ANY(me.emails)
  ),
  cutoff AS (SELECT (now() - interval '24 hours') AS ts)
  SELECT
    (SELECT count(*) FROM my_firms),
    (SELECT count(*) FROM my_firms WHERE hubspot_engagements_synced_at IS NOT NULL AND hubspot_engagements_synced_at >= (SELECT ts FROM cutoff)),
    (SELECT count(*) FROM my_firms WHERE hubspot_engagements_synced_at IS NOT NULL AND hubspot_engagements_synced_at < (SELECT ts FROM cutoff)),
    (SELECT count(*) FROM my_firms WHERE hubspot_engagements_synced_at IS NULL),
    (SELECT count(*) FROM hubspot_engagements e WHERE e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms)),
    (SELECT count(*) FROM hubspot_engagements e WHERE e.hubspot_object_type = 'email' AND e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms)),
    (SELECT count(*) FROM hubspot_engagements e WHERE e.hubspot_object_type = 'call' AND e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms)),
    (SELECT count(*) FROM hubspot_engagements e WHERE e.hubspot_object_type = 'meeting' AND e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms)),
    (SELECT count(*) FROM hubspot_engagements e WHERE e.hubspot_object_type = 'note' AND e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms));
$$;


ALTER FUNCTION "public"."sdr_engagement_sync_stats"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sdr_firm_response_status"("_user_id" "uuid") RETURNS TABLE("firm_id" "uuid", "firm_name" "text", "hubspot_company_id" "text", "last_outbound_at" timestamp with time zone, "last_outbound_type" "text", "last_response_at" timestamp with time zone, "last_response_type" "text", "days_since_outbound" integer, "is_non_responder" boolean, "threshold_days" integer, "ever_responded" boolean, "response_count" integer, "outbound_email_count" integer, "inbound_email_count" integer, "outbound_call_count" integer, "inbound_call_count" integer, "connected_call_count" integer, "meeting_count" integer, "last_meeting_at" timestamp with time zone, "followup_research_queued_at" timestamp with time zone, "followup_research_completed_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  WITH me AS (
    SELECT
      ARRAY_REMOVE(ARRAY[lower(hubspot_owner_email), lower(email), lower(secondary_email)], NULL) AS emails,
      COALESCE(sdr_nonresponder_days, 14) AS threshold
    FROM profiles
    WHERE id = _user_id
  ),
  my_firms AS (
    SELECT f.id, f.firm_name, f.hubspot_company_id,
           f.followup_research_queued_at, f.followup_research_completed_at
    FROM sdr_firms f, me
    WHERE f.hubspot_company_id IS NOT NULL
      AND lower(f.hubspot_owner_email) = ANY(me.emails)
  ),
  firm_engagements AS (
    SELECT e.*
    FROM hubspot_engagements e
    WHERE e.hubspot_company_id IN (SELECT hubspot_company_id FROM my_firms)
  ),
  outbound_ranked AS (
    SELECT
      e.hubspot_company_id,
      e.occurred_at,
      e.hubspot_object_type,
      ROW_NUMBER() OVER (PARTITION BY e.hubspot_company_id ORDER BY e.occurred_at DESC) AS rn
    FROM firm_engagements e
    WHERE (e.hubspot_object_type = 'email' AND e.direction IN ('EMAIL', 'OUTBOUND'))
       OR (e.hubspot_object_type = 'call'  AND e.direction = 'OUTBOUND')
  ),
  outbound AS (
    SELECT hubspot_company_id, occurred_at AS last_at, hubspot_object_type AS last_type
    FROM outbound_ranked WHERE rn = 1
  ),
  response_ranked AS (
    SELECT
      e.hubspot_company_id,
      e.occurred_at,
      e.hubspot_object_type,
      ROW_NUMBER() OVER (PARTITION BY e.hubspot_company_id ORDER BY e.occurred_at DESC) AS rn
    FROM firm_engagements e
    WHERE (e.hubspot_object_type = 'email' AND e.direction = 'INCOMING_EMAIL')
       OR (e.hubspot_object_type = 'call'  AND e.direction = 'INBOUND')
       OR (
         e.hubspot_object_type = 'call'
         AND e.call_disposition IN (
           'CONNECTED',
           'LEFT_LIVE_MESSAGE',
           'f240bbac-87c9-4f6e-bf70-924b57d47db7'
         )
       )
  ),
  response AS (
    SELECT hubspot_company_id, occurred_at AS last_at, hubspot_object_type AS last_type
    FROM response_ranked WHERE rn = 1
  ),
  counts AS (
    SELECT
      e.hubspot_company_id,
      COUNT(*) FILTER (WHERE e.hubspot_object_type = 'email' AND e.direction IN ('EMAIL', 'OUTBOUND'))::int AS outbound_email_count,
      COUNT(*) FILTER (WHERE e.hubspot_object_type = 'email' AND e.direction = 'INCOMING_EMAIL')::int AS inbound_email_count,
      COUNT(*) FILTER (WHERE e.hubspot_object_type = 'call' AND e.direction = 'OUTBOUND')::int AS outbound_call_count,
      COUNT(*) FILTER (WHERE e.hubspot_object_type = 'call' AND e.direction = 'INBOUND')::int AS inbound_call_count,
      COUNT(*) FILTER (
        WHERE e.hubspot_object_type = 'call'
        AND (
          e.direction = 'INBOUND'
          OR e.call_disposition IN (
            'CONNECTED',
            'LEFT_LIVE_MESSAGE',
            'f240bbac-87c9-4f6e-bf70-924b57d47db7'
          )
        )
      )::int AS connected_call_count,
      COUNT(*) FILTER (WHERE e.hubspot_object_type = 'meeting')::int AS meeting_count,
      MAX(e.occurred_at) FILTER (WHERE e.hubspot_object_type = 'meeting') AS last_meeting_at,
      COUNT(*) FILTER (
        WHERE (e.hubspot_object_type = 'email' AND e.direction = 'INCOMING_EMAIL')
           OR (e.hubspot_object_type = 'call' AND e.direction = 'INBOUND')
           OR (
             e.hubspot_object_type = 'call'
             AND e.call_disposition IN (
               'CONNECTED',
               'LEFT_LIVE_MESSAGE',
               'f240bbac-87c9-4f6e-bf70-924b57d47db7'
             )
           )
      )::int AS response_count
    FROM firm_engagements e
    GROUP BY e.hubspot_company_id
  )
  SELECT
    f.id,
    f.firm_name,
    f.hubspot_company_id,
    o.last_at,
    o.last_type,
    r.last_at,
    r.last_type,
    CASE WHEN o.last_at IS NULL THEN NULL
         ELSE (EXTRACT(EPOCH FROM (now() - o.last_at)) / 86400)::int END,
    (
      o.last_at IS NOT NULL
      AND (r.last_at IS NULL OR r.last_at < o.last_at)
      AND (EXTRACT(EPOCH FROM (now() - o.last_at)) / 86400) >= (SELECT threshold FROM me)
    ),
    (SELECT threshold FROM me),
    (r.last_at IS NOT NULL),
    COALESCE(c.response_count, 0),
    COALESCE(c.outbound_email_count, 0),
    COALESCE(c.inbound_email_count, 0),
    COALESCE(c.outbound_call_count, 0),
    COALESCE(c.inbound_call_count, 0),
    COALESCE(c.connected_call_count, 0),
    COALESCE(c.meeting_count, 0),
    c.last_meeting_at,
    f.followup_research_queued_at,
    f.followup_research_completed_at
  FROM my_firms f
  LEFT JOIN outbound o ON o.hubspot_company_id = f.hubspot_company_id
  LEFT JOIN response r ON r.hubspot_company_id = f.hubspot_company_id
  LEFT JOIN counts c ON c.hubspot_company_id = f.hubspot_company_id;
$$;


ALTER FUNCTION "public"."sdr_firm_response_status"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_active_sdr_rule_set"("p_rule_set_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT user_id INTO v_user_id
  FROM public.sdr_rule_sets
  WHERE id = p_rule_set_id;

  IF v_user_id IS NULL OR v_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Rule set not found or not owned by caller';
  END IF;

  UPDATE public.sdr_rule_sets
  SET is_active = false, updated_at = now()
  WHERE user_id = auth.uid()
    AND id <> p_rule_set_id
    AND is_active = true;

  UPDATE public.sdr_rule_sets
  SET is_active = true, updated_at = now()
  WHERE id = p_rule_set_id
    AND is_active = false;
END;
$$;


ALTER FUNCTION "public"."set_active_sdr_rule_set"("p_rule_set_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_rtl_firm_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_rtl_firm_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_ticket_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  _default_assignee uuid;
BEGIN
  IF NEW.owner_id IS NULL THEN
    NEW.owner_id := NEW.submitted_by;
  END IF;
  IF NEW.assigned_to IS NULL THEN
    SELECT NULLIF(value, '')::uuid INTO _default_assignee
    FROM public.app_settings
    WHERE key = 'default_ticket_assignee_id';
    IF _default_assignee IS NOT NULL THEN
      NEW.assigned_to := _default_assignee;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_ticket_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_ticket_sequential_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.sequential_id IS NULL THEN
    NEW.sequential_id := nextval('public.ticket_seq');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_ticket_sequential_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin new.updated_at = now(); return new; end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at_sdr_rule_sets"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at_sdr_rule_sets"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tas_advance_sequence"("p_sequence_id" "uuid", "p_notes" "text" DEFAULT NULL::"text", "p_copy_used" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_seq          record;
  v_next_step    record;
  v_days_gap     integer;
  v_next_date    date;
  v_next_channel text;
  v_next_label   text;
  v_use_inmail   boolean := false;
  v_li_connected boolean := false;
begin

  select s.*, c.li_connected as contact_li_connected
  into   v_seq
  from   tas_sequences  s
  join   tas_contacts   c on c.id = s.contact_id
  where  s.id = p_sequence_id
  for    update of s;

  if not found then
    return json_build_object('ok', false, 'error', 'Sequence not found');
  end if;

  if v_seq.sequence_status != 'active' then
    return json_build_object('ok', false, 'error', 'Sequence is not active');
  end if;

  update tas_sequence_steps
  set
    status       = 'completed',
    completed_at = now(),
    message_body = coalesce(p_copy_used, message_body)
  where sequence_id = p_sequence_id
    and step_number = v_seq.current_step
    and status      = 'pending';

  if p_notes is not null and trim(p_notes) != '' then
    update tas_sequences
    set partner_notes = p_notes, updated_at = now()
    where id = p_sequence_id;
  end if;

  if v_seq.current_step >= v_seq.total_steps then
    update tas_sequences set
      sequence_status     = 'completed',
      completed_at        = now(),
      last_step_at        = now(),
      next_action_date    = null,
      next_action_channel = null,
      next_action_label   = null,
      updated_at          = now()
    where id = p_sequence_id;

    return json_build_object('ok', true, 'status', 'completed', 'message', 'All steps complete');
  end if;

  v_days_gap := case v_seq.sequence_tier
    when 'hot' then
      case v_seq.current_step
        when 1 then 3 when 2 then 2 when 3 then 2
        when 4 then 2 when 5 then 2 when 6 then 3 else 3
      end
    when 'warm' then
      case v_seq.current_step
        when 1 then 5 when 2 then 3 when 3 then 3
        when 4 then 3 when 5 then 3 when 6 then 4 else 4
      end
    else
      case v_seq.current_step
        when 1 then 7 when 2 then 6 when 3 then 6
        when 4 then 6 else 7
      end
  end;

  v_next_date := current_date + v_days_gap;

  select * into v_next_step
  from   tas_sequence_steps
  where  sequence_id = p_sequence_id
    and  step_number = v_seq.current_step + 1;

  v_next_channel := v_next_step.channel;
  v_next_label   := v_next_step.step_label;

  if v_seq.current_step = 1
     and v_seq.sequence_tier in ('hot', 'warm')
     and not v_seq.inmail_used
     and v_seq.li_connection_sent_at is not null
     and (now() - v_seq.li_connection_sent_at) >= interval '5 days'
     and not v_seq.contact_li_connected
  then
    v_use_inmail   := true;
    v_next_channel := 'inmail';
    v_next_label   := 'Send InMail (no connection after 5 days)';
    v_next_date    := current_date;
  end if;

  update tas_sequences set
    current_step        = v_seq.current_step + 1,
    next_action_date    = v_next_date,
    next_action_channel = v_next_channel,
    next_action_label   = v_next_label,
    last_step_at        = now(),
    inmail_used         = inmail_used or v_use_inmail,
    updated_at          = now()
  where id = p_sequence_id;

  -- Stamp scheduled_date on the immediate next step
  update tas_sequence_steps
  set scheduled_date = v_next_date
  where sequence_id  = p_sequence_id
    and step_number  = v_seq.current_step + 1;

  -- Project estimated scheduled dates on all further future steps
  update tas_sequence_steps ss
  set scheduled_date = (
    v_next_date + (
      (ss.step_number - (v_seq.current_step + 1)) *
      CASE v_seq.sequence_tier
        WHEN 'hot'  THEN 2
        WHEN 'warm' THEN 3
        ELSE             6
      END
    ) * INTERVAL '1 day'
  )::date
  where ss.sequence_id = p_sequence_id
    and ss.step_number > v_seq.current_step + 1
    and ss.status = 'pending';

  if v_use_inmail then
    insert into tas_inmail_budget (user_id, month, credits_total, credits_used, credits_refunded)
    values (v_seq.assigned_to, date_trunc('month', current_date)::date, 50, 1, 0)
    on conflict (user_id, month)
    do update set
      credits_used = tas_inmail_budget.credits_used + 1,
      updated_at   = now();
  end if;

  return json_build_object(
    'ok',           true,
    'status',       'advanced',
    'prev_step',    v_seq.current_step,
    'next_step',    v_seq.current_step + 1,
    'next_date',    v_next_date::text,
    'next_channel', v_next_channel,
    'next_label',   v_next_label,
    'inmail_queued',v_use_inmail
  );

end;
$$;


ALTER FUNCTION "public"."tas_advance_sequence"("p_sequence_id" "uuid", "p_notes" "text", "p_copy_used" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_expansion_email_templates_touch"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END$$;


ALTER FUNCTION "public"."tg_expansion_email_templates_touch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."track_email_open"("p_tracking_pixel_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  UPDATE email_activity_log
  SET open_count = open_count + 1,
      first_opened_at = COALESCE(first_opened_at, now()),
      status = CASE WHEN status IN ('drafted', 'sent') THEN 'opened' ELSE status END
  WHERE tracking_pixel_id = p_tracking_pixel_id;
$$;


ALTER FUNCTION "public"."track_email_open"("p_tracking_pixel_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."undo_import"("p_log_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Delete all sequences tagged with this import
  DELETE FROM tas_sequences WHERE import_log_id = p_log_id;

  -- Clean up contacts that are no longer referenced by any sequence
  DELETE FROM tas_contacts
  WHERE id NOT IN (SELECT contact_id FROM tas_sequences WHERE contact_id IS NOT NULL);

  -- Clean up businesses no longer referenced by any contact or sequence
  DELETE FROM tas_businesses
  WHERE id NOT IN (SELECT business_id FROM tas_contacts  WHERE business_id IS NOT NULL)
    AND id NOT IN (SELECT business_id FROM tas_sequences WHERE business_id IS NOT NULL);

  -- Delete the log entry itself
  DELETE FROM tas_import_logs WHERE id = p_log_id;
END;
$$;


ALTER FUNCTION "public"."undo_import"("p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_document_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_document_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_task_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_task_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_ticket_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_ticket_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_has_tag"("_user_id" "uuid", "_tag" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ select exists (select 1 from public.profiles where id = _user_id and _tag = any(tags)) $$;


ALTER FUNCTION "public"."user_has_tag"("_user_id" "uuid", "_tag" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_nine_box_score"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.performance_col NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'performance_col must be between 1 and 3';
  END IF;
  IF NEW.potential_row NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'potential_row must be between 1 and 3';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_nine_box_score"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_notification_type"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.type NOT IN (
    'task_assigned','task_due_soon','task_comment','task_completed_created',
    'ticket_updated','ticket_created','ticket_assigned','ticket_status_changed','ticket_comment','ticket_owner_changed',
    'rfp_new_matching','rfp_bid_received','rfp_question_posted','rfp_question_answered','rfp_awarded',
    'document_uploaded','document_shared','document_approved','document_rejected',
    'project_update','project_task_completed','project_status_changed','project_member_added','project_due_soon',
    'agreement_status_changed',
    'announcement_posted','mention','comment_posted','kb_article_published',
    'checkin_reminder','checkin_submitted','comment_tagged'
  ) THEN
    RAISE EXCEPTION 'Invalid notification type: %', NEW.type;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_notification_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_project_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.status NOT IN ('active', 'completed', 'archived', 'on_track', 'at_risk', 'off_track') THEN
    RAISE EXCEPTION 'status must be active, completed, archived, on_track, at_risk, or off_track';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_project_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_task_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.priority NOT IN ('low', 'medium', 'high', 'urgent') THEN
    RAISE EXCEPTION 'priority must be low, medium, high, or urgent';
  END IF;
  IF NEW.status NOT IN ('not_started', 'in_progress', 'blocked', 'complete') THEN
    RAISE EXCEPTION 'status must be not_started, in_progress, blocked, or complete';
  END IF;
  IF NEW.source_type NOT IN ('standalone', 'checklist', 'ticket', 'project', 'ssg_engagement', 'hris_onboarding', 'hris_offboarding') THEN
    RAISE EXCEPTION 'source_type must be standalone, checklist, ticket, project, ssg_engagement, hris_onboarding, or hris_offboarding';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_task_fields"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activity_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "user_name" "text",
    "user_organization" "text",
    "event_type" "text" NOT NULL,
    "event_category" "text" NOT NULL,
    "description" "text" NOT NULL,
    "page_section" "text",
    "target_id" "text",
    "target_type" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "text",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."activity_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."announcements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid"
);


ALTER TABLE "public"."announcements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "key" "text" NOT NULL,
    "value" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."assessment_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed" boolean DEFAULT false NOT NULL,
    "score_pct" integer,
    "band_label" "text",
    "maximize_value_clicked" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."assessment_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bdr_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_number" integer,
    "partner_user_id" "uuid",
    "partner_name" "text",
    "prospect_count" integer DEFAULT 10,
    "claimed_count" integer DEFAULT 0,
    "skipped_count" integer DEFAULT 0,
    "flagged_count" integer DEFAULT 0,
    "status" "text" DEFAULT 'ACTIVE'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone
);


ALTER TABLE "public"."bdr_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bdr_business_people" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid",
    "person_name" "text",
    "title" "text",
    "email" "text",
    "phone" "text",
    "linkedin_url" "text",
    "person_status" "text",
    "bio_notes" "text",
    "source_url" "text",
    "date_added" "date" DEFAULT CURRENT_DATE
);


ALTER TABLE "public"."bdr_business_people" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bdr_businesses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_name" "text",
    "website" "text",
    "industry" "text",
    "business_model_type" "text",
    "location_city" "text",
    "location_state" "text",
    "company_status" "text",
    "staff_estimate_researched" "text",
    "est_revenue_researched" "text",
    "company_description" "text",
    "strategic_direction" "text",
    "accounting_complexity_tags" "text"[],
    "real_estate_flag" boolean DEFAULT false,
    "rd_flag" boolean DEFAULT false,
    "nonprofit_flag" boolean DEFAULT false,
    "vc_backed_flag" boolean DEFAULT false,
    "timing_signal" "text",
    "source_notes" "text",
    "last_researched_at" timestamp with time zone DEFAULT "now"(),
    "logo_url" "text",
    "sector" "text",
    "latitude" double precision,
    "longitude" double precision,
    "geocoded_at" timestamp with time zone
);


ALTER TABLE "public"."bdr_businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bdr_prospects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid",
    "batch_id" "uuid",
    "contact_name" "text",
    "seamless_title" "text",
    "verified_title" "text",
    "email" "text",
    "phone" "text",
    "linkedin_url" "text",
    "website" "text",
    "location_city" "text",
    "location_state" "text",
    "verdict" "text",
    "employment_status" "text",
    "bio_background" "text",
    "personalization_hook" "text",
    "timing_signal" "text",
    "accounting_complexity_tags" "text"[],
    "business_model_type" "text",
    "real_estate_flag" boolean DEFAULT false,
    "rd_flag" boolean DEFAULT false,
    "draft_email_long" "text",
    "draft_email_short" "text",
    "notes_flags" "text",
    "source_notes" "text",
    "is_available" boolean DEFAULT true,
    "partner_action" "text",
    "partner_action_at" timestamp with time zone,
    "partner_notes" "text",
    "flag_reason" "text",
    "outreach_status" "text" DEFAULT 'NOT_STARTED'::"text",
    "outreach_status_updated_at" timestamp with time zone,
    "date_researched" "date",
    "researched_by_user_id" "uuid",
    "researched_by_name" "text",
    "seamless_raw" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "title_category" "text",
    "photo_url" "text",
    "email_status" "text",
    "draft_subject_long" "text",
    "draft_subject_short" "text",
    "draft_generated_at" timestamp with time zone,
    "draft_generated_by" "uuid",
    CONSTRAINT "bdr_prospects_email_status_check" CHECK ((("email_status" IS NULL) OR ("email_status" = ANY (ARRAY['ready'::"text", 'drafted'::"text"]))))
);


ALTER TABLE "public"."bdr_prospects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bdr_seamless_staging" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "imported_at" timestamp with time zone DEFAULT "now"(),
    "processed" boolean DEFAULT false,
    "processed_at" timestamp with time zone,
    "import_batch" "text",
    "Company Name" "text",
    "Company Name - Cleaned" "text",
    "Company Annual Revenue" "text",
    "Company Revenue Range" "text",
    "Company Staff Count" "text",
    "Company Staff Count Range" "text",
    "Company Industry" "text",
    "Company City" "text",
    "Company State" "text",
    "Company State Abbr" "text",
    "Company Country" "text",
    "Company Country - Numeric" "text",
    "Company Country (Alpha 2)" "text",
    "Company Country (Alpha 3)" "text",
    "Company County" "text",
    "Company Post Code" "text",
    "Company Street 1" "text",
    "Company Street 2" "text",
    "Company Street 3" "text",
    "Company Location" "text",
    "Company Website Domain" "text",
    "Company Description" "text",
    "Company Founded Date" "text",
    "Company LI Profile Url" "text",
    "Company LinkedIn ID" "text",
    "Company Phone 1" "text",
    "Company Phone 1 Total AI" "text",
    "Company Phone 2" "text",
    "Company Phone 2 Total AI" "text",
    "Company Phone 3" "text",
    "Company Phone 3 Total AI" "text",
    "Company Phone 4" "text",
    "Company Phone 4 Total AI" "text",
    "Company Phone 5" "text",
    "Company Phone 5 Total AI" "text",
    "Company Phone 6" "text",
    "Company Phone 6 Total AI" "text",
    "Company Phone 7" "text",
    "Company Phone 7 Total AI" "text",
    "Company Phone 8" "text",
    "Company Phone 8 Total AI" "text",
    "Company Phone 9" "text",
    "Company Phone 9 Total AI" "text",
    "Company Phone 10" "text",
    "Company Phone 10 Total AI" "text",
    "Company Funding Total" "text",
    "Company Latest Funding Date" "text",
    "Company Latest Funding Classifications" "text",
    "NAICS Code" "text",
    "SIC Code" "text",
    "Contact Full Name" "text",
    "First Name" "text",
    "First Name_2" "text",
    "Last Name" "text",
    "Last Name_2" "text",
    "Middle Name" "text",
    "Title" "text",
    "Department" "text",
    "Seniority" "text",
    "Contact LI Profile URL" "text",
    "Contact City" "text",
    "Contact State" "text",
    "Contact State Abbr" "text",
    "Contact Country" "text",
    "Contact Country - Numeric" "text",
    "Contact Country (Alpha 2)" "text",
    "Contact Country (Alpha 3)" "text",
    "Contact County" "text",
    "Contact Post Code" "text",
    "Contact Location" "text",
    "Contact Location - City" "text",
    "Contact Location - State" "text",
    "Contact Location - State Abbreviation" "text",
    "Contact Location - Country" "text",
    "Contact Location - Country Alpha-2 Code" "text",
    "Contact Location - Country Alpha-3 Code" "text",
    "Contact Location - Country Numeric Code" "text",
    "Contact Location - ZIP" "text",
    "Contact Phone" "text",
    "Contact Phone 1" "text",
    "Contact Phone 1 Total AI" "text",
    "Contact Phone 2" "text",
    "Contact Phone 2 Total AI" "text",
    "Contact Phone 3" "text",
    "Contact Phone 3 Total AI" "text",
    "Contact Phone 4" "text",
    "Contact Phone 4 Total AI" "text",
    "Contact Phone 5" "text",
    "Contact Phone 5 Total AI" "text",
    "Contact Phone 6" "text",
    "Contact Phone 6 Total AI" "text",
    "Contact Phone 7" "text",
    "Contact Phone 7 Total AI" "text",
    "Contact Phone 8" "text",
    "Contact Phone 8 Total AI" "text",
    "Contact Phone 9" "text",
    "Contact Phone 9 Total AI" "text",
    "Contact Phone 10" "text",
    "Contact Phone 10 Total AI" "text",
    "Contact Mobile Phone" "text",
    "Contact Mobile Phone 1 Total AI" "text",
    "Contact Mobile Phone 2" "text",
    "Contact Mobile Phone 2 Total AI" "text",
    "Contact Mobile Phone 3" "text",
    "Contact Mobile Phone 3 Total AI" "text",
    "Contact Mobile Phone 4" "text",
    "Contact Mobile Phone 4 Total AI" "text",
    "Contact Mobile Phone 5" "text",
    "Contact Mobile Phone 5 Total AI" "text",
    "Contact Mobile Phone 6" "text",
    "Contact Mobile Phone 6 Total AI" "text",
    "Contact Mobile Phone 7" "text",
    "Contact Mobile Phone 7 Total AI" "text",
    "Contact Mobile Phone 8" "text",
    "Contact Mobile Phone 8 Total AI" "text",
    "Contact Mobile Phone 9" "text",
    "Contact Mobile Phone 9 Total AI" "text",
    "Contact Mobile Phone 10" "text",
    "Contact Mobile Phone 10 Total AI" "text",
    "Email 1" "text",
    "Email 1 Total AI" "text",
    "Email 1 Validation" "text",
    "Email 2" "text",
    "Email 2 Total AI" "text",
    "Email 2 Validation" "text",
    "Email 3" "text",
    "Email 3 Total AI" "text",
    "Email 3 Validation" "text",
    "Email 4" "text",
    "Email 4 Total AI" "text",
    "Email 4 Validation" "text",
    "Email 5" "text",
    "Email 5 Total AI" "text",
    "Email 5 Validation" "text",
    "Email 6" "text",
    "Email 6 Total AI" "text",
    "Email 6 Validation" "text",
    "Email 7" "text",
    "Email 7 Total AI" "text",
    "Email 7 Validation" "text",
    "Email 8" "text",
    "Email 8 Total AI" "text",
    "Email 8 Validation" "text",
    "Email 9" "text",
    "Email 9 Total AI" "text",
    "Email 9 Validation" "text",
    "Email 10" "text",
    "Email 10 Total AI" "text",
    "Email 10 Validation" "text",
    "Primary Email" "text",
    "Personal Email" "text",
    "Personal Email Total AI" "text",
    "Personal Email Validation" "text",
    "Personal Email 2" "text",
    "Personal Email 2 Total AI" "text",
    "Personal Email 2 Validation" "text",
    "Personal Email 3" "text",
    "Personal Email 3 Total AI" "text",
    "Personal Email 3 Validation" "text",
    "Date Imported" "text",
    "Research Date" "text",
    "Seamless Username" "text",
    "leadSource" "text",
    "List" "text",
    "Lists" "text",
    "Intel" "text",
    "Job Change Type" "text",
    "Past Job" "text",
    "Time at Company" "text",
    "Time in Role" "text",
    "Location" "text",
    "Website" "text",
    "CRM & Social" "text",
    "CRM Account ID" "text",
    "Current CRM User Email" "text",
    "Current CRM User ID" "text"
);


ALTER TABLE "public"."bdr_seamless_staging" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_plan_checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "checkin_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "health" "text" DEFAULT 'on_track'::"text" NOT NULL,
    "progress_notes" "text",
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_plan_checkins_health_check" CHECK (("health" = ANY (ARRAY['on_track'::"text", 'at_risk'::"text", 'off_track'::"text"])))
);


ALTER TABLE "public"."business_plan_checkins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_plan_revenue_drivers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "category" "text" DEFAULT 'other'::"text" NOT NULL,
    "label" "text",
    "amount_type" "text" DEFAULT 'dollar'::"text" NOT NULL,
    "amount" numeric DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_plan_revenue_drivers_amount_type_check" CHECK (("amount_type" = ANY (ARRAY['dollar'::"text", 'percent'::"text"]))),
    CONSTRAINT "business_plan_revenue_drivers_category_check" CHECK (("category" = ANY (ARRAY['organic_growth'::"text", 'acquisition'::"text", 'referral_partner'::"text", 'ssg'::"text", 'fee_increase'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."business_plan_revenue_drivers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "plan_year" integer NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "goals" "text",
    "needs_from_alliance" "text",
    "alliance_commitments" "text",
    "revenue_baseline" numeric,
    "revenue_target" numeric,
    "target_lift_pct" numeric DEFAULT 10 NOT NULL,
    "owner_id" "uuid",
    "documented_at" timestamp with time zone,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_plans_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."business_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checkin_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "assignee_id" "uuid" NOT NULL,
    "manager_id" "uuid" NOT NULL,
    "frequency" "text" DEFAULT 'weekly'::"text" NOT NULL,
    "reminder_day" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."checkin_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checkin_edit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "submission_id" "uuid" NOT NULL,
    "edited_by" "uuid" NOT NULL,
    "edited_by_name" "text",
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "changes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL
);


ALTER TABLE "public"."checkin_edit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checkin_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "assignee_id" "uuid" NOT NULL,
    "manager_id" "uuid" NOT NULL,
    "meeting_date" "date" NOT NULL,
    "is_draft" boolean DEFAULT false NOT NULL,
    "submitted_at" timestamp with time zone,
    "presence_head_color" "text",
    "presence_head_word" "text",
    "presence_head_context" "text",
    "presence_heart_color" "text",
    "presence_heart_word" "text",
    "presence_heart_context" "text",
    "presence_hands_color" "text",
    "presence_hands_word" "text",
    "presence_hands_context" "text",
    "presence_soul_color" "text",
    "presence_soul_word" "text",
    "presence_soul_context" "text",
    "presence_overall_color" "text",
    "presence_overall_word" "text",
    "presence_overall_context" "text",
    "to_dones" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "rocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "issues" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "my_todos" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "supervisor_todos" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "monthly_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."checkin_submissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checkin_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."checkin_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "organization_id" "uuid",
    "user_id" "uuid",
    "assigned_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "owner_id" "uuid",
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid"
);


ALTER TABLE "public"."checklist_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_custom_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "section" "text",
    "sort_order" integer DEFAULT 0,
    "due_date" "date",
    "assignee_id" "uuid",
    "completed" boolean DEFAULT false,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."checklist_custom_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_item_overrides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "checklist_item_id" "uuid" NOT NULL,
    "description" "text",
    "due_date" "date",
    "sort_order" integer,
    "section" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."checklist_item_overrides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "section" "text",
    "default_assignee_id" "uuid",
    "description" "text",
    "due_days_offset" integer
);


ALTER TABLE "public"."checklist_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_progress" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "checklist_item_id" "uuid" NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "completed" boolean DEFAULT false,
    "completed_by" "uuid",
    "completed_at" timestamp with time zone
);


ALTER TABLE "public"."checklist_progress" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checklist_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."checklist_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_mentions" (
    "comment_id" "uuid" NOT NULL,
    "mentioned_user_id" "uuid" NOT NULL
);


ALTER TABLE "public"."comment_mentions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."custom_field_definitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "field_type" "text" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "applies_to" "text"[] DEFAULT ARRAY['task'::"text"] NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "custom_field_definitions_applies_to_valid" CHECK ((("cardinality"("applies_to") >= 1) AND ("applies_to" <@ ARRAY['task'::"text", 'project'::"text", 'hris_leave_request'::"text", 'hris_benefit_plan'::"text", 'hris_checklist_template'::"text", 'hris_checklist_template_item'::"text", 'hris_employee_details'::"text"]))),
    CONSTRAINT "custom_field_definitions_field_type_check" CHECK (("field_type" = ANY (ARRAY['number'::"text", 'text'::"text", 'single_select'::"text", 'date'::"text", 'checkbox'::"text"])))
);


ALTER TABLE "public"."custom_field_definitions" OWNER TO "postgres";


COMMENT ON TABLE "public"."custom_field_definitions" IS 'Reusable, searchable library of custom field definitions. Anyone can add one; attach to tasks via task_custom_field_values.';



CREATE TABLE IF NOT EXISTS "public"."custom_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "color" "text",
    "is_system" boolean DEFAULT false NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."custom_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dashboard_access" (
    "dashboard_id" "uuid" NOT NULL,
    "permission_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dashboard_access" OWNER TO "postgres";


COMMENT ON TABLE "public"."dashboard_access" IS 'Permission keys that grant view access to a dashboard.';



CREATE TABLE IF NOT EXISTS "public"."dashboard_datasets" (
    "dashboard_id" "uuid" NOT NULL,
    "dataset_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dashboard_datasets" OWNER TO "postgres";


COMMENT ON TABLE "public"."dashboard_datasets" IS 'Dashboards -> datasets dependency graph. Many-to-many.';



CREATE TABLE IF NOT EXISTS "public"."dashboards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "route_path" "text" NOT NULL,
    "icon_name" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "sort_order" integer DEFAULT 100 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dashboards" OWNER TO "postgres";


COMMENT ON TABLE "public"."dashboards" IS 'Registry of reporting dashboards. The Reporting page queries this table.';



CREATE TABLE IF NOT EXISTS "public"."data_sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "description" "text",
    "external_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."data_sources" OWNER TO "postgres";


COMMENT ON TABLE "public"."data_sources" IS 'Registry of upstream systems we sync data from. One row per integration.';



CREATE TABLE IF NOT EXISTS "public"."dataset_access" (
    "dataset_id" "uuid" NOT NULL,
    "permission_key" "text" NOT NULL,
    "access_level" "text" DEFAULT 'read'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dataset_access" OWNER TO "postgres";


COMMENT ON TABLE "public"."dataset_access" IS 'Permission keys that grant access to a dataset. Pure string keys (matches role_permissions).';



CREATE TABLE IF NOT EXISTS "public"."datasets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "data_source_id" "uuid" NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "last_synced_at" timestamp with time zone,
    "last_sync_status" "text",
    "last_sync_error" "text",
    "row_count" bigint,
    "refresh_interval_minutes" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sync_function_name" "text",
    "next_run_at" timestamp with time zone,
    "last_run_started_at" timestamp with time zone,
    "last_alerted_at" timestamp with time zone
);


ALTER TABLE "public"."datasets" OWNER TO "postgres";


COMMENT ON TABLE "public"."datasets" IS 'Individual managed tables within a data source. One row per public.* table we sync.';



COMMENT ON COLUMN "public"."datasets"."sync_function_name" IS 'Edge function that refreshes this dataset. Multiple datasets may share the same function — the dispatcher groups them so only one HTTP call fires per tick. NULL means "no automated sync" (e.g. Redtail datasets with no edge function yet).';



COMMENT ON COLUMN "public"."datasets"."next_run_at" IS 'When this dataset is next due for refresh. Edge function sets to now() + refresh_interval_minutes on success; on failure, set to now() + 15 minutes (back-off).';



COMMENT ON COLUMN "public"."datasets"."last_run_started_at" IS 'Set by the dispatcher when it fires a sync. Used to detect in-flight runs (last_run_started_at > last_synced_at). Stale runs older than 15 minutes are treated as crashed and re-dispatched.';



COMMENT ON COLUMN "public"."datasets"."last_alerted_at" IS 'When we last sent a failure email for this dataset. Used by notify_dataset_sync_failure() to debounce repeat emails to one per sync function per hour.';



CREATE TABLE IF NOT EXISTS "public"."desks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "icon" "text",
    "color" "text" DEFAULT '#4F46E5'::"text",
    "permission_key" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."desks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."document_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_folders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "parent_id" "uuid",
    "default_visibility" "text" DEFAULT 'organization'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "folders_default_visibility_check" CHECK (("default_visibility" = ANY (ARRAY['alliance'::"text", 'private'::"text"])))
);


ALTER TABLE "public"."document_folders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "document_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."document_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid",
    "folder_id" "uuid",
    "granted_to_user_id" "uuid",
    "granted_to_org_id" "uuid",
    "granted_to_tag" "text",
    "access_level" "text" DEFAULT 'view'::"text" NOT NULL,
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "at_least_one_resource" CHECK ((("document_id" IS NOT NULL) OR ("folder_id" IS NOT NULL))),
    CONSTRAINT "at_least_one_target" CHECK ((("granted_to_user_id" IS NOT NULL) OR ("granted_to_org_id" IS NOT NULL) OR ("granted_to_tag" IS NOT NULL))),
    CONSTRAINT "document_permissions_access_level_check" CHECK (("access_level" = ANY (ARRAY['view'::"text", 'upload'::"text", 'manage'::"text"])))
);


ALTER TABLE "public"."document_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_stars" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "document_id" "uuid",
    "folder_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "star_one_target" CHECK (((("document_id" IS NOT NULL) AND ("folder_id" IS NULL)) OR (("document_id" IS NULL) AND ("folder_id" IS NOT NULL))))
);


ALTER TABLE "public"."document_stars" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "file_path" "text" NOT NULL,
    "file_name" "text" NOT NULL,
    "file_size" bigint,
    "mime_type" "text",
    "category_id" "uuid",
    "folder_id" "uuid",
    "uploaded_by" "uuid" NOT NULL,
    "organization_id" "uuid",
    "visibility" "text" DEFAULT 'organization'::"text" NOT NULL,
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "rejection_note" "text",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "flagged_for_discussion" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid",
    CONSTRAINT "documents_visibility_check" CHECK (("visibility" = ANY (ARRAY['alliance'::"text", 'private'::"text"])))
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_activity_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "prospect_id" "uuid",
    "gmail_draft_id" "text",
    "gmail_message_id" "text",
    "gmail_thread_id" "text",
    "tracking_pixel_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email_type" "text" NOT NULL,
    "subject" "text",
    "recipient_email" "text" NOT NULL,
    "status" "text" DEFAULT 'drafted'::"text" NOT NULL,
    "drafted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    "first_opened_at" timestamp with time zone,
    "open_count" integer DEFAULT 0 NOT NULL,
    "replied_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "opportunity_id" "uuid",
    "source_type" "text" DEFAULT 'bdr'::"text",
    CONSTRAINT "email_activity_log_source_ref_chk" CHECK (((("prospect_id" IS NOT NULL) AND ("opportunity_id" IS NULL)) OR (("prospect_id" IS NULL) AND ("opportunity_id" IS NOT NULL)))),
    CONSTRAINT "email_activity_log_source_type_chk" CHECK (("source_type" = ANY (ARRAY['bdr'::"text", 'expansion'::"text"])))
);


ALTER TABLE "public"."email_activity_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_connections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'google'::"text" NOT NULL,
    "google_email" "text" NOT NULL,
    "refresh_token_encrypted" "text" NOT NULL,
    "refresh_token_iv" "text" NOT NULL,
    "scopes" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "connected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone,
    "is_active" boolean DEFAULT true NOT NULL,
    "account_email" "text"
);


ALTER TABLE "public"."email_connections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expansion_email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "label" "text",
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "tier_scope" "text",
    "strength" "text" DEFAULT 'suggested'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "expansion_email_templates_kind_check" CHECK (("kind" = ANY (ARRAY['example'::"text", 'instruction'::"text"]))),
    CONSTRAINT "expansion_email_templates_strength_check" CHECK (("strength" = ANY (ARRAY['required'::"text", 'suggested'::"text", 'context'::"text"]))),
    CONSTRAINT "expansion_email_templates_tier_scope_check" CHECK ((("tier_scope" IS NULL) OR ("tier_scope" = ANY (ARRAY['Tier 1'::"text", 'Tier 2'::"text", 'Tier 3'::"text"]))))
);


ALTER TABLE "public"."expansion_email_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expansion_opportunities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "firm" "text" NOT NULL,
    "client_name" "text",
    "business_name" "text" NOT NULL,
    "email" "text",
    "domain" "text",
    "owner_group" "text",
    "entity_count" integer DEFAULT 1,
    "related_entities" "text"[],
    "expansion_type" "text" DEFAULT 'cfo_advisory'::"text",
    "score" integer DEFAULT 0,
    "tier_recommendation" "text",
    "scoring_reasons" "text",
    "research_status" "text" DEFAULT 'pending'::"text",
    "business_description" "text",
    "industry" "text",
    "revenue_estimate" "text",
    "employee_estimate" "text",
    "year_founded" "text",
    "headquarters" "text",
    "website_url" "text",
    "linkedin_url" "text",
    "fit_summary" "text",
    "pain_points" "text",
    "recommended_services" "text"[],
    "pitch_angle" "text",
    "draft_email" "text",
    "partner_action" "text",
    "partner_action_at" timestamp with time zone,
    "partner_notes" "text",
    "assigned_to" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "draft_email_long" "text",
    "draft_email_short" "text",
    "email_status" "text",
    "draft_generated_at" timestamp with time zone,
    "draft_generated_by" "uuid",
    "last_researched_at" timestamp with time zone,
    "last_researched_by" "uuid",
    "research_depth" "text",
    "firm_key" "text" GENERATED ALWAYS AS ((("lower"(COALESCE(NULLIF("btrim"("owner_group"), ''::"text"), NULLIF("btrim"("client_name"), ''::"text"), "business_name")) || '|'::"text") || "lower"("firm"))) STORED,
    "draft_subject_long" "text",
    "draft_subject_short" "text",
    CONSTRAINT "expansion_opportunities_email_status_chk" CHECK ((("email_status" IS NULL) OR ("email_status" = ANY (ARRAY['ready'::"text", 'drafted'::"text"])))),
    CONSTRAINT "expansion_opportunities_research_depth_chk" CHECK ((("research_depth" IS NULL) OR ("research_depth" = ANY (ARRAY['light'::"text", 'deep'::"text"]))))
);


ALTER TABLE "public"."expansion_opportunities" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."expansion_firm_dashboard" WITH ("security_invoker"='on') AS
 SELECT "firm_key",
    "max"("firm") AS "firm",
    "max"("client_name") AS "client_name",
    "max"("owner_group") AS "owner_group",
    ("count"(*))::integer AS "opportunity_count",
    ("count"(*) FILTER (WHERE (("research_status" = 'researched'::"text") OR ("last_researched_at" IS NOT NULL))))::integer AS "researched_count",
    ("count"(*) FILTER (WHERE ("partner_action" IS NOT NULL)))::integer AS "contacted_count",
    ("count"(*) FILTER (WHERE ("partner_action" = 'CONVERTED'::"text")))::integer AS "converted_count",
    ("count"(*) FILTER (WHERE ("email_status" = 'drafted'::"text")))::integer AS "drafted_count",
    ("count"(*) FILTER (WHERE ("email_status" = 'ready'::"text")))::integer AS "ready_count",
    "max"("last_researched_at") AS "last_researched_at",
    ("sum"("entity_count"))::integer AS "total_entities",
    "max"("score") AS "top_score",
    ("avg"("score"))::numeric(6,1) AS "avg_score",
    "array_agg"(DISTINCT "tier_recommendation") FILTER (WHERE ("tier_recommendation" IS NOT NULL)) AS "tiers_present"
   FROM "public"."expansion_opportunities"
  GROUP BY "firm_key";


ALTER VIEW "public"."expansion_firm_dashboard" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."expansion_research_outcomes" WITH ("security_invoker"='true') AS
 SELECT ("count"(*))::integer AS "total",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NULL) OR ("research_depth" IS NULL))))::integer AS "unresearched",
    ("count"(*) FILTER (WHERE ("last_researched_at" IS NOT NULL)))::integer AS "researched",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("partner_action" IS DISTINCT FROM 'DECLINED'::"text") AND ("partner_action" IS DISTINCT FROM 'REVIEW'::"text"))))::integer AS "viable",
    ("count"(*) FILTER (WHERE ("partner_action" = 'DECLINED'::"text")))::integer AS "declined",
    ("count"(*) FILTER (WHERE ("partner_action" = 'REVIEW'::"text")))::integer AS "in_review",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("research_depth" = 'deep'::"text"))))::integer AS "deep",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("research_depth" = 'light'::"text"))))::integer AS "light",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("research_depth" IS NULL))))::integer AS "unlabeled",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("tier_recommendation" = 'Tier 3'::"text"))))::integer AS "tier3",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("tier_recommendation" = 'Tier 2'::"text"))))::integer AS "tier2",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND ("tier_recommendation" = 'Tier 1'::"text"))))::integer AS "tier1",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NOT NULL) AND (("tier_recommendation" IS NULL) OR ("tier_recommendation" <> ALL (ARRAY['Tier 1'::"text", 'Tier 2'::"text", 'Tier 3'::"text"]))))))::integer AS "tier_other",
    (COALESCE("round"("avg"("score") FILTER (WHERE ("last_researched_at" IS NOT NULL)), 1), (0)::numeric))::numeric(6,1) AS "avg_score_researched",
    ("count"(*) FILTER (WHERE (("last_researched_at" IS NULL) OR ("pain_points" IS NULL) OR ("length"(COALESCE("pain_points", ''::"text")) < 20) OR ("fit_summary" IS NULL) OR ("length"(COALESCE("fit_summary", ''::"text")) < 20) OR ("pitch_angle" IS NULL) OR ("length"(COALESCE("pitch_angle", ''::"text")) < 20) OR ("recommended_services" IS NULL) OR (COALESCE("array_length"("recommended_services", 1), 0) = 0))))::integer AS "needs_enrichment",
    ("count"(*) FILTER (WHERE ("email_status" = 'ready'::"text")))::integer AS "ready_to_draft",
    ("count"(*) FILTER (WHERE ("email_status" = 'drafted'::"text")))::integer AS "drafted",
    ("count"(*) FILTER (WHERE ("last_researched_at" < ("now"() - '90 days'::interval))))::integer AS "stale_research"
   FROM "public"."expansion_opportunities";


ALTER VIEW "public"."expansion_research_outcomes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expansion_research_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "firm_key" "text" NOT NULL,
    "opportunity_id" "uuid",
    "ran_by" "uuid",
    "ran_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "depth" "text",
    "summary" "text",
    "sources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "notes" "text",
    CONSTRAINT "expansion_research_runs_depth_check" CHECK ((("depth" IS NULL) OR ("depth" = ANY (ARRAY['light'::"text", 'deep'::"text"]))))
);


ALTER TABLE "public"."expansion_research_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."firm_software" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "deployment" "text",
    "edition" "text",
    "seats" integer,
    "renewal_date" "date",
    "satisfaction" smallint,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "firm_software_deployment_check" CHECK (("deployment" = ANY (ARRAY['cloud'::"text", 'on_premises'::"text", 'desktop'::"text", 'hybrid'::"text"]))),
    CONSTRAINT "firm_software_satisfaction_check" CHECK ((("satisfaction" >= 1) AND ("satisfaction" <= 5))),
    CONSTRAINT "firm_software_seats_check" CHECK (("seats" > 0)),
    CONSTRAINT "firm_software_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'evaluating'::"text", 'sunsetting'::"text", 'retired'::"text"])))
);


ALTER TABLE "public"."firm_software" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."firm_software_costs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "firm_software_id" "uuid" NOT NULL,
    "fee_type" "text" NOT NULL,
    "description" "text",
    "amount" numeric(12,2) NOT NULL,
    "billing_cycle" "text" DEFAULT 'annual'::"text" NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "firm_software_costs_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "firm_software_costs_billing_cycle_check" CHECK (("billing_cycle" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'annual'::"text", 'one_time'::"text"]))),
    CONSTRAINT "firm_software_costs_fee_type_check" CHECK (("fee_type" = ANY (ARRAY['platform'::"text", 'per_user'::"text", 'per_return'::"text", 'usage'::"text", 'module'::"text", 'support'::"text", 'implementation'::"text", 'other'::"text"]))),
    CONSTRAINT "firm_software_costs_quantity_check" CHECK (("quantity" > 0))
);


ALTER TABLE "public"."firm_software_costs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_benefit_enrollments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "coverage_level" "text",
    "effective_date" "date",
    "employee_cost" numeric,
    "employer_cost" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_benefit_enrollments_status_check" CHECK (("status" = ANY (ARRAY['enrolled'::"text", 'waived'::"text", 'pending'::"text"])))
);


ALTER TABLE "public"."hris_benefit_enrollments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_benefit_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "provider" "text",
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_benefit_plans_type_check" CHECK (("type" = ANY (ARRAY['health'::"text", 'dental'::"text", 'vision'::"text", 'retirement_401k'::"text", 'life'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."hris_benefit_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_checklist_template_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "assignee_role" "text" DEFAULT 'new_hire'::"text" NOT NULL,
    "due_offset_days" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_checklist_template_items_assignee_role_check" CHECK (("assignee_role" = ANY (ARRAY['new_hire'::"text", 'manager'::"text", 'hr'::"text", 'it'::"text"])))
);


ALTER TABLE "public"."hris_checklist_template_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_checklist_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_checklist_templates_type_check" CHECK (("type" = ANY (ARRAY['onboarding'::"text", 'offboarding'::"text"])))
);


ALTER TABLE "public"."hris_checklist_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_compensation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "effective_date" "date" NOT NULL,
    "comp_type" "text" NOT NULL,
    "annual_salary" numeric,
    "hourly_rate" numeric,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "pay_frequency" "text",
    "change_reason" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_compensation_comp_type_check" CHECK (("comp_type" = ANY (ARRAY['salary'::"text", 'hourly'::"text"])))
);


ALTER TABLE "public"."hris_compensation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_custom_field_values" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "field_id" "uuid" NOT NULL,
    "value_number" numeric,
    "value_text" "text",
    "value_date" "date",
    "value_bool" boolean,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_custom_field_values_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['hris_leave_request'::"text", 'hris_benefit_plan'::"text", 'hris_checklist_template'::"text", 'hris_checklist_template_item'::"text", 'hris_employee_details'::"text"])))
);


ALTER TABLE "public"."hris_custom_field_values" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_emergency_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "relationship" "text",
    "phone" "text",
    "email" "text",
    "is_primary" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hris_emergency_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_employee_checklists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "template_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "status" "text" DEFAULT 'not_started'::"text" NOT NULL,
    "start_date" "date",
    "started_by" "uuid",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_employee_checklists_status_check" CHECK (("status" = ANY (ARRAY['not_started'::"text", 'in_progress'::"text", 'completed'::"text"]))),
    CONSTRAINT "hris_employee_checklists_type_check" CHECK (("type" = ANY (ARRAY['onboarding'::"text", 'offboarding'::"text"])))
);


ALTER TABLE "public"."hris_employee_checklists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_employee_details" (
    "profile_id" "uuid" NOT NULL,
    "employee_number" "text",
    "employment_type" "text",
    "employment_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "hire_date" "date",
    "termination_date" "date",
    "work_location" "text",
    "date_of_birth" "date",
    "home_address" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_employee_details_employment_status_check" CHECK (("employment_status" = ANY (ARRAY['active'::"text", 'on_leave'::"text", 'terminated'::"text"]))),
    CONSTRAINT "hris_employee_details_employment_type_check" CHECK (("employment_type" = ANY (ARRAY['full_time'::"text", 'part_time'::"text", 'contractor'::"text", 'intern'::"text"])))
);


ALTER TABLE "public"."hris_employee_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_leave_action_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "leave_request_id" "uuid" NOT NULL,
    "manager_id" "uuid" NOT NULL,
    "token_hash" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "used_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hris_leave_action_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_leave_balances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "leave_type_id" "uuid" NOT NULL,
    "year" integer NOT NULL,
    "allotted_hours" numeric DEFAULT 0 NOT NULL,
    "used_hours" numeric DEFAULT 0 NOT NULL,
    "carryover_hours" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hris_leave_balances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_leave_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "leave_type_id" "uuid" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "hours" numeric NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approver_id" "uuid",
    "decided_at" timestamp with time zone,
    "decided_by" "uuid",
    "decision_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "hris_leave_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."hris_leave_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hris_leave_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" "text",
    "is_paid" boolean DEFAULT true NOT NULL,
    "requires_approval" boolean DEFAULT true NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hris_leave_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_companies" (
    "hubspot_id" "text" NOT NULL,
    "name" "text",
    "domain" "text",
    "state" "text",
    "city" "text",
    "industry" "text",
    "raw_properties" "jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."hs_companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_contacts" (
    "hubspot_id" "text" NOT NULL,
    "email" "text",
    "firstname" "text",
    "lastname" "text",
    "jobtitle" "text",
    "company" "text",
    "hubspot_owner_id" "text",
    "lifecyclestage" "text",
    "raw_properties" "jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."hs_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_deals" (
    "hubspot_id" "text" NOT NULL,
    "dealname" "text",
    "amount" numeric,
    "dealstage" "text",
    "dealstage_label" "text",
    "pipeline" "text",
    "pipeline_label" "text",
    "closedate" timestamp with time zone,
    "createdate" timestamp with time zone,
    "hs_lastmodifieddate" timestamp with time zone,
    "hubspot_owner_id" "text",
    "associated_contact_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "associated_company_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "raw_properties" "jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "opportunity_source" "text",
    "referral_source_individual" "text",
    "next_call" timestamp with time zone,
    "description" "text",
    "hs_next_step" "text",
    "recent_changes" "jsonb",
    "probability" numeric
);


ALTER TABLE "public"."hs_deals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_engagements" (
    "hubspot_id" "text" NOT NULL,
    "engagement_type" "text" NOT NULL,
    "hubspot_owner_id" "text",
    "hs_timestamp" timestamp with time zone,
    "hs_createdate" timestamp with time zone,
    "hs_lastmodifieddate" timestamp with time zone,
    "direction" "text",
    "subject" "text",
    "body_preview" "text",
    "hs_email_logged_from" "text",
    "hs_email_sequence_id" "text",
    "hs_email_status" "text",
    "call_disposition" "text",
    "call_duration_seconds" integer,
    "meeting_outcome" "text",
    "associated_contact_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "associated_deal_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "associated_company_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "raw_properties" "jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    CONSTRAINT "hs_engagements_type_check" CHECK (("engagement_type" = ANY (ARRAY['email'::"text", 'call'::"text", 'meeting'::"text", 'note'::"text", 'task'::"text"])))
);


ALTER TABLE "public"."hs_engagements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_owners" (
    "hubspot_id" "text" NOT NULL,
    "email" "text",
    "first_name" "text",
    "last_name" "text",
    "full_name" "text",
    "user_id" "text",
    "archived" boolean DEFAULT false NOT NULL,
    "raw_properties" "jsonb",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."hs_owners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hs_sync_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "status" "text" DEFAULT 'in_progress'::"text" NOT NULL,
    "deals_synced" integer DEFAULT 0 NOT NULL,
    "contacts_synced" integer DEFAULT 0 NOT NULL,
    "companies_synced" integer DEFAULT 0 NOT NULL,
    "error_message" "text",
    "triggered_by" "uuid",
    "engagements_synced" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "hs_sync_log_status_check" CHECK (("status" = ANY (ARRAY['in_progress'::"text", 'success'::"text", 'failure'::"text"])))
);


ALTER TABLE "public"."hs_sync_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hub_api_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token_hash" "text" NOT NULL,
    "label" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "last_used_at" timestamp with time zone
);


ALTER TABLE "public"."hub_api_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hubspot_contact_classifications" (
    "hubspot_contact_id" "text" NOT NULL,
    "classification" "text" NOT NULL,
    "reasoning" "text",
    "model_version" "text",
    "classified_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "manually_overridden" boolean DEFAULT false NOT NULL,
    "override_by" "uuid",
    "override_at" timestamp with time zone,
    CONSTRAINT "hubspot_contact_classifications_classification_check" CHECK (("classification" = ANY (ARRAY['lead'::"text", 'not_lead'::"text"])))
);


ALTER TABLE "public"."hubspot_contact_classifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hubspot_engagement_contacts" (
    "hubspot_engagement_id" "text" NOT NULL,
    "hubspot_contact_id" "text" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hubspot_engagement_contacts" OWNER TO "postgres";


COMMENT ON TABLE "public"."hubspot_engagement_contacts" IS 'Many-to-many: a single HubSpot engagement (email/call/meeting/note) can involve multiple contacts. Populated by hubspot-sync-engagements from v4 /associations/contacts edges. Used by sdr_contact_engagement_summary RPC to attribute engagements per contact.';



CREATE TABLE IF NOT EXISTS "public"."hubspot_engagements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "hubspot_engagement_id" "text" NOT NULL,
    "hubspot_object_type" "text" NOT NULL,
    "hubspot_company_id" "text",
    "hubspot_contact_id" "text",
    "direction" "text",
    "occurred_at" timestamp with time zone NOT NULL,
    "subject" "text",
    "body_preview" "text",
    "call_disposition" "text",
    "call_duration_seconds" integer,
    "raw" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hubspot_engagements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inbox_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "actor_id" "uuid",
    "target_type" "text" NOT NULL,
    "target_id" "text" NOT NULL,
    "target_name" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "summary" "text" NOT NULL,
    "detail" "jsonb" DEFAULT '{}'::"jsonb",
    "link" "text",
    "read" boolean DEFAULT false NOT NULL,
    "archived" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bookmarked" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."inbox_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_description_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_description_id" "uuid" NOT NULL,
    "version" integer NOT NULL,
    "methodology" "text" NOT NULL,
    "methodology_label" "text",
    "structure" "jsonb" NOT NULL,
    "note" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."job_description_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_base_article_page_links" (
    "article_id" "uuid" NOT NULL,
    "page_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."knowledge_base_article_page_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_base_articles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "summary" "text",
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."knowledge_base_articles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."knowledge_base_edit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "article_id" "uuid" NOT NULL,
    "edited_by" "uuid" NOT NULL,
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "summary" "text"
);


ALTER TABLE "public"."knowledge_base_edit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_agreements_log" (
    "id" bigint NOT NULL,
    "firm_name" "text",
    "structure" "text",
    "partner_name" "text",
    "partner_org" "text",
    "partner_email" "text",
    "partner_state" "text",
    "cpa_state" "text",
    "generated_by" "text",
    "generated_at" timestamp with time zone DEFAULT "now"(),
    "compliance_verdict" "text",
    "organization_id" "uuid",
    "partner_code" "text",
    "contract_file_path" "text",
    "contract_external_url" "text",
    "cancelled_at" "date",
    "cancellation_reason" "text",
    "notes" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'unsigned'::"text" NOT NULL,
    "contract_signed_file_path" "text",
    "compensation_structure_key" "text",
    "effective_date" "date",
    "end_date" "date",
    "tiers" "jsonb",
    "intro_fee_amount" numeric,
    "locked_at" timestamp with time zone,
    "w9_file_path" "text"
);


ALTER TABLE "public"."laa_agreements_log" OWNER TO "postgres";


ALTER TABLE "public"."laa_agreements_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."laa_agreements_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."laa_canopy_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "canopy_instance" "text" NOT NULL,
    "organization_id" "uuid",
    "referral_code" "text",
    "client_name" "text",
    "payment_month" "text",
    "total_payment_amount" numeric,
    "source_email_received_at" timestamp with time zone,
    "imported_at" timestamp with time zone DEFAULT "now"(),
    "client_creation_date" "text"
);


ALTER TABLE "public"."laa_canopy_payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_cpa_rules" (
    "id" bigint NOT NULL,
    "cpa_state" "text" NOT NULL,
    "cpa_state_name" "text",
    "can_pay_rev_share" "text",
    "can_pay_fixed_fee" "text",
    "can_pay_marketing_fee" "text",
    "can_pay_client_credit" "text",
    "disclosure_required" "text",
    "disclosure_details" "text",
    "attest_restriction" "text",
    "attest_restriction_detail" "text",
    "governing_statute" "text",
    "governing_rule" "text",
    "primary_source_link" "text",
    "citation_text" "text",
    "notes" "text",
    "confidence_level" "text",
    "source_authority_score" "text",
    "researched_at" "text",
    "no_restriction_basis" "text"
);


ALTER TABLE "public"."laa_cpa_rules" OWNER TO "postgres";


ALTER TABLE "public"."laa_cpa_rules" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."laa_cpa_rules_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."laa_firm_compensation" (
    "organization_id" "uuid" NOT NULL,
    "compensation" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid"
);


ALTER TABLE "public"."laa_firm_compensation" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_firm_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid",
    "service_slug" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_firm_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_firms" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "short" "text",
    "state" "text",
    "active" boolean DEFAULT true,
    "compensation" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_firms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_recipient_rules" (
    "id" bigint NOT NULL,
    "recipient_state" "text" NOT NULL,
    "recipient_state_name" "text",
    "profession" "text" NOT NULL,
    "can_receive_rev_share" "text",
    "can_receive_fixed_fee" "text",
    "can_receive_marketing_fee" "text",
    "can_receive_client_credit" "text",
    "disclosure_required_by_recipient" "text",
    "disclosure_details" "text",
    "employer_approval_required" "text",
    "key_restrictions" "text",
    "governing_rule" "text",
    "primary_source_link" "text",
    "citation_text" "text",
    "notes" "text",
    "confidence_level" "text",
    "source_authority_score" "text",
    "researched_at" "text",
    "no_restriction_basis" "text"
);


ALTER TABLE "public"."laa_recipient_rules" OWNER TO "postgres";


ALTER TABLE "public"."laa_recipient_rules" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."laa_recipient_rules_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."laa_referral_payouts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid",
    "agreement_id" "uuid",
    "referral_code" "text",
    "client_name" "text",
    "payment_month" "text",
    "payment_amount" numeric,
    "compensation_structure" "text",
    "payout_amount" numeric,
    "payout_rate" numeric,
    "status" "text" DEFAULT 'due'::"text",
    "paid_at" timestamp with time zone,
    "paid_by" "uuid",
    "calculated_at" timestamp with time zone DEFAULT "now"(),
    "agreement_log_id" bigint
);


ALTER TABLE "public"."laa_referral_payouts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_rfp_bids" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rfp_id" "uuid",
    "bidding_org_id" "uuid",
    "submitted_by" "uuid",
    "proposal_notes" "text",
    "estimated_hours" numeric,
    "hourly_rate" numeric,
    "flat_fee" numeric,
    "additional_fee_notes" "text",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_rfp_bids" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_rfp_questions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rfp_id" "uuid",
    "asked_by" "uuid",
    "asking_org_id" "uuid",
    "question" "text" NOT NULL,
    "answer" "text",
    "answered_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_rfp_questions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_rfps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "requesting_org_id" "uuid",
    "submitted_by" "uuid",
    "title" "text" NOT NULL,
    "service_slug" "text" NOT NULL,
    "description" "text",
    "timeline_start" "date",
    "timeline_end" "date",
    "budget_notes" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_rfps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."laa_service_catalog" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."laa_service_catalog" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."linked_emails" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "primary_user_id" "uuid" NOT NULL,
    "linked_email" "text" NOT NULL,
    "linked_auth_uid" "uuid",
    "merged_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."linked_emails" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."my_task_automation_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "automation_id" "uuid" NOT NULL,
    "task_id" "uuid" NOT NULL,
    "triggered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "result" "text" NOT NULL,
    "detail" "text"
);


ALTER TABLE "public"."my_task_automation_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."my_task_automations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "section_id" "uuid",
    "name" "text",
    "trigger_type" "text" NOT NULL,
    "trigger_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "action_type" "text" NOT NULL,
    "action_config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."my_task_automations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."my_task_section_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "task_id" "uuid" NOT NULL,
    "section_id" "uuid" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."my_task_section_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."my_task_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."my_task_sections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nine_box_scores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "scored_by" "uuid" NOT NULL,
    "performance_col" integer NOT NULL,
    "potential_row" integer NOT NULL,
    "reason" "text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."nine_box_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ninety_user_mappings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ninety_user_id" "text" NOT NULL,
    "hub_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ninety_user_mappings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "actor_id" "uuid",
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "link" "text",
    "read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."oauth_access_tokens" (
    "token_hash" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "client_id" "text" NOT NULL,
    "scope" "text" DEFAULT ''::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."oauth_access_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."oauth_authorization_codes" (
    "code_hash" "text" NOT NULL,
    "client_id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "redirect_uri" "text" NOT NULL,
    "scope" "text" DEFAULT ''::"text" NOT NULL,
    "code_challenge" "text" NOT NULL,
    "code_challenge_method" "text" DEFAULT 'S256'::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "consumed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."oauth_authorization_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."oauth_clients" (
    "client_id" "text" NOT NULL,
    "client_name" "text",
    "redirect_uris" "text"[] NOT NULL,
    "token_endpoint_auth_method" "text" DEFAULT 'none'::"text" NOT NULL,
    "grant_types" "text"[] DEFAULT ARRAY['authorization_code'::"text", 'refresh_token'::"text"] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."oauth_clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."oauth_refresh_tokens" (
    "token_hash" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "client_id" "text" NOT NULL,
    "scope" "text" DEFAULT ''::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "replaced_by" "text",
    "revoked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."oauth_refresh_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "date_joined" "date",
    "services_offered" "text",
    "description" "text",
    "logo_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "organization_type" "text",
    "entrance_revenue" numeric,
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "website" "text",
    "city" "text",
    "state" "text",
    "country" "text",
    "street_address_1" "text",
    "street_address_2" "text",
    "firm_size" integer,
    "headquarters" "text",
    "founded_year" integer,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid"
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."organizations"."archived_at" IS 'When the company was archived (soft-deleted). NULL = active. Archived companies are hidden from the admin list and firm-selection pickers but retain all linked records.';



COMMENT ON COLUMN "public"."organizations"."archived_by" IS 'Profile that archived the company (audit trail). NULL if never archived or the archiver profile was removed.';



CREATE TABLE IF NOT EXISTS "public"."permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "key" "text" NOT NULL,
    "module" "text" NOT NULL,
    "description" "text"
);


ALTER TABLE "public"."permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pinned_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "label" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pinned_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."pinned_items" IS 'Personal Home pins. One row per (user, entity_type, entity_id). entity_id is TEXT to support both uuid-backed entities (desks, projects) and keyed entities (nav items). entity_type is open by design; the frontend pin registry decides what is renderable.';



CREATE TABLE IF NOT EXISTS "public"."prep_briefs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "brief_date" "date" NOT NULL,
    "content" "text" NOT NULL,
    "model" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."prep_briefs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prep_calendar_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'google'::"text" NOT NULL,
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "location" "text",
    "meeting_url" "text",
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "is_all_day" boolean DEFAULT false NOT NULL,
    "is_cancelled" boolean DEFAULT false NOT NULL,
    "organizer_email" "text",
    "attendees" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "resolved_kind" "text",
    "resolved_ref_id" "uuid",
    "resolved_hs_id" "text",
    "resolved_label" "text",
    "resolved_domain" "text",
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."prep_calendar_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prep_reminder_preferences" (
    "user_id" "uuid" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "send_time_local" time without time zone DEFAULT '07:30:00'::time without time zone NOT NULL,
    "timezone" "text",
    "include_empty_days" boolean DEFAULT false NOT NULL,
    "last_sent_on" "date",
    "last_sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "auto_sync_enabled" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."prep_reminder_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text",
    "full_name" "text",
    "title" "text",
    "phone" "text",
    "avatar_url" "text",
    "organization_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "first_name" "text",
    "last_name" "text",
    "preferred_name" "text",
    "booking_link" "text",
    "status" "text" DEFAULT 'created'::"text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "team" "text",
    "secondary_email" "text",
    "manager_id" "uuid",
    "invite_token" "text",
    "invite_token_expires_at" timestamp with time zone,
    "role_id" "uuid",
    "timezone" "text" DEFAULT 'America/Denver'::"text",
    "date_format" "text" DEFAULT 'MM/DD/YYYY'::"text",
    "default_landing_page" "text" DEFAULT 'home'::"text",
    "my_tasks_group_by" "text" DEFAULT 'sections'::"text",
    "mcp_api_token" "text",
    "mcp_api_token_preview" "text",
    "mcp_api_token_created_at" timestamp with time zone,
    "hubspot_owner_email" "text",
    "sdr_nonresponder_days" integer DEFAULT 14 NOT NULL,
    "default_hubspot_sequence_id" "text",
    "sdr_draft_lengths" "text"[] DEFAULT ARRAY['long'::"text", 'short'::"text"] NOT NULL,
    "sdr_default_preferred_length" "text" DEFAULT 'long'::"text" NOT NULL,
    "hubspot_sender_email" "text",
    "merged_into" "uuid",
    CONSTRAINT "profiles_sdr_default_preferred_in_lengths" CHECK (("sdr_default_preferred_length" = ANY ("sdr_draft_lengths"))),
    CONSTRAINT "profiles_sdr_default_preferred_length_valid" CHECK (("sdr_default_preferred_length" = ANY (ARRAY['short'::"text", 'medium'::"text", 'long'::"text"]))),
    CONSTRAINT "profiles_sdr_draft_lengths_valid" CHECK ((("array_length"("sdr_draft_lengths", 1) > 0) AND ("sdr_draft_lengths" <@ ARRAY['short'::"text", 'medium'::"text", 'long'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."booking_link" IS 'For booking links like Calendly, Google Scheduler, etc';



COMMENT ON COLUMN "public"."profiles"."hubspot_owner_email" IS 'Optional override: if this profile''s HubSpot owner email differs from their auth email (e.g. Jacob auth=jacob@linkedaccounting.com but HubSpot=ferrell@linkedaccounting.com), set this so My Firms can match.';



COMMENT ON COLUMN "public"."profiles"."hubspot_sender_email" IS 'Email of the personal inbox connected to this user''s HubSpot account, used as senderEmail for Sequences enrollments. Distinct from hubspot_owner_email when the connected inbox differs from the HubSpot user''s primary email.';



CREATE TABLE IF NOT EXISTS "public"."project_custom_fields" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "field_id" "uuid" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_custom_fields" OWNER TO "postgres";


COMMENT ON TABLE "public"."project_custom_fields" IS 'Attaches a library field (custom_field_definitions) to a project as a column. Visibility inherits the parent project via RLS.';



CREATE TABLE IF NOT EXISTS "public"."project_favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."project_favorites" OWNER TO "postgres";


COMMENT ON COLUMN "public"."project_favorites"."sort_order" IS 'Per-user order of starred projects in the Work rail Starred group (lower = higher). Reordered by drag-and-drop. Written on own rows via the existing "Users can manage own favorites" policy.';



CREATE TABLE IF NOT EXISTS "public"."project_field_aggregations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "source_kind" "text" NOT NULL,
    "field_id" "uuid",
    "builtin_field" "text",
    "fn" "text" NOT NULL,
    "filter" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "label" "text",
    "show_project" boolean DEFAULT true NOT NULL,
    "show_section" boolean DEFAULT true NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pfa_source_shape" CHECK (((("source_kind" = 'custom_field'::"text") AND ("field_id" IS NOT NULL)) OR (("source_kind" = 'builtin'::"text") AND ("builtin_field" IS NOT NULL)) OR ("source_kind" = 'task_count'::"text"))),
    CONSTRAINT "project_field_aggregations_builtin_field_check" CHECK ((("builtin_field" IS NULL) OR ("builtin_field" = ANY (ARRAY['priority'::"text", 'status'::"text", 'due_date'::"text", 'assigned_to'::"text"])))),
    CONSTRAINT "project_field_aggregations_fn_check" CHECK (("fn" = ANY (ARRAY['sum'::"text", 'avg'::"text", 'min'::"text", 'max'::"text", 'count'::"text", 'count_filled'::"text", 'count_where'::"text"]))),
    CONSTRAINT "project_field_aggregations_source_kind_check" CHECK (("source_kind" = ANY (ARRAY['custom_field'::"text", 'builtin'::"text", 'task_count'::"text"])))
);


ALTER TABLE "public"."project_field_aggregations" OWNER TO "postgres";


COMMENT ON TABLE "public"."project_field_aggregations" IS 'Per-project rollup definitions (sum/avg/count/...) shown as dashboard chips at the project top and per section. Computed client-side; visibility inherits the parent project via RLS.';



CREATE TABLE IF NOT EXISTS "public"."project_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "added_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_resources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "url" "text",
    "file_path" "text",
    "file_name" "text",
    "file_size" bigint,
    "mime_type" "text",
    "resource_type" "text" DEFAULT 'link'::"text" NOT NULL,
    "added_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_resources" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "order_index" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_sections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_share_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "token" "text" DEFAULT "replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text") NOT NULL,
    "label" "text",
    "created_by" "uuid" NOT NULL,
    "expires_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "view_count" integer DEFAULT 0 NOT NULL,
    "last_viewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "allow_comments" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."project_share_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_shared_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "share_link_id" "uuid",
    "task_id" "uuid",
    "author_name" "text" NOT NULL,
    "author_email" "text",
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_shared_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_template_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_template_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_template_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "order_index" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_template_sections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_template_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_section_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "default_assignee_role" "text",
    "due_date_offset_days" integer,
    "order_index" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_template_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."project_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "assigned_to_org" "uuid",
    "assigned_to_user" "uuid",
    "owner_id" "uuid",
    "created_by" "uuid" NOT NULL,
    "template_id" "uuid",
    "start_date" "date",
    "due_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "color" "text",
    CONSTRAINT "projects_color_hex_chk" CHECK ((("color" IS NULL) OR ("color" ~ '^#[0-9A-Fa-f]{6}$'::"text")))
);


ALTER TABLE "public"."projects" OWNER TO "postgres";


COMMENT ON COLUMN "public"."projects"."color" IS 'Optional Asana-style global project color (hex, e.g. #378ADD); rendered as the dot in the Work rail. Visible to all members; editable by admins + project owners (projects UPDATE policy: admin OR is_project_owner). NULL falls back to the rail palette.';



CREATE TABLE IF NOT EXISTS "public"."quick_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "url" "text" NOT NULL,
    "description" "text",
    "icon_name" "text" DEFAULT 'ExternalLink'::"text",
    "visible_to_roles" "public"."app_role"[] DEFAULT '{}'::"public"."app_role"[],
    "visible_to_tags" "text"[] DEFAULT '{}'::"text"[],
    "show_in_sidebar" boolean DEFAULT false,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid"
);


ALTER TABLE "public"."quick_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."release_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "commit_sha" "text" NOT NULL,
    "commit_url" "text",
    "pr_number" integer,
    "pr_url" "text",
    "title" "text" NOT NULL,
    "summary" "text",
    "tier" smallint,
    "review_status" "text" DEFAULT 'reviewed'::"text" NOT NULL,
    "author" "text" NOT NULL,
    "author_avatar_url" "text",
    "additions" integer,
    "deletions" integer,
    "changed_files" integer,
    "landed_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "release_notes_review_status_check" CHECK (("review_status" = ANY (ARRAY['reviewed'::"text", 'bypass'::"text"])))
);


ALTER TABLE "public"."release_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reporting_sync_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sync_function_name" "text" NOT NULL,
    "error_message" "text",
    "fired_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recipient_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."reporting_sync_alerts" OWNER TO "postgres";


COMMENT ON TABLE "public"."reporting_sync_alerts" IS 'Audit log of failure alerts fired by the dispatcher. recipient_count is how many users were emailed (after permission filtering).';



CREATE TABLE IF NOT EXISTS "public"."role_permissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "role_id" "uuid" NOT NULL,
    "permission_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."role_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_system_role" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_accounts" (
    "id" bigint NOT NULL,
    "contact_id" bigint,
    "account_type" "text",
    "balance" numeric(15,2) DEFAULT 0,
    "status" "text",
    "managed" boolean DEFAULT false,
    "product" "text",
    "company" "text",
    "deleted" boolean DEFAULT false,
    "redtail_created_at" timestamp with time zone,
    "redtail_updated_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_activities" (
    "id" bigint NOT NULL,
    "subject" "text",
    "description" "text",
    "location" "text",
    "start_date" timestamp with time zone,
    "end_date" timestamp with time zone,
    "all_day" boolean DEFAULT false,
    "completed" boolean DEFAULT false,
    "completed_at" timestamp with time zone,
    "category_id" integer,
    "category" "text",
    "activity_code_id" integer,
    "importance" integer,
    "contact_id" bigint,
    "contact_ids" bigint[],
    "organizer_user_id" integer,
    "added_by" integer,
    "attendees" "jsonb",
    "deleted" boolean DEFAULT false,
    "redtail_created_at" timestamp with time zone,
    "redtail_updated_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_contact_org_mapping" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_field" "text" NOT NULL,
    "match_value" "text" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_contact_org_mapping" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_contacts" (
    "id" bigint NOT NULL,
    "type" "text",
    "first_name" "text",
    "last_name" "text",
    "full_name" "text",
    "status" "text",
    "category" "text",
    "source" "text",
    "referred_by" "text",
    "servicing_advisor" "text",
    "writing_advisor" "text",
    "organization_id" "uuid",
    "referred_by_user_id" "uuid",
    "deleted" boolean DEFAULT false,
    "redtail_created_at" timestamp with time zone,
    "redtail_updated_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_firm_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_value" "text" NOT NULL,
    "hidden" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_firm_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_notes" (
    "id" bigint NOT NULL,
    "contact_id" bigint,
    "category" "text",
    "note_type" "text",
    "body" "text",
    "deleted" boolean DEFAULT false,
    "redtail_created_at" timestamp with time zone,
    "redtail_updated_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_opportunities" (
    "id" bigint NOT NULL,
    "contact_id" bigint,
    "name" "text",
    "source" "text",
    "stage" "text",
    "opportunity_type" "text",
    "amount" numeric(15,2) DEFAULT 0,
    "probability" integer,
    "projected_revenue" numeric(15,2) DEFAULT 0,
    "actual_revenue" numeric(15,2) DEFAULT 0,
    "close_date" "date",
    "deleted" boolean DEFAULT false,
    "redtail_created_at" timestamp with time zone,
    "redtail_updated_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_opportunities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_reminders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "reminder_type" "text" NOT NULL,
    "reminder_date" timestamp with time zone NOT NULL,
    "source_object_id" bigint NOT NULL,
    "source_object_type" "text" NOT NULL,
    "contact_id" bigint,
    "title" "text",
    "synced_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_reminders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_sync_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    "status" "text" DEFAULT 'running'::"text",
    "contacts_synced" integer DEFAULT 0,
    "accounts_synced" integer DEFAULT 0,
    "opportunities_synced" integer DEFAULT 0,
    "notes_synced" integer DEFAULT 0,
    "error_message" "text",
    "triggered_by" "uuid",
    "reminders_synced" integer DEFAULT 0,
    "activities_synced" integer DEFAULT 0
);


ALTER TABLE "public"."rtl_sync_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rtl_sync_state" (
    "key" "text" NOT NULL,
    "value_int" bigint,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."rtl_sync_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_number" integer NOT NULL,
    "state" "text",
    "source_file" "text",
    "contact_count" integer DEFAULT 0,
    "firm_count" integer DEFAULT 0,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "notes" "text",
    "created_by_user_id" "uuid",
    "created_by_name" "text"
);


ALTER TABLE "public"."sdr_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid",
    "firm_id" "uuid",
    "is_reviewed" boolean DEFAULT false,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "state" "text",
    "name" "text" NOT NULL,
    "title" "text",
    "email" "text",
    "direct_phone" "text",
    "seamless_email" "text",
    "firm_name" "text",
    "website" "text",
    "verdict" "text",
    "icp_size" "text",
    "employment_status" "text",
    "firm_status" "text",
    "bio_background" "text",
    "personalization_hook" "text",
    "notes_flags" "text",
    "reviewer_notes" "text",
    "date_researched" "date",
    "seamless_raw" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "batch_label" "text",
    "researched_by_user_id" "uuid",
    "researched_by_name" "text",
    "email_addresses" "jsonb" DEFAULT '[]'::"jsonb",
    "hubspot_contact_id" "text",
    "hubspot_synced_at" timestamp with time zone,
    "hubspot_owner_email" "text",
    "hubspot_checked_at" timestamp with time zone,
    "draft_email_long" "text",
    "draft_email_short" "text",
    "email_status" "text",
    "draft_generated_at" timestamp with time zone,
    "draft_generated_by" "uuid",
    "followup_status" "text",
    "followup_email_long" "text",
    "followup_email_short" "text",
    "followup_draft_generated_at" timestamp with time zone,
    "followup_draft_generated_by" "uuid",
    "draft_subject_long" "text",
    "draft_subject_short" "text",
    "followup_subject_long" "text",
    "followup_subject_short" "text",
    "preferred_draft_type" "text",
    "draft_email_medium" "text",
    "draft_subject_medium" "text",
    "followup_email_medium" "text",
    "followup_subject_medium" "text",
    "excluded_from_outreach" boolean DEFAULT false NOT NULL,
    "excluded_at" timestamp with time zone,
    "excluded_by" "uuid",
    "exclusion_reason" "text",
    CONSTRAINT "sdr_contacts_email_status_check" CHECK ((("email_status" IS NULL) OR ("email_status" = ANY (ARRAY['ready'::"text", 'drafted'::"text"]))))
);


ALTER TABLE "public"."sdr_contacts" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sdr_contacts"."hubspot_contact_id" IS 'HubSpot Contact record ID after push. Null means not yet synced.';



COMMENT ON COLUMN "public"."sdr_contacts"."hubspot_synced_at" IS 'Last time this contact was successfully pushed to HubSpot.';



COMMENT ON COLUMN "public"."sdr_contacts"."draft_email_long" IS 'Long-form email draft, generated via MCP';



COMMENT ON COLUMN "public"."sdr_contacts"."draft_email_short" IS 'Short-form email draft, generated via MCP';



COMMENT ON COLUMN "public"."sdr_contacts"."email_status" IS 'ready = marked for drafting; drafted = draft(s) generated. NULL = not yet in pipeline.';



COMMENT ON COLUMN "public"."sdr_contacts"."followup_status" IS 'Parallel to email_status but for follow-up drafts. null | ready | drafted.';



COMMENT ON COLUMN "public"."sdr_contacts"."followup_email_long" IS 'Long-form follow-up email draft. Separate from draft_email_long so first-touch drafts are never clobbered.';



COMMENT ON COLUMN "public"."sdr_contacts"."followup_email_short" IS 'Short-form follow-up email draft.';



COMMENT ON COLUMN "public"."sdr_contacts"."followup_draft_generated_at" IS 'When the follow-up draft was generated.';



COMMENT ON COLUMN "public"."sdr_contacts"."followup_draft_generated_by" IS 'User id that triggered the follow-up draft.';



COMMENT ON COLUMN "public"."sdr_contacts"."preferred_draft_type" IS 'Which draft variant to push to HubSpot as the preferred draft: draft_email_long | draft_email_short | followup_email_long | followup_email_short | null';



COMMENT ON COLUMN "public"."sdr_contacts"."excluded_from_outreach" IS 'When TRUE, this contact is excluded from outreach: skipped by bulk mark-partners-ready and push-to-HubSpot actions. Set during firm review when reviewer confirms the contact is not a partner / not a good fit.';



COMMENT ON COLUMN "public"."sdr_contacts"."excluded_at" IS 'When the exclusion was set.';



COMMENT ON COLUMN "public"."sdr_contacts"."excluded_by" IS 'User (profiles.id) who excluded this contact.';



COMMENT ON COLUMN "public"."sdr_contacts"."exclusion_reason" IS 'Optional free-form reason for exclusion.';



CREATE TABLE IF NOT EXISTS "public"."sdr_firm_staff" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "firm_id" "uuid",
    "state" "text",
    "firm_name" "text",
    "website" "text",
    "firm_status" "text",
    "person_name" "text" NOT NULL,
    "title" "text",
    "person_status" "text",
    "email" "text",
    "phone" "text",
    "bio_notes" "text",
    "source_url" "text",
    "reviewer_notes" "text",
    "date_added" "date" DEFAULT CURRENT_DATE,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "photo_url" "text"
);


ALTER TABLE "public"."sdr_firm_staff" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_known_acquisitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "state" "text",
    "original_firm" "text",
    "old_website" "text",
    "acquirer_new_brand" "text",
    "date_confirmed" "text",
    "revenue_at_acquisition" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sdr_known_acquisitions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sdr_research_dashboard" WITH ("security_invoker"='true') AS
 WITH "contact_counts" AS (
         SELECT "sdr_contacts"."firm_id",
            ("count"(*))::integer AS "contact_count",
            ("count"(*) FILTER (WHERE ("sdr_contacts"."verdict" = 'REACH OUT'::"text")))::integer AS "reach_out_count",
            ("count"(*) FILTER (WHERE ("sdr_contacts"."verdict" ~~ '%VERIFY%'::"text")))::integer AS "verify_count",
            ("count"(*) FILTER (WHERE ("sdr_contacts"."verdict" ~~ 'SKIP%'::"text")))::integer AS "skip_count"
           FROM "public"."sdr_contacts"
          GROUP BY "sdr_contacts"."firm_id"
        ), "staff_counts" AS (
         SELECT "sdr_firm_staff"."firm_id",
            ("count"(*))::integer AS "staff_logged",
            ("count"(*) FILTER (WHERE ("sdr_firm_staff"."photo_url" IS NOT NULL)))::integer AS "staff_photos_count",
            ("count"(*) FILTER (WHERE (COALESCE("sdr_firm_staff"."person_status", 'Active'::"text") <> ALL (ARRAY['Departed'::"text", 'Deceased'::"text", 'HISTORICAL'::"text"]))))::integer AS "active_roster",
            ("count"(*) FILTER (WHERE (("lower"(COALESCE("sdr_firm_staff"."title", ''::"text")) ~ '(partner|principal|shareholder|managing director|owner|founder|president|ceo|chief executive)'::"text") AND (COALESCE("sdr_firm_staff"."person_status", 'Active'::"text") <> ALL (ARRAY['Departed'::"text", 'Deceased'::"text", 'HISTORICAL'::"text"])))))::integer AS "partner_titled_roster"
           FROM "public"."sdr_firm_staff"
          GROUP BY "sdr_firm_staff"."firm_id"
        ), "base" AS (
         SELECT "f"."id" AS "firm_id",
            "f"."firm_name",
            "f"."website",
            "f"."state",
            "f"."location",
            "f"."firm_status",
            "f"."icp_revenue_fit",
            "f"."est_revenue",
            "f"."staff_est",
            "f"."last_researched_at",
            "f"."logo_url",
            "f"."brand_primary_color",
            "f"."brand_secondary_color",
            "f"."partner_count",
            "f"."hubspot_owner_email",
            "f"."is_available",
            "f"."partner_action",
            "f"."queue_id",
            "f"."services_offered",
            "f"."niches",
            "f"."strategic_direction",
            "f"."specialty",
            "f"."known_team_members",
            "f"."staff_roster_complete",
            COALESCE("cc"."contact_count", 0) AS "contact_count",
            COALESCE("cc"."reach_out_count", 0) AS "reach_out_count",
            COALESCE("cc"."verify_count", 0) AS "verify_count",
            COALESCE("cc"."skip_count", 0) AS "skip_count",
            COALESCE("sc"."staff_logged", 0) AS "staff_logged",
            COALESCE("sc"."staff_photos_count", 0) AS "staff_photos_count",
            COALESCE("sc"."active_roster", 0) AS "active_roster",
            COALESCE("sc"."partner_titled_roster", 0) AS "partner_titled_roster",
            ("f"."logo_url" IS NOT NULL) AS "has_logo",
            ("f"."brand_primary_color" IS NOT NULL) AS "has_brand_colors",
            (("f"."services_offered" IS NOT NULL) AND ("f"."services_offered" <> '[]'::"jsonb")) AS "has_services",
            (("f"."tech_stack" IS NOT NULL) AND ("f"."tech_stack" <> '{}'::"jsonb")) AS "has_tech_stack",
            (("f"."niches" IS NOT NULL) AND ("array_length"("f"."niches", 1) > 0)) AS "has_niches",
            (("f"."partner_count" IS NOT NULL) AND ("f"."partner_count" > 0)) AS "has_partner_count",
            (("f"."strategic_direction" IS NOT NULL) AND ("length"("f"."strategic_direction") >= 50)) AS "has_strategic",
            (("f"."specialty" IS NOT NULL) AND ("length"("f"."specialty") >= 20)) AS "has_specialty_rich",
            (("f"."known_team_members" IS NOT NULL) AND ("length"("f"."known_team_members") >= 20)) AS "has_known_team",
            (("f"."icp_revenue_fit" IS NOT NULL) AND ("f"."icp_revenue_fit" !~~ 'VERIFY - Auto-imported%'::"text") AND ("f"."icp_revenue_fit" !~~ 'VERIFY (Seamless:%'::"text")) AS "has_canonical_icp",
            (("f"."icp_revenue_fit" IS NULL) OR ("f"."icp_revenue_fit" ~~ 'VERIFY - Auto-imported%'::"text") OR ("f"."icp_revenue_fit" ~~ 'VERIFY (Seamless:%'::"text")) AS "gap_canonical_icp",
            "public"."is_seamless_default_revenue"("f"."est_revenue") AS "gap_seamless_revenue",
            "public"."is_seamless_default_staff"("f"."staff_est") AS "gap_seamless_staff",
            ("f"."partner_count" IS NULL) AS "gap_partner_count",
            (NOT ((("f"."known_team_members" IS NOT NULL) AND ("length"("f"."known_team_members") >= 20)) OR (COALESCE("sc"."staff_logged", 0) > 0))) AS "gap_no_roster",
                CASE
                    WHEN "f"."staff_roster_complete" THEN false
                    WHEN ("f"."staff_est" IS NULL) THEN false
                    WHEN ("f"."staff_est" ~ '^\s*\d+\s*$'::"text") THEN (COALESCE("sc"."active_roster", 0) < ("regexp_replace"("f"."staff_est", '\D'::"text", ''::"text", 'g'::"text"))::integer)
                    WHEN ("f"."staff_est" ~ '^\s*\d+\s*-\s*\d+\s*$'::"text") THEN (COALESCE("sc"."active_roster", 0) < (("string_to_array"("regexp_replace"("f"."staff_est", '[^0-9-]'::"text", ''::"text", 'g'::"text"), '-'::"text"))[1])::integer)
                    ELSE false
                END AS "gap_roster_under_staff_est",
            (("f"."partner_count" IS NOT NULL) AND (COALESCE("sc"."partner_titled_roster", 0) > 0) AND (COALESCE("sc"."partner_titled_roster", 0) <> "f"."partner_count")) AS "gap_partner_count_mismatch"
           FROM (("public"."sdr_firms" "f"
             LEFT JOIN "contact_counts" "cc" ON (("cc"."firm_id" = "f"."id")))
             LEFT JOIN "staff_counts" "sc" ON (("sc"."firm_id" = "f"."id")))
        ), "scored" AS (
         SELECT "b"."firm_id",
            "b"."firm_name",
            "b"."website",
            "b"."state",
            "b"."location",
            "b"."firm_status",
            "b"."icp_revenue_fit",
            "b"."est_revenue",
            "b"."staff_est",
            "b"."last_researched_at",
            "b"."logo_url",
            "b"."brand_primary_color",
            "b"."brand_secondary_color",
            "b"."partner_count",
            "b"."hubspot_owner_email",
            "b"."is_available",
            "b"."partner_action",
            "b"."queue_id",
            "b"."services_offered",
            "b"."niches",
            "b"."strategic_direction",
            "b"."specialty",
            "b"."known_team_members",
            "b"."staff_roster_complete",
            "b"."contact_count",
            "b"."reach_out_count",
            "b"."verify_count",
            "b"."skip_count",
            "b"."staff_logged",
            "b"."staff_photos_count",
            "b"."active_roster",
            "b"."partner_titled_roster",
            "b"."has_logo",
            "b"."has_brand_colors",
            "b"."has_services",
            "b"."has_tech_stack",
            "b"."has_niches",
            "b"."has_partner_count",
            "b"."has_strategic",
            "b"."has_specialty_rich",
            "b"."has_known_team",
            "b"."has_canonical_icp",
            "b"."gap_canonical_icp",
            "b"."gap_seamless_revenue",
            "b"."gap_seamless_staff",
            "b"."gap_partner_count",
            "b"."gap_no_roster",
            "b"."gap_roster_under_staff_est",
            "b"."gap_partner_count_mismatch",
            (((((
                CASE
                    WHEN "b"."has_strategic" THEN 40
                    ELSE 0
                END +
                CASE
                    WHEN "b"."has_specialty_rich" THEN 15
                    ELSE 0
                END) +
                CASE
                    WHEN (("b"."services_offered" IS NOT NULL) AND ("jsonb_array_length"("b"."services_offered") >= 1)) THEN 15
                    ELSE 0
                END) +
                CASE
                    WHEN "b"."has_niches" THEN 10
                    ELSE 0
                END) +
                CASE
                    WHEN ("b"."has_known_team" OR ("b"."staff_logged" >= 1)) THEN 10
                    ELSE 0
                END) +
                CASE
                    WHEN "b"."has_canonical_icp" THEN 10
                    ELSE 0
                END) AS "research_score",
            ("b"."has_strategic" AND (NOT "b"."gap_canonical_icp") AND (NOT "b"."gap_seamless_revenue") AND (NOT "b"."gap_seamless_staff") AND (NOT "b"."gap_partner_count") AND (NOT "b"."gap_no_roster")) AS "is_fully_researched"
           FROM "base" "b"
        )
 SELECT "firm_id",
    "firm_name",
    "website",
    "state",
    "location",
    "firm_status",
    "icp_revenue_fit",
    "est_revenue",
    "staff_est",
    "last_researched_at",
    "logo_url",
    "brand_primary_color",
    "brand_secondary_color",
    "partner_count",
    "hubspot_owner_email",
    "is_available",
    "partner_action",
    "queue_id",
    "services_offered",
    "niches",
    "strategic_direction",
    "specialty",
    "known_team_members",
    "contact_count",
    "reach_out_count",
    "verify_count",
    "skip_count",
    "staff_logged",
    "staff_photos_count",
    "has_logo",
    "has_brand_colors",
    "has_services",
    "has_tech_stack",
    "has_niches",
    "has_partner_count",
    "has_strategic",
    "has_specialty_rich",
    "has_known_team",
    "has_canonical_icp",
    "research_score",
        CASE
            WHEN ("research_score" < 40) THEN 'UNRESEARCHED'::"text"
            WHEN ("research_score" >= 75) THEN 'RICH'::"text"
            WHEN ("research_score" >= 50) THEN 'SOLID'::"text"
            ELSE 'BARE'::"text"
        END AS "research_tier",
        CASE
            WHEN (("icp_revenue_fit" IS NOT NULL) AND (("icp_revenue_fit" ~~ '%SKIP%'::"text") OR ("icp_revenue_fit" ~~ '❌%'::"text") OR ("icp_revenue_fit" ~~* '%acquired%'::"text") OR ("icp_revenue_fit" ~~ 'BELOW ICP%'::"text") OR ("icp_revenue_fit" ~~ 'Below ICP%'::"text") OR ("icp_revenue_fit" ~~ 'Above ICP%'::"text") OR ("icp_revenue_fit" ~~ 'OUT OF GEO%'::"text") OR ("icp_revenue_fit" ~~ 'WRONG INDUSTRY%'::"text"))) THEN 'OUT_OF_SCOPE'::"text"
            WHEN ("hubspot_owner_email" IS NOT NULL) THEN 'OWNED_HUBSPOT'::"text"
            WHEN ("partner_action" = 'CLAIMED'::"text") THEN 'CLAIMED'::"text"
            WHEN ("queue_id" IS NOT NULL) THEN 'IN_QUEUE'::"text"
            WHEN (NOT "has_strategic") THEN 'NEEDS_RESEARCH'::"text"
            WHEN (NOT "is_fully_researched") THEN 'RESEARCH_INCOMPLETE'::"text"
            ELSE 'QUEUE_READY'::"text"
        END AS "pipeline_status",
        CASE
            WHEN ("staff_logged" > 0) THEN 'CRAWLED'::"text"
            WHEN ("last_researched_at" IS NOT NULL) THEN 'VISITED'::"text"
            ELSE 'NOT_CRAWLED'::"text"
        END AS "crawl_status",
    "active_roster",
    "partner_titled_roster",
    "gap_canonical_icp",
    "gap_seamless_revenue",
    "gap_seamless_staff",
    "gap_partner_count",
    "gap_no_roster",
    "gap_roster_under_staff_est",
    "gap_partner_count_mismatch",
    "is_fully_researched",
    "staff_roster_complete"
   FROM "scored"
  ORDER BY "research_score" DESC, "firm_name";


ALTER VIEW "public"."sdr_research_dashboard" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_seamless_imports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "imported_at" timestamp with time zone DEFAULT "now"(),
    "processed" boolean DEFAULT false,
    "processed_at" timestamp with time zone,
    "import_batch" "text",
    "Research Date" "text",
    "Contact Full Name" "text",
    "First Name" "text",
    "Middle Name" "text",
    "First Name_2" "text",
    "Last Name" "text",
    "Last Name_2" "text",
    "Title" "text",
    "Department" "text",
    "Seniority" "text",
    "Company Name" "text",
    "Company Name - Cleaned" "text",
    "Website" "text",
    "Lists" "text",
    "List" "text",
    "Primary Email" "text",
    "Intel" "text",
    "Contact LI Profile URL" "text",
    "Email 1" "text",
    "Email 1 Validation" "text",
    "Email 1 Total AI" "text",
    "Email 2" "text",
    "Email 2 Validation" "text",
    "Email 2 Total AI" "text",
    "Email 3" "text",
    "Email 3 Validation" "text",
    "Email 3 Total AI" "text",
    "Email 4" "text",
    "Email 4 Validation" "text",
    "Email 4 Total AI" "text",
    "Email 5" "text",
    "Email 5 Validation" "text",
    "Email 5 Total AI" "text",
    "Email 6" "text",
    "Email 6 Validation" "text",
    "Email 6 Total AI" "text",
    "Email 7" "text",
    "Email 7 Validation" "text",
    "Email 7 Total AI" "text",
    "Email 8" "text",
    "Email 8 Validation" "text",
    "Email 8 Total AI" "text",
    "Email 9" "text",
    "Email 9 Validation" "text",
    "Email 9 Total AI" "text",
    "Email 10" "text",
    "Email 10 Validation" "text",
    "Email 10 Total AI" "text",
    "Personal Email" "text",
    "Personal Email Validation" "text",
    "Personal Email Total AI" "text",
    "Personal Email 2" "text",
    "Personal Email 2 Validation" "text",
    "Personal Email 2 Total AI" "text",
    "Personal Email 3" "text",
    "Personal Email 3 Validation" "text",
    "Personal Email 3 Total AI" "text",
    "Contact Phone 1" "text",
    "Contact Phone 1 Total AI" "text",
    "Company Phone 1" "text",
    "Company Phone 1 Total AI" "text",
    "Contact Phone 2" "text",
    "Contact Phone 2 Total AI" "text",
    "Company Phone 2" "text",
    "Company Phone 2 Total AI" "text",
    "Contact Phone 3" "text",
    "Contact Phone 3 Total AI" "text",
    "Company Phone 3" "text",
    "Company Phone 3 Total AI" "text",
    "Contact Phone 4" "text",
    "Contact Phone 4 Total AI" "text",
    "Company Phone 4" "text",
    "Company Phone 4 Total AI" "text",
    "Contact Phone 5" "text",
    "Contact Phone 5 Total AI" "text",
    "Company Phone 5" "text",
    "Company Phone 5 Total AI" "text",
    "Contact Phone 6" "text",
    "Contact Phone 6 Total AI" "text",
    "Company Phone 6" "text",
    "Company Phone 6 Total AI" "text",
    "Contact Phone 7" "text",
    "Contact Phone 7 Total AI" "text",
    "Company Phone 7" "text",
    "Company Phone 7 Total AI" "text",
    "Contact Phone 8" "text",
    "Contact Phone 8 Total AI" "text",
    "Company Phone 8" "text",
    "Company Phone 8 Total AI" "text",
    "Contact Phone 9" "text",
    "Contact Phone 9 Total AI" "text",
    "Company Phone 9" "text",
    "Company Phone 9 Total AI" "text",
    "Contact Phone 10" "text",
    "Contact Phone 10 Total AI" "text",
    "Current CRM User Email" "text",
    "Company Phone 10" "text",
    "Company Phone 10 Total AI" "text",
    "Contact Mobile Phone" "text",
    "Contact Mobile Phone 1 Total AI" "text",
    "Contact Mobile Phone 2" "text",
    "Contact Mobile Phone 2 Total AI" "text",
    "Contact Mobile Phone 3" "text",
    "Contact City" "text",
    "Contact Mobile Phone 3 Total AI" "text",
    "Contact Mobile Phone 4" "text",
    "Contact State" "text",
    "Contact Mobile Phone 4 Total AI" "text",
    "Contact State Abbr" "text",
    "Contact Post Code" "text",
    "Contact Mobile Phone 5" "text",
    "Contact Mobile Phone 5 Total AI" "text",
    "Contact County" "text",
    "Contact Country" "text",
    "Contact Mobile Phone 6" "text",
    "Contact Country (Alpha 2)" "text",
    "Contact Mobile Phone 6 Total AI" "text",
    "Contact Country (Alpha 3)" "text",
    "Contact Mobile Phone 7" "text",
    "Contact Country - Numeric" "text",
    "Contact Mobile Phone 7 Total AI" "text",
    "Contact Mobile Phone 8" "text",
    "Contact Mobile Phone 8 Total AI" "text",
    "Contact Mobile Phone 9" "text",
    "Contact Mobile Phone 9 Total AI" "text",
    "Contact Mobile Phone 10" "text",
    "Contact Mobile Phone 10 Total AI" "text",
    "Contact Location" "text",
    "Company County" "text",
    "Contact Location - City" "text",
    "Contact Location - State" "text",
    "Contact Location - State Abbreviation" "text",
    "Contact Location - ZIP" "text",
    "Contact Location - Country" "text",
    "Contact Location - Country Alpha-2 Code" "text",
    "Contact Location - Country Alpha-3 Code" "text",
    "Contact Location - Country Numeric Code" "text",
    "Company Location" "text",
    "Company Street 1" "text",
    "Company Street 2" "text",
    "Company Street 3" "text",
    "Company City" "text",
    "Company State" "text",
    "Company State Abbr" "text",
    "Company Post Code" "text",
    "Company Country" "text",
    "Company Country (Alpha 2)" "text",
    "Company Country (Alpha 3)" "text",
    "Company Country - Numeric" "text",
    "Company Annual Revenue" "text",
    "Company Description" "text",
    "Company Website Domain" "text",
    "Company Founded Date" "text",
    "Company Industry" "text",
    "Company LI Profile Url" "text",
    "Company LinkedIn ID" "text",
    "Company Revenue Range" "text",
    "Company Staff Count" "text",
    "Company Staff Count Range" "text",
    "Seamless Username" "text",
    "CRM Account ID" "text",
    "CRM & Social" "text",
    "Date Imported" "text",
    "leadSource" "text",
    "Contact Phone" "text",
    "Location" "text",
    "Current CRM User ID" "text",
    "SIC Code" "text",
    "NAICS Code" "text",
    "Job Change Type" "text",
    "Past Job" "text",
    "Time in Role" "text",
    "Time at Company" "text",
    "Company Funding Total" "text",
    "Company Latest Funding Date" "text",
    "Company Latest Funding Classifications" "text"
);


ALTER TABLE "public"."sdr_seamless_imports" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sdr_import_pipeline_stats" WITH ("security_invoker"='true') AS
 WITH "imports" AS (
         SELECT "count"(*) AS "raw_contacts",
            "count"(DISTINCT "lower"(TRIM(BOTH FROM "sdr_seamless_imports"."Company Name"))) AS "unique_companies",
            "count"(*) FILTER (WHERE ("sdr_seamless_imports"."processed" = true)) AS "processed_count",
            "count"(*) FILTER (WHERE (("sdr_seamless_imports"."processed" = false) OR ("sdr_seamless_imports"."processed" IS NULL))) AS "unprocessed_count"
           FROM "public"."sdr_seamless_imports"
        ), "firms" AS (
         SELECT "count"(*) AS "firms_created",
            "count"(*) FILTER (WHERE ("sdr_firms"."last_researched_at" IS NOT NULL)) AS "firms_researched",
            "count"(*) FILTER (WHERE ("sdr_firms"."icp_revenue_fit" ~~ '%In range%'::"text")) AS "icp_in_range",
            "count"(*) FILTER (WHERE ("sdr_firms"."icp_revenue_fit" ~~* '%verify%'::"text")) AS "icp_verify",
            "count"(*) FILTER (WHERE ("sdr_firms"."icp_revenue_fit" ~~ '%Below%'::"text")) AS "icp_below",
            "count"(*) FILTER (WHERE ("sdr_firms"."icp_revenue_fit" ~~ '%Above%'::"text")) AS "icp_above",
            "count"(*) FILTER (WHERE ("sdr_firms"."icp_revenue_fit" ~~* '%skip%'::"text")) AS "icp_skip"
           FROM "public"."sdr_firms"
        ), "contacts" AS (
         SELECT "count"(*) AS "total_contacts",
            "count"(*) FILTER (WHERE ("sdr_contacts"."verdict" = 'REACH OUT'::"text")) AS "reach_out_contacts",
            "count"(*) FILTER (WHERE ("sdr_contacts"."verdict" ~~ '%VERIFY%'::"text")) AS "verify_contacts",
            "count"(*) FILTER (WHERE (("sdr_contacts"."verdict" ~~ 'SKIP%'::"text") OR ("sdr_contacts"."verdict" ~~ 'BELOW%'::"text"))) AS "skip_contacts"
           FROM "public"."sdr_contacts"
        ), "staff" AS (
         SELECT "count"(*) AS "staff_logged"
           FROM "public"."sdr_firm_staff"
        ), "acq" AS (
         SELECT "count"(*) AS "known_acquisitions"
           FROM "public"."sdr_known_acquisitions"
        ), "dashboard" AS (
         SELECT "count"(*) FILTER (WHERE ("sdr_research_dashboard"."research_tier" = 'RICH'::"text")) AS "tier_rich",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."research_tier" = 'SOLID'::"text")) AS "tier_solid",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."research_tier" = 'BARE'::"text")) AS "tier_bare",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."research_tier" = 'UNRESEARCHED'::"text")) AS "tier_unresearched",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'QUEUE_READY'::"text")) AS "pipe_queue_ready",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'NEEDS_RESEARCH'::"text")) AS "pipe_needs_research",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'RESEARCH_INCOMPLETE'::"text")) AS "pipe_research_incomplete",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'IN_QUEUE'::"text")) AS "pipe_in_queue",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'CLAIMED'::"text")) AS "pipe_claimed",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'OWNED_HUBSPOT'::"text")) AS "pipe_owned_hubspot",
            "count"(*) FILTER (WHERE ("sdr_research_dashboard"."pipeline_status" = 'OUT_OF_SCOPE'::"text")) AS "pipe_out_of_scope"
           FROM "public"."sdr_research_dashboard"
        )
 SELECT "imports"."raw_contacts",
    "imports"."unique_companies",
    "imports"."processed_count",
    "imports"."unprocessed_count",
    "firms"."firms_created",
    "firms"."firms_researched",
    "contacts"."total_contacts",
    "contacts"."reach_out_contacts",
    "contacts"."verify_contacts",
    "contacts"."skip_contacts",
    "staff"."staff_logged",
    "acq"."known_acquisitions",
    "firms"."icp_in_range",
    "firms"."icp_verify",
    "firms"."icp_below",
    "firms"."icp_above",
    "firms"."icp_skip",
    "dashboard"."tier_rich",
    "dashboard"."tier_solid",
    "dashboard"."tier_bare",
    "dashboard"."tier_unresearched",
    "dashboard"."pipe_queue_ready",
    "dashboard"."pipe_needs_research",
    "dashboard"."pipe_research_incomplete",
    "dashboard"."pipe_in_queue",
    "dashboard"."pipe_claimed",
    "dashboard"."pipe_owned_hubspot",
    "dashboard"."pipe_out_of_scope"
   FROM "imports",
    "firms",
    "contacts",
    "staff",
    "acq",
    "dashboard";


ALTER VIEW "public"."sdr_import_pipeline_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_prospect_queues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "partner_user_id" "uuid" NOT NULL,
    "partner_name" "text",
    "queue_number" integer NOT NULL,
    "queue_name" "text",
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "firm_count" integer DEFAULT 0 NOT NULL,
    "claimed_count" integer DEFAULT 0 NOT NULL,
    "skipped_count" integer DEFAULT 0 NOT NULL,
    "flagged_count" integer DEFAULT 0 NOT NULL,
    "filters" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "released_count" integer DEFAULT 0
);


ALTER TABLE "public"."sdr_prospect_queues" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sdr_research_by_state" WITH ("security_invoker"='true') AS
 SELECT "state",
    ("count"(*))::integer AS "total",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'QUEUE_READY'::"text")))::integer AS "queue_ready",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'NEEDS_RESEARCH'::"text")))::integer AS "needs_research",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'RESEARCH_INCOMPLETE'::"text")))::integer AS "research_incomplete",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'IN_QUEUE'::"text")))::integer AS "in_queue",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'CLAIMED'::"text")))::integer AS "claimed",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'OWNED_HUBSPOT'::"text")))::integer AS "owned_hubspot",
    ("count"(*) FILTER (WHERE ("pipeline_status" = 'OUT_OF_SCOPE'::"text")))::integer AS "out_of_scope",
    ("count"(*) FILTER (WHERE ("research_tier" = 'RICH'::"text")))::integer AS "tier_rich",
    ("count"(*) FILTER (WHERE ("research_tier" = 'SOLID'::"text")))::integer AS "tier_solid",
    ("count"(*) FILTER (WHERE ("research_tier" = 'BARE'::"text")))::integer AS "tier_bare",
    ("count"(*) FILTER (WHERE ("research_tier" = 'UNRESEARCHED'::"text")))::integer AS "tier_unresearched",
    ("round"("avg"("research_score"), 1))::double precision AS "avg_score"
   FROM "public"."sdr_research_dashboard"
  WHERE ("state" IS NOT NULL)
  GROUP BY "state";


ALTER VIEW "public"."sdr_research_by_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sdr_rule_sets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sdr_rule_sets_name_check" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);


ALTER TABLE "public"."sdr_rule_sets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."software_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 100 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."software_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."software_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "vendor" "text",
    "category_id" "uuid",
    "website" "text",
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."software_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_advisors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'advisor'::"text" NOT NULL,
    "service_lines" "text"[] DEFAULT ARRAY['cfo_advisory'::"text"] NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ssg_advisors_role_check" CHECK (("role" = ANY (ARRAY['advisor'::"text", 'senior_advisor'::"text", 'manager'::"text"])))
);


ALTER TABLE "public"."ssg_advisors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_calendar_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "connected_user_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'google'::"text" NOT NULL,
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "location" "text",
    "meeting_url" "text",
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "is_all_day" boolean DEFAULT false NOT NULL,
    "is_cancelled" boolean DEFAULT false NOT NULL,
    "organizer_email" "text",
    "attendees" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ssg_calendar_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_emails" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "connected_user_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'google'::"text" NOT NULL,
    "gmail_message_id" "text" NOT NULL,
    "gmail_thread_id" "text",
    "from_email" "text",
    "from_name" "text",
    "to_emails" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "cc_emails" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "subject" "text",
    "snippet" "text",
    "body_text" "text",
    "body_html" "text",
    "is_outbound" boolean DEFAULT false NOT NULL,
    "has_attachments" boolean DEFAULT false NOT NULL,
    "sent_at" timestamp with time zone,
    "synced_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ssg_emails" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_engagement_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "title" "text",
    "email" "text",
    "phone" "text",
    "is_primary" boolean DEFAULT false NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ssg_engagement_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_engagements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_name" "text" NOT NULL,
    "member_firm_id" "uuid",
    "service_line" "text" NOT NULL,
    "primary_advisor_id" "uuid",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "canopy_client_id" "text",
    "industry" "text",
    "engagement_started_at" timestamp with time zone,
    "next_call_at" timestamp with time zone,
    "last_meeting_at" timestamp with time zone,
    "last_email_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "relationship_manager_id" "uuid",
    "status_notes" "text",
    CONSTRAINT "ssg_engagements_service_line_check" CHECK (("service_line" = ANY (ARRAY['cfo_advisory'::"text", 'cost_segregation'::"text", 'rd_tax_credit'::"text", 'other'::"text"]))),
    CONSTRAINT "ssg_engagements_status_check" CHECK (("status" = ANY (ARRAY['pipeline'::"text", 'active'::"text", 'paused'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."ssg_engagements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_functions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "capacity_status" "text" DEFAULT 'accepting'::"text" NOT NULL,
    "manager_id" "uuid",
    "is_archived" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ssg_functions_capacity_status_check" CHECK (("capacity_status" = ANY (ARRAY['accepting'::"text", 'limited'::"text", 'full'::"text"])))
);


ALTER TABLE "public"."ssg_functions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_insights" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "meeting_id" "uuid",
    "signal_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "detail" "text",
    "quote" "text",
    "tax_topics" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "confidence" "text" DEFAULT 'medium'::"text" NOT NULL,
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "detected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ssg_insights_confidence_check" CHECK (("confidence" = ANY (ARRAY['high'::"text", 'medium'::"text", 'low'::"text"]))),
    CONSTRAINT "ssg_insights_signal_type_check" CHECK (("signal_type" = ANY (ARRAY['capital_purchase'::"text", 'hiring'::"text", 'real_estate'::"text", 'business_transaction'::"text", 'entity_change'::"text", 'succession'::"text", 'financing'::"text", 'major_expense'::"text", 'other'::"text"]))),
    CONSTRAINT "ssg_insights_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'reviewed'::"text", 'dismissed'::"text"])))
);


ALTER TABLE "public"."ssg_insights" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_meetings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "recorded_at" timestamp with time zone NOT NULL,
    "duration_minutes" integer,
    "fathom_meeting_id" "text",
    "transcript_url" "text",
    "recording_url" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "calendar_event_id" "uuid",
    "summary" "text",
    "raw_payload" "jsonb",
    "transcript" "jsonb",
    "transcript_sync_attempted_at" timestamp with time zone,
    "source" "text",
    "host_user_id" "uuid"
);


ALTER TABLE "public"."ssg_meetings" OWNER TO "postgres";


COMMENT ON COLUMN "public"."ssg_meetings"."summary" IS 'AI meeting summary (Fathom default_summary). Populated by ssg-fathom-webhook.';



COMMENT ON COLUMN "public"."ssg_meetings"."raw_payload" IS 'Full raw Fathom webhook payload, retained for refinement/debugging.';



COMMENT ON COLUMN "public"."ssg_meetings"."transcript" IS 'Fathom transcript as a jsonb array of utterances: [{speaker:{display_name,matched_calendar_invitee_email}, text, timestamp}]. Populated by ssg-fathom-webhook / ssg-fathom-backfill.';



COMMENT ON COLUMN "public"."ssg_meetings"."transcript_sync_attempted_at" IS 'Last time ssg-sync-fathom tried (and failed) to backfill this meeting''s transcript; NULL = never tried. Drives re-sweep backoff so permanent gaps are not paged every run.';



COMMENT ON COLUMN "public"."ssg_meetings"."source" IS 'Ingest source: ''gemini'' (uploaded Gemini notes .docx), ''fathom'' (Fathom webhook/backfill), ''manual'' (hand-entered). NULL on legacy rows — infer ''fathom'' when fathom_meeting_id is present, else ''manual''.';



COMMENT ON COLUMN "public"."ssg_meetings"."host_user_id" IS 'The hub user this recording is attributed to (Fathom host, else the linked calendar event''s connected_user_id). Drives the Daily Prepper''s directional pooling: a recording is withheld from a viewer for whom host_user_id is a manager-chain superior. NULL = account-shared (legacy or unattributable calls).';



CREATE TABLE IF NOT EXISTS "public"."ssg_member_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "function_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "bill_rate" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ssg_member_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ssg_outcomes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engagement_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "success_story" "text",
    "completed_at" timestamp with time zone,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ssg_outcomes_status_check" CHECK (("status" = ANY (ARRAY['primary'::"text", 'active'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."ssg_outcomes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_businesses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_name" "text" NOT NULL,
    "website" "text",
    "industry" "text",
    "industry_vertical" "text",
    "linkedin_company_url" "text",
    "location_city" "text",
    "location_state" character(2),
    "headcount_estimate" "text",
    "est_revenue" "text",
    "years_in_business" integer,
    "ownership_structure" "text",
    "company_status" "text" DEFAULT 'Independent'::"text",
    "icp_track" "text",
    "tas_icp_score" integer,
    "tas_icp_tier" "text",
    "icp_fit" "text",
    "exit_signal_flags" "text"[],
    "acquisition_signal_flags" "text"[],
    "strategic_direction" "text",
    "company_description" "text",
    "likely_timeline" "text",
    "signal_source_notes" "text",
    "source_notes" "text",
    "real_estate_flag" boolean DEFAULT false,
    "pe_backed_flag" boolean DEFAULT false,
    "vc_backed_flag" boolean DEFAULT false,
    "nonprofit_flag" boolean DEFAULT false,
    "hubspot_company_id" "text",
    "hubspot_synced_at" timestamp with time zone,
    "logo_url" "text",
    "last_researched_at" timestamp with time zone,
    "is_available" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_existing_client" boolean DEFAULT false NOT NULL,
    CONSTRAINT "tas_businesses_company_status_check" CHECK (("company_status" = ANY (ARRAY['Independent'::"text", 'PE-backed'::"text", 'Acquired'::"text", 'Public'::"text", 'Unknown'::"text"]))),
    CONSTRAINT "tas_businesses_icp_track_check" CHECK (("icp_track" = ANY (ARRAY['exit_seller'::"text", 'acquisition_buyer'::"text", 'both'::"text"]))),
    CONSTRAINT "tas_businesses_likely_timeline_check" CHECK (("likely_timeline" = ANY (ARRAY['1-2 years'::"text", '3-5 years'::"text", '5+ years'::"text", 'Acquisition-minded'::"text", 'Unknown'::"text"]))),
    CONSTRAINT "tas_businesses_ownership_structure_check" CHECK (("ownership_structure" = ANY (ARRAY['Sole owner'::"text", 'Partners'::"text", 'Family-owned'::"text", 'Employee-owned'::"text", 'Unknown'::"text"]))),
    CONSTRAINT "tas_businesses_tas_icp_score_check" CHECK ((("tas_icp_score" >= 0) AND ("tas_icp_score" <= 100))),
    CONSTRAINT "tas_businesses_tas_icp_tier_check" CHECK (("tas_icp_tier" = ANY (ARRAY['Hot'::"text", 'Warm'::"text", 'Watchlist'::"text", 'Disqualified'::"text"])))
);


ALTER TABLE "public"."tas_businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_consultant_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "display_name" "text" NOT NULL,
    "title" "text" DEFAULT 'TAS Consultant'::"text" NOT NULL,
    "email" "text",
    "phone" "text",
    "linkedin_url" "text",
    "bio" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 99 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tas_consultant_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "business_id" "uuid" NOT NULL,
    "contact_name" "text" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "title" "text",
    "contact_role" "text",
    "seniority" "text",
    "email" "text",
    "phone" "text",
    "linkedin_url" "text",
    "li_connected" boolean DEFAULT false,
    "li_connected_at" timestamp with time zone,
    "sequence_track" "text",
    "bio_background" "text",
    "personalization_hook" "text",
    "owner_age_estimate" "text",
    "notes_flags" "text",
    "hubspot_contact_id" "text",
    "hubspot_synced_at" timestamp with time zone,
    "verdict" "text" DEFAULT 'REACH OUT'::"text",
    "draft_li_connection" "text",
    "draft_li_welcome" "text",
    "draft_li_inmail" "text",
    "draft_vm_1" "text",
    "draft_vm_2" "text",
    "draft_email_value_subject" "text",
    "draft_email_value_body" "text",
    "draft_email_cta_subject" "text",
    "draft_email_cta_body" "text",
    "draft_email_breakup_subject" "text",
    "draft_email_breakup_body" "text",
    "draft_generated_at" timestamp with time zone,
    "source" "text" DEFAULT 'Sales Navigator'::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "draft_li_inmail_subject" "text",
    "linkedin_not_found" boolean DEFAULT false NOT NULL,
    "referral_role" "text",
    CONSTRAINT "tas_contacts_contact_role_check" CHECK (("contact_role" = ANY (ARRAY['Primary'::"text", 'Secondary'::"text"]))),
    CONSTRAINT "tas_contacts_referral_role_check" CHECK (("referral_role" = ANY (ARRAY['wealth_advisor'::"text", 'banker'::"text", 'abl'::"text", 'insurance'::"text", 'attorney'::"text", 'business_broker'::"text", 'private_equity'::"text", 'family_office'::"text", 'cpa'::"text", 'connector'::"text", 'other'::"text"]))),
    CONSTRAINT "tas_contacts_sequence_track_check" CHECK (("sequence_track" = ANY (ARRAY['direct'::"text", 'referral_partner'::"text"]))),
    CONSTRAINT "tas_contacts_verdict_check" CHECK (("verdict" = ANY (ARRAY['REACH OUT'::"text", 'VERIFY'::"text", 'SKIP'::"text", 'CONVERTED'::"text", 'DISQUALIFIED'::"text"])))
);


ALTER TABLE "public"."tas_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_sequences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "sequence_track" "text" NOT NULL,
    "sequence_tier" "text" NOT NULL,
    "sequence_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "current_step" integer DEFAULT 1 NOT NULL,
    "total_steps" integer DEFAULT 5 NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_step_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "next_action_date" "date",
    "next_action_channel" "text",
    "next_action_label" "text",
    "li_connection_sent_at" timestamp with time zone,
    "li_connection_deadline" "date",
    "inmail_used" boolean DEFAULT false,
    "first_response_at" timestamp with time zone,
    "first_response_channel" "text",
    "meeting_booked_at" timestamp with time zone,
    "meeting_date" timestamp with time zone,
    "outreach_status" "text" DEFAULT 'Not Started'::"text" NOT NULL,
    "outreach_status_updated_at" timestamp with time zone,
    "hubspot_deal_id" "text",
    "partner_notes" "text",
    "assigned_to" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "consultant_profile_id" "uuid",
    "queue_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "referral_tier" "text" DEFAULT 'primary'::"text" NOT NULL,
    "import_log_id" "uuid",
    "needs_review" boolean DEFAULT false NOT NULL,
    "is_pinned" boolean DEFAULT false NOT NULL,
    CONSTRAINT "tas_sequences_next_action_channel_check" CHECK (("next_action_channel" = ANY (ARRAY['linkedin'::"text", 'email'::"text", 'voicemail'::"text", 'inmail'::"text"]))),
    CONSTRAINT "tas_sequences_outreach_status_check" CHECK (("outreach_status" = ANY (ARRAY['Not Started'::"text", 'Connection Sent'::"text", 'Connected'::"text", 'InMail Sent'::"text", 'Email Sent'::"text", 'Follow-Up Sent'::"text", 'Meeting Scheduled'::"text", 'Converted'::"text", 'No Response'::"text", 'Declined'::"text"]))),
    CONSTRAINT "tas_sequences_queue_status_check" CHECK (("queue_status" = ANY (ARRAY['active'::"text", 'pending'::"text", 'archived'::"text"]))),
    CONSTRAINT "tas_sequences_referral_tier_check" CHECK (("referral_tier" = ANY (ARRAY['primary'::"text", 'secondary'::"text", 'tertiary'::"text"]))),
    CONSTRAINT "tas_sequences_sequence_status_check" CHECK (("sequence_status" = ANY (ARRAY['active'::"text", 'paused'::"text", 'responded'::"text", 'meeting_booked'::"text", 'converted'::"text", 'completed'::"text", 'disqualified'::"text"]))),
    CONSTRAINT "tas_sequences_sequence_tier_check" CHECK (("sequence_tier" = ANY (ARRAY['hot'::"text", 'warm'::"text", 'watchlist'::"text"]))),
    CONSTRAINT "tas_sequences_sequence_track_check" CHECK (("sequence_track" = ANY (ARRAY['direct'::"text", 'referral_partner'::"text"])))
);


ALTER TABLE "public"."tas_sequences" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."tas_daily_action_queue" AS
 SELECT "s"."id" AS "sequence_id",
    "s"."next_action_date",
    "s"."next_action_channel",
    "s"."next_action_label",
    "s"."sequence_tier",
    "s"."sequence_track",
    "s"."outreach_status",
    "s"."current_step",
    "s"."total_steps",
    "s"."inmail_used",
    "s"."li_connection_deadline",
    "s"."referral_tier",
    "s"."queue_status",
    "s"."needs_review",
    "c"."id" AS "contact_id",
    "c"."contact_name",
    "c"."first_name",
    "c"."title",
    "c"."email",
    "c"."phone",
    "c"."linkedin_url",
    "c"."li_connected",
    "c"."personalization_hook",
    "b"."id" AS "business_id",
    "b"."business_name",
    "b"."industry_vertical",
    "b"."location_city",
    "b"."location_state",
    "b"."est_revenue",
    "b"."tas_icp_tier",
    "b"."icp_track",
    "b"."logo_url",
    "s"."consultant_profile_id"
   FROM (("public"."tas_sequences" "s"
     JOIN "public"."tas_contacts" "c" ON (("c"."id" = "s"."contact_id")))
     JOIN "public"."tas_businesses" "b" ON (("b"."id" = "s"."business_id")))
  WHERE (("s"."sequence_status" = 'active'::"text") AND ("s"."next_action_date" <= CURRENT_DATE) AND ("s"."queue_status" = 'active'::"text"));


ALTER VIEW "public"."tas_daily_action_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_import_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "consultant_profile_id" "uuid",
    "filename" "text" DEFAULT 'Unknown File'::"text" NOT NULL,
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "records_created" integer DEFAULT 0 NOT NULL,
    "records_skipped" integer DEFAULT 0 NOT NULL,
    "records_failed" integer DEFAULT 0 NOT NULL,
    "prospects_created" integer DEFAULT 0 NOT NULL,
    "cois_created" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."tas_import_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_inmail_budget" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "credits_total" integer DEFAULT 50 NOT NULL,
    "credits_used" integer DEFAULT 0 NOT NULL,
    "credits_refunded" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "consultant_profile_id" "uuid"
);


ALTER TABLE "public"."tas_inmail_budget" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."tas_inmail_budget_view" AS
 SELECT "id",
    "user_id",
    "month",
    "credits_total",
    "credits_used",
    "credits_refunded",
    "created_at",
    "updated_at",
    (("credits_total" + "credits_refunded") - "credits_used") AS "credits_remaining",
    "round"(((("credits_used")::numeric / (NULLIF("credits_total", 0))::numeric) * (100)::numeric)) AS "pct_used"
   FROM "public"."tas_inmail_budget" "b";


ALTER VIEW "public"."tas_inmail_budget_view" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."tas_pipeline_summary" AS
 SELECT "count"(*) FILTER (WHERE ("sequence_status" = 'active'::"text")) AS "active_sequences",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Not Started'::"text")) AS "not_started",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Connection Sent'::"text")) AS "connection_sent",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Connected'::"text")) AS "connected",
    "count"(*) FILTER (WHERE ("outreach_status" = 'InMail Sent'::"text")) AS "inmail_sent",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Email Sent'::"text")) AS "email_sent",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Follow-Up Sent'::"text")) AS "follow_up_sent",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Meeting Scheduled'::"text")) AS "meeting_scheduled",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Converted'::"text")) AS "converted",
    "count"(*) FILTER (WHERE ("outreach_status" = 'No Response'::"text")) AS "no_response",
    "count"(*) FILTER (WHERE ("outreach_status" = 'Declined'::"text")) AS "declined",
    "count"(*) FILTER (WHERE ("sequence_tier" = 'hot'::"text")) AS "hot_leads",
    "count"(*) FILTER (WHERE ("sequence_tier" = 'warm'::"text")) AS "warm_leads",
    "count"(*) FILTER (WHERE ("sequence_tier" = 'watchlist'::"text")) AS "watchlist_leads",
    "count"(*) FILTER (WHERE ("sequence_track" = 'direct'::"text")) AS "direct_track",
    "count"(*) FILTER (WHERE ("sequence_track" = 'referral_partner'::"text")) AS "referral_track"
   FROM "public"."tas_sequences" "s";


ALTER VIEW "public"."tas_pipeline_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tas_sequence_steps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sequence_id" "uuid" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "business_id" "uuid" NOT NULL,
    "step_number" integer NOT NULL,
    "step_label" "text" NOT NULL,
    "channel" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "subject_line" "text",
    "message_body" "text",
    "inmail_credit_used" boolean DEFAULT false,
    "completed_at" timestamp with time zone,
    "skipped_at" timestamp with time zone,
    "skip_reason" "text",
    "response_received" boolean DEFAULT false,
    "response_at" timestamp with time zone,
    "response_notes" "text",
    "hubspot_engagement_id" "text",
    "hubspot_synced_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "scheduled_date" "date",
    CONSTRAINT "tas_sequence_steps_channel_check" CHECK (("channel" = ANY (ARRAY['linkedin'::"text", 'email'::"text", 'voicemail'::"text", 'inmail'::"text"]))),
    CONSTRAINT "tas_sequence_steps_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'completed'::"text", 'skipped'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."tas_sequence_steps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "uploaded_by" "uuid" NOT NULL,
    "file_name" "text" NOT NULL,
    "file_size" integer NOT NULL,
    "mime_type" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."task_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_collaborators" (
    "task_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"(),
    "added_by" "uuid"
);


ALTER TABLE "public"."task_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    "is_deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."task_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_custom_field_values" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "field_id" "uuid" NOT NULL,
    "value_number" numeric,
    "value_text" "text",
    "value_date" "date",
    "value_bool" boolean,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."task_custom_field_values" OWNER TO "postgres";


COMMENT ON TABLE "public"."task_custom_field_values" IS 'Value of a custom field on a task. Row visibility inherits the parent task via RLS.';



CREATE TABLE IF NOT EXISTS "public"."task_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "field_name" "text" NOT NULL,
    "old_value" "text",
    "new_value" "text",
    "changed_by" "uuid" NOT NULL,
    "changed_by_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."task_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."task_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_project_memberships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "task_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "section_id" "uuid",
    "position" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."task_project_memberships" OWNER TO "postgres";


COMMENT ON TABLE "public"."task_project_memberships" IS 'Multi-homing join table: one row per (task, project). section_id is the task''s placement within that project (NULL = No Section). The task''s content stays on public.tasks and is shared across all its memberships.';



CREATE TABLE IF NOT EXISTS "public"."task_saved_views" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "context" "text" DEFAULT 'my_tasks'::"text" NOT NULL,
    "name" "text" NOT NULL,
    "is_system" boolean DEFAULT false NOT NULL,
    "view_type" "text" DEFAULT 'list'::"text" NOT NULL,
    "group_by" "text",
    "group_sort" "text",
    "sort_field" "text",
    "sort_direction" "text",
    "filters" "jsonb",
    "column_config" "jsonb",
    "position" integer DEFAULT 0 NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."task_saved_views" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text",
    "assigned_to" "uuid",
    "assigned_by" "uuid",
    "due_date" "date",
    "priority" "text",
    "status" "text" DEFAULT 'not_started'::"text" NOT NULL,
    "source_type" "text" DEFAULT 'standalone'::"text" NOT NULL,
    "source_reference_id" "uuid",
    "notes" "text",
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_item_id" "uuid",
    "project_id" "uuid",
    "section_id" "uuid",
    "updated_by" "uuid",
    "ninety_id" "text",
    "sync_source" "text",
    "_sync_lock" boolean DEFAULT false,
    "parent_task_id" "uuid",
    "recurrence_type" "text",
    "recurrence_days" integer[],
    "recurrence_end_date" "date",
    "recurrence_parent_id" "uuid",
    "external_owner_name" "text",
    "external_owner_role" "text",
    "ai_generated_by" "text",
    "ai_source_meeting_id" "uuid"
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "icon_name" "text" DEFAULT 'Ticket'::"text",
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."ticket_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "is_internal" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ticket_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_field_definitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "category_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "field_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "options" "jsonb",
    "is_required" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."ticket_field_definitions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_field_values" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "field_definition_id" "uuid" NOT NULL,
    "value" "text" NOT NULL
);


ALTER TABLE "public"."ticket_field_values" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "is_internal_note" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone
);


ALTER TABLE "public"."ticket_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ticket_notifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ticket_seq"
    START WITH 1001
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ticket_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_statuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#6b7280'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_closed" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."ticket_statuses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "status_id" "uuid" NOT NULL,
    "category_id" "uuid" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "assigned_to" "uuid",
    "organization_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sequential_id" integer NOT NULL,
    "owner_id" "uuid"
);


ALTER TABLE "public"."tickets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."training_courses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "thumbnail_url" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "sort_order" integer DEFAULT 100 NOT NULL,
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "training_courses_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text"])))
);


ALTER TABLE "public"."training_courses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."training_lesson_progress" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lesson_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "completed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."training_lesson_progress" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."training_lessons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "course_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "video_url" "text",
    "sort_order" integer DEFAULT 100 NOT NULL,
    "duration_minutes" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "training_lessons_duration_minutes_check" CHECK (("duration_minutes" >= 0))
);


ALTER TABLE "public"."training_lessons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."training_resources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "course_id" "uuid" NOT NULL,
    "lesson_id" "uuid",
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "file_path" "text",
    "url" "text",
    "mime_type" "text",
    "file_size" bigint,
    "sort_order" integer DEFAULT 100 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "training_resources_kind_check" CHECK (("kind" = ANY (ARRAY['file'::"text", 'link'::"text"])))
);


ALTER TABLE "public"."training_resources" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transition_assessment_submissions" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "business_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text",
    "score_pct" integer NOT NULL,
    "band" "text" NOT NULL,
    "answers" integer[] NOT NULL,
    "category_scores" "jsonb",
    "ip" "text",
    "user_agent" "text",
    CONSTRAINT "transition_assessment_submissions_score_pct_check" CHECK ((("score_pct" >= 0) AND ("score_pct" <= 100)))
);


ALTER TABLE "public"."transition_assessment_submissions" OWNER TO "postgres";


COMMENT ON TABLE "public"."transition_assessment_submissions" IS 'Stores completed Family Transition Assessment responses from tas-transition.vercel.app. Independent of tas_assessment_submissions.';



CREATE SEQUENCE IF NOT EXISTS "public"."transition_assessment_submissions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."transition_assessment_submissions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."transition_assessment_submissions_id_seq" OWNED BY "public"."transition_assessment_submissions"."id";



CREATE TABLE IF NOT EXISTS "public"."user_home_layouts" (
    "user_id" "uuid" NOT NULL,
    "layout" "jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_home_layouts" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_home_layouts" IS 'Per-user Home dashboard layout: ordered jsonb array of {id, hidden} widget entries. No row = default layout. Widget ids are defined by the frontend home-widget registry; unknown ids are ignored on read.';



CREATE TABLE IF NOT EXISTS "public"."user_notification_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "preferences" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_notification_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_role_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "assigned_by" "uuid",
    "assigned_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_role_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "public"."app_role" DEFAULT 'member'::"public"."app_role" NOT NULL
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendor_contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text",
    "title" "text",
    "email" "text",
    "phone" "text",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."vendor_contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "website" "text",
    "category" "text",
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid"
);


ALTER TABLE "public"."vendors" OWNER TO "postgres";


ALTER TABLE ONLY "public"."transition_assessment_submissions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."transition_assessment_submissions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."activity_logs"
    ADD CONSTRAINT "activity_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."assessment_leads"
    ADD CONSTRAINT "assessment_leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_batches"
    ADD CONSTRAINT "bdr_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_business_people"
    ADD CONSTRAINT "bdr_business_people_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_businesses"
    ADD CONSTRAINT "bdr_businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_businesses"
    ADD CONSTRAINT "bdr_businesses_website_key" UNIQUE ("website");



ALTER TABLE ONLY "public"."bdr_email_templates"
    ADD CONSTRAINT "bdr_email_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_prospects"
    ADD CONSTRAINT "bdr_prospects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bdr_seamless_staging"
    ADD CONSTRAINT "bdr_seamless_staging_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_plan_checkins"
    ADD CONSTRAINT "business_plan_checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_plan_revenue_drivers"
    ADD CONSTRAINT "business_plan_revenue_drivers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_plans"
    ADD CONSTRAINT "business_plans_organization_id_plan_year_key" UNIQUE ("organization_id", "plan_year");



ALTER TABLE ONLY "public"."business_plans"
    ADD CONSTRAINT "business_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checkin_assignments"
    ADD CONSTRAINT "checkin_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checkin_edit_log"
    ADD CONSTRAINT "checkin_edit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checkin_submissions"
    ADD CONSTRAINT "checkin_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checkin_templates"
    ADD CONSTRAINT "checkin_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_custom_items"
    ADD CONSTRAINT "checklist_custom_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_item_overrides"
    ADD CONSTRAINT "checklist_item_overrides_assignment_id_checklist_item_id_key" UNIQUE ("assignment_id", "checklist_item_id");



ALTER TABLE ONLY "public"."checklist_item_overrides"
    ADD CONSTRAINT "checklist_item_overrides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_progress"
    ADD CONSTRAINT "checklist_progress_checklist_item_id_assignment_id_key" UNIQUE ("checklist_item_id", "assignment_id");



ALTER TABLE ONLY "public"."checklist_progress"
    ADD CONSTRAINT "checklist_progress_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checklist_templates"
    ADD CONSTRAINT "checklist_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment_mentions"
    ADD CONSTRAINT "comment_mentions_pkey" PRIMARY KEY ("comment_id", "mentioned_user_id");



ALTER TABLE ONLY "public"."custom_field_definitions"
    ADD CONSTRAINT "custom_field_definitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."custom_roles"
    ADD CONSTRAINT "custom_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dashboard_access"
    ADD CONSTRAINT "dashboard_access_pkey" PRIMARY KEY ("dashboard_id", "permission_key");



ALTER TABLE ONLY "public"."dashboard_datasets"
    ADD CONSTRAINT "dashboard_datasets_pkey" PRIMARY KEY ("dashboard_id", "dataset_id");



ALTER TABLE ONLY "public"."dashboards"
    ADD CONSTRAINT "dashboards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dashboards"
    ADD CONSTRAINT "dashboards_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."data_sources"
    ADD CONSTRAINT "data_sources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."data_sources"
    ADD CONSTRAINT "data_sources_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."dataset_access"
    ADD CONSTRAINT "dataset_access_pkey" PRIMARY KEY ("dataset_id", "permission_key", "access_level");



ALTER TABLE ONLY "public"."datasets"
    ADD CONSTRAINT "datasets_data_source_id_slug_key" UNIQUE ("data_source_id", "slug");



ALTER TABLE ONLY "public"."datasets"
    ADD CONSTRAINT "datasets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."desks"
    ADD CONSTRAINT "desks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."desks"
    ADD CONSTRAINT "desks_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."document_categories"
    ADD CONSTRAINT "document_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_folders"
    ADD CONSTRAINT "document_folders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_notifications"
    ADD CONSTRAINT "document_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_user_id_document_id_key" UNIQUE ("user_id", "document_id");



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_user_id_folder_id_key" UNIQUE ("user_id", "folder_id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_activity_log"
    ADD CONSTRAINT "email_activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_activity_log"
    ADD CONSTRAINT "email_activity_log_tracking_pixel_id_key" UNIQUE ("tracking_pixel_id");



ALTER TABLE ONLY "public"."email_connections"
    ADD CONSTRAINT "email_connections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_connections"
    ADD CONSTRAINT "email_connections_user_id_provider_key" UNIQUE ("user_id", "provider");



ALTER TABLE ONLY "public"."expansion_email_templates"
    ADD CONSTRAINT "expansion_email_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expansion_opportunities"
    ADD CONSTRAINT "expansion_opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expansion_research_runs"
    ADD CONSTRAINT "expansion_research_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."firm_software_costs"
    ADD CONSTRAINT "firm_software_costs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."firm_software"
    ADD CONSTRAINT "firm_software_organization_id_product_id_key" UNIQUE ("organization_id", "product_id");



ALTER TABLE ONLY "public"."firm_software"
    ADD CONSTRAINT "firm_software_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_benefit_enrollments"
    ADD CONSTRAINT "hris_benefit_enrollments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_benefit_plans"
    ADD CONSTRAINT "hris_benefit_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_checklist_template_items"
    ADD CONSTRAINT "hris_checklist_template_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_checklist_templates"
    ADD CONSTRAINT "hris_checklist_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_compensation"
    ADD CONSTRAINT "hris_compensation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_custom_field_values"
    ADD CONSTRAINT "hris_custom_field_values_entity_type_entity_id_field_id_key" UNIQUE ("entity_type", "entity_id", "field_id");



ALTER TABLE ONLY "public"."hris_custom_field_values"
    ADD CONSTRAINT "hris_custom_field_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_emergency_contacts"
    ADD CONSTRAINT "hris_emergency_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_employee_checklists"
    ADD CONSTRAINT "hris_employee_checklists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_employee_details"
    ADD CONSTRAINT "hris_employee_details_pkey" PRIMARY KEY ("profile_id");



ALTER TABLE ONLY "public"."hris_leave_action_tokens"
    ADD CONSTRAINT "hris_leave_action_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_leave_action_tokens"
    ADD CONSTRAINT "hris_leave_action_tokens_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "public"."hris_leave_balances"
    ADD CONSTRAINT "hris_leave_balances_employee_id_leave_type_id_year_key" UNIQUE ("employee_id", "leave_type_id", "year");



ALTER TABLE ONLY "public"."hris_leave_balances"
    ADD CONSTRAINT "hris_leave_balances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_leave_requests"
    ADD CONSTRAINT "hris_leave_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hris_leave_types"
    ADD CONSTRAINT "hris_leave_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hs_companies"
    ADD CONSTRAINT "hs_companies_pkey" PRIMARY KEY ("hubspot_id");



ALTER TABLE ONLY "public"."hs_contacts"
    ADD CONSTRAINT "hs_contacts_pkey" PRIMARY KEY ("hubspot_id");



ALTER TABLE ONLY "public"."hs_deals"
    ADD CONSTRAINT "hs_deals_pkey" PRIMARY KEY ("hubspot_id");



ALTER TABLE ONLY "public"."hs_engagements"
    ADD CONSTRAINT "hs_engagements_pkey" PRIMARY KEY ("hubspot_id");



ALTER TABLE ONLY "public"."hs_owners"
    ADD CONSTRAINT "hs_owners_pkey" PRIMARY KEY ("hubspot_id");



ALTER TABLE ONLY "public"."hs_sync_log"
    ADD CONSTRAINT "hs_sync_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hub_api_tokens"
    ADD CONSTRAINT "hub_api_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hub_api_tokens"
    ADD CONSTRAINT "hub_api_tokens_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "public"."hubspot_contact_classifications"
    ADD CONSTRAINT "hubspot_contact_classifications_pkey" PRIMARY KEY ("hubspot_contact_id");



ALTER TABLE ONLY "public"."hubspot_engagement_contacts"
    ADD CONSTRAINT "hubspot_engagement_contacts_pkey" PRIMARY KEY ("hubspot_engagement_id", "hubspot_contact_id");



ALTER TABLE ONLY "public"."hubspot_engagements"
    ADD CONSTRAINT "hubspot_engagements_hubspot_engagement_id_hubspot_object_ty_key" UNIQUE ("hubspot_engagement_id", "hubspot_object_type");



ALTER TABLE ONLY "public"."hubspot_engagements"
    ADD CONSTRAINT "hubspot_engagements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inbox_items"
    ADD CONSTRAINT "inbox_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_description_versions"
    ADD CONSTRAINT "job_description_versions_job_description_id_version_key" UNIQUE ("job_description_id", "version");



ALTER TABLE ONLY "public"."job_description_versions"
    ADD CONSTRAINT "job_description_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_descriptions"
    ADD CONSTRAINT "job_descriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_descriptions"
    ADD CONSTRAINT "job_descriptions_profile_id_key" UNIQUE ("profile_id");



ALTER TABLE ONLY "public"."knowledge_base_article_page_links"
    ADD CONSTRAINT "knowledge_base_article_page_links_pkey" PRIMARY KEY ("article_id", "page_key");



ALTER TABLE ONLY "public"."knowledge_base_articles"
    ADD CONSTRAINT "knowledge_base_articles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."knowledge_base_edit_log"
    ADD CONSTRAINT "knowledge_base_edit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_agreements_log"
    ADD CONSTRAINT "laa_agreements_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_canopy_payments"
    ADD CONSTRAINT "laa_canopy_payments_canopy_instance_client_name_payment_mon_key" UNIQUE ("canopy_instance", "client_name", "payment_month", "total_payment_amount");



ALTER TABLE ONLY "public"."laa_canopy_payments"
    ADD CONSTRAINT "laa_canopy_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_cpa_rules"
    ADD CONSTRAINT "laa_cpa_rules_cpa_state_key" UNIQUE ("cpa_state");



ALTER TABLE ONLY "public"."laa_cpa_rules"
    ADD CONSTRAINT "laa_cpa_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_firm_compensation"
    ADD CONSTRAINT "laa_firm_compensation_pkey" PRIMARY KEY ("organization_id");



ALTER TABLE ONLY "public"."laa_firm_services"
    ADD CONSTRAINT "laa_firm_services_organization_id_service_slug_key" UNIQUE ("organization_id", "service_slug");



ALTER TABLE ONLY "public"."laa_firm_services"
    ADD CONSTRAINT "laa_firm_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_firms"
    ADD CONSTRAINT "laa_firms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_recipient_rules"
    ADD CONSTRAINT "laa_recipient_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_recipient_rules"
    ADD CONSTRAINT "laa_recipient_rules_recipient_state_profession_key" UNIQUE ("recipient_state", "profession");



ALTER TABLE ONLY "public"."laa_referral_payouts"
    ADD CONSTRAINT "laa_referral_payouts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_rfp_bids"
    ADD CONSTRAINT "laa_rfp_bids_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_rfp_bids"
    ADD CONSTRAINT "laa_rfp_bids_rfp_id_bidding_org_id_key" UNIQUE ("rfp_id", "bidding_org_id");



ALTER TABLE ONLY "public"."laa_rfp_questions"
    ADD CONSTRAINT "laa_rfp_questions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_rfps"
    ADD CONSTRAINT "laa_rfps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_service_catalog"
    ADD CONSTRAINT "laa_service_catalog_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."laa_service_catalog"
    ADD CONSTRAINT "laa_service_catalog_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."laa_service_catalog"
    ADD CONSTRAINT "laa_service_catalog_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."linked_emails"
    ADD CONSTRAINT "linked_emails_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."my_task_automation_logs"
    ADD CONSTRAINT "my_task_automation_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."my_task_automations"
    ADD CONSTRAINT "my_task_automations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."my_task_section_assignments"
    ADD CONSTRAINT "my_task_section_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."my_task_section_assignments"
    ADD CONSTRAINT "my_task_section_assignments_user_id_task_id_key" UNIQUE ("user_id", "task_id");



ALTER TABLE ONLY "public"."my_task_sections"
    ADD CONSTRAINT "my_task_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nine_box_scores"
    ADD CONSTRAINT "nine_box_scores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ninety_user_mappings"
    ADD CONSTRAINT "ninety_user_mappings_ninety_user_id_key" UNIQUE ("ninety_user_id");



ALTER TABLE ONLY "public"."ninety_user_mappings"
    ADD CONSTRAINT "ninety_user_mappings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."oauth_access_tokens"
    ADD CONSTRAINT "oauth_access_tokens_pkey" PRIMARY KEY ("token_hash");



ALTER TABLE ONLY "public"."oauth_authorization_codes"
    ADD CONSTRAINT "oauth_authorization_codes_pkey" PRIMARY KEY ("code_hash");



ALTER TABLE ONLY "public"."oauth_clients"
    ADD CONSTRAINT "oauth_clients_pkey" PRIMARY KEY ("client_id");



ALTER TABLE ONLY "public"."oauth_refresh_tokens"
    ADD CONSTRAINT "oauth_refresh_tokens_pkey" PRIMARY KEY ("token_hash");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."permissions"
    ADD CONSTRAINT "permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pinned_items"
    ADD CONSTRAINT "pinned_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pinned_items"
    ADD CONSTRAINT "pinned_items_user_id_entity_type_entity_id_key" UNIQUE ("user_id", "entity_type", "entity_id");



ALTER TABLE ONLY "public"."prep_briefs"
    ADD CONSTRAINT "prep_briefs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prep_briefs"
    ADD CONSTRAINT "prep_briefs_user_id_event_id_brief_date_key" UNIQUE ("user_id", "event_id", "brief_date");



ALTER TABLE ONLY "public"."prep_calendar_events"
    ADD CONSTRAINT "prep_calendar_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prep_reminder_preferences"
    ADD CONSTRAINT "prep_reminder_preferences_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_invite_token_key" UNIQUE ("invite_token");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_custom_fields"
    ADD CONSTRAINT "project_custom_fields_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_custom_fields"
    ADD CONSTRAINT "project_custom_fields_project_id_field_id_key" UNIQUE ("project_id", "field_id");



ALTER TABLE ONLY "public"."project_favorites"
    ADD CONSTRAINT "project_favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_favorites"
    ADD CONSTRAINT "project_favorites_project_id_user_id_key" UNIQUE ("project_id", "user_id");



ALTER TABLE ONLY "public"."project_field_aggregations"
    ADD CONSTRAINT "project_field_aggregations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_project_id_user_id_key" UNIQUE ("project_id", "user_id");



ALTER TABLE ONLY "public"."project_resources"
    ADD CONSTRAINT "project_resources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_sections"
    ADD CONSTRAINT "project_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_share_links"
    ADD CONSTRAINT "project_share_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_share_links"
    ADD CONSTRAINT "project_share_links_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."project_shared_comments"
    ADD CONSTRAINT "project_shared_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_template_members"
    ADD CONSTRAINT "project_template_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_template_members"
    ADD CONSTRAINT "project_template_members_template_id_user_id_key" UNIQUE ("template_id", "user_id");



ALTER TABLE ONLY "public"."project_template_sections"
    ADD CONSTRAINT "project_template_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_template_tasks"
    ADD CONSTRAINT "project_template_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_templates"
    ADD CONSTRAINT "project_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quick_links"
    ADD CONSTRAINT "quick_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."release_notes"
    ADD CONSTRAINT "release_notes_commit_sha_key" UNIQUE ("commit_sha");



ALTER TABLE ONLY "public"."release_notes"
    ADD CONSTRAINT "release_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reporting_sync_alerts"
    ADD CONSTRAINT "reporting_sync_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_id_permission_key_key" UNIQUE ("role_id", "permission_key");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_accounts"
    ADD CONSTRAINT "rtl_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_activities"
    ADD CONSTRAINT "rtl_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_contact_org_mapping"
    ADD CONSTRAINT "rtl_contact_org_mapping_match_field_match_value_key" UNIQUE ("match_field", "match_value");



ALTER TABLE ONLY "public"."rtl_contact_org_mapping"
    ADD CONSTRAINT "rtl_contact_org_mapping_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_contacts"
    ADD CONSTRAINT "rtl_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_firm_settings"
    ADD CONSTRAINT "rtl_firm_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_firm_settings"
    ADD CONSTRAINT "rtl_firm_settings_source_value_key" UNIQUE ("source_value");



ALTER TABLE ONLY "public"."rtl_notes"
    ADD CONSTRAINT "rtl_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_opportunities"
    ADD CONSTRAINT "rtl_opportunities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_reminders"
    ADD CONSTRAINT "rtl_reminders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_reminders"
    ADD CONSTRAINT "rtl_reminders_reminder_type_source_object_id_reminder_date_key" UNIQUE ("reminder_type", "source_object_id", "reminder_date");



ALTER TABLE ONLY "public"."rtl_sync_log"
    ADD CONSTRAINT "rtl_sync_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rtl_sync_state"
    ADD CONSTRAINT "rtl_sync_state_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."sdr_batches"
    ADD CONSTRAINT "sdr_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_email_templates"
    ADD CONSTRAINT "sdr_email_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_firm_staff"
    ADD CONSTRAINT "sdr_firm_staff_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_firms"
    ADD CONSTRAINT "sdr_firms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_known_acquisitions"
    ADD CONSTRAINT "sdr_known_acquisitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_prospect_queues"
    ADD CONSTRAINT "sdr_prospect_queues_partner_user_id_queue_number_key" UNIQUE ("partner_user_id", "queue_number");



ALTER TABLE ONLY "public"."sdr_prospect_queues"
    ADD CONSTRAINT "sdr_prospect_queues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_rule_sets"
    ADD CONSTRAINT "sdr_rule_sets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sdr_seamless_imports"
    ADD CONSTRAINT "sdr_seamless_imports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."software_categories"
    ADD CONSTRAINT "software_categories_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."software_categories"
    ADD CONSTRAINT "software_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."software_products"
    ADD CONSTRAINT "software_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_advisors"
    ADD CONSTRAINT "ssg_advisors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_advisors"
    ADD CONSTRAINT "ssg_advisors_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."ssg_calendar_events"
    ADD CONSTRAINT "ssg_calendar_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_emails"
    ADD CONSTRAINT "ssg_emails_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_engagement_contacts"
    ADD CONSTRAINT "ssg_engagement_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_engagements"
    ADD CONSTRAINT "ssg_engagements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_functions"
    ADD CONSTRAINT "ssg_functions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_insights"
    ADD CONSTRAINT "ssg_insights_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_meetings"
    ADD CONSTRAINT "ssg_meetings_fathom_meeting_id_key" UNIQUE ("fathom_meeting_id");



ALTER TABLE ONLY "public"."ssg_meetings"
    ADD CONSTRAINT "ssg_meetings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_member_assignments"
    ADD CONSTRAINT "ssg_member_assignments_function_id_user_id_key" UNIQUE ("function_id", "user_id");



ALTER TABLE ONLY "public"."ssg_member_assignments"
    ADD CONSTRAINT "ssg_member_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ssg_outcomes"
    ADD CONSTRAINT "ssg_outcomes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_businesses"
    ADD CONSTRAINT "tas_businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_consultant_profiles"
    ADD CONSTRAINT "tas_consultant_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_contacts"
    ADD CONSTRAINT "tas_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_import_logs"
    ADD CONSTRAINT "tas_import_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_inmail_budget"
    ADD CONSTRAINT "tas_inmail_budget_one_per_user_month" UNIQUE ("user_id", "month");



ALTER TABLE ONLY "public"."tas_inmail_budget"
    ADD CONSTRAINT "tas_inmail_budget_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_sequence_steps"
    ADD CONSTRAINT "tas_sequence_steps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_one_active_per_contact" EXCLUDE USING "btree" ("contact_id" WITH =) WHERE (("sequence_status" = 'active'::"text"));



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_attachments"
    ADD CONSTRAINT "task_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_collaborators"
    ADD CONSTRAINT "task_collaborators_pkey" PRIMARY KEY ("task_id", "user_id");



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_custom_field_values"
    ADD CONSTRAINT "task_custom_field_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_custom_field_values"
    ADD CONSTRAINT "task_custom_field_values_task_id_field_id_key" UNIQUE ("task_id", "field_id");



ALTER TABLE ONLY "public"."task_history"
    ADD CONSTRAINT "task_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_notifications"
    ADD CONSTRAINT "task_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_task_id_project_id_key" UNIQUE ("task_id", "project_id");



ALTER TABLE ONLY "public"."task_saved_views"
    ADD CONSTRAINT "task_saved_views_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_ninety_id_unique" UNIQUE ("ninety_id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_categories"
    ADD CONSTRAINT "ticket_categories_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."ticket_categories"
    ADD CONSTRAINT "ticket_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_comments"
    ADD CONSTRAINT "ticket_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_field_definitions"
    ADD CONSTRAINT "ticket_field_definitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_field_values"
    ADD CONSTRAINT "ticket_field_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_field_values"
    ADD CONSTRAINT "ticket_field_values_ticket_id_field_definition_id_key" UNIQUE ("ticket_id", "field_definition_id");



ALTER TABLE ONLY "public"."ticket_messages"
    ADD CONSTRAINT "ticket_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_notifications"
    ADD CONSTRAINT "ticket_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_statuses"
    ADD CONSTRAINT "ticket_statuses_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."ticket_statuses"
    ADD CONSTRAINT "ticket_statuses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."training_courses"
    ADD CONSTRAINT "training_courses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."training_lesson_progress"
    ADD CONSTRAINT "training_lesson_progress_lesson_id_user_id_key" UNIQUE ("lesson_id", "user_id");



ALTER TABLE ONLY "public"."training_lesson_progress"
    ADD CONSTRAINT "training_lesson_progress_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."training_lessons"
    ADD CONSTRAINT "training_lessons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."training_resources"
    ADD CONSTRAINT "training_resources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transition_assessment_submissions"
    ADD CONSTRAINT "transition_assessment_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_home_layouts"
    ADD CONSTRAINT "user_home_layouts_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_role_assignments"
    ADD CONSTRAINT "user_role_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_role_assignments"
    ADD CONSTRAINT "user_role_assignments_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_role_key" UNIQUE ("user_id", "role");



ALTER TABLE ONLY "public"."vendor_contacts"
    ADD CONSTRAINT "vendor_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_pkey" PRIMARY KEY ("id");



CREATE INDEX "bdr_businesses_geocoded_idx" ON "public"."bdr_businesses" USING "btree" ("latitude", "longitude") WHERE (("latitude" IS NOT NULL) AND ("longitude" IS NOT NULL));



CREATE INDEX "bdr_email_templates_user_id_idx" ON "public"."bdr_email_templates" USING "btree" ("user_id");



CREATE INDEX "bdr_email_templates_user_kind_idx" ON "public"."bdr_email_templates" USING "btree" ("user_id", "kind", "sort_order");



CREATE INDEX "bdr_prospects_email_status_idx" ON "public"."bdr_prospects" USING "btree" ("email_status") WHERE ("email_status" IS NOT NULL);



CREATE INDEX "idx_activity_logs_created_at" ON "public"."activity_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_activity_logs_event_category" ON "public"."activity_logs" USING "btree" ("event_category");



CREATE INDEX "idx_activity_logs_event_type" ON "public"."activity_logs" USING "btree" ("event_type");



CREATE INDEX "idx_activity_logs_target" ON "public"."activity_logs" USING "btree" ("target_type", "target_id");



CREATE INDEX "idx_activity_logs_user_id" ON "public"."activity_logs" USING "btree" ("user_id");



CREATE INDEX "idx_bdr_prospects_batch_id" ON "public"."bdr_prospects" USING "btree" ("batch_id");



CREATE INDEX "idx_bdr_prospects_business_id" ON "public"."bdr_prospects" USING "btree" ("business_id");



CREATE INDEX "idx_bdr_prospects_email" ON "public"."bdr_prospects" USING "btree" ("email") WHERE ("email" IS NOT NULL);



CREATE INDEX "idx_bdr_prospects_pool" ON "public"."bdr_prospects" USING "btree" ("is_available", "verdict") WHERE ("is_available" = true);



CREATE INDEX "idx_bp_revenue_drivers_plan" ON "public"."business_plan_revenue_drivers" USING "btree" ("plan_id");



CREATE INDEX "idx_business_plan_checkins_date" ON "public"."business_plan_checkins" USING "btree" ("checkin_date" DESC);



CREATE INDEX "idx_business_plan_checkins_plan" ON "public"."business_plan_checkins" USING "btree" ("plan_id");



CREATE INDEX "idx_business_plans_organization" ON "public"."business_plans" USING "btree" ("organization_id");



CREATE INDEX "idx_business_plans_owner" ON "public"."business_plans" USING "btree" ("owner_id");



CREATE INDEX "idx_business_plans_plan_year" ON "public"."business_plans" USING "btree" ("plan_year");



CREATE INDEX "idx_business_plans_status" ON "public"."business_plans" USING "btree" ("status");



CREATE INDEX "idx_cfd_active" ON "public"."custom_field_definitions" USING "btree" ("is_active");



CREATE INDEX "idx_cfd_created_by" ON "public"."custom_field_definitions" USING "btree" ("created_by");



CREATE INDEX "idx_checkin_assignments_assignee" ON "public"."checkin_assignments" USING "btree" ("assignee_id");



CREATE INDEX "idx_checkin_assignments_manager" ON "public"."checkin_assignments" USING "btree" ("manager_id");



CREATE INDEX "idx_checkin_edit_log_submission" ON "public"."checkin_edit_log" USING "btree" ("submission_id", "edited_at" DESC);



CREATE INDEX "idx_checkin_submissions_assignee" ON "public"."checkin_submissions" USING "btree" ("assignee_id");



CREATE INDEX "idx_checkin_submissions_assignment" ON "public"."checkin_submissions" USING "btree" ("assignment_id");



CREATE INDEX "idx_checkin_submissions_manager" ON "public"."checkin_submissions" USING "btree" ("manager_id");



CREATE INDEX "idx_checkin_submissions_meeting" ON "public"."checkin_submissions" USING "btree" ("meeting_date");



CREATE INDEX "idx_checklist_assignments_deleted_at" ON "public"."checklist_assignments" USING "btree" ("deleted_at");



CREATE INDEX "idx_contact_classifications_classified_at" ON "public"."hubspot_contact_classifications" USING "btree" ("classified_at" DESC);



CREATE INDEX "idx_dashboard_datasets_dashboard" ON "public"."dashboard_datasets" USING "btree" ("dashboard_id");



CREATE INDEX "idx_dashboard_datasets_dataset" ON "public"."dashboard_datasets" USING "btree" ("dataset_id");



CREATE INDEX "idx_datasets_source" ON "public"."datasets" USING "btree" ("data_source_id");



CREATE INDEX "idx_email_activity_log_opportunity" ON "public"."email_activity_log" USING "btree" ("opportunity_id") WHERE ("opportunity_id" IS NOT NULL);



CREATE INDEX "idx_email_activity_prospect" ON "public"."email_activity_log" USING "btree" ("prospect_id");



CREATE INDEX "idx_email_activity_thread" ON "public"."email_activity_log" USING "btree" ("gmail_thread_id");



CREATE INDEX "idx_email_activity_tracking" ON "public"."email_activity_log" USING "btree" ("tracking_pixel_id");



CREATE INDEX "idx_exp_opp_action" ON "public"."expansion_opportunities" USING "btree" ("partner_action");



CREATE INDEX "idx_exp_opp_firm" ON "public"."expansion_opportunities" USING "btree" ("firm");



CREATE INDEX "idx_exp_opp_owner" ON "public"."expansion_opportunities" USING "btree" ("owner_group");



CREATE INDEX "idx_exp_opp_research" ON "public"."expansion_opportunities" USING "btree" ("research_status");



CREATE INDEX "idx_exp_opp_score" ON "public"."expansion_opportunities" USING "btree" ("score" DESC);



CREATE INDEX "idx_exp_opp_tier" ON "public"."expansion_opportunities" USING "btree" ("tier_recommendation");



CREATE INDEX "idx_exp_opp_type" ON "public"."expansion_opportunities" USING "btree" ("expansion_type");



CREATE INDEX "idx_expansion_email_templates_user" ON "public"."expansion_email_templates" USING "btree" ("user_id", "kind", "sort_order");



CREATE INDEX "idx_expansion_opportunities_firm_key" ON "public"."expansion_opportunities" USING "btree" ("firm_key");



CREATE INDEX "idx_expansion_research_runs_firm_key" ON "public"."expansion_research_runs" USING "btree" ("firm_key");



CREATE INDEX "idx_expansion_research_runs_opp" ON "public"."expansion_research_runs" USING "btree" ("opportunity_id");



CREATE INDEX "idx_expansion_research_runs_ran_at" ON "public"."expansion_research_runs" USING "btree" ("ran_at" DESC);



CREATE INDEX "idx_firm_software_costs_assignment" ON "public"."firm_software_costs" USING "btree" ("firm_software_id");



CREATE INDEX "idx_firm_software_organization" ON "public"."firm_software" USING "btree" ("organization_id");



CREATE INDEX "idx_firm_software_product" ON "public"."firm_software" USING "btree" ("product_id");



CREATE INDEX "idx_firm_software_renewal" ON "public"."firm_software" USING "btree" ("renewal_date") WHERE ("renewal_date" IS NOT NULL);



CREATE INDEX "idx_hcfv_entity" ON "public"."hris_custom_field_values" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_hcfv_field" ON "public"."hris_custom_field_values" USING "btree" ("field_id");



CREATE INDEX "idx_hlat_request" ON "public"."hris_leave_action_tokens" USING "btree" ("leave_request_id");



CREATE INDEX "idx_hris_benefit_enrollments_employee" ON "public"."hris_benefit_enrollments" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_benefit_enrollments_plan" ON "public"."hris_benefit_enrollments" USING "btree" ("plan_id");



CREATE INDEX "idx_hris_compensation_employee" ON "public"."hris_compensation" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_emergency_contacts_employee" ON "public"."hris_emergency_contacts" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_employee_checklists_employee" ON "public"."hris_employee_checklists" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_leave_balances_employee" ON "public"."hris_leave_balances" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_leave_requests_employee" ON "public"."hris_leave_requests" USING "btree" ("employee_id");



CREATE INDEX "idx_hris_leave_requests_status" ON "public"."hris_leave_requests" USING "btree" ("status");



CREATE INDEX "idx_hris_template_items_template" ON "public"."hris_checklist_template_items" USING "btree" ("template_id");



CREATE INDEX "idx_hs_companies_state" ON "public"."hs_companies" USING "btree" ("state") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_contacts_email" ON "public"."hs_contacts" USING "btree" ("email") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_createdate" ON "public"."hs_deals" USING "btree" ("createdate" DESC) WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_dealstage" ON "public"."hs_deals" USING "btree" ("dealstage") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_opportunity_source" ON "public"."hs_deals" USING "btree" ("opportunity_source") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_owner" ON "public"."hs_deals" USING "btree" ("hubspot_owner_id") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_pipeline" ON "public"."hs_deals" USING "btree" ("pipeline") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_deals_probability" ON "public"."hs_deals" USING "btree" ("probability") WHERE ((NOT "deleted") AND ("probability" IS NOT NULL));



CREATE INDEX "idx_hs_eng_company" ON "public"."hubspot_engagements" USING "btree" ("hubspot_company_id", "occurred_at" DESC);



CREATE INDEX "idx_hs_eng_contact" ON "public"."hubspot_engagements" USING "btree" ("hubspot_contact_id", "occurred_at" DESC);



CREATE INDEX "idx_hs_eng_occurred" ON "public"."hubspot_engagements" USING "btree" ("occurred_at" DESC);



CREATE INDEX "idx_hs_engagements_contact_ids" ON "public"."hs_engagements" USING "gin" ("associated_contact_ids");



CREATE INDEX "idx_hs_engagements_deal_ids" ON "public"."hs_engagements" USING "gin" ("associated_deal_ids");



CREATE INDEX "idx_hs_engagements_lastmodified" ON "public"."hs_engagements" USING "btree" ("hs_lastmodifieddate" DESC) WHERE (NOT "deleted");



CREATE INDEX "idx_hs_engagements_owner_time" ON "public"."hs_engagements" USING "btree" ("hubspot_owner_id", "hs_timestamp" DESC) WHERE (NOT "deleted");



CREATE INDEX "idx_hs_engagements_type_time" ON "public"."hs_engagements" USING "btree" ("engagement_type", "hs_timestamp" DESC) WHERE (NOT "deleted");



CREATE INDEX "idx_hs_owners_email" ON "public"."hs_owners" USING "btree" ("email") WHERE (NOT "deleted");



CREATE INDEX "idx_hs_sync_log_started" ON "public"."hs_sync_log" USING "btree" ("started_at" DESC);



CREATE INDEX "idx_hub_api_tokens_hash" ON "public"."hub_api_tokens" USING "btree" ("token_hash");



CREATE INDEX "idx_hubspot_engagement_contacts_contact" ON "public"."hubspot_engagement_contacts" USING "btree" ("hubspot_contact_id");



CREATE INDEX "idx_hubspot_engagement_contacts_engagement" ON "public"."hubspot_engagement_contacts" USING "btree" ("hubspot_engagement_id");



CREATE INDEX "idx_inbox_user_bookmarked" ON "public"."inbox_items" USING "btree" ("user_id", "bookmarked") WHERE ("bookmarked" = true);



CREATE INDEX "idx_inbox_user_created" ON "public"."inbox_items" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_inbox_user_read" ON "public"."inbox_items" USING "btree" ("user_id", "read", "archived");



CREATE INDEX "idx_inbox_user_target" ON "public"."inbox_items" USING "btree" ("user_id", "target_type", "target_id");



CREATE INDEX "idx_job_description_versions_jd" ON "public"."job_description_versions" USING "btree" ("job_description_id");



CREATE INDEX "idx_job_descriptions_organization" ON "public"."job_descriptions" USING "btree" ("organization_id");



CREATE INDEX "idx_kb_article_page_links_page_key" ON "public"."knowledge_base_article_page_links" USING "btree" ("page_key");



CREATE INDEX "idx_nine_box_scores_employee" ON "public"."nine_box_scores" USING "btree" ("employee_id", "created_at" DESC);



CREATE INDEX "idx_nine_box_scores_scored_by" ON "public"."nine_box_scores" USING "btree" ("scored_by");



CREATE INDEX "idx_notifications_user_created" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_notifications_user_read" ON "public"."notifications" USING "btree" ("user_id", "read");



CREATE INDEX "idx_pcf_field" ON "public"."project_custom_fields" USING "btree" ("field_id");



CREATE INDEX "idx_pcf_project" ON "public"."project_custom_fields" USING "btree" ("project_id", "display_order");



CREATE INDEX "idx_permissions_key" ON "public"."permissions" USING "btree" ("key");



CREATE INDEX "idx_pfa_field" ON "public"."project_field_aggregations" USING "btree" ("field_id");



CREATE INDEX "idx_pfa_project" ON "public"."project_field_aggregations" USING "btree" ("project_id", "display_order");



CREATE INDEX "idx_pinned_items_user" ON "public"."pinned_items" USING "btree" ("user_id", "sort_order");



CREATE UNIQUE INDEX "idx_prep_calendar_events_user_provider_external" ON "public"."prep_calendar_events" USING "btree" ("provider", "external_id", "user_id");



CREATE INDEX "idx_prep_calendar_events_user_resolved" ON "public"."prep_calendar_events" USING "btree" ("user_id", "resolved_kind", "resolved_ref_id");



CREATE INDEX "idx_prep_calendar_events_user_start" ON "public"."prep_calendar_events" USING "btree" ("user_id", "start_time" DESC);



CREATE INDEX "idx_prep_reminder_prefs_autosync" ON "public"."prep_reminder_preferences" USING "btree" ("user_id") WHERE ("auto_sync_enabled" OR "enabled");



CREATE INDEX "idx_prep_reminder_prefs_enabled" ON "public"."prep_reminder_preferences" USING "btree" ("user_id") WHERE "enabled";



CREATE INDEX "idx_profiles_invite_token" ON "public"."profiles" USING "btree" ("invite_token") WHERE ("invite_token" IS NOT NULL);



CREATE INDEX "idx_profiles_manager_id" ON "public"."profiles" USING "btree" ("manager_id");



CREATE INDEX "idx_profiles_role_id" ON "public"."profiles" USING "btree" ("role_id");



CREATE INDEX "idx_project_share_links_project" ON "public"."project_share_links" USING "btree" ("project_id", "created_at" DESC);



CREATE INDEX "idx_project_shared_comments_project" ON "public"."project_shared_comments" USING "btree" ("project_id", "created_at" DESC);



CREATE INDEX "idx_release_notes_landed_at" ON "public"."release_notes" USING "btree" ("landed_at" DESC);



CREATE INDEX "idx_reporting_sync_alerts_fired_at" ON "public"."reporting_sync_alerts" USING "btree" ("fired_at" DESC);



CREATE INDEX "idx_role_permissions_permission_key" ON "public"."role_permissions" USING "btree" ("permission_key");



CREATE INDEX "idx_role_permissions_role_id" ON "public"."role_permissions" USING "btree" ("role_id");



CREATE INDEX "idx_rtl_accounts_contact" ON "public"."rtl_accounts" USING "btree" ("contact_id");



CREATE INDEX "idx_rtl_activities_completed" ON "public"."rtl_activities" USING "btree" ("completed");



CREATE INDEX "idx_rtl_activities_contact" ON "public"."rtl_activities" USING "btree" ("contact_id");



CREATE INDEX "idx_rtl_activities_start" ON "public"."rtl_activities" USING "btree" ("start_date");



CREATE INDEX "idx_rtl_contacts_org" ON "public"."rtl_contacts" USING "btree" ("organization_id");



CREATE INDEX "idx_rtl_contacts_referred_by_user" ON "public"."rtl_contacts" USING "btree" ("referred_by_user_id");



CREATE INDEX "idx_rtl_contacts_source" ON "public"."rtl_contacts" USING "btree" ("source");



CREATE INDEX "idx_rtl_notes_contact" ON "public"."rtl_notes" USING "btree" ("contact_id");



CREATE INDEX "idx_rtl_notes_created" ON "public"."rtl_notes" USING "btree" ("redtail_created_at" DESC);



CREATE INDEX "idx_rtl_opportunities_contact" ON "public"."rtl_opportunities" USING "btree" ("contact_id");



CREATE INDEX "idx_rtl_reminders_contact" ON "public"."rtl_reminders" USING "btree" ("contact_id");



CREATE INDEX "idx_rtl_reminders_date" ON "public"."rtl_reminders" USING "btree" ("reminder_date");



CREATE INDEX "idx_sdr_contacts_email_status_ready" ON "public"."sdr_contacts" USING "btree" ("firm_id") WHERE ("email_status" = 'ready'::"text");



CREATE INDEX "idx_sdr_contacts_excluded_from_outreach" ON "public"."sdr_contacts" USING "btree" ("excluded_from_outreach") WHERE ("excluded_from_outreach" = true);



CREATE INDEX "idx_sdr_contacts_firm_id" ON "public"."sdr_contacts" USING "btree" ("firm_id");



CREATE INDEX "idx_sdr_contacts_hubspot_contact_id" ON "public"."sdr_contacts" USING "btree" ("hubspot_contact_id") WHERE ("hubspot_contact_id" IS NOT NULL);



CREATE INDEX "idx_sdr_email_templates_user_active" ON "public"."sdr_email_templates" USING "btree" ("user_id", "kind", "active", "sort_order");



CREATE INDEX "idx_sdr_firm_staff_firm_id" ON "public"."sdr_firm_staff" USING "btree" ("firm_id");



CREATE INDEX "idx_sdr_firms_hubspot_company_id" ON "public"."sdr_firms" USING "btree" ("hubspot_company_id") WHERE ("hubspot_company_id" IS NOT NULL);



CREATE INDEX "idx_sdr_firms_pool_eligible" ON "public"."sdr_firms" USING "btree" ("state", "partner_count") WHERE (("is_available" IS TRUE) AND ("partner_action" IS NULL) AND ("hubspot_owner_email" IS NULL));



CREATE INDEX "idx_seamless_company_state" ON "public"."sdr_seamless_imports" USING "btree" ("Company State Abbr");



CREATE UNIQUE INDEX "idx_seamless_imports_unique_person" ON "public"."sdr_seamless_imports" USING "btree" ("lower"(TRIM(BOTH FROM "First Name_2")), "lower"(TRIM(BOTH FROM "Last Name_2")), "lower"(TRIM(BOTH FROM "Company Name")));



CREATE INDEX "idx_seamless_processed" ON "public"."sdr_seamless_imports" USING "btree" ("processed");



CREATE INDEX "idx_seamless_website" ON "public"."sdr_seamless_imports" USING "btree" ("Website");



CREATE INDEX "idx_software_products_category" ON "public"."software_products" USING "btree" ("category_id");



CREATE INDEX "idx_ssg_advisors_user" ON "public"."ssg_advisors" USING "btree" ("user_id");



CREATE INDEX "idx_ssg_calendar_events_engagement_start" ON "public"."ssg_calendar_events" USING "btree" ("engagement_id", "start_time" DESC);



CREATE UNIQUE INDEX "idx_ssg_calendar_events_provider_external" ON "public"."ssg_calendar_events" USING "btree" ("provider", "external_id");



CREATE INDEX "idx_ssg_calendar_events_start_time" ON "public"."ssg_calendar_events" USING "btree" ("start_time");



CREATE INDEX "idx_ssg_emails_engagement_sent" ON "public"."ssg_emails" USING "btree" ("engagement_id", "sent_at" DESC);



CREATE UNIQUE INDEX "idx_ssg_emails_provider_message" ON "public"."ssg_emails" USING "btree" ("provider", "gmail_message_id");



CREATE INDEX "idx_ssg_emails_thread" ON "public"."ssg_emails" USING "btree" ("gmail_thread_id") WHERE ("gmail_thread_id" IS NOT NULL);



CREATE INDEX "idx_ssg_engagement_contacts_email_lower" ON "public"."ssg_engagement_contacts" USING "btree" ("lower"("email")) WHERE ("email" IS NOT NULL);



CREATE INDEX "idx_ssg_engagement_contacts_engagement" ON "public"."ssg_engagement_contacts" USING "btree" ("engagement_id");



CREATE INDEX "idx_ssg_engagements_member_firm" ON "public"."ssg_engagements" USING "btree" ("member_firm_id");



CREATE INDEX "idx_ssg_engagements_primary_advisor" ON "public"."ssg_engagements" USING "btree" ("primary_advisor_id");



CREATE INDEX "idx_ssg_engagements_relationship_manager" ON "public"."ssg_engagements" USING "btree" ("relationship_manager_id");



CREATE INDEX "idx_ssg_engagements_service_line" ON "public"."ssg_engagements" USING "btree" ("service_line");



CREATE INDEX "idx_ssg_engagements_status" ON "public"."ssg_engagements" USING "btree" ("status");



CREATE INDEX "idx_ssg_insights_engagement" ON "public"."ssg_insights" USING "btree" ("engagement_id");



CREATE INDEX "idx_ssg_insights_meeting" ON "public"."ssg_insights" USING "btree" ("meeting_id");



CREATE INDEX "idx_ssg_insights_status" ON "public"."ssg_insights" USING "btree" ("status");



CREATE INDEX "idx_ssg_meetings_calendar_event" ON "public"."ssg_meetings" USING "btree" ("calendar_event_id") WHERE ("calendar_event_id" IS NOT NULL);



CREATE INDEX "idx_ssg_meetings_engagement" ON "public"."ssg_meetings" USING "btree" ("engagement_id");



CREATE INDEX "idx_ssg_meetings_engagement_host" ON "public"."ssg_meetings" USING "btree" ("engagement_id", "host_user_id");



CREATE INDEX "idx_ssg_meetings_recorded_at" ON "public"."ssg_meetings" USING "btree" ("recorded_at" DESC);



CREATE INDEX "idx_ssg_outcomes_engagement" ON "public"."ssg_outcomes" USING "btree" ("engagement_id");



CREATE INDEX "idx_task_collaborators_task_id" ON "public"."task_collaborators" USING "btree" ("task_id");



CREATE INDEX "idx_task_collaborators_user_id" ON "public"."task_collaborators" USING "btree" ("user_id");



CREATE INDEX "idx_task_comments_task_created" ON "public"."task_comments" USING "btree" ("task_id", "created_at");



CREATE INDEX "idx_tasks_ninety_id" ON "public"."tasks" USING "btree" ("ninety_id");



CREATE INDEX "idx_tasks_parent_task_id" ON "public"."tasks" USING "btree" ("parent_task_id");



CREATE INDEX "idx_tasks_recurrence_parent" ON "public"."tasks" USING "btree" ("recurrence_parent_id") WHERE ("recurrence_parent_id" IS NOT NULL);



CREATE INDEX "idx_tasks_source_reference" ON "public"."tasks" USING "btree" ("source_type", "source_reference_id") WHERE ("source_reference_id" IS NOT NULL);



CREATE INDEX "idx_tasks_sync_source" ON "public"."tasks" USING "btree" ("sync_source");



CREATE INDEX "idx_tcfv_field_date" ON "public"."task_custom_field_values" USING "btree" ("field_id", "value_date");



CREATE INDEX "idx_tcfv_field_number" ON "public"."task_custom_field_values" USING "btree" ("field_id", "value_number");



CREATE INDEX "idx_tcfv_field_text" ON "public"."task_custom_field_values" USING "btree" ("field_id", "value_text");



CREATE INDEX "idx_tcfv_task" ON "public"."task_custom_field_values" USING "btree" ("task_id");



CREATE INDEX "idx_ticket_messages_ticket_created" ON "public"."ticket_messages" USING "btree" ("ticket_id", "created_at");



CREATE INDEX "idx_tickets_assigned_to" ON "public"."tickets" USING "btree" ("assigned_to");



CREATE INDEX "idx_tickets_owner_id" ON "public"."tickets" USING "btree" ("owner_id");



CREATE UNIQUE INDEX "idx_tickets_sequential_id" ON "public"."tickets" USING "btree" ("sequential_id");



CREATE INDEX "idx_tpm_project_section" ON "public"."task_project_memberships" USING "btree" ("project_id", "section_id", "position");



CREATE INDEX "idx_tpm_section" ON "public"."task_project_memberships" USING "btree" ("section_id") WHERE ("section_id" IS NOT NULL);



CREATE INDEX "idx_tpm_task" ON "public"."task_project_memberships" USING "btree" ("task_id");



CREATE INDEX "idx_training_courses_not_deleted" ON "public"."training_courses" USING "btree" ("id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_training_courses_status_sort" ON "public"."training_courses" USING "btree" ("status", "sort_order");



CREATE INDEX "idx_training_lesson_progress_user" ON "public"."training_lesson_progress" USING "btree" ("user_id");



CREATE INDEX "idx_training_lessons_course" ON "public"."training_lessons" USING "btree" ("course_id", "sort_order");



CREATE INDEX "idx_training_resources_course" ON "public"."training_resources" USING "btree" ("course_id", "sort_order");



CREATE INDEX "idx_training_resources_lesson" ON "public"."training_resources" USING "btree" ("lesson_id");



CREATE INDEX "idx_transition_submissions_created_at" ON "public"."transition_assessment_submissions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_transition_submissions_email" ON "public"."transition_assessment_submissions" USING "btree" ("email");



CREATE INDEX "idx_user_role_assignments_role_id" ON "public"."user_role_assignments" USING "btree" ("role_id");



CREATE INDEX "idx_user_role_assignments_user_id" ON "public"."user_role_assignments" USING "btree" ("user_id");



CREATE UNIQUE INDEX "laa_agreements_log_partner_code_unique" ON "public"."laa_agreements_log" USING "btree" ("partner_code") WHERE ("partner_code" IS NOT NULL);



CREATE INDEX "oauth_access_tokens_expires_at_idx" ON "public"."oauth_access_tokens" USING "btree" ("expires_at");



CREATE INDEX "oauth_access_tokens_user_id_idx" ON "public"."oauth_access_tokens" USING "btree" ("user_id");



CREATE INDEX "oauth_authorization_codes_expires_at_idx" ON "public"."oauth_authorization_codes" USING "btree" ("expires_at");



CREATE INDEX "oauth_authorization_codes_user_id_idx" ON "public"."oauth_authorization_codes" USING "btree" ("user_id");



CREATE INDEX "oauth_refresh_tokens_expires_at_idx" ON "public"."oauth_refresh_tokens" USING "btree" ("expires_at");



CREATE INDEX "oauth_refresh_tokens_user_client_idx" ON "public"."oauth_refresh_tokens" USING "btree" ("user_id", "client_id");



CREATE INDEX "sdr_email_templates_rule_set_id_idx" ON "public"."sdr_email_templates" USING "btree" ("rule_set_id");



CREATE UNIQUE INDEX "sdr_rule_sets_one_active_per_user" ON "public"."sdr_rule_sets" USING "btree" ("user_id") WHERE ("is_active" = true);



CREATE INDEX "sdr_rule_sets_user_id_idx" ON "public"."sdr_rule_sets" USING "btree" ("user_id");



CREATE UNIQUE INDEX "software_products_name_lower_key" ON "public"."software_products" USING "btree" ("lower"("name"));



CREATE INDEX "tas_businesses_available_idx" ON "public"."tas_businesses" USING "btree" ("is_available");



CREATE INDEX "tas_businesses_icp_tier_idx" ON "public"."tas_businesses" USING "btree" ("tas_icp_tier");



CREATE INDEX "tas_businesses_icp_track_idx" ON "public"."tas_businesses" USING "btree" ("icp_track");



CREATE INDEX "tas_businesses_state_idx" ON "public"."tas_businesses" USING "btree" ("location_state");



CREATE INDEX "tas_contacts_business_id_idx" ON "public"."tas_contacts" USING "btree" ("business_id");



CREATE INDEX "tas_contacts_track_idx" ON "public"."tas_contacts" USING "btree" ("sequence_track");



CREATE INDEX "tas_contacts_verdict_idx" ON "public"."tas_contacts" USING "btree" ("verdict");



CREATE INDEX "tas_import_logs_consultant_idx" ON "public"."tas_import_logs" USING "btree" ("consultant_profile_id", "imported_at" DESC);



CREATE INDEX "tas_sequences_assigned_idx" ON "public"."tas_sequences" USING "btree" ("assigned_to");



CREATE INDEX "tas_sequences_contact_id_idx" ON "public"."tas_sequences" USING "btree" ("contact_id");



CREATE INDEX "tas_sequences_import_log_idx" ON "public"."tas_sequences" USING "btree" ("import_log_id") WHERE ("import_log_id" IS NOT NULL);



CREATE INDEX "tas_sequences_needs_review_idx" ON "public"."tas_sequences" USING "btree" ("needs_review") WHERE ("needs_review" = true);



CREATE INDEX "tas_sequences_next_action_idx" ON "public"."tas_sequences" USING "btree" ("next_action_date") WHERE ("sequence_status" = 'active'::"text");



CREATE INDEX "tas_sequences_queue_status_idx" ON "public"."tas_sequences" USING "btree" ("queue_status");



CREATE INDEX "tas_sequences_referral_tier_idx" ON "public"."tas_sequences" USING "btree" ("referral_tier");



CREATE INDEX "tas_sequences_status_idx" ON "public"."tas_sequences" USING "btree" ("sequence_status");



CREATE INDEX "tas_steps_channel_idx" ON "public"."tas_sequence_steps" USING "btree" ("channel");



CREATE INDEX "tas_steps_completed_at_idx" ON "public"."tas_sequence_steps" USING "btree" ("completed_at");



CREATE INDEX "tas_steps_contact_id_idx" ON "public"."tas_sequence_steps" USING "btree" ("contact_id");



CREATE INDEX "tas_steps_sequence_id_idx" ON "public"."tas_sequence_steps" USING "btree" ("sequence_id");



CREATE INDEX "tas_steps_status_idx" ON "public"."tas_sequence_steps" USING "btree" ("status");



CREATE UNIQUE INDEX "task_saved_views_unique_system_view" ON "public"."task_saved_views" USING "btree" ("user_id", "context", "name") WHERE ("is_system" = true);



COMMENT ON INDEX "public"."task_saved_views_unique_system_view" IS 'Prevents duplicate system views (My Tasks / Assigned by Me / Team) from the race-prone first-load seed in useSavedViews.ts. Partial (is_system = true) so user-created views stay unconstrained. A concurrent losing seed fails with 23505, which the app swallows.';



CREATE OR REPLACE TRIGGER "bdr_email_templates_set_updated_at" BEFORE UPDATE ON "public"."bdr_email_templates" FOR EACH ROW EXECUTE FUNCTION "public"."bdr_email_templates_set_updated_at"();



CREATE OR REPLACE TRIGGER "inbox_comment_mention_trigger" AFTER INSERT ON "public"."comment_mentions" FOR EACH ROW EXECUTE FUNCTION "public"."inbox_on_comment_mention"();



CREATE OR REPLACE TRIGGER "inbox_project_change_trigger" AFTER UPDATE ON "public"."projects" FOR EACH ROW EXECUTE FUNCTION "public"."inbox_on_project_change"();



CREATE OR REPLACE TRIGGER "inbox_task_change_trigger" AFTER INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."inbox_on_task_change"();



CREATE OR REPLACE TRIGGER "inbox_task_comment_trigger" AFTER INSERT ON "public"."task_comments" FOR EACH ROW EXECUTE FUNCTION "public"."inbox_on_task_comment"();



CREATE OR REPLACE TRIGGER "prevent_tag_self_escalation_trigger" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_tag_self_escalation"();



CREATE OR REPLACE TRIGGER "rtl_firm_settings_updated_at" BEFORE UPDATE ON "public"."rtl_firm_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_rtl_firm_settings_updated_at"();



CREATE OR REPLACE TRIGGER "sdr_rule_sets_updated_at" BEFORE UPDATE ON "public"."sdr_rule_sets" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_sdr_rule_sets"();



CREATE OR REPLACE TRIGGER "tas_businesses_updated_at" BEFORE UPDATE ON "public"."tas_businesses" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "tas_contacts_updated_at" BEFORE UPDATE ON "public"."tas_contacts" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "tas_inmail_budget_updated_at" BEFORE UPDATE ON "public"."tas_inmail_budget" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "tas_sequences_updated_at" BEFORE UPDATE ON "public"."tas_sequences" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "tasks_updated_at" BEFORE UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."update_task_updated_at"();



CREATE OR REPLACE TRIGGER "ticket_updated_at" BEFORE UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."update_ticket_updated_at"();



CREATE OR REPLACE TRIGGER "trg_auto_add_reassigned_collaborator" AFTER UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."auto_add_reassigned_collaborator"();



CREATE OR REPLACE TRIGGER "trg_auto_add_task_collaborators" AFTER INSERT ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."auto_add_task_collaborators"();



CREATE OR REPLACE TRIGGER "trg_auto_complete_batch" AFTER UPDATE OF "partner_action" ON "public"."bdr_prospects" FOR EACH ROW EXECUTE FUNCTION "public"."auto_complete_batch"();



CREATE OR REPLACE TRIGGER "trg_cfd_touch" BEFORE UPDATE ON "public"."custom_field_definitions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_dashboards_touch" BEFORE UPDATE ON "public"."dashboards" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_data_sources_touch" BEFORE UPDATE ON "public"."data_sources" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_datasets_touch" BEFORE UPDATE ON "public"."datasets" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_documents_updated_at" BEFORE UPDATE ON "public"."documents" FOR EACH ROW EXECUTE FUNCTION "public"."update_document_updated_at"();



CREATE OR REPLACE TRIGGER "trg_expansion_email_templates_touch" BEFORE UPDATE ON "public"."expansion_email_templates" FOR EACH ROW EXECUTE FUNCTION "public"."tg_expansion_email_templates_touch"();



CREATE OR REPLACE TRIGGER "trg_firm_software_costs_touch" BEFORE UPDATE ON "public"."firm_software_costs" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_firm_software_touch" BEFORE UPDATE ON "public"."firm_software" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_hcfv_touch" BEFORE UPDATE ON "public"."hris_custom_field_values" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_hris_apply_leave_balance" AFTER UPDATE OF "status" ON "public"."hris_leave_requests" FOR EACH ROW EXECUTE FUNCTION "public"."hris_apply_leave_balance"();



CREATE OR REPLACE TRIGGER "trg_hris_default_employee_number" BEFORE INSERT ON "public"."hris_employee_details" FOR EACH ROW EXECUTE FUNCTION "public"."hris_default_employee_number"();



CREATE OR REPLACE TRIGGER "trg_job_descriptions_touch" BEFORE UPDATE ON "public"."job_descriptions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_notify_task_assigned" AFTER INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."notify_task_assigned"();



CREATE OR REPLACE TRIGGER "trg_notify_ticket_assigned" AFTER UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."notify_ticket_assigned"();



CREATE OR REPLACE TRIGGER "trg_notify_ticket_created" AFTER INSERT ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."notify_ticket_created"();



CREATE OR REPLACE TRIGGER "trg_notify_ticket_owner_changed" AFTER UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."notify_ticket_owner_changed"();



CREATE OR REPLACE TRIGGER "trg_notify_ticket_status_changed" AFTER UPDATE ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."notify_ticket_status_changed"();



CREATE OR REPLACE TRIGGER "trg_pfa_touch" BEFORE UPDATE ON "public"."project_field_aggregations" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sdr_email_templates_updated_at" BEFORE UPDATE ON "public"."sdr_email_templates" FOR EACH ROW EXECUTE FUNCTION "public"."sdr_email_templates_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_set_ticket_defaults" BEFORE INSERT ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."set_ticket_defaults"();



CREATE OR REPLACE TRIGGER "trg_set_ticket_sequential_id" BEFORE INSERT ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."set_ticket_sequential_id"();



CREATE OR REPLACE TRIGGER "trg_software_products_touch" BEFORE UPDATE ON "public"."software_products" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_tcfv_touch" BEFORE UPDATE ON "public"."task_custom_field_values" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_training_courses_touch" BEFORE UPDATE ON "public"."training_courses" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_training_lessons_touch" BEFORE UPDATE ON "public"."training_lessons" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_validate_nine_box_score" BEFORE INSERT ON "public"."nine_box_scores" FOR EACH ROW EXECUTE FUNCTION "public"."validate_nine_box_score"();



CREATE OR REPLACE TRIGGER "update_task_saved_views_updated_at" BEFORE UPDATE ON "public"."task_saved_views" FOR EACH ROW EXECUTE FUNCTION "public"."update_task_updated_at"();



CREATE OR REPLACE TRIGGER "validate_notification_type_trigger" BEFORE INSERT OR UPDATE ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."validate_notification_type"();



CREATE OR REPLACE TRIGGER "validate_project_status_trigger" BEFORE INSERT OR UPDATE ON "public"."projects" FOR EACH ROW EXECUTE FUNCTION "public"."validate_project_status"();



CREATE OR REPLACE TRIGGER "validate_task_fields_trigger" BEFORE INSERT OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."validate_task_fields"();



ALTER TABLE ONLY "public"."bdr_batches"
    ADD CONSTRAINT "bdr_batches_partner_user_id_fkey" FOREIGN KEY ("partner_user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."bdr_business_people"
    ADD CONSTRAINT "bdr_business_people_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."bdr_businesses"("id");



ALTER TABLE ONLY "public"."bdr_email_templates"
    ADD CONSTRAINT "bdr_email_templates_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bdr_prospects"
    ADD CONSTRAINT "bdr_prospects_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."bdr_batches"("id");



ALTER TABLE ONLY "public"."bdr_prospects"
    ADD CONSTRAINT "bdr_prospects_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."bdr_businesses"("id");



ALTER TABLE ONLY "public"."bdr_prospects"
    ADD CONSTRAINT "bdr_prospects_draft_generated_by_fkey" FOREIGN KEY ("draft_generated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."business_plan_checkins"
    ADD CONSTRAINT "business_plan_checkins_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_plan_checkins"
    ADD CONSTRAINT "business_plan_checkins_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."business_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_plan_revenue_drivers"
    ADD CONSTRAINT "business_plan_revenue_drivers_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."business_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_plans"
    ADD CONSTRAINT "business_plans_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."business_plans"
    ADD CONSTRAINT "business_plans_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."business_plans"
    ADD CONSTRAINT "business_plans_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."checkin_assignments"
    ADD CONSTRAINT "checkin_assignments_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."checkin_assignments"
    ADD CONSTRAINT "checkin_assignments_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."checkin_assignments"
    ADD CONSTRAINT "checkin_assignments_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."checkin_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checkin_edit_log"
    ADD CONSTRAINT "checkin_edit_log_edited_by_fkey" FOREIGN KEY ("edited_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checkin_edit_log"
    ADD CONSTRAINT "checkin_edit_log_submission_id_fkey" FOREIGN KEY ("submission_id") REFERENCES "public"."checkin_submissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checkin_submissions"
    ADD CONSTRAINT "checkin_submissions_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."checkin_submissions"
    ADD CONSTRAINT "checkin_submissions_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."checkin_assignments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checkin_submissions"
    ADD CONSTRAINT "checkin_submissions_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."checkin_templates"
    ADD CONSTRAINT "checkin_templates_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_deleted_by_fkey" FOREIGN KEY ("deleted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."checklist_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_assignments"
    ADD CONSTRAINT "checklist_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_custom_items"
    ADD CONSTRAINT "checklist_custom_items_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."checklist_assignments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_item_overrides"
    ADD CONSTRAINT "checklist_item_overrides_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."checklist_assignments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_item_overrides"
    ADD CONSTRAINT "checklist_item_overrides_checklist_item_id_fkey" FOREIGN KEY ("checklist_item_id") REFERENCES "public"."checklist_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."checklist_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_progress"
    ADD CONSTRAINT "checklist_progress_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."checklist_assignments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_progress"
    ADD CONSTRAINT "checklist_progress_checklist_item_id_fkey" FOREIGN KEY ("checklist_item_id") REFERENCES "public"."checklist_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_progress"
    ADD CONSTRAINT "checklist_progress_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."checklist_templates"
    ADD CONSTRAINT "checklist_templates_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comment_mentions"
    ADD CONSTRAINT "comment_mentions_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."task_comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_mentions"
    ADD CONSTRAINT "comment_mentions_mentioned_user_id_fkey" FOREIGN KEY ("mentioned_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."custom_field_definitions"
    ADD CONSTRAINT "custom_field_definitions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."custom_roles"
    ADD CONSTRAINT "custom_roles_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."dashboard_access"
    ADD CONSTRAINT "dashboard_access_dashboard_id_fkey" FOREIGN KEY ("dashboard_id") REFERENCES "public"."dashboards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dashboard_datasets"
    ADD CONSTRAINT "dashboard_datasets_dashboard_id_fkey" FOREIGN KEY ("dashboard_id") REFERENCES "public"."dashboards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dashboard_datasets"
    ADD CONSTRAINT "dashboard_datasets_dataset_id_fkey" FOREIGN KEY ("dataset_id") REFERENCES "public"."datasets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dataset_access"
    ADD CONSTRAINT "dataset_access_dataset_id_fkey" FOREIGN KEY ("dataset_id") REFERENCES "public"."datasets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."datasets"
    ADD CONSTRAINT "datasets_data_source_id_fkey" FOREIGN KEY ("data_source_id") REFERENCES "public"."data_sources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_folders"
    ADD CONSTRAINT "document_folders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."document_folders"
    ADD CONSTRAINT "document_folders_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."document_folders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."document_notifications"
    ADD CONSTRAINT "document_notifications_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_notifications"
    ADD CONSTRAINT "document_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_folder_id_fkey" FOREIGN KEY ("folder_id") REFERENCES "public"."document_folders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_granted_to_org_id_fkey" FOREIGN KEY ("granted_to_org_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_permissions"
    ADD CONSTRAINT "document_permissions_granted_to_user_id_fkey" FOREIGN KEY ("granted_to_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_folder_id_fkey" FOREIGN KEY ("folder_id") REFERENCES "public"."document_folders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."document_stars"
    ADD CONSTRAINT "document_stars_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."document_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_folder_id_fkey" FOREIGN KEY ("folder_id") REFERENCES "public"."document_folders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_activity_log"
    ADD CONSTRAINT "email_activity_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_connections"
    ADD CONSTRAINT "email_connections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expansion_email_templates"
    ADD CONSTRAINT "expansion_email_templates_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expansion_opportunities"
    ADD CONSTRAINT "expansion_opportunities_draft_generated_by_fkey" FOREIGN KEY ("draft_generated_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."expansion_opportunities"
    ADD CONSTRAINT "expansion_opportunities_last_researched_by_fkey" FOREIGN KEY ("last_researched_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."expansion_research_runs"
    ADD CONSTRAINT "expansion_research_runs_opportunity_id_fkey" FOREIGN KEY ("opportunity_id") REFERENCES "public"."expansion_opportunities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."expansion_research_runs"
    ADD CONSTRAINT "expansion_research_runs_ran_by_fkey" FOREIGN KEY ("ran_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."firm_software_costs"
    ADD CONSTRAINT "firm_software_costs_firm_software_id_fkey" FOREIGN KEY ("firm_software_id") REFERENCES "public"."firm_software"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."firm_software"
    ADD CONSTRAINT "firm_software_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."firm_software"
    ADD CONSTRAINT "firm_software_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."software_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_benefit_enrollments"
    ADD CONSTRAINT "hris_benefit_enrollments_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_benefit_enrollments"
    ADD CONSTRAINT "hris_benefit_enrollments_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."hris_benefit_plans"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."hris_checklist_template_items"
    ADD CONSTRAINT "hris_checklist_template_items_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."hris_checklist_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_compensation"
    ADD CONSTRAINT "hris_compensation_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."hris_compensation"
    ADD CONSTRAINT "hris_compensation_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_custom_field_values"
    ADD CONSTRAINT "hris_custom_field_values_field_id_fkey" FOREIGN KEY ("field_id") REFERENCES "public"."custom_field_definitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_custom_field_values"
    ADD CONSTRAINT "hris_custom_field_values_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hris_emergency_contacts"
    ADD CONSTRAINT "hris_emergency_contacts_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_employee_checklists"
    ADD CONSTRAINT "hris_employee_checklists_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_employee_checklists"
    ADD CONSTRAINT "hris_employee_checklists_started_by_fkey" FOREIGN KEY ("started_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."hris_employee_checklists"
    ADD CONSTRAINT "hris_employee_checklists_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."hris_checklist_templates"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."hris_employee_details"
    ADD CONSTRAINT "hris_employee_details_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_leave_action_tokens"
    ADD CONSTRAINT "hris_leave_action_tokens_leave_request_id_fkey" FOREIGN KEY ("leave_request_id") REFERENCES "public"."hris_leave_requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_leave_action_tokens"
    ADD CONSTRAINT "hris_leave_action_tokens_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."hris_leave_balances"
    ADD CONSTRAINT "hris_leave_balances_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_leave_balances"
    ADD CONSTRAINT "hris_leave_balances_leave_type_id_fkey" FOREIGN KEY ("leave_type_id") REFERENCES "public"."hris_leave_types"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_leave_requests"
    ADD CONSTRAINT "hris_leave_requests_approver_id_fkey" FOREIGN KEY ("approver_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."hris_leave_requests"
    ADD CONSTRAINT "hris_leave_requests_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."hris_leave_requests"
    ADD CONSTRAINT "hris_leave_requests_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hris_leave_requests"
    ADD CONSTRAINT "hris_leave_requests_leave_type_id_fkey" FOREIGN KEY ("leave_type_id") REFERENCES "public"."hris_leave_types"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."hs_sync_log"
    ADD CONSTRAINT "hs_sync_log_triggered_by_fkey" FOREIGN KEY ("triggered_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hub_api_tokens"
    ADD CONSTRAINT "hub_api_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hubspot_contact_classifications"
    ADD CONSTRAINT "hubspot_contact_classifications_override_by_fkey" FOREIGN KEY ("override_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."inbox_items"
    ADD CONSTRAINT "inbox_items_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."inbox_items"
    ADD CONSTRAINT "inbox_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_description_versions"
    ADD CONSTRAINT "job_description_versions_job_description_id_fkey" FOREIGN KEY ("job_description_id") REFERENCES "public"."job_descriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_descriptions"
    ADD CONSTRAINT "job_descriptions_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_descriptions"
    ADD CONSTRAINT "job_descriptions_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_base_article_page_links"
    ADD CONSTRAINT "knowledge_base_article_page_links_article_id_fkey" FOREIGN KEY ("article_id") REFERENCES "public"."knowledge_base_articles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."knowledge_base_edit_log"
    ADD CONSTRAINT "knowledge_base_edit_log_article_id_fkey" FOREIGN KEY ("article_id") REFERENCES "public"."knowledge_base_articles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_agreements_log"
    ADD CONSTRAINT "laa_agreements_log_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."laa_canopy_payments"
    ADD CONSTRAINT "laa_canopy_payments_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."laa_firm_compensation"
    ADD CONSTRAINT "laa_firm_compensation_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_firm_compensation"
    ADD CONSTRAINT "laa_firm_compensation_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."laa_firm_services"
    ADD CONSTRAINT "laa_firm_services_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_referral_payouts"
    ADD CONSTRAINT "laa_referral_payouts_agreement_log_id_fkey" FOREIGN KEY ("agreement_log_id") REFERENCES "public"."laa_agreements_log"("id");



ALTER TABLE ONLY "public"."laa_referral_payouts"
    ADD CONSTRAINT "laa_referral_payouts_paid_by_fkey" FOREIGN KEY ("paid_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."laa_referral_payouts"
    ADD CONSTRAINT "laa_referral_payouts_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."laa_canopy_payments"("id");



ALTER TABLE ONLY "public"."laa_rfp_bids"
    ADD CONSTRAINT "laa_rfp_bids_bidding_org_id_fkey" FOREIGN KEY ("bidding_org_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_rfp_bids"
    ADD CONSTRAINT "laa_rfp_bids_rfp_id_fkey" FOREIGN KEY ("rfp_id") REFERENCES "public"."laa_rfps"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_rfp_bids"
    ADD CONSTRAINT "laa_rfp_bids_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."laa_rfp_questions"
    ADD CONSTRAINT "laa_rfp_questions_asked_by_fkey" FOREIGN KEY ("asked_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."laa_rfp_questions"
    ADD CONSTRAINT "laa_rfp_questions_asking_org_id_fkey" FOREIGN KEY ("asking_org_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."laa_rfp_questions"
    ADD CONSTRAINT "laa_rfp_questions_rfp_id_fkey" FOREIGN KEY ("rfp_id") REFERENCES "public"."laa_rfps"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_rfps"
    ADD CONSTRAINT "laa_rfps_requesting_org_id_fkey" FOREIGN KEY ("requesting_org_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."laa_rfps"
    ADD CONSTRAINT "laa_rfps_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."linked_emails"
    ADD CONSTRAINT "linked_emails_primary_user_id_fkey" FOREIGN KEY ("primary_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_automation_logs"
    ADD CONSTRAINT "my_task_automation_logs_automation_id_fkey" FOREIGN KEY ("automation_id") REFERENCES "public"."my_task_automations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_automation_logs"
    ADD CONSTRAINT "my_task_automation_logs_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_automations"
    ADD CONSTRAINT "my_task_automations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_section_assignments"
    ADD CONSTRAINT "my_task_section_assignments_section_id_fkey" FOREIGN KEY ("section_id") REFERENCES "public"."my_task_sections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_section_assignments"
    ADD CONSTRAINT "my_task_section_assignments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_section_assignments"
    ADD CONSTRAINT "my_task_section_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."my_task_sections"
    ADD CONSTRAINT "my_task_sections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nine_box_scores"
    ADD CONSTRAINT "nine_box_scores_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ninety_user_mappings"
    ADD CONSTRAINT "ninety_user_mappings_hub_user_id_fkey" FOREIGN KEY ("hub_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_access_tokens"
    ADD CONSTRAINT "oauth_access_tokens_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_access_tokens"
    ADD CONSTRAINT "oauth_access_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_authorization_codes"
    ADD CONSTRAINT "oauth_authorization_codes_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_authorization_codes"
    ADD CONSTRAINT "oauth_authorization_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_refresh_tokens"
    ADD CONSTRAINT "oauth_refresh_tokens_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."oauth_clients"("client_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."oauth_refresh_tokens"
    ADD CONSTRAINT "oauth_refresh_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."prep_briefs"
    ADD CONSTRAINT "prep_briefs_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."prep_calendar_events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prep_briefs"
    ADD CONSTRAINT "prep_briefs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prep_calendar_events"
    ADD CONSTRAINT "prep_calendar_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prep_reminder_preferences"
    ADD CONSTRAINT "prep_reminder_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_merged_into_fkey" FOREIGN KEY ("merged_into") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."project_custom_fields"
    ADD CONSTRAINT "project_custom_fields_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_custom_fields"
    ADD CONSTRAINT "project_custom_fields_field_id_fkey" FOREIGN KEY ("field_id") REFERENCES "public"."custom_field_definitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_custom_fields"
    ADD CONSTRAINT "project_custom_fields_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_favorites"
    ADD CONSTRAINT "project_favorites_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_field_aggregations"
    ADD CONSTRAINT "project_field_aggregations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_field_aggregations"
    ADD CONSTRAINT "project_field_aggregations_field_id_fkey" FOREIGN KEY ("field_id") REFERENCES "public"."custom_field_definitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_field_aggregations"
    ADD CONSTRAINT "project_field_aggregations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_resources"
    ADD CONSTRAINT "project_resources_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."project_resources"
    ADD CONSTRAINT "project_resources_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_sections"
    ADD CONSTRAINT "project_sections_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_share_links"
    ADD CONSTRAINT "project_share_links_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."project_share_links"
    ADD CONSTRAINT "project_share_links_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_shared_comments"
    ADD CONSTRAINT "project_shared_comments_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_shared_comments"
    ADD CONSTRAINT "project_shared_comments_share_link_id_fkey" FOREIGN KEY ("share_link_id") REFERENCES "public"."project_share_links"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_shared_comments"
    ADD CONSTRAINT "project_shared_comments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_template_members"
    ADD CONSTRAINT "project_template_members_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."project_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_template_members"
    ADD CONSTRAINT "project_template_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_template_sections"
    ADD CONSTRAINT "project_template_sections_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."project_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_template_tasks"
    ADD CONSTRAINT "project_template_tasks_template_section_id_fkey" FOREIGN KEY ("template_section_id") REFERENCES "public"."project_template_sections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_assigned_to_org_fkey" FOREIGN KEY ("assigned_to_org") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."project_templates"("id");



ALTER TABLE ONLY "public"."quick_links"
    ADD CONSTRAINT "quick_links_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."custom_roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rtl_accounts"
    ADD CONSTRAINT "rtl_accounts_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."rtl_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rtl_contact_org_mapping"
    ADD CONSTRAINT "rtl_contact_org_mapping_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."rtl_contacts"
    ADD CONSTRAINT "rtl_contacts_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."rtl_contacts"
    ADD CONSTRAINT "rtl_contacts_referred_by_user_id_fkey" FOREIGN KEY ("referred_by_user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."rtl_opportunities"
    ADD CONSTRAINT "rtl_opportunities_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."rtl_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rtl_sync_log"
    ADD CONSTRAINT "rtl_sync_log_triggered_by_fkey" FOREIGN KEY ("triggered_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."sdr_batches"
    ADD CONSTRAINT "sdr_batches_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."sdr_batches"
    ADD CONSTRAINT "sdr_batches_created_by_user_id_fkey" FOREIGN KEY ("created_by_user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."sdr_batches"("id");



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_draft_generated_by_fkey" FOREIGN KEY ("draft_generated_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_excluded_by_fkey" FOREIGN KEY ("excluded_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_firm_id_fkey" FOREIGN KEY ("firm_id") REFERENCES "public"."sdr_firms"("id");



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_jacob_checked_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."sdr_contacts"
    ADD CONSTRAINT "sdr_contacts_researched_by_user_id_fkey" FOREIGN KEY ("researched_by_user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."sdr_email_templates"
    ADD CONSTRAINT "sdr_email_templates_rule_set_id_fkey" FOREIGN KEY ("rule_set_id") REFERENCES "public"."sdr_rule_sets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sdr_email_templates"
    ADD CONSTRAINT "sdr_email_templates_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sdr_firm_staff"
    ADD CONSTRAINT "sdr_firm_staff_firm_id_fkey" FOREIGN KEY ("firm_id") REFERENCES "public"."sdr_firms"("id");



ALTER TABLE ONLY "public"."sdr_firms"
    ADD CONSTRAINT "sdr_firms_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."sdr_batches"("id");



ALTER TABLE ONLY "public"."sdr_firms"
    ADD CONSTRAINT "sdr_firms_partner_user_id_fkey" FOREIGN KEY ("partner_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sdr_firms"
    ADD CONSTRAINT "sdr_firms_queue_id_fkey" FOREIGN KEY ("queue_id") REFERENCES "public"."sdr_prospect_queues"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sdr_prospect_queues"
    ADD CONSTRAINT "sdr_prospect_queues_partner_user_id_fkey" FOREIGN KEY ("partner_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sdr_rule_sets"
    ADD CONSTRAINT "sdr_rule_sets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."software_products"
    ADD CONSTRAINT "software_products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."software_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_advisors"
    ADD CONSTRAINT "ssg_advisors_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_calendar_events"
    ADD CONSTRAINT "ssg_calendar_events_connected_user_id_fkey" FOREIGN KEY ("connected_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_calendar_events"
    ADD CONSTRAINT "ssg_calendar_events_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_emails"
    ADD CONSTRAINT "ssg_emails_connected_user_id_fkey" FOREIGN KEY ("connected_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_emails"
    ADD CONSTRAINT "ssg_emails_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_engagement_contacts"
    ADD CONSTRAINT "ssg_engagement_contacts_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_engagements"
    ADD CONSTRAINT "ssg_engagements_member_firm_id_fkey" FOREIGN KEY ("member_firm_id") REFERENCES "public"."organizations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_engagements"
    ADD CONSTRAINT "ssg_engagements_primary_advisor_id_fkey" FOREIGN KEY ("primary_advisor_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_engagements"
    ADD CONSTRAINT "ssg_engagements_relationship_manager_id_fkey" FOREIGN KEY ("relationship_manager_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_functions"
    ADD CONSTRAINT "ssg_functions_manager_id_fkey" FOREIGN KEY ("manager_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_insights"
    ADD CONSTRAINT "ssg_insights_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_insights"
    ADD CONSTRAINT "ssg_insights_meeting_id_fkey" FOREIGN KEY ("meeting_id") REFERENCES "public"."ssg_meetings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_meetings"
    ADD CONSTRAINT "ssg_meetings_calendar_event_id_fkey" FOREIGN KEY ("calendar_event_id") REFERENCES "public"."ssg_calendar_events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_meetings"
    ADD CONSTRAINT "ssg_meetings_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_meetings"
    ADD CONSTRAINT "ssg_meetings_host_user_id_fkey" FOREIGN KEY ("host_user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ssg_member_assignments"
    ADD CONSTRAINT "ssg_member_assignments_function_id_fkey" FOREIGN KEY ("function_id") REFERENCES "public"."ssg_functions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_member_assignments"
    ADD CONSTRAINT "ssg_member_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ssg_outcomes"
    ADD CONSTRAINT "ssg_outcomes_engagement_id_fkey" FOREIGN KEY ("engagement_id") REFERENCES "public"."ssg_engagements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_contacts"
    ADD CONSTRAINT "tas_contacts_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."tas_businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_import_logs"
    ADD CONSTRAINT "tas_import_logs_consultant_profile_id_fkey" FOREIGN KEY ("consultant_profile_id") REFERENCES "public"."tas_consultant_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_inmail_budget"
    ADD CONSTRAINT "tas_inmail_budget_consultant_profile_id_fkey" FOREIGN KEY ("consultant_profile_id") REFERENCES "public"."tas_consultant_profiles"("id");



ALTER TABLE ONLY "public"."tas_inmail_budget"
    ADD CONSTRAINT "tas_inmail_budget_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tas_sequence_steps"
    ADD CONSTRAINT "tas_sequence_steps_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."tas_businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_sequence_steps"
    ADD CONSTRAINT "tas_sequence_steps_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."tas_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_sequence_steps"
    ADD CONSTRAINT "tas_sequence_steps_sequence_id_fkey" FOREIGN KEY ("sequence_id") REFERENCES "public"."tas_sequences"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."tas_businesses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_consultant_profile_id_fkey" FOREIGN KEY ("consultant_profile_id") REFERENCES "public"."tas_consultant_profiles"("id");



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."tas_contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tas_sequences"
    ADD CONSTRAINT "tas_sequences_import_log_id_fkey" FOREIGN KEY ("import_log_id") REFERENCES "public"."tas_import_logs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_attachments"
    ADD CONSTRAINT "task_attachments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_collaborators"
    ADD CONSTRAINT "task_collaborators_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_collaborators"
    ADD CONSTRAINT "task_collaborators_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_collaborators"
    ADD CONSTRAINT "task_collaborators_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."task_comments"
    ADD CONSTRAINT "task_comments_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_custom_field_values"
    ADD CONSTRAINT "task_custom_field_values_field_id_fkey" FOREIGN KEY ("field_id") REFERENCES "public"."custom_field_definitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_custom_field_values"
    ADD CONSTRAINT "task_custom_field_values_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_custom_field_values"
    ADD CONSTRAINT "task_custom_field_values_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_history"
    ADD CONSTRAINT "task_history_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_notifications"
    ADD CONSTRAINT "task_notifications_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_notifications"
    ADD CONSTRAINT "task_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_section_id_fkey" FOREIGN KEY ("section_id") REFERENCES "public"."project_sections"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."task_project_memberships"
    ADD CONSTRAINT "task_project_memberships_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."task_saved_views"
    ADD CONSTRAINT "task_saved_views_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_ai_source_meeting_id_fkey" FOREIGN KEY ("ai_source_meeting_id") REFERENCES "public"."ssg_meetings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_parent_task_id_fkey" FOREIGN KEY ("parent_task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_recurrence_parent_id_fkey" FOREIGN KEY ("recurrence_parent_id") REFERENCES "public"."tasks"("id");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_section_id_fkey" FOREIGN KEY ("section_id") REFERENCES "public"."project_sections"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ticket_comments"
    ADD CONSTRAINT "ticket_comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ticket_comments"
    ADD CONSTRAINT "ticket_comments_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_field_definitions"
    ADD CONSTRAINT "ticket_field_definitions_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."ticket_categories"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_field_values"
    ADD CONSTRAINT "ticket_field_values_field_definition_id_fkey" FOREIGN KEY ("field_definition_id") REFERENCES "public"."ticket_field_definitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_field_values"
    ADD CONSTRAINT "ticket_field_values_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_messages"
    ADD CONSTRAINT "ticket_messages_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ticket_messages"
    ADD CONSTRAINT "ticket_messages_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_notifications"
    ADD CONSTRAINT "ticket_notifications_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ticket_notifications"
    ADD CONSTRAINT "ticket_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."ticket_categories"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_status_id_fkey" FOREIGN KEY ("status_id") REFERENCES "public"."ticket_statuses"("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."training_lesson_progress"
    ADD CONSTRAINT "training_lesson_progress_lesson_id_fkey" FOREIGN KEY ("lesson_id") REFERENCES "public"."training_lessons"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."training_lesson_progress"
    ADD CONSTRAINT "training_lesson_progress_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."training_lessons"
    ADD CONSTRAINT "training_lessons_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."training_courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."training_resources"
    ADD CONSTRAINT "training_resources_course_id_fkey" FOREIGN KEY ("course_id") REFERENCES "public"."training_courses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."training_resources"
    ADD CONSTRAINT "training_resources_lesson_id_fkey" FOREIGN KEY ("lesson_id") REFERENCES "public"."training_lessons"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_home_layouts"
    ADD CONSTRAINT "user_home_layouts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_notification_preferences"
    ADD CONSTRAINT "user_notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_role_assignments"
    ADD CONSTRAINT "user_role_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."user_role_assignments"
    ADD CONSTRAINT "user_role_assignments_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."custom_roles"("id");



ALTER TABLE ONLY "public"."user_role_assignments"
    ADD CONSTRAINT "user_role_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_contacts"
    ADD CONSTRAINT "vendor_contacts_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."vendors"("id") ON DELETE CASCADE;



CREATE POLICY "Access write bdr_batches" ON "public"."bdr_batches" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true))))));



CREATE POLICY "Access write bdr_business_people" ON "public"."bdr_business_people" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true))))));



CREATE POLICY "Access write bdr_businesses" ON "public"."bdr_businesses" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true))))));



CREATE POLICY "Access write bdr_prospects" ON "public"."bdr_prospects" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true)))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND (("rp"."permission_key" = 'desks.bdr'::"text") OR ("cr"."is_system" = true))))));



CREATE POLICY "Active users can create tasks" ON "public"."tasks" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND (("assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))));



CREATE POLICY "Active users can insert expansion_opportunities" ON "public"."expansion_opportunities" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text")));



CREATE POLICY "Active users can insert own scores" ON "public"."nine_box_scores" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND (("scored_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))));



CREATE POLICY "Active users can insert task comments" ON "public"."task_comments" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("author_id" = "auth"."uid"()) AND ("task_id" IN ( SELECT "tasks"."id"
   FROM "public"."tasks"
  WHERE (("tasks"."assigned_to" = "auth"."uid"()) OR ("tasks"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("tasks"."assigned_to" IN ( SELECT "profiles"."id"
           FROM "public"."profiles"
          WHERE ("profiles"."manager_id" = "auth"."uid"()))))))));



CREATE POLICY "Active users can insert task history" ON "public"."task_history" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can insert task notifications" ON "public"."task_notifications" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read active checkin_templates" ON "public"."checkin_templates" FOR SELECT TO "authenticated" USING (("is_active" = true));



CREATE POLICY "Active users can read app_settings" ON "public"."app_settings" FOR SELECT USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read custom_roles" ON "public"."custom_roles" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read permissions" ON "public"."permissions" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read project_template_members" ON "public"."project_template_members" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read role_permissions" ON "public"."role_permissions" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read roles" ON "public"."roles" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can read scores" ON "public"."nine_box_scores" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Active users can update expansion_opportunities" ON "public"."expansion_opportunities" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text"))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text")));



CREATE POLICY "Active users read hs_engagements" ON "public"."hubspot_engagements" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Add task to project" ON "public"."task_project_memberships" FOR INSERT TO "authenticated" WITH CHECK ((("created_by" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_project_memberships"."task_id"))) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "task_project_memberships"."project_id")))));



CREATE POLICY "Admin full access" ON "public"."desks" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."laa_canopy_payments" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."laa_referral_payouts" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_batches" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_contacts" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_firm_staff" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_firms" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_known_acquisitions" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admin full access" ON "public"."sdr_seamless_imports" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "Admins can delete articles" ON "public"."knowledge_base_articles" FOR DELETE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can delete custom_roles" ON "public"."custom_roles" FOR DELETE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can delete role assignments" ON "public"."user_role_assignments" FOR DELETE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can delete role_permissions" ON "public"."role_permissions" FOR DELETE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can delete ssg_advisors" ON "public"."ssg_advisors" FOR DELETE TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Admins can insert custom_roles" ON "public"."custom_roles" FOR INSERT TO "authenticated" WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can insert role assignments" ON "public"."user_role_assignments" FOR INSERT TO "authenticated" WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can insert role_permissions" ON "public"."role_permissions" FOR INSERT TO "authenticated" WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can insert ssg_advisors" ON "public"."ssg_advisors" FOR INSERT TO "authenticated" WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Admins can manage all documents" ON "public"."documents" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage announcements" ON "public"."announcements" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage app_settings" ON "public"."app_settings" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage assignments" ON "public"."checklist_assignments" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage categories" ON "public"."ticket_categories" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage checkin_assignments" ON "public"."checkin_assignments" USING (("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR (EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = 'performance.view_org'::"text"))))));



CREATE POLICY "Admins can manage checkin_templates" ON "public"."checkin_templates" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage comments" ON "public"."ticket_comments" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage custom items" ON "public"."checklist_custom_items" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage doc categories" ON "public"."document_categories" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage doc notifications" ON "public"."document_notifications" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage document_permissions" ON "public"."document_permissions" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage field defs" ON "public"."ticket_field_definitions" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage field values" ON "public"."ticket_field_values" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage folders" ON "public"."document_folders" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage items" ON "public"."checklist_items" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage linked_emails" ON "public"."linked_emails" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage links" ON "public"."quick_links" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage ninety_user_mappings" ON "public"."ninety_user_mappings" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role_id" = 'c326d694-79d2-46b2-a822-e0cfe7d2ed79'::"uuid")))));



CREATE POLICY "Admins can manage notifications" ON "public"."ticket_notifications" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage orgs" ON "public"."organizations" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage overrides" ON "public"."checklist_item_overrides" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage profiles" ON "public"."profiles" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage progress" ON "public"."checklist_progress" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_members" ON "public"."project_members" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_resources" ON "public"."project_resources" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_sections" ON "public"."project_sections" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_template_members" ON "public"."project_template_members" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_template_sections" ON "public"."project_template_sections" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_template_tasks" ON "public"."project_template_tasks" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage project_templates" ON "public"."project_templates" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage projects" ON "public"."projects" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage roles" ON "public"."user_roles" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage service catalog" ON "public"."laa_service_catalog" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_roles"
  WHERE (("user_roles"."user_id" = "auth"."uid"()) AND ("user_roles"."role" = 'admin'::"public"."app_role")))));



CREATE POLICY "Admins can manage ssg_functions" ON "public"."ssg_functions" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage ssg_member_assignments" ON "public"."ssg_member_assignments" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage statuses" ON "public"."ticket_statuses" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage templates" ON "public"."checklist_templates" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage vendor contacts" ON "public"."vendor_contacts" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can manage vendors" ON "public"."vendors" TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can read all checkin_submissions" ON "public"."checkin_submissions" FOR SELECT USING (("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR (EXISTS ( SELECT 1
   FROM (("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "cr"."id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = 'performance.view_org'::"text"))))));



CREATE POLICY "Admins can read all logs" ON "public"."activity_logs" FOR SELECT TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can read all role assignments" ON "public"."user_role_assignments" FOR SELECT TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can update contact classifications" ON "public"."hubspot_contact_classifications" FOR UPDATE TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Admins can update custom_roles" ON "public"."custom_roles" FOR UPDATE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can update role assignments" ON "public"."user_role_assignments" FOR UPDATE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can update role_permissions" ON "public"."role_permissions" FOR UPDATE TO "authenticated" USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")) WITH CHECK ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Admins can update ssg_advisors" ON "public"."ssg_advisors" FOR UPDATE TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Admins can update tickets" ON "public"."tickets" FOR UPDATE USING ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"));



CREATE POLICY "Alliance docs visible to all authenticated" ON "public"."documents" FOR SELECT USING ((("deleted_at" IS NULL) AND ("status" = 'approved'::"text") AND ("visibility" = 'alliance'::"text") AND (("folder_id" IS NULL) OR ("public"."get_effective_folder_visibility"("folder_id") = 'alliance'::"text"))));



CREATE POLICY "Assignee can insert checkin_submissions" ON "public"."checkin_submissions" FOR INSERT TO "authenticated" WITH CHECK (("assignee_id" = "auth"."uid"()));



CREATE POLICY "Assignee can read own checkin_submissions" ON "public"."checkin_submissions" FOR SELECT TO "authenticated" USING (("assignee_id" = "auth"."uid"()));



CREATE POLICY "Assignee can update checkin_submissions" ON "public"."checkin_submissions" FOR UPDATE TO "authenticated" USING (("assignee_id" = "auth"."uid"())) WITH CHECK (("assignee_id" = "auth"."uid"()));



CREATE POLICY "Attach project custom fields" ON "public"."project_custom_fields" FOR INSERT TO "authenticated" WITH CHECK ((("created_by" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_custom_fields"."project_id")))));



CREATE POLICY "Authenticated can read announcements" ON "public"."announcements" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read articles" ON "public"."knowledge_base_articles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read categories" ON "public"."ticket_categories" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read doc categories" ON "public"."document_categories" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read edit log" ON "public"."knowledge_base_edit_log" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read field defs" ON "public"."ticket_field_definitions" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read folders" ON "public"."document_folders" FOR SELECT USING (("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("public"."get_effective_folder_visibility"("id") <> 'private'::"text") OR ("created_by" = "auth"."uid"()) OR "public"."has_folder_permission"("auth"."uid"(), "id")));



CREATE POLICY "Authenticated can read items" ON "public"."checklist_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read links" ON "public"."quick_links" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read orgs" ON "public"."organizations" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read page links" ON "public"."knowledge_base_article_page_links" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read profiles" ON "public"."profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read project_template_sections" ON "public"."project_template_sections" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Authenticated can read project_template_tasks" ON "public"."project_template_tasks" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Authenticated can read project_templates" ON "public"."project_templates" FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Authenticated can read ssg_functions" ON "public"."ssg_functions" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read statuses" ON "public"."ticket_statuses" FOR SELECT USING (true);



CREATE POLICY "Authenticated can read templates" ON "public"."checklist_templates" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read vendor contacts" ON "public"."vendor_contacts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated can read vendors" ON "public"."vendors" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated insert" ON "public"."sdr_seamless_imports" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated insert consultant profiles" ON "public"."tas_consultant_profiles" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated insert own inbox items" ON "public"."inbox_items" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Authenticated insert own notifications" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Authenticated read" ON "public"."sdr_batches" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read" ON "public"."sdr_contacts" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read" ON "public"."sdr_firm_staff" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read" ON "public"."sdr_firms" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read" ON "public"."sdr_known_acquisitions" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read" ON "public"."sdr_seamless_imports" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read bdr_batches" ON "public"."bdr_batches" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read bdr_business_people" ON "public"."bdr_business_people" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read bdr_businesses" ON "public"."bdr_businesses" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read bdr_prospects" ON "public"."bdr_prospects" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated read consultant profiles" ON "public"."tas_consultant_profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read desks" ON "public"."desks" FOR SELECT TO "authenticated" USING (("is_active" AND ("auth"."role"() = 'authenticated'::"text")));



CREATE POLICY "Authenticated update" ON "public"."sdr_seamless_imports" FOR UPDATE USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated update consultant profiles" ON "public"."tas_consultant_profiles" FOR UPDATE TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can create folders" ON "public"."document_folders" FOR INSERT TO "authenticated" WITH CHECK (("created_by" = "auth"."uid"()));



CREATE POLICY "Authenticated users can read RFPs" ON "public"."laa_rfps" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read bids" ON "public"."laa_rfp_bids" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read expansion_opportunities" ON "public"."expansion_opportunities" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read firm services" ON "public"."laa_firm_services" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read questions" ON "public"."laa_rfp_questions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read service catalog" ON "public"."laa_service_catalog" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can select bdr staging" ON "public"."bdr_seamless_staging" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can upload documents" ON "public"."documents" FOR INSERT WITH CHECK (("uploaded_by" = "auth"."uid"()));



CREATE POLICY "Authenticated users can view task collaborators" ON "public"."task_collaborators" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authors can update own comments" ON "public"."task_comments" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("author_id" = "auth"."uid"()))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("author_id" = "auth"."uid"())));



CREATE POLICY "Authors can update own messages" ON "public"."ticket_messages" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("author_id" = "auth"."uid"()))) WITH CHECK (("author_id" = "auth"."uid"()));



CREATE POLICY "BDR users can insert bdr staging" ON "public"."bdr_seamless_staging" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.bdr'::"text")));



CREATE POLICY "BDR users can update bdr staging" ON "public"."bdr_seamless_staging" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.bdr'::"text"))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.bdr'::"text")));



CREATE POLICY "BP users can delete business_plan_checkins" ON "public"."business_plan_checkins" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can delete business_plan_revenue_drivers" ON "public"."business_plan_revenue_drivers" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can delete business_plans" ON "public"."business_plans" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can insert business_plan_checkins" ON "public"."business_plan_checkins" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can insert business_plan_revenue_drivers" ON "public"."business_plan_revenue_drivers" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can insert business_plans" ON "public"."business_plans" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can read business_plan_checkins" ON "public"."business_plan_checkins" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can read business_plan_revenue_drivers" ON "public"."business_plan_revenue_drivers" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can read business_plans" ON "public"."business_plans" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can update business_plan_checkins" ON "public"."business_plan_checkins" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can update business_plan_revenue_drivers" ON "public"."business_plan_revenue_drivers" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "BP users can update business_plans" ON "public"."business_plans" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.business-planning.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Block pending bdr_batches" ON "public"."bdr_batches" AS RESTRICTIVE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."status" <> 'Pending'::"text")))));



CREATE POLICY "Block pending bdr_business_people" ON "public"."bdr_business_people" AS RESTRICTIVE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."status" <> 'Pending'::"text")))));



CREATE POLICY "Block pending bdr_businesses" ON "public"."bdr_businesses" AS RESTRICTIVE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."status" <> 'Pending'::"text")))));



CREATE POLICY "Block pending bdr_prospects" ON "public"."bdr_prospects" AS RESTRICTIVE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."status" <> 'Pending'::"text")))));



CREATE POLICY "Block pending users" ON "public"."announcements" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checkin_edit_log" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_assignments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_custom_items" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_item_overrides" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_items" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_progress" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."checklist_templates" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."desks" AS RESTRICTIVE USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."document_categories" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."document_folders" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."document_notifications" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."documents" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."knowledge_base_article_page_links" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."knowledge_base_articles" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."knowledge_base_edit_log" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."organizations" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."quick_links" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ssg_functions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ssg_member_assignments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_categories" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_comments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_field_definitions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_field_values" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_notifications" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."ticket_statuses" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."tickets" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."user_notification_preferences" AS RESTRICTIVE USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."status" <> 'pending'::"text")))));



CREATE POLICY "Block pending users" ON "public"."vendor_contacts" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users" ON "public"."vendors" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users activity_logs" ON "public"."activity_logs" AS RESTRICTIVE FOR SELECT TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users app_settings" ON "public"."app_settings" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users checkin_assignments" ON "public"."checkin_assignments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users checkin_submissions" ON "public"."checkin_submissions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users checkin_templates" ON "public"."checkin_templates" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users comment_mentions" ON "public"."comment_mentions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users custom_roles" ON "public"."custom_roles" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users document_permissions" ON "public"."document_permissions" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users document_stars" ON "public"."document_stars" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users from task_saved_views" ON "public"."task_saved_views" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users my_task_automation_logs" ON "public"."my_task_automation_logs" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users my_task_automations" ON "public"."my_task_automations" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users my_task_section_assignments" ON "public"."my_task_section_assignments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users my_task_sections" ON "public"."my_task_sections" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users permissions" ON "public"."permissions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users pinned_items" ON "public"."pinned_items" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users profiles" ON "public"."profiles" AS RESTRICTIVE FOR SELECT TO "authenticated" USING ((("id" = "auth"."uid"()) OR "public"."is_active_user"("auth"."uid"())));



CREATE POLICY "Block pending users project_favorites" ON "public"."project_favorites" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_members" ON "public"."project_members" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_resources" ON "public"."project_resources" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_sections" ON "public"."project_sections" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_share_links" ON "public"."project_share_links" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_shared_comments" ON "public"."project_shared_comments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_template_members" ON "public"."project_template_members" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_template_sections" ON "public"."project_template_sections" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_template_tasks" ON "public"."project_template_tasks" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users project_templates" ON "public"."project_templates" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users projects" ON "public"."projects" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users role_permissions" ON "public"."role_permissions" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users roles" ON "public"."roles" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users task_attachments" ON "public"."task_attachments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users task_comments" ON "public"."task_comments" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users task_history" ON "public"."task_history" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users task_notifications" ON "public"."task_notifications" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users tasks" ON "public"."tasks" TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users ticket_messages" ON "public"."ticket_messages" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users user_home_layouts" ON "public"."user_home_layouts" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users user_role_assignments" ON "public"."user_role_assignments" AS RESTRICTIVE TO "authenticated" USING ("public"."is_active_user"("auth"."uid"())) WITH CHECK ("public"."is_active_user"("auth"."uid"()));



CREATE POLICY "Block pending users user_roles" ON "public"."user_roles" AS RESTRICTIVE FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."is_active_user"("auth"."uid"())));



CREATE POLICY "Create custom field definitions" ON "public"."custom_field_definitions" FOR INSERT TO "authenticated" WITH CHECK (("created_by" = "auth"."uid"()));



CREATE POLICY "Create project field aggregations" ON "public"."project_field_aggregations" FOR INSERT TO "authenticated" WITH CHECK ((("created_by" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_field_aggregations"."project_id")))));



CREATE POLICY "Creators and admins can delete tasks" ON "public"."tasks" FOR DELETE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND (("assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))));



CREATE POLICY "Delete custom field definitions with admin" ON "public"."custom_field_definitions" FOR DELETE TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Delete own training progress" ON "public"."training_lesson_progress" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Delete project field aggregations" ON "public"."project_field_aggregations" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_field_aggregations"."project_id"))));



CREATE POLICY "Delete task custom field values" ON "public"."task_custom_field_values" FOR DELETE TO "authenticated" USING ("public"."can_edit_task"("auth"."uid"(), "task_id"));



CREATE POLICY "Detach project custom fields" ON "public"."project_custom_fields" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_custom_fields"."project_id"))));



CREATE POLICY "Document owners can manage permissions on their docs" ON "public"."document_permissions" USING (((("document_id" IS NOT NULL) AND ("document_id" IN ( SELECT "documents"."id"
   FROM "public"."documents"
  WHERE ("documents"."uploaded_by" = "auth"."uid"())))) OR (("folder_id" IS NOT NULL) AND ("folder_id" IN ( SELECT "document_folders"."id"
   FROM "public"."document_folders"
  WHERE ("document_folders"."created_by" = "auth"."uid"())))))) WITH CHECK (((("document_id" IS NOT NULL) AND ("document_id" IN ( SELECT "documents"."id"
   FROM "public"."documents"
  WHERE ("documents"."uploaded_by" = "auth"."uid"())))) OR (("folder_id" IS NOT NULL) AND ("folder_id" IN ( SELECT "document_folders"."id"
   FROM "public"."document_folders"
  WHERE ("document_folders"."created_by" = "auth"."uid"()))))));



CREATE POLICY "Editors delete training courses" ON "public"."training_courses" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors delete training lessons" ON "public"."training_lessons" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors delete training resources" ON "public"."training_resources" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors insert training courses" ON "public"."training_courses" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors insert training lessons" ON "public"."training_lessons" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors insert training resources" ON "public"."training_resources" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors update training courses" ON "public"."training_courses" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors update training lessons" ON "public"."training_lessons" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Editors update training resources" ON "public"."training_resources" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "File Share can insert doc notifications" ON "public"."document_notifications" FOR INSERT WITH CHECK (("public"."user_has_tag"("auth"."uid"(), 'File Share'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "File Share reviewers can read all documents" ON "public"."documents" FOR SELECT USING (("public"."user_has_tag"("auth"."uid"(), 'File Share'::"text") AND ("deleted_at" IS NULL)));



CREATE POLICY "File Share reviewers can update documents" ON "public"."documents" FOR UPDATE USING ("public"."user_has_tag"("auth"."uid"(), 'File Share'::"text"));



CREATE POLICY "Firm partners read own-firm ssg tasks" ON "public"."tasks" FOR SELECT TO "authenticated" USING ((("source_type" = 'ssg_engagement'::"text") AND "public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND (("source_reference_id")::"text" IN ( SELECT ("e"."id")::"text" AS "id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_calendar_events" ON "public"."ssg_calendar_events" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_emails" ON "public"."ssg_emails" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_engagements" ON "public"."ssg_engagements" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("member_firm_id" IN ( SELECT "p"."organization_id"
   FROM "public"."profiles" "p"
  WHERE ("p"."id" = "auth"."uid"())))));



CREATE POLICY "Firm partners read own-firm ssg_insights" ON "public"."ssg_insights" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_meetings" ON "public"."ssg_meetings" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Firm partners read own-firm ssg_outcomes" ON "public"."ssg_outcomes" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view-own-firm'::"text") AND ("engagement_id" IN ( SELECT "e"."id"
   FROM "public"."ssg_engagements" "e"
  WHERE ("e"."member_firm_id" IN ( SELECT "p"."organization_id"
           FROM "public"."profiles" "p"
          WHERE ("p"."id" = "auth"."uid"())))))));



CREATE POLICY "Insert own training progress" ON "public"."training_lesson_progress" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Insert task custom field values" ON "public"."task_custom_field_values" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_task"("auth"."uid"(), "task_id"));



CREATE POLICY "KB tagged users can delete page links" ON "public"."knowledge_base_article_page_links" FOR DELETE USING (("public"."user_has_tag"("auth"."uid"(), 'Knowledge Base'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "KB tagged users can insert articles" ON "public"."knowledge_base_articles" FOR INSERT TO "authenticated" WITH CHECK (("public"."user_has_tag"("auth"."uid"(), 'Knowledge Base'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "KB tagged users can insert edit log" ON "public"."knowledge_base_edit_log" FOR INSERT TO "authenticated" WITH CHECK (("public"."user_has_tag"("auth"."uid"(), 'Knowledge Base'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "KB tagged users can insert page links" ON "public"."knowledge_base_article_page_links" FOR INSERT WITH CHECK (("public"."user_has_tag"("auth"."uid"(), 'Knowledge Base'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "KB tagged users can update articles" ON "public"."knowledge_base_articles" FOR UPDATE TO "authenticated" USING (("public"."user_has_tag"("auth"."uid"(), 'Knowledge Base'::"text") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Manage dashboard_access with admin" ON "public"."dashboard_access" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage dashboard_datasets with admin" ON "public"."dashboard_datasets" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage dashboards with admin" ON "public"."dashboards" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage data_sources with admin" ON "public"."data_sources" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage dataset_access with admin" ON "public"."dataset_access" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage datasets with admin" ON "public"."datasets" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manage reporting_sync_alerts with admin" ON "public"."reporting_sync_alerts" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Manager can read checkin_submissions" ON "public"."checkin_submissions" FOR SELECT TO "authenticated" USING (("manager_id" = "auth"."uid"()));



CREATE POLICY "Manager chain can read checkin_submissions" ON "public"."checkin_submissions" FOR SELECT TO "authenticated" USING ("public"."is_in_manager_chain"("auth"."uid"(), "assignee_id"));



CREATE POLICY "Managers and admins delete job descriptions" ON "public"."job_descriptions" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.manage'::"text") OR "public"."is_manager_in_chain"("profile_id")));



CREATE POLICY "Managers and admins insert job descriptions" ON "public"."job_descriptions" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.manage'::"text") OR "public"."is_manager_in_chain"("profile_id")));



CREATE POLICY "Managers and admins update job descriptions" ON "public"."job_descriptions" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.manage'::"text") OR "public"."is_manager_in_chain"("profile_id"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.manage'::"text") OR "public"."is_manager_in_chain"("profile_id")));



CREATE POLICY "Managers can delete project_shared_comments" ON "public"."project_shared_comments" FOR DELETE TO "authenticated" USING ("public"."can_manage_project"("auth"."uid"(), "project_id"));



CREATE POLICY "Managers can manage project_share_links" ON "public"."project_share_links" TO "authenticated" USING ("public"."can_manage_project"("auth"."uid"(), "project_id")) WITH CHECK ("public"."can_manage_project"("auth"."uid"(), "project_id"));



CREATE POLICY "Members can insert comments on own tickets" ON "public"."ticket_comments" FOR INSERT WITH CHECK ((("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"()))) AND ("is_internal" = false) AND ("author_id" = "auth"."uid"())));



CREATE POLICY "Members can insert own field values" ON "public"."ticket_field_values" FOR INSERT WITH CHECK (("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"()))));



CREATE POLICY "Members can insert own tickets" ON "public"."tickets" FOR INSERT WITH CHECK (("submitted_by" = "auth"."uid"()));



CREATE POLICY "Members can read own field values" ON "public"."ticket_field_values" FOR SELECT USING ((("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"()))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Members can read own projects" ON "public"."projects" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_member"("auth"."uid"(), "id"))));



CREATE POLICY "Members can read own ssg assignments" ON "public"."ssg_member_assignments" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Members can read own tickets" ON "public"."tickets" FOR SELECT TO "authenticated" USING ((("submitted_by" = "auth"."uid"()) OR ("owner_id" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Members can read project sections they can see" ON "public"."project_sections" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_member"("auth"."uid"(), "project_id"))));



CREATE POLICY "Members can read project_members" ON "public"."project_members" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND (("user_id" = "auth"."uid"()) OR "public"."is_project_member"("auth"."uid"(), "project_id") OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))));



CREATE POLICY "Members can read project_resources" ON "public"."project_resources" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_member"("auth"."uid"(), "project_id"))));



CREATE POLICY "Members can read project_shared_comments" ON "public"."project_shared_comments" FOR SELECT TO "authenticated" USING (("public"."is_project_member"("auth"."uid"(), "project_id") OR "public"."can_manage_project"("auth"."uid"(), "project_id")));



CREATE POLICY "Members can read public comments on own tickets" ON "public"."ticket_comments" FOR SELECT USING (((("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"()))) AND ("is_internal" = false)) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Members can read tasks in their projects" ON "public"."tasks" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND "public"."can_read_task_via_project"("auth"."uid"(), "id")));



CREATE POLICY "Owners can manage project_sections" ON "public"."project_sections" TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_owner"("auth"."uid"(), "project_id")))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_owner"("auth"."uid"(), "project_id"))));



CREATE POLICY "Owners can update projects" ON "public"."projects" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_owner"("auth"."uid"(), "id"))));



CREATE POLICY "Partner can update contacts at claimed firms" ON "public"."sdr_contacts" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."sdr_firms" "f"
  WHERE (("f"."id" = "sdr_contacts"."firm_id") AND ("f"."partner_user_id" = "auth"."uid"()) AND ("f"."partner_action" = 'CLAIMED'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."sdr_firms" "f"
  WHERE (("f"."id" = "sdr_contacts"."firm_id") AND ("f"."partner_user_id" = "auth"."uid"()) AND ("f"."partner_action" = 'CLAIMED'::"text")))));



CREATE POLICY "Partner can update own claimed firms" ON "public"."sdr_firms" FOR UPDATE TO "authenticated" USING ((("partner_user_id" = "auth"."uid"()) AND ("partner_action" = 'CLAIMED'::"text"))) WITH CHECK ((("partner_user_id" = "auth"."uid"()) AND ("partner_action" = 'CLAIMED'::"text")));



CREATE POLICY "Project owners can manage members" ON "public"."project_members" TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND "public"."is_project_owner"("auth"."uid"(), "project_id"))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."is_project_owner"("auth"."uid"(), "project_id")));



CREATE POLICY "Project owners can manage resources" ON "public"."project_resources" TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_owner"("auth"."uid"(), "project_id")))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR "public"."is_project_owner"("auth"."uid"(), "project_id"))));



CREATE POLICY "Read custom field definitions" ON "public"."custom_field_definitions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Read dashboard_access with registry view or admin or entitled" ON "public"."dashboard_access" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), "permission_key")));



CREATE POLICY "Read dashboard_datasets with registry view or admin" ON "public"."dashboard_datasets" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read dashboards if entitled" ON "public"."dashboards" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR (EXISTS ( SELECT 1
   FROM "public"."dashboard_access" "da"
  WHERE (("da"."dashboard_id" = "dashboards"."id") AND "public"."has_permission"("auth"."uid"(), "da"."permission_key"))))));



CREATE POLICY "Read data_sources with registry view or admin" ON "public"."data_sources" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read dataset_access with registry view or admin" ON "public"."dataset_access" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read datasets with registry view or admin" ON "public"."datasets" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read job description versions by tier" ON "public"."job_description_versions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."job_descriptions" "jd"
  WHERE (("jd"."id" = "job_description_versions"."job_description_id") AND ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.view_all'::"text") OR ("jd"."organization_id" = ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"()))))))));



CREATE POLICY "Read job descriptions by tier" ON "public"."job_descriptions" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR "public"."has_permission"("auth"."uid"(), 'job_descriptions.view_all'::"text") OR ("organization_id" = ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"())))));



CREATE POLICY "Read lessons of visible courses" ON "public"."training_lessons" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."training_courses" "c"
  WHERE (("c"."id" = "training_lessons"."course_id") AND ((("c"."status" = 'published'::"text") AND ("c"."deleted_at" IS NULL)) OR "public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))))));



CREATE POLICY "Read own training progress" ON "public"."training_lesson_progress" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Read project custom fields" ON "public"."project_custom_fields" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_custom_fields"."project_id"))));



CREATE POLICY "Read project field aggregations" ON "public"."project_field_aggregations" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_field_aggregations"."project_id"))));



CREATE POLICY "Read published or own training courses" ON "public"."training_courses" FOR SELECT TO "authenticated" USING (((("status" = 'published'::"text") AND ("deleted_at" IS NULL)) OR "public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read release_notes with admin access" ON "public"."release_notes" FOR SELECT TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.access'::"text"));



CREATE POLICY "Read reporting_sync_alerts with registry view or admin" ON "public"."reporting_sync_alerts" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.registry.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Read resources of visible courses" ON "public"."training_resources" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."training_courses" "c"
  WHERE (("c"."id" = "training_resources"."course_id") AND ((("c"."status" = 'published'::"text") AND ("c"."deleted_at" IS NULL)) OR "public"."has_permission"("auth"."uid"(), 'kb.edit_any'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))))));



CREATE POLICY "Read task custom field values" ON "public"."task_custom_field_values" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_custom_field_values"."task_id"))));



CREATE POLICY "Read task project memberships" ON "public"."task_project_memberships" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_project_memberships"."task_id"))) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "task_project_memberships"."project_id")))));



CREATE POLICY "Remove task from project" ON "public"."task_project_memberships" FOR DELETE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_project_memberships"."task_id"))) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "task_project_memberships"."project_id")))));



CREATE POLICY "Reporting and admin users can read contact classifications" ON "public"."hubspot_contact_classifications" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_companies" ON "public"."hs_companies" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_contacts" ON "public"."hs_contacts" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_deals" ON "public"."hs_deals" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_engagements" ON "public"."hs_engagements" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_owners" ON "public"."hs_owners" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Reporting and admin users can read hs_sync_log" ON "public"."hs_sync_log" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'reporting.member_firm_pipeline.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Requesting firm can answer questions" ON "public"."laa_rfp_questions" FOR UPDATE TO "authenticated" USING (("rfp_id" IN ( SELECT "laa_rfps"."id"
   FROM "public"."laa_rfps"
  WHERE ("laa_rfps"."requesting_org_id" = ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"()))))));



CREATE POLICY "Role managers can manage permissions" ON "public"."permissions" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.roles.manage'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.roles.manage'::"text"));



CREATE POLICY "Role managers can manage roles" ON "public"."roles" TO "authenticated" USING ("public"."has_permission"("auth"."uid"(), 'admin.roles.manage'::"text")) WITH CHECK ("public"."has_permission"("auth"."uid"(), 'admin.roles.manage'::"text"));



CREATE POLICY "SSG advisors can read ssg_advisors" ON "public"."ssg_advisors" FOR SELECT TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg tasks" ON "public"."tasks" TO "authenticated" USING ((("source_type" = 'ssg_engagement'::"text") AND "public"."is_ssg_advisor"("auth"."uid"()))) WITH CHECK ((("source_type" = 'ssg_engagement'::"text") AND "public"."is_ssg_advisor"("auth"."uid"())));



CREATE POLICY "SSG advisors manage ssg_calendar_events" ON "public"."ssg_calendar_events" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_emails" ON "public"."ssg_emails" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_engagements" ON "public"."ssg_engagements" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_insights" ON "public"."ssg_insights" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_meetings" ON "public"."ssg_meetings" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG advisors manage ssg_outcomes" ON "public"."ssg_outcomes" TO "authenticated" USING ("public"."is_ssg_advisor"("auth"."uid"())) WITH CHECK ("public"."is_ssg_advisor"("auth"."uid"()));



CREATE POLICY "SSG managers delete ssg_insights" ON "public"."ssg_insights" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG managers insert ssg_insights" ON "public"."ssg_insights" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG managers update ssg_insights" ON "public"."ssg_insights" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_calendar_events" ON "public"."ssg_calendar_events" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_emails" ON "public"."ssg_emails" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_engagements" ON "public"."ssg_engagements" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_meetings" ON "public"."ssg_meetings" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can delete ssg_outcomes" ON "public"."ssg_outcomes" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_calendar_events" ON "public"."ssg_calendar_events" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_emails" ON "public"."ssg_emails" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_engagements" ON "public"."ssg_engagements" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_meetings" ON "public"."ssg_meetings" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can insert ssg_outcomes" ON "public"."ssg_outcomes" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_advisors" ON "public"."ssg_advisors" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_calendar_events" ON "public"."ssg_calendar_events" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_emails" ON "public"."ssg_emails" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_engagements" ON "public"."ssg_engagements" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_meetings" ON "public"."ssg_meetings" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can read ssg_outcomes" ON "public"."ssg_outcomes" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_calendar_events" ON "public"."ssg_calendar_events" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_emails" ON "public"."ssg_emails" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_engagement_contacts" ON "public"."ssg_engagement_contacts" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_engagements" ON "public"."ssg_engagements" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_meetings" ON "public"."ssg_meetings" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users can update ssg_outcomes" ON "public"."ssg_outcomes" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "SSG users read ssg_insights" ON "public"."ssg_insights" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.ssg-engagements.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can delete firm_software" ON "public"."firm_software" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can delete firm_software_costs" ON "public"."firm_software_costs" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can delete software_categories" ON "public"."software_categories" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can delete software_products" ON "public"."software_products" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can insert firm_software" ON "public"."firm_software" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can insert firm_software_costs" ON "public"."firm_software_costs" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can insert software_categories" ON "public"."software_categories" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can insert software_products" ON "public"."software_products" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can read firm_software" ON "public"."firm_software" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can read firm_software_costs" ON "public"."firm_software_costs" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can read software_categories" ON "public"."software_categories" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can read software_products" ON "public"."software_products" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can update firm_software" ON "public"."firm_software" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can update firm_software_costs" ON "public"."firm_software_costs" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can update software_categories" ON "public"."software_categories" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Software users can update software_products" ON "public"."software_products" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'software.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Task participants can upload attachments" ON "public"."task_attachments" FOR INSERT TO "authenticated" WITH CHECK ((("uploaded_by" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE (("t"."id" = "task_attachments"."task_id") AND (("t"."assigned_to" = "auth"."uid"()) OR ("t"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")))))));



CREATE POLICY "Ticket owner can read public messages" ON "public"."ticket_messages" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("public"."has_permission"("auth"."uid"(), 'tickets.manage'::"text") OR (("is_internal_note" = false) AND ("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"())))))));



CREATE POLICY "Update own or admin custom field definitions" ON "public"."custom_field_definitions" FOR UPDATE TO "authenticated" USING ((("created_by" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK ((("created_by" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "Update own training progress" ON "public"."training_lesson_progress" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Update project custom fields" ON "public"."project_custom_fields" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_custom_fields"."project_id")))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_custom_fields"."project_id"))));



CREATE POLICY "Update project field aggregations" ON "public"."project_field_aggregations" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_field_aggregations"."project_id")))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "project_field_aggregations"."project_id"))));



CREATE POLICY "Update task custom field values" ON "public"."task_custom_field_values" FOR UPDATE TO "authenticated" USING ("public"."can_edit_task"("auth"."uid"(), "task_id")) WITH CHECK ("public"."can_edit_task"("auth"."uid"(), "task_id"));



CREATE POLICY "Update task project membership" ON "public"."task_project_memberships" FOR UPDATE TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_project_memberships"."task_id"))) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "task_project_memberships"."project_id"))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE ("t"."id" = "task_project_memberships"."task_id"))) AND (EXISTS ( SELECT 1
   FROM "public"."projects" "p"
  WHERE ("p"."id" = "task_project_memberships"."project_id")))));



CREATE POLICY "Uploader or admin can delete attachments" ON "public"."task_attachments" FOR DELETE TO "authenticated" USING ((("uploaded_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can add collaborators" ON "public"."task_collaborators" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Users can delete own comment mentions" ON "public"."comment_mentions" FOR DELETE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("comment_id" IN ( SELECT "tc"."id"
   FROM "public"."task_comments" "tc"
  WHERE ("tc"."author_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete own documents" ON "public"."documents" FOR DELETE USING (("uploaded_by" = "auth"."uid"()));



CREATE POLICY "Users can delete own folders" ON "public"."document_folders" FOR DELETE TO "authenticated" USING (("created_by" = "auth"."uid"()));



CREATE POLICY "Users can delete own saved views" ON "public"."task_saved_views" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can insert RFPs for their org" ON "public"."laa_rfps" FOR INSERT TO "authenticated" WITH CHECK (("requesting_org_id" = ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert bids for their org" ON "public"."laa_rfp_bids" FOR INSERT TO "authenticated" WITH CHECK (("bidding_org_id" = ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert comment mentions" ON "public"."comment_mentions" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("comment_id" IN ( SELECT "tc"."id"
   FROM "public"."task_comments" "tc"
  WHERE ("tc"."author_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert messages" ON "public"."ticket_messages" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND ("author_id" = "auth"."uid"()) AND ("public"."has_permission"("auth"."uid"(), 'tickets.manage'::"text") OR (("is_internal_note" = false) AND ("ticket_id" IN ( SELECT "tickets"."id"
   FROM "public"."tickets"
  WHERE ("tickets"."submitted_by" = "auth"."uid"())))))));



CREATE POLICY "Users can insert own automation logs" ON "public"."my_task_automation_logs" FOR INSERT TO "authenticated" WITH CHECK (("automation_id" IN ( SELECT "my_task_automations"."id"
   FROM "public"."my_task_automations"
  WHERE ("my_task_automations"."user_id" = "auth"."uid"()))));



CREATE POLICY "Users can insert own preferences" ON "public"."user_notification_preferences" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own saved views" ON "public"."task_saved_views" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can insert own submission edit logs" ON "public"."checkin_edit_log" FOR INSERT TO "authenticated" WITH CHECK ((("edited_by" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."checkin_submissions" "cs"
  WHERE (("cs"."id" = "checkin_edit_log"."submission_id") AND ("cs"."assignee_id" = "auth"."uid"()))))));



CREATE POLICY "Users can insert questions" ON "public"."laa_rfp_questions" FOR INSERT TO "authenticated" WITH CHECK (("asking_org_id" = ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert relevant overrides" ON "public"."checklist_item_overrides" FOR INSERT WITH CHECK ((("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can manage own automations" ON "public"."my_task_automations" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own favorites" ON "public"."project_favorites" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own home layout" ON "public"."user_home_layouts" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own pins" ON "public"."pinned_items" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own section assignments" ON "public"."my_task_section_assignments" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own sections" ON "public"."my_task_sections" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage own stars" ON "public"."document_stars" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can manage relevant custom items" ON "public"."checklist_custom_items" USING (("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))));



CREATE POLICY "Users can only insert own activity logs" ON "public"."activity_logs" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND (("user_id" = "auth"."uid"()) OR ("user_id" IS NULL))));



CREATE POLICY "Users can read comment mentions" ON "public"."comment_mentions" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("comment_id" IN ( SELECT "tc"."id"
   FROM "public"."task_comments" "tc"
  WHERE ("tc"."task_id" IN ( SELECT "t"."id"
           FROM "public"."tasks" "t"
          WHERE (("t"."assigned_to" = "auth"."uid"()) OR ("t"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("t"."assigned_to" IN ( SELECT "p"."id"
                   FROM "public"."profiles" "p"
                  WHERE ("p"."manager_id" = "auth"."uid"()))))))))));



CREATE POLICY "Users can read own assignments" ON "public"."checklist_assignments" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR ("organization_id" IN ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read own automation logs" ON "public"."my_task_automation_logs" FOR SELECT TO "authenticated" USING (("automation_id" IN ( SELECT "my_task_automations"."id"
   FROM "public"."my_task_automations"
  WHERE ("my_task_automations"."user_id" = "auth"."uid"()))));



CREATE POLICY "Users can read own checkin_assignments" ON "public"."checkin_assignments" FOR SELECT TO "authenticated" USING ((("assignee_id" = "auth"."uid"()) OR ("manager_id" = "auth"."uid"())));



CREATE POLICY "Users can read own doc notifications" ON "public"."document_notifications" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own documents" ON "public"."documents" FOR SELECT USING ((("uploaded_by" = "auth"."uid"()) AND ("deleted_at" IS NULL)));



CREATE POLICY "Users can read own favorites" ON "public"."project_favorites" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own inbox items" ON "public"."inbox_items" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own linked emails" ON "public"."linked_emails" FOR SELECT TO "authenticated" USING (("primary_user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own notifications" ON "public"."ticket_notifications" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own pins" ON "public"."pinned_items" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own preferences" ON "public"."user_notification_preferences" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read own role" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own role assignment" ON "public"."user_role_assignments" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own saved views" ON "public"."task_saved_views" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own submission edit logs" ON "public"."checkin_edit_log" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."checkin_submissions" "cs"
  WHERE (("cs"."id" = "checkin_edit_log"."submission_id") AND (("cs"."assignee_id" = "auth"."uid"()) OR ("cs"."manager_id" = "auth"."uid"()))))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read own task notifications" ON "public"."task_notifications" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("user_id" = "auth"."uid"())));



CREATE POLICY "Users can read permissions they are granted" ON "public"."document_permissions" FOR SELECT USING ((("granted_to_user_id" = "auth"."uid"()) OR ("granted_to_org_id" IN ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))) OR ("granted_to_tag" IN ( SELECT "unnest"("profiles"."tags") AS "unnest"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))) OR ("granted_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read relevant custom items" ON "public"."checklist_custom_items" FOR SELECT USING ((("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read relevant overrides" ON "public"."checklist_item_overrides" FOR SELECT USING ((("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read relevant progress" ON "public"."checklist_progress" FOR SELECT TO "authenticated" USING ((("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role")));



CREATE POLICY "Users can read relevant tasks" ON "public"."tasks" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND (("assigned_to" = "auth"."uid"()) OR ("assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("assigned_to" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))))));



CREATE POLICY "Users can read task attachments" ON "public"."task_attachments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE (("t"."id" = "task_attachments"."task_id") AND (("t"."assigned_to" = "auth"."uid"()) OR ("t"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))))));



CREATE POLICY "Users can read task comments" ON "public"."task_comments" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("task_id" IN ( SELECT "tasks"."id"
   FROM "public"."tasks"
  WHERE (("tasks"."assigned_to" = "auth"."uid"()) OR ("tasks"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("tasks"."assigned_to" IN ( SELECT "profiles"."id"
           FROM "public"."profiles"
          WHERE ("profiles"."manager_id" = "auth"."uid"()))))))));



CREATE POLICY "Users can read task history" ON "public"."task_history" FOR SELECT TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("task_id" IN ( SELECT "tasks"."id"
   FROM "public"."tasks"
  WHERE (("tasks"."assigned_to" = "auth"."uid"()) OR ("tasks"."assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role") OR ("tasks"."assigned_to" IN ( SELECT "profiles"."id"
           FROM "public"."profiles"
          WHERE ("profiles"."manager_id" = "auth"."uid"()))))))));



CREATE POLICY "Users can remove collaborators" ON "public"."task_collaborators" FOR DELETE TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."name" = 'Admin'::"text") AND ("cr"."is_system" = true)))) OR (EXISTS ( SELECT 1
   FROM "public"."tasks" "t"
  WHERE (("t"."id" = "task_collaborators"."task_id") AND (("t"."assigned_by" = "auth"."uid"()) OR ("t"."assigned_to" = "auth"."uid"())))))));



CREATE POLICY "Users can update own doc notifications" ON "public"."document_notifications" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own documents" ON "public"."documents" FOR UPDATE USING (("uploaded_by" = "auth"."uid"()));



CREATE POLICY "Users can update own folders" ON "public"."document_folders" FOR UPDATE TO "authenticated" USING (("created_by" = "auth"."uid"()));



CREATE POLICY "Users can update own inbox items" ON "public"."inbox_items" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own notifications" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own notifications" ON "public"."ticket_notifications" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own preferences" ON "public"."user_notification_preferences" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "Users can update own saved views" ON "public"."task_saved_views" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own task notifications" ON "public"."task_notifications" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND ("user_id" = "auth"."uid"())));



CREATE POLICY "Users can update relevant overrides" ON "public"."checklist_item_overrides" FOR UPDATE USING (("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))));



CREATE POLICY "Users can update relevant progress" ON "public"."checklist_progress" FOR UPDATE TO "authenticated" USING (("assignment_id" IN ( SELECT "checklist_assignments"."id"
   FROM "public"."checklist_assignments"
  WHERE (("checklist_assignments"."user_id" = "auth"."uid"()) OR ("checklist_assignments"."organization_id" IN ( SELECT "profiles"."organization_id"
           FROM "public"."profiles"
          WHERE ("profiles"."id" = "auth"."uid"())))))));



CREATE POLICY "Users can update relevant tasks" ON "public"."tasks" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND (("assigned_to" = "auth"."uid"()) OR ("assigned_by" = "auth"."uid"()) OR "public"."has_role"("auth"."uid"(), 'admin'::"public"."app_role"))));



CREATE POLICY "Users can update their org's RFPs" ON "public"."laa_rfps" FOR UPDATE TO "authenticated" USING (("requesting_org_id" = ( SELECT "profiles"."organization_id"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))));



CREATE POLICY "Users manage own email activity" ON "public"."email_activity_log" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own email connections" ON "public"."email_connections" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own prep reminder prefs" ON "public"."prep_reminder_preferences" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users manage own tokens" ON "public"."hub_api_tokens" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users manage their own queues" ON "public"."sdr_prospect_queues" USING (("auth"."uid"() = "partner_user_id")) WITH CHECK (("auth"."uid"() = "partner_user_id"));



CREATE POLICY "Users read own prep briefs" ON "public"."prep_briefs" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users read own prep_calendar_events" ON "public"."prep_calendar_events" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users with explicit permission can read documents" ON "public"."documents" FOR SELECT USING ((("deleted_at" IS NULL) AND "public"."has_document_permission"("auth"."uid"(), "id")));



ALTER TABLE "public"."activity_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."announcements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "anon can insert assessment leads" ON "public"."assessment_leads" FOR INSERT TO "anon" WITH CHECK (true);



ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."assessment_leads" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "auth delete" ON "public"."laa_agreements_log" FOR DELETE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth insert" ON "public"."laa_agreements_log" FOR INSERT WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth read" ON "public"."laa_agreements_log" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth read" ON "public"."laa_cpa_rules" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth read" ON "public"."laa_firm_compensation" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth read" ON "public"."laa_firms" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth read" ON "public"."laa_recipient_rules" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth update" ON "public"."laa_agreements_log" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth write" ON "public"."laa_firm_compensation" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "auth write" ON "public"."laa_firms" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "authenticated read tas_businesses" ON "public"."tas_businesses" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated read tas_contacts" ON "public"."tas_contacts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated read tas_sequence_steps" ON "public"."tas_sequence_steps" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated read tas_sequences" ON "public"."tas_sequences" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated write tas_businesses" ON "public"."tas_businesses" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated write tas_contacts" ON "public"."tas_contacts" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated write tas_sequence_steps" ON "public"."tas_sequence_steps" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated write tas_sequences" ON "public"."tas_sequences" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."bdr_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bdr_business_people" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bdr_businesses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bdr_email_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "bdr_email_templates_delete_own" ON "public"."bdr_email_templates" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bdr_email_templates_insert_own" ON "public"."bdr_email_templates" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "bdr_email_templates_select_own" ON "public"."bdr_email_templates" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bdr_email_templates_update_own" ON "public"."bdr_email_templates" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."bdr_prospects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bdr_seamless_staging" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_plan_checkins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_plan_revenue_drivers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."business_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checkin_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checkin_edit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checkin_submissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checkin_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_custom_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_item_overrides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_progress" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."checklist_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_mentions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."custom_field_definitions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."custom_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dashboard_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dashboard_datasets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dashboards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."data_sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dataset_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."datasets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."desks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_folders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_stars" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_activity_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_connections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expansion_email_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "expansion_email_templates_delete_own" ON "public"."expansion_email_templates" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "expansion_email_templates_insert_own" ON "public"."expansion_email_templates" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "expansion_email_templates_select_own" ON "public"."expansion_email_templates" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "expansion_email_templates_update_own" ON "public"."expansion_email_templates" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."expansion_opportunities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expansion_research_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "expansion_research_runs_insert" ON "public"."expansion_research_runs" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text")));



CREATE POLICY "expansion_research_runs_select" ON "public"."expansion_research_runs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "expansion_research_runs_update" ON "public"."expansion_research_runs" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text"))) WITH CHECK (("public"."is_active_user"("auth"."uid"()) AND "public"."has_permission"("auth"."uid"(), 'desks.access'::"text")));



ALTER TABLE "public"."firm_software" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."firm_software_costs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hcfv read" ON "public"."hris_custom_field_values" FOR SELECT TO "authenticated" USING (((("entity_type" = 'hris_leave_request'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_leave_requests" "r"
  WHERE ("r"."id" = "hris_custom_field_values"."entity_id")))) OR (("entity_type" = 'hris_employee_details'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_employee_details" "d"
  WHERE ("d"."profile_id" = "hris_custom_field_values"."entity_id")))) OR (("entity_type" = 'hris_benefit_plan'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_benefit_plans" "p"
  WHERE ("p"."id" = "hris_custom_field_values"."entity_id")))) OR (("entity_type" = 'hris_checklist_template'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_checklist_templates" "t"
  WHERE ("t"."id" = "hris_custom_field_values"."entity_id")))) OR (("entity_type" = 'hris_checklist_template_item'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_checklist_template_items" "i"
  WHERE ("i"."id" = "hris_custom_field_values"."entity_id"))))));



CREATE POLICY "hcfv write" ON "public"."hris_custom_field_values" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR (("entity_type" = 'hris_leave_request'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_leave_requests" "r"
  WHERE (("r"."id" = "hris_custom_field_values"."entity_id") AND ("r"."employee_id" = "auth"."uid"()))))))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text") OR (("entity_type" = 'hris_leave_request'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."hris_leave_requests" "r"
  WHERE (("r"."id" = "hris_custom_field_values"."entity_id") AND ("r"."employee_id" = "auth"."uid"())))))));



CREATE POLICY "hris comp insert" ON "public"."hris_compensation" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris comp read" ON "public"."hris_compensation" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris details delete" ON "public"."hris_employee_details" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris details insert" ON "public"."hris_employee_details" FOR INSERT TO "authenticated" WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris details read" ON "public"."hris_employee_details" FOR SELECT TO "authenticated" USING ((("profile_id" = "auth"."uid"()) OR ("profile_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris details update" ON "public"."hris_employee_details" FOR UPDATE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec delete" ON "public"."hris_emergency_contacts" FOR DELETE TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec insert" ON "public"."hris_emergency_contacts" FOR INSERT TO "authenticated" WITH CHECK ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec read" ON "public"."hris_emergency_contacts" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec update" ON "public"."hris_emergency_contacts" FOR UPDATE TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec_list read" ON "public"."hris_employee_checklists" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris ec_list write" ON "public"."hris_employee_checklists" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris enroll read" ON "public"."hris_benefit_enrollments" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris enroll write" ON "public"."hris_benefit_enrollments" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lb read" ON "public"."hris_leave_balances" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lb write" ON "public"."hris_leave_balances" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lr delete" ON "public"."hris_leave_requests" FOR DELETE TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lr insert" ON "public"."hris_leave_requests" FOR INSERT TO "authenticated" WITH CHECK ((("employee_id" = "auth"."uid"()) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lr read" ON "public"."hris_leave_requests" FOR SELECT TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lr update" ON "public"."hris_leave_requests" FOR UPDATE TO "authenticated" USING ((("employee_id" = "auth"."uid"()) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (((("employee_id" = "auth"."uid"()) AND ("status" = 'cancelled'::"text")) OR ("employee_id" IN ( SELECT "profiles"."id"
   FROM "public"."profiles"
  WHERE ("profiles"."manager_id" = "auth"."uid"()))) OR "public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris lt read" ON "public"."hris_leave_types" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "hris lt write" ON "public"."hris_leave_types" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris plan read" ON "public"."hris_benefit_plans" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "hris plan write" ON "public"."hris_benefit_plans" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.comp'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris tmpl item read" ON "public"."hris_checklist_template_items" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris tmpl item write" ON "public"."hris_checklist_template_items" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris tmpl read" ON "public"."hris_checklist_templates" FOR SELECT TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.view'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



CREATE POLICY "hris tmpl write" ON "public"."hris_checklist_templates" TO "authenticated" USING (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text"))) WITH CHECK (("public"."has_permission"("auth"."uid"(), 'desks.hris.manage'::"text") OR "public"."has_permission"("auth"."uid"(), 'admin.access'::"text")));



ALTER TABLE "public"."hris_benefit_enrollments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_benefit_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_checklist_template_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_checklist_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_compensation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_custom_field_values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_emergency_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_employee_checklists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_employee_details" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_leave_action_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_leave_balances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_leave_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hris_leave_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_companies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_deals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_engagements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_owners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hs_sync_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hub_api_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hubspot_contact_classifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hubspot_engagement_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hubspot_engagements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inbox_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_description_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_descriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."knowledge_base_article_page_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."knowledge_base_articles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."knowledge_base_edit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_agreements_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_canopy_payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_cpa_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_firm_compensation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_firm_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_firms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_recipient_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_referral_payouts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_rfp_bids" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_rfp_questions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_rfps" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."laa_service_catalog" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."linked_emails" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "marketing_site_partners_read" ON "public"."profiles" FOR SELECT TO "anon" USING ((("status" = 'active'::"text") AND ("avatar_url" IS NOT NULL)));



ALTER TABLE "public"."my_task_automation_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."my_task_automations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."my_task_section_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."my_task_sections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nine_box_scores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ninety_user_mappings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."oauth_access_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."oauth_authorization_codes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."oauth_clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."oauth_refresh_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pinned_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."prep_briefs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."prep_calendar_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."prep_reminder_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_custom_fields" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_field_aggregations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_resources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_sections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_share_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_shared_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_template_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_template_sections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_template_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quick_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."release_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reporting_sync_alerts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."role_permissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rtl_accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_accounts_select" ON "public"."rtl_accounts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."rtl_contacts" "c"
  WHERE (("c"."id" = "rtl_accounts"."contact_id") AND "public"."can_view_rtl_contact"("c"."organization_id")))));



ALTER TABLE "public"."rtl_activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_activities_select" ON "public"."rtl_activities" FOR SELECT USING ((("contact_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."rtl_contacts" "c"
  WHERE (("c"."id" = "rtl_activities"."contact_id") AND "public"."can_view_rtl_contact"("c"."organization_id")))) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = 'wealth.view_all'::"text"))))));



ALTER TABLE "public"."rtl_contact_org_mapping" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_contact_org_mapping_all" ON "public"."rtl_contact_org_mapping" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."is_system" = true) AND ("cr"."name" = 'Admin'::"text")))));



CREATE POLICY "rtl_contact_org_mapping_select" ON "public"."rtl_contact_org_mapping" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."is_system" = true) AND ("cr"."name" = 'Admin'::"text")))));



ALTER TABLE "public"."rtl_contacts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_contacts_select" ON "public"."rtl_contacts" FOR SELECT USING ("public"."can_view_rtl_contact"("organization_id"));



ALTER TABLE "public"."rtl_firm_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_firm_settings_select" ON "public"."rtl_firm_settings" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = ANY (ARRAY['wealth.view'::"text", 'wealth.view_all'::"text", 'wealth.admin'::"text"]))))) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."is_system" = true) AND ("cr"."name" = 'Admin'::"text"))))));



CREATE POLICY "rtl_firm_settings_write" ON "public"."rtl_firm_settings" USING (((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = 'wealth.admin'::"text")))) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."is_system" = true) AND ("cr"."name" = 'Admin'::"text"))))));



ALTER TABLE "public"."rtl_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_notes_select" ON "public"."rtl_notes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."rtl_contacts" "c"
  WHERE (("c"."id" = "rtl_notes"."contact_id") AND "public"."can_view_rtl_contact"("c"."organization_id")))));



ALTER TABLE "public"."rtl_opportunities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_opportunities_select" ON "public"."rtl_opportunities" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."rtl_contacts" "c"
  WHERE (("c"."id" = "rtl_opportunities"."contact_id") AND "public"."can_view_rtl_contact"("c"."organization_id")))));



ALTER TABLE "public"."rtl_reminders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_reminders_select" ON "public"."rtl_reminders" FOR SELECT USING ((("contact_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."rtl_contacts" "c"
  WHERE (("c"."id" = "rtl_reminders"."contact_id") AND "public"."can_view_rtl_contact"("c"."organization_id")))) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = 'wealth.view_all'::"text"))))));



ALTER TABLE "public"."rtl_sync_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rtl_sync_log_select" ON "public"."rtl_sync_log" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."role_permissions" "rp" ON (("rp"."role_id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("rp"."permission_key" = ANY (ARRAY['wealth.view'::"text", 'wealth.view_all'::"text", 'wealth.sync'::"text"]))))) OR (EXISTS ( SELECT 1
   FROM ("public"."user_role_assignments" "ura"
     JOIN "public"."custom_roles" "cr" ON (("cr"."id" = "ura"."role_id")))
  WHERE (("ura"."user_id" = "auth"."uid"()) AND ("cr"."is_system" = true) AND ("cr"."name" = 'Admin'::"text"))))));



ALTER TABLE "public"."rtl_sync_state" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rule_sets_delete_own" ON "public"."sdr_rule_sets" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "rule_sets_insert_own" ON "public"."sdr_rule_sets" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "rule_sets_select_own" ON "public"."sdr_rule_sets" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "rule_sets_update_own" ON "public"."sdr_rule_sets" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."sdr_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_email_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sdr_email_templates_delete_own" ON "public"."sdr_email_templates" FOR DELETE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "sdr_email_templates_insert_own" ON "public"."sdr_email_templates" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "sdr_email_templates_select_own" ON "public"."sdr_email_templates" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "sdr_email_templates_update_own" ON "public"."sdr_email_templates" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."sdr_firm_staff" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_firms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_known_acquisitions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_prospect_queues" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_rule_sets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sdr_seamless_imports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service role full access" ON "public"."assessment_leads" TO "service_role" USING (true);



ALTER TABLE "public"."software_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."software_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_advisors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_calendar_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_emails" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_engagement_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_engagements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_functions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_insights" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_meetings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_member_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ssg_outcomes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_businesses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_consultant_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_inmail_budget" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_sequence_steps" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tas_sequences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_collaborators" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_custom_field_values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_project_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."task_saved_views" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_field_definitions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_field_values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ticket_statuses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tickets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."training_courses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."training_lesson_progress" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."training_lessons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."training_resources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transition_assessment_submissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_home_layouts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_notification_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_role_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users read own inmail budget" ON "public"."tas_inmail_budget" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "users write own inmail budget" ON "public"."tas_inmail_budget" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."vendor_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vendors" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."project_favorites";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."project_sections";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."projects";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."task_project_memberships";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."tasks";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































































































































REVOKE ALL ON FUNCTION "public"."_user_ref_columns"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_user_ref_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."action_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid", "p_action" "text", "p_flag_reason" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."action_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid", "p_action" "text", "p_flag_reason" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."action_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid", "p_action" "text", "p_flag_reason" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_mcp_connections"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_mcp_connections"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_mcp_connections"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_merge_user_data"("p_primary" "uuid", "p_secondary" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_merge_user_data"("p_primary" "uuid", "p_secondary" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_revoke_mcp_connection"("target_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_pending_user"("target_user_id" "uuid", "target_role" "text", "target_organization_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_pending_user"("target_user_id" "uuid", "target_role" "text", "target_organization_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_pending_user"("target_user_id" "uuid", "target_role" "text", "target_organization_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_add_reassigned_collaborator"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_add_reassigned_collaborator"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_add_reassigned_collaborator"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_add_task_collaborators"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_add_task_collaborators"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_add_task_collaborators"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_complete_batch"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_complete_batch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_complete_batch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bdr_email_templates_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."bdr_email_templates_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bdr_email_templates_set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."bulk_claim_sdr_firms"("p_user_id" "uuid", "p_firm_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."bulk_claim_sdr_firms"("p_user_id" "uuid", "p_firm_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_claim_sdr_firms"("p_user_id" "uuid", "p_firm_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_edit_task"("uid" "uuid", "tid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_manage_job_description"("p_profile_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_manage_project"("_user_id" "uuid", "_project_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_manage_project"("_user_id" "uuid", "_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_manage_project"("_user_id" "uuid", "_project_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_read_task_via_project"("uid" "uuid", "tid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_view_rtl_contact"("p_contact_org_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_view_rtl_contact"("p_contact_org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_view_rtl_contact"("p_contact_org_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."clone_sdr_rule_set"("p_source_id" "uuid", "p_new_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clone_sdr_rule_set"("p_source_id" "uuid", "p_new_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_filtered_batch"("p_user_id" "uuid", "p_user_name" "text", "p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean, "p_batch_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_filtered_batch"("p_user_id" "uuid", "p_user_name" "text", "p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean, "p_batch_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_filtered_batch"("p_user_id" "uuid", "p_user_name" "text", "p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean, "p_batch_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_sdr_queue"("p_user_id" "uuid", "p_user_name" "text", "p_queue_name" "text", "p_queue_size" integer, "p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_sdr_queue"("p_user_id" "uuid", "p_user_name" "text", "p_queue_name" "text", "p_queue_size" integer, "p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_sdr_queue"("p_user_id" "uuid", "p_user_name" "text", "p_queue_name" "text", "p_queue_size" integer, "p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_sdr_rule_set"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_sdr_rule_set"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_sdr_rule_set"("p_rule_set_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_sdr_rule_set"("p_rule_set_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_ssg_engagement"("_engagement_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_bdr_crawl_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_bdr_crawl_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bdr_crawl_stats"() TO "service_role";



GRANT ALL ON TABLE "public"."bdr_email_templates" TO "anon";
GRANT ALL ON TABLE "public"."bdr_email_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_email_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_email_templates" TO "website_reader";



GRANT ALL ON FUNCTION "public"."get_bdr_email_templates_for"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_bdr_email_templates_for"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bdr_email_templates_for"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_bdr_geocode_coverage"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_bdr_geocode_coverage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bdr_geocode_coverage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_effective_folder_visibility"("_folder_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_effective_folder_visibility"("_folder_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_effective_folder_visibility"("_folder_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_filtered_prospect_count"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_filtered_prospect_count"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_filtered_prospect_count"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_api_token_info"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_api_token_info"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_api_token_info"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_claimed_firms"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_claimed_firms"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_claimed_firms"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_claimed_prospects"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_claimed_prospects"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_claimed_prospects"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_onboarding_overdue_summary"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_onboarding_overdue_summary"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_onboarding_overdue_summary"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_user_tokens"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_user_tokens"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_user_tokens"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pool_stats"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_pool_stats"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pool_stats"("p_title_categories" "text"[], "p_states" "text"[], "p_sectors" "text"[], "p_re_flag" boolean, "p_rd_flag" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_sdr_eligible_gap_count"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_sdr_eligible_gap_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_eligible_gap_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_eligible_gap_count"() TO "service_role";



GRANT ALL ON TABLE "public"."sdr_email_templates" TO "anon";
GRANT ALL ON TABLE "public"."sdr_email_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_email_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_email_templates" TO "website_reader";



GRANT ALL ON FUNCTION "public"."get_sdr_email_templates_for"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_email_templates_for"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_count"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_count"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_count"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_stats"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_stats"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_firm_pool_stats"("p_states" "text"[], "p_min_staff" integer, "p_max_staff" integer, "p_min_partners" integer, "p_max_partners" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_firms_for_map"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_firms_for_map"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_firms_for_map"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_geocode_coverage"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_geocode_coverage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_geocode_coverage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_hubspot_coverage"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_hubspot_coverage"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_hubspot_coverage"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_queue_firms"("p_queue_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_queue_firms"("p_queue_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_queue_firms"("p_queue_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_sdr_skipped_firms"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_sdr_skipped_firms"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_sdr_skipped_firms"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_skipped_firms"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sdr_templates_for_rule_set"("p_rule_set_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sdr_templates_for_rule_set"("p_rule_set_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_permissions"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_permissions"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_permissions"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role_name"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role_name"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role_name"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."has_document_permission"("_user_id" "uuid", "_document_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."has_document_permission"("_user_id" "uuid", "_document_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_document_permission"("_user_id" "uuid", "_document_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_folder_permission"("_user_id" "uuid", "_folder_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."has_folder_permission"("_user_id" "uuid", "_folder_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_folder_permission"("_user_id" "uuid", "_folder_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_permission_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_permission_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_permission"("_user_id" "uuid", "_permission_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "anon";
GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_role"("_user_id" "uuid", "_role" "public"."app_role") TO "service_role";



GRANT ALL ON FUNCTION "public"."hris_apply_leave_balance"() TO "anon";
GRANT ALL ON FUNCTION "public"."hris_apply_leave_balance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."hris_apply_leave_balance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hris_default_employee_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."hris_default_employee_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."hris_default_employee_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hris_start_checklist"("p_template_id" "uuid", "p_employee_id" "uuid", "p_start_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."hris_start_checklist"("p_template_id" "uuid", "p_employee_id" "uuid", "p_start_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hris_start_checklist"("p_template_id" "uuid", "p_employee_id" "uuid", "p_start_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."hydrate_sdr_from_seamless"("p_industries" "text"[], "p_states" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."hydrate_sdr_from_seamless"("p_industries" "text"[], "p_states" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hydrate_sdr_from_seamless"("p_industries" "text"[], "p_states" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_on_comment_mention"() TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_on_comment_mention"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_on_comment_mention"() TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_on_project_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_on_project_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_on_project_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_on_task_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_on_task_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_on_task_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."inbox_on_task_comment"() TO "anon";
GRANT ALL ON FUNCTION "public"."inbox_on_task_comment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."inbox_on_task_comment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_inbox_item"("_user_id" "uuid", "_actor_id" "uuid", "_target_type" "text", "_target_id" "text", "_target_name" "text", "_event_type" "text", "_summary" "text", "_detail" "jsonb", "_link" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_inbox_item"("_user_id" "uuid", "_actor_id" "uuid", "_target_type" "text", "_target_id" "text", "_target_name" "text", "_event_type" "text", "_summary" "text", "_detail" "jsonb", "_link" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_inbox_item"("_user_id" "uuid", "_actor_id" "uuid", "_target_type" "text", "_target_id" "text", "_target_name" "text", "_event_type" "text", "_summary" "text", "_detail" "jsonb", "_link" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_notification"("_user_id" "uuid", "_actor_id" "uuid", "_type" "text", "_title" "text", "_body" "text", "_link" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_notification"("_user_id" "uuid", "_actor_id" "uuid", "_type" "text", "_title" "text", "_body" "text", "_link" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_notification"("_user_id" "uuid", "_actor_id" "uuid", "_type" "text", "_title" "text", "_body" "text", "_link" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_active_user"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_active_user"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_active_user"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_in_manager_chain"("_viewer_id" "uuid", "_assignee_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_in_manager_chain"("_viewer_id" "uuid", "_assignee_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_in_manager_chain"("_viewer_id" "uuid", "_assignee_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_manager_in_chain"("p_employee" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_project_member"("_user_id" "uuid", "_project_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_project_member"("_user_id" "uuid", "_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_project_member"("_user_id" "uuid", "_project_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_project_owner"("_user_id" "uuid", "_project_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_project_owner"("_user_id" "uuid", "_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_project_owner"("_user_id" "uuid", "_project_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."sdr_firms" TO "anon";
GRANT ALL ON TABLE "public"."sdr_firms" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_firms" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_firms" TO "website_reader";



GRANT ALL ON FUNCTION "public"."is_sdr_firm_fully_researched"("f" "public"."sdr_firms") TO "anon";
GRANT ALL ON FUNCTION "public"."is_sdr_firm_fully_researched"("f" "public"."sdr_firms") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_sdr_firm_fully_researched"("f" "public"."sdr_firms") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_seamless_default_revenue"("s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_seamless_default_revenue"("s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_seamless_default_revenue"("s" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_seamless_default_staff"("s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_seamless_default_staff"("s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_seamless_default_staff"("s" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_ssg_advisor"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_ssg_advisor"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_ssg_advisor"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_sdr_rule_sets_for"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_sdr_rule_sets_for"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_dataset_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."notify_dataset_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_dataset_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_task_assigned"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_task_assigned"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_task_assigned"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_ticket_assigned"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_ticket_assigned"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_ticket_assigned"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_ticket_created"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_ticket_created"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_ticket_created"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_ticket_owner_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_ticket_owner_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_ticket_owner_changed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_ticket_status_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_ticket_status_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_ticket_status_changed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."parse_staff_count"("s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."parse_staff_count"("s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."parse_staff_count"("s" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."prep_dispatch_due_digests"() TO "anon";
GRANT ALL ON FUNCTION "public"."prep_dispatch_due_digests"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prep_dispatch_due_digests"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prep_superiors"("_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."prep_superiors"("_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."prep_superiors"("_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_tag_self_escalation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_tag_self_escalation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_tag_self_escalation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_bdr_staging"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_bdr_staging"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reassign_ticket_owner"("p_ticket_id" "uuid", "p_new_owner_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reclaim_sdr_skipped_firm"("p_firm_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."release_bdr_batch"("p_batch_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."release_bdr_batch"("p_batch_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_bdr_batch"("p_batch_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_sdr_firm"("p_firm_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."release_sdr_queue"("p_queue_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."release_sdr_queue"("p_queue_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_sdr_queue"("p_queue_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_sdr_skipped_firm"("p_firm_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rename_sdr_rule_set"("p_rule_set_id" "uuid", "p_new_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rename_sdr_rule_set"("p_rule_set_id" "uuid", "p_new_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."report_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."report_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_sync_failure"("p_sync_function_name" "text", "p_error" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."report_sync_success"("p_table_name" "text", "p_row_count" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."report_sync_success"("p_table_name" "text", "p_row_count" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_sync_success"("p_table_name" "text", "p_row_count" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."reporting_dispatch_due_syncs"() TO "anon";
GRANT ALL ON FUNCTION "public"."reporting_dispatch_due_syncs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reporting_dispatch_due_syncs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reporting_owner_engagement_counts"("p_since" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."reporting_owner_engagement_counts"("p_since" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."reporting_owner_engagement_counts"("p_since" timestamp with time zone) TO "service_role";



GRANT ALL ON TABLE "public"."job_descriptions" TO "anon";
GRANT ALL ON TABLE "public"."job_descriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."job_descriptions" TO "service_role";
GRANT SELECT ON TABLE "public"."job_descriptions" TO "website_reader";



GRANT ALL ON FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_job_description"("p_profile_id" "uuid", "p_methodology" "text", "p_methodology_label" "text", "p_structure" "jsonb", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sdr_contact_engagement_summary"("_firm_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sdr_contact_engagement_summary"("_firm_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sdr_contact_engagement_summary"("_firm_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sdr_email_templates_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."sdr_email_templates_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sdr_email_templates_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sdr_engagement_sync_stats"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sdr_engagement_sync_stats"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sdr_engagement_sync_stats"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sdr_firm_response_status"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sdr_firm_response_status"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sdr_firm_response_status"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_active_sdr_rule_set"("p_rule_set_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_active_sdr_rule_set"("p_rule_set_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_rtl_firm_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_rtl_firm_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_rtl_firm_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_ticket_defaults"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_ticket_defaults"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_ticket_defaults"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_ticket_sequential_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_ticket_sequential_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_ticket_sequential_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at_sdr_rule_sets"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at_sdr_rule_sets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at_sdr_rule_sets"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tas_advance_sequence"("p_sequence_id" "uuid", "p_notes" "text", "p_copy_used" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."tas_advance_sequence"("p_sequence_id" "uuid", "p_notes" "text", "p_copy_used" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tas_advance_sequence"("p_sequence_id" "uuid", "p_notes" "text", "p_copy_used" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_expansion_email_templates_touch"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_expansion_email_templates_touch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_expansion_email_templates_touch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."track_email_open"("p_tracking_pixel_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."track_email_open"("p_tracking_pixel_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."track_email_open"("p_tracking_pixel_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."undo_import"("p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."undo_import"("p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."undo_import"("p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_document_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_document_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_document_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_task_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_task_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_task_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_ticket_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_ticket_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_ticket_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_has_tag"("_user_id" "uuid", "_tag" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_has_tag"("_user_id" "uuid", "_tag" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_has_tag"("_user_id" "uuid", "_tag" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_nine_box_score"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_nine_box_score"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_nine_box_score"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_notification_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_notification_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_notification_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_project_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_project_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_project_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_task_fields"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_task_fields"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_task_fields"() TO "service_role";
























GRANT ALL ON TABLE "public"."activity_logs" TO "anon";
GRANT ALL ON TABLE "public"."activity_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."activity_logs" TO "website_reader";



GRANT ALL ON TABLE "public"."announcements" TO "anon";
GRANT ALL ON TABLE "public"."announcements" TO "authenticated";
GRANT ALL ON TABLE "public"."announcements" TO "service_role";
GRANT SELECT ON TABLE "public"."announcements" TO "website_reader";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."app_settings" TO "website_reader";



GRANT ALL ON TABLE "public"."assessment_leads" TO "anon";
GRANT ALL ON TABLE "public"."assessment_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."assessment_leads" TO "service_role";
GRANT SELECT ON TABLE "public"."assessment_leads" TO "website_reader";



GRANT ALL ON TABLE "public"."bdr_batches" TO "anon";
GRANT ALL ON TABLE "public"."bdr_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_batches" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_batches" TO "website_reader";



GRANT ALL ON TABLE "public"."bdr_business_people" TO "anon";
GRANT ALL ON TABLE "public"."bdr_business_people" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_business_people" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_business_people" TO "website_reader";



GRANT ALL ON TABLE "public"."bdr_businesses" TO "anon";
GRANT ALL ON TABLE "public"."bdr_businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_businesses" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_businesses" TO "website_reader";



GRANT ALL ON TABLE "public"."bdr_prospects" TO "anon";
GRANT ALL ON TABLE "public"."bdr_prospects" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_prospects" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_prospects" TO "website_reader";



GRANT ALL ON TABLE "public"."bdr_seamless_staging" TO "anon";
GRANT ALL ON TABLE "public"."bdr_seamless_staging" TO "authenticated";
GRANT ALL ON TABLE "public"."bdr_seamless_staging" TO "service_role";
GRANT SELECT ON TABLE "public"."bdr_seamless_staging" TO "website_reader";



GRANT ALL ON TABLE "public"."business_plan_checkins" TO "anon";
GRANT ALL ON TABLE "public"."business_plan_checkins" TO "authenticated";
GRANT ALL ON TABLE "public"."business_plan_checkins" TO "service_role";
GRANT SELECT ON TABLE "public"."business_plan_checkins" TO "website_reader";



GRANT ALL ON TABLE "public"."business_plan_revenue_drivers" TO "anon";
GRANT ALL ON TABLE "public"."business_plan_revenue_drivers" TO "authenticated";
GRANT ALL ON TABLE "public"."business_plan_revenue_drivers" TO "service_role";
GRANT SELECT ON TABLE "public"."business_plan_revenue_drivers" TO "website_reader";



GRANT ALL ON TABLE "public"."business_plans" TO "anon";
GRANT ALL ON TABLE "public"."business_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."business_plans" TO "service_role";
GRANT SELECT ON TABLE "public"."business_plans" TO "website_reader";



GRANT ALL ON TABLE "public"."checkin_assignments" TO "anon";
GRANT ALL ON TABLE "public"."checkin_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."checkin_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."checkin_assignments" TO "website_reader";



GRANT ALL ON TABLE "public"."checkin_edit_log" TO "anon";
GRANT ALL ON TABLE "public"."checkin_edit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."checkin_edit_log" TO "service_role";
GRANT SELECT ON TABLE "public"."checkin_edit_log" TO "website_reader";



GRANT ALL ON TABLE "public"."checkin_submissions" TO "anon";
GRANT ALL ON TABLE "public"."checkin_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."checkin_submissions" TO "service_role";
GRANT SELECT ON TABLE "public"."checkin_submissions" TO "website_reader";



GRANT ALL ON TABLE "public"."checkin_templates" TO "anon";
GRANT ALL ON TABLE "public"."checkin_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."checkin_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."checkin_templates" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_assignments" TO "anon";
GRANT ALL ON TABLE "public"."checklist_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_assignments" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_custom_items" TO "anon";
GRANT ALL ON TABLE "public"."checklist_custom_items" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_custom_items" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_custom_items" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_item_overrides" TO "anon";
GRANT ALL ON TABLE "public"."checklist_item_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_item_overrides" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_item_overrides" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_items" TO "anon";
GRANT ALL ON TABLE "public"."checklist_items" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_items" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_items" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_progress" TO "anon";
GRANT ALL ON TABLE "public"."checklist_progress" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_progress" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_progress" TO "website_reader";



GRANT ALL ON TABLE "public"."checklist_templates" TO "anon";
GRANT ALL ON TABLE "public"."checklist_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."checklist_templates" TO "website_reader";



GRANT ALL ON TABLE "public"."comment_mentions" TO "anon";
GRANT ALL ON TABLE "public"."comment_mentions" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_mentions" TO "service_role";
GRANT SELECT ON TABLE "public"."comment_mentions" TO "website_reader";



GRANT ALL ON TABLE "public"."custom_field_definitions" TO "anon";
GRANT ALL ON TABLE "public"."custom_field_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."custom_field_definitions" TO "service_role";
GRANT SELECT ON TABLE "public"."custom_field_definitions" TO "website_reader";



GRANT ALL ON TABLE "public"."custom_roles" TO "anon";
GRANT ALL ON TABLE "public"."custom_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."custom_roles" TO "service_role";
GRANT SELECT ON TABLE "public"."custom_roles" TO "website_reader";



GRANT ALL ON TABLE "public"."dashboard_access" TO "anon";
GRANT ALL ON TABLE "public"."dashboard_access" TO "authenticated";
GRANT ALL ON TABLE "public"."dashboard_access" TO "service_role";
GRANT SELECT ON TABLE "public"."dashboard_access" TO "website_reader";



GRANT ALL ON TABLE "public"."dashboard_datasets" TO "anon";
GRANT ALL ON TABLE "public"."dashboard_datasets" TO "authenticated";
GRANT ALL ON TABLE "public"."dashboard_datasets" TO "service_role";
GRANT SELECT ON TABLE "public"."dashboard_datasets" TO "website_reader";



GRANT ALL ON TABLE "public"."dashboards" TO "anon";
GRANT ALL ON TABLE "public"."dashboards" TO "authenticated";
GRANT ALL ON TABLE "public"."dashboards" TO "service_role";
GRANT SELECT ON TABLE "public"."dashboards" TO "website_reader";



GRANT ALL ON TABLE "public"."data_sources" TO "anon";
GRANT ALL ON TABLE "public"."data_sources" TO "authenticated";
GRANT ALL ON TABLE "public"."data_sources" TO "service_role";
GRANT SELECT ON TABLE "public"."data_sources" TO "website_reader";



GRANT ALL ON TABLE "public"."dataset_access" TO "anon";
GRANT ALL ON TABLE "public"."dataset_access" TO "authenticated";
GRANT ALL ON TABLE "public"."dataset_access" TO "service_role";
GRANT SELECT ON TABLE "public"."dataset_access" TO "website_reader";



GRANT ALL ON TABLE "public"."datasets" TO "anon";
GRANT ALL ON TABLE "public"."datasets" TO "authenticated";
GRANT ALL ON TABLE "public"."datasets" TO "service_role";
GRANT SELECT ON TABLE "public"."datasets" TO "website_reader";



GRANT ALL ON TABLE "public"."desks" TO "anon";
GRANT ALL ON TABLE "public"."desks" TO "authenticated";
GRANT ALL ON TABLE "public"."desks" TO "service_role";
GRANT SELECT ON TABLE "public"."desks" TO "website_reader";



GRANT ALL ON TABLE "public"."document_categories" TO "anon";
GRANT ALL ON TABLE "public"."document_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."document_categories" TO "service_role";
GRANT SELECT ON TABLE "public"."document_categories" TO "website_reader";



GRANT ALL ON TABLE "public"."document_folders" TO "anon";
GRANT ALL ON TABLE "public"."document_folders" TO "authenticated";
GRANT ALL ON TABLE "public"."document_folders" TO "service_role";
GRANT SELECT ON TABLE "public"."document_folders" TO "website_reader";



GRANT ALL ON TABLE "public"."document_notifications" TO "anon";
GRANT ALL ON TABLE "public"."document_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."document_notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."document_notifications" TO "website_reader";



GRANT ALL ON TABLE "public"."document_permissions" TO "anon";
GRANT ALL ON TABLE "public"."document_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."document_permissions" TO "service_role";
GRANT SELECT ON TABLE "public"."document_permissions" TO "website_reader";



GRANT ALL ON TABLE "public"."document_stars" TO "anon";
GRANT ALL ON TABLE "public"."document_stars" TO "authenticated";
GRANT ALL ON TABLE "public"."document_stars" TO "service_role";
GRANT SELECT ON TABLE "public"."document_stars" TO "website_reader";



GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";
GRANT SELECT ON TABLE "public"."documents" TO "website_reader";



GRANT ALL ON TABLE "public"."email_activity_log" TO "anon";
GRANT ALL ON TABLE "public"."email_activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."email_activity_log" TO "service_role";
GRANT SELECT ON TABLE "public"."email_activity_log" TO "website_reader";



GRANT ALL ON TABLE "public"."email_connections" TO "anon";
GRANT ALL ON TABLE "public"."email_connections" TO "authenticated";
GRANT ALL ON TABLE "public"."email_connections" TO "service_role";
GRANT SELECT ON TABLE "public"."email_connections" TO "website_reader";



GRANT ALL ON TABLE "public"."expansion_email_templates" TO "anon";
GRANT ALL ON TABLE "public"."expansion_email_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."expansion_email_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."expansion_email_templates" TO "website_reader";



GRANT ALL ON TABLE "public"."expansion_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."expansion_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."expansion_opportunities" TO "service_role";
GRANT SELECT ON TABLE "public"."expansion_opportunities" TO "website_reader";



GRANT ALL ON TABLE "public"."expansion_firm_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."expansion_firm_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."expansion_firm_dashboard" TO "service_role";
GRANT SELECT ON TABLE "public"."expansion_firm_dashboard" TO "website_reader";



GRANT ALL ON TABLE "public"."expansion_research_outcomes" TO "anon";
GRANT ALL ON TABLE "public"."expansion_research_outcomes" TO "authenticated";
GRANT ALL ON TABLE "public"."expansion_research_outcomes" TO "service_role";
GRANT SELECT ON TABLE "public"."expansion_research_outcomes" TO "website_reader";



GRANT ALL ON TABLE "public"."expansion_research_runs" TO "anon";
GRANT ALL ON TABLE "public"."expansion_research_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."expansion_research_runs" TO "service_role";
GRANT SELECT ON TABLE "public"."expansion_research_runs" TO "website_reader";



GRANT ALL ON TABLE "public"."firm_software" TO "anon";
GRANT ALL ON TABLE "public"."firm_software" TO "authenticated";
GRANT ALL ON TABLE "public"."firm_software" TO "service_role";
GRANT SELECT ON TABLE "public"."firm_software" TO "website_reader";



GRANT ALL ON TABLE "public"."firm_software_costs" TO "anon";
GRANT ALL ON TABLE "public"."firm_software_costs" TO "authenticated";
GRANT ALL ON TABLE "public"."firm_software_costs" TO "service_role";
GRANT SELECT ON TABLE "public"."firm_software_costs" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_benefit_enrollments" TO "anon";
GRANT ALL ON TABLE "public"."hris_benefit_enrollments" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_benefit_enrollments" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_benefit_enrollments" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_benefit_plans" TO "anon";
GRANT ALL ON TABLE "public"."hris_benefit_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_benefit_plans" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_benefit_plans" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_checklist_template_items" TO "anon";
GRANT ALL ON TABLE "public"."hris_checklist_template_items" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_checklist_template_items" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_checklist_template_items" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_checklist_templates" TO "anon";
GRANT ALL ON TABLE "public"."hris_checklist_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_checklist_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_checklist_templates" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_compensation" TO "anon";
GRANT ALL ON TABLE "public"."hris_compensation" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_compensation" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_compensation" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_custom_field_values" TO "anon";
GRANT ALL ON TABLE "public"."hris_custom_field_values" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_custom_field_values" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_custom_field_values" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_emergency_contacts" TO "anon";
GRANT ALL ON TABLE "public"."hris_emergency_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_emergency_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_emergency_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_employee_checklists" TO "anon";
GRANT ALL ON TABLE "public"."hris_employee_checklists" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_employee_checklists" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_employee_checklists" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_employee_details" TO "anon";
GRANT ALL ON TABLE "public"."hris_employee_details" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_employee_details" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_employee_details" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_leave_action_tokens" TO "anon";
GRANT ALL ON TABLE "public"."hris_leave_action_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_leave_action_tokens" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_leave_action_tokens" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_leave_balances" TO "anon";
GRANT ALL ON TABLE "public"."hris_leave_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_leave_balances" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_leave_balances" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_leave_requests" TO "anon";
GRANT ALL ON TABLE "public"."hris_leave_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_leave_requests" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_leave_requests" TO "website_reader";



GRANT ALL ON TABLE "public"."hris_leave_types" TO "anon";
GRANT ALL ON TABLE "public"."hris_leave_types" TO "authenticated";
GRANT ALL ON TABLE "public"."hris_leave_types" TO "service_role";
GRANT SELECT ON TABLE "public"."hris_leave_types" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_companies" TO "anon";
GRANT ALL ON TABLE "public"."hs_companies" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_companies" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_companies" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_contacts" TO "anon";
GRANT ALL ON TABLE "public"."hs_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_deals" TO "anon";
GRANT ALL ON TABLE "public"."hs_deals" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_deals" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_deals" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_engagements" TO "anon";
GRANT ALL ON TABLE "public"."hs_engagements" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_engagements" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_engagements" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_owners" TO "anon";
GRANT ALL ON TABLE "public"."hs_owners" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_owners" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_owners" TO "website_reader";



GRANT ALL ON TABLE "public"."hs_sync_log" TO "anon";
GRANT ALL ON TABLE "public"."hs_sync_log" TO "authenticated";
GRANT ALL ON TABLE "public"."hs_sync_log" TO "service_role";
GRANT SELECT ON TABLE "public"."hs_sync_log" TO "website_reader";



GRANT ALL ON TABLE "public"."hub_api_tokens" TO "anon";
GRANT ALL ON TABLE "public"."hub_api_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."hub_api_tokens" TO "service_role";
GRANT SELECT ON TABLE "public"."hub_api_tokens" TO "website_reader";



GRANT ALL ON TABLE "public"."hubspot_contact_classifications" TO "anon";
GRANT ALL ON TABLE "public"."hubspot_contact_classifications" TO "authenticated";
GRANT ALL ON TABLE "public"."hubspot_contact_classifications" TO "service_role";
GRANT SELECT ON TABLE "public"."hubspot_contact_classifications" TO "website_reader";



GRANT ALL ON TABLE "public"."hubspot_engagement_contacts" TO "anon";
GRANT ALL ON TABLE "public"."hubspot_engagement_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."hubspot_engagement_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."hubspot_engagement_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."hubspot_engagements" TO "anon";
GRANT ALL ON TABLE "public"."hubspot_engagements" TO "authenticated";
GRANT ALL ON TABLE "public"."hubspot_engagements" TO "service_role";
GRANT SELECT ON TABLE "public"."hubspot_engagements" TO "website_reader";



GRANT ALL ON TABLE "public"."inbox_items" TO "anon";
GRANT ALL ON TABLE "public"."inbox_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inbox_items" TO "service_role";
GRANT SELECT ON TABLE "public"."inbox_items" TO "website_reader";



GRANT ALL ON TABLE "public"."job_description_versions" TO "anon";
GRANT ALL ON TABLE "public"."job_description_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."job_description_versions" TO "service_role";
GRANT SELECT ON TABLE "public"."job_description_versions" TO "website_reader";



GRANT ALL ON TABLE "public"."knowledge_base_article_page_links" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_base_article_page_links" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_base_article_page_links" TO "service_role";
GRANT SELECT ON TABLE "public"."knowledge_base_article_page_links" TO "website_reader";



GRANT ALL ON TABLE "public"."knowledge_base_articles" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_base_articles" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_base_articles" TO "service_role";
GRANT SELECT ON TABLE "public"."knowledge_base_articles" TO "website_reader";



GRANT ALL ON TABLE "public"."knowledge_base_edit_log" TO "anon";
GRANT ALL ON TABLE "public"."knowledge_base_edit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."knowledge_base_edit_log" TO "service_role";
GRANT SELECT ON TABLE "public"."knowledge_base_edit_log" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_agreements_log" TO "anon";
GRANT ALL ON TABLE "public"."laa_agreements_log" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_agreements_log" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_agreements_log" TO "website_reader";



GRANT ALL ON SEQUENCE "public"."laa_agreements_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."laa_agreements_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."laa_agreements_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."laa_canopy_payments" TO "anon";
GRANT ALL ON TABLE "public"."laa_canopy_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_canopy_payments" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_canopy_payments" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_cpa_rules" TO "anon";
GRANT ALL ON TABLE "public"."laa_cpa_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_cpa_rules" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_cpa_rules" TO "website_reader";



GRANT ALL ON SEQUENCE "public"."laa_cpa_rules_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."laa_cpa_rules_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."laa_cpa_rules_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."laa_firm_compensation" TO "anon";
GRANT ALL ON TABLE "public"."laa_firm_compensation" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_firm_compensation" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_firm_compensation" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_firm_services" TO "anon";
GRANT ALL ON TABLE "public"."laa_firm_services" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_firm_services" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_firm_services" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_firms" TO "anon";
GRANT ALL ON TABLE "public"."laa_firms" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_firms" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_firms" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_recipient_rules" TO "anon";
GRANT ALL ON TABLE "public"."laa_recipient_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_recipient_rules" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_recipient_rules" TO "website_reader";



GRANT ALL ON SEQUENCE "public"."laa_recipient_rules_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."laa_recipient_rules_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."laa_recipient_rules_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."laa_referral_payouts" TO "anon";
GRANT ALL ON TABLE "public"."laa_referral_payouts" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_referral_payouts" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_referral_payouts" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_rfp_bids" TO "anon";
GRANT ALL ON TABLE "public"."laa_rfp_bids" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_rfp_bids" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_rfp_bids" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_rfp_questions" TO "anon";
GRANT ALL ON TABLE "public"."laa_rfp_questions" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_rfp_questions" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_rfp_questions" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_rfps" TO "anon";
GRANT ALL ON TABLE "public"."laa_rfps" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_rfps" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_rfps" TO "website_reader";



GRANT ALL ON TABLE "public"."laa_service_catalog" TO "anon";
GRANT ALL ON TABLE "public"."laa_service_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."laa_service_catalog" TO "service_role";
GRANT SELECT ON TABLE "public"."laa_service_catalog" TO "website_reader";



GRANT ALL ON TABLE "public"."linked_emails" TO "anon";
GRANT ALL ON TABLE "public"."linked_emails" TO "authenticated";
GRANT ALL ON TABLE "public"."linked_emails" TO "service_role";
GRANT SELECT ON TABLE "public"."linked_emails" TO "website_reader";



GRANT ALL ON TABLE "public"."my_task_automation_logs" TO "anon";
GRANT ALL ON TABLE "public"."my_task_automation_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."my_task_automation_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."my_task_automation_logs" TO "website_reader";



GRANT ALL ON TABLE "public"."my_task_automations" TO "anon";
GRANT ALL ON TABLE "public"."my_task_automations" TO "authenticated";
GRANT ALL ON TABLE "public"."my_task_automations" TO "service_role";
GRANT SELECT ON TABLE "public"."my_task_automations" TO "website_reader";



GRANT ALL ON TABLE "public"."my_task_section_assignments" TO "anon";
GRANT ALL ON TABLE "public"."my_task_section_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."my_task_section_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."my_task_section_assignments" TO "website_reader";



GRANT ALL ON TABLE "public"."my_task_sections" TO "anon";
GRANT ALL ON TABLE "public"."my_task_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."my_task_sections" TO "service_role";
GRANT SELECT ON TABLE "public"."my_task_sections" TO "website_reader";



GRANT ALL ON TABLE "public"."nine_box_scores" TO "anon";
GRANT ALL ON TABLE "public"."nine_box_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."nine_box_scores" TO "service_role";
GRANT SELECT ON TABLE "public"."nine_box_scores" TO "website_reader";



GRANT ALL ON TABLE "public"."ninety_user_mappings" TO "anon";
GRANT ALL ON TABLE "public"."ninety_user_mappings" TO "authenticated";
GRANT ALL ON TABLE "public"."ninety_user_mappings" TO "service_role";
GRANT SELECT ON TABLE "public"."ninety_user_mappings" TO "website_reader";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."notifications" TO "website_reader";



GRANT ALL ON TABLE "public"."oauth_access_tokens" TO "service_role";
GRANT SELECT ON TABLE "public"."oauth_access_tokens" TO "website_reader";



GRANT ALL ON TABLE "public"."oauth_authorization_codes" TO "service_role";
GRANT SELECT ON TABLE "public"."oauth_authorization_codes" TO "website_reader";



GRANT ALL ON TABLE "public"."oauth_clients" TO "service_role";
GRANT SELECT ON TABLE "public"."oauth_clients" TO "website_reader";



GRANT ALL ON TABLE "public"."oauth_refresh_tokens" TO "service_role";
GRANT SELECT ON TABLE "public"."oauth_refresh_tokens" TO "website_reader";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";
GRANT SELECT ON TABLE "public"."organizations" TO "website_reader";



GRANT ALL ON TABLE "public"."permissions" TO "anon";
GRANT ALL ON TABLE "public"."permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."permissions" TO "service_role";
GRANT SELECT ON TABLE "public"."permissions" TO "website_reader";



GRANT ALL ON TABLE "public"."pinned_items" TO "anon";
GRANT ALL ON TABLE "public"."pinned_items" TO "authenticated";
GRANT ALL ON TABLE "public"."pinned_items" TO "service_role";
GRANT SELECT ON TABLE "public"."pinned_items" TO "website_reader";



GRANT ALL ON TABLE "public"."prep_briefs" TO "anon";
GRANT ALL ON TABLE "public"."prep_briefs" TO "authenticated";
GRANT ALL ON TABLE "public"."prep_briefs" TO "service_role";
GRANT SELECT ON TABLE "public"."prep_briefs" TO "website_reader";



GRANT ALL ON TABLE "public"."prep_calendar_events" TO "anon";
GRANT ALL ON TABLE "public"."prep_calendar_events" TO "authenticated";
GRANT ALL ON TABLE "public"."prep_calendar_events" TO "service_role";
GRANT SELECT ON TABLE "public"."prep_calendar_events" TO "website_reader";



GRANT ALL ON TABLE "public"."prep_reminder_preferences" TO "anon";
GRANT ALL ON TABLE "public"."prep_reminder_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."prep_reminder_preferences" TO "service_role";
GRANT SELECT ON TABLE "public"."prep_reminder_preferences" TO "website_reader";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";
GRANT SELECT ON TABLE "public"."profiles" TO "website_reader";



GRANT SELECT("id") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("email") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("full_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("title") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("phone") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("avatar_url") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("organization_id") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("first_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("last_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("preferred_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("booking_link") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("status") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("tags") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("team") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("secondary_email") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("manager_id") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("role_id") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("timezone") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("date_format") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("default_landing_page") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("my_tasks_group_by") ON TABLE "public"."profiles" TO "authenticated";



GRANT ALL ON TABLE "public"."project_custom_fields" TO "anon";
GRANT ALL ON TABLE "public"."project_custom_fields" TO "authenticated";
GRANT ALL ON TABLE "public"."project_custom_fields" TO "service_role";
GRANT SELECT ON TABLE "public"."project_custom_fields" TO "website_reader";



GRANT ALL ON TABLE "public"."project_favorites" TO "anon";
GRANT ALL ON TABLE "public"."project_favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."project_favorites" TO "service_role";
GRANT SELECT ON TABLE "public"."project_favorites" TO "website_reader";



GRANT ALL ON TABLE "public"."project_field_aggregations" TO "anon";
GRANT ALL ON TABLE "public"."project_field_aggregations" TO "authenticated";
GRANT ALL ON TABLE "public"."project_field_aggregations" TO "service_role";
GRANT SELECT ON TABLE "public"."project_field_aggregations" TO "website_reader";



GRANT ALL ON TABLE "public"."project_members" TO "anon";
GRANT ALL ON TABLE "public"."project_members" TO "authenticated";
GRANT ALL ON TABLE "public"."project_members" TO "service_role";
GRANT SELECT ON TABLE "public"."project_members" TO "website_reader";



GRANT ALL ON TABLE "public"."project_resources" TO "anon";
GRANT ALL ON TABLE "public"."project_resources" TO "authenticated";
GRANT ALL ON TABLE "public"."project_resources" TO "service_role";
GRANT SELECT ON TABLE "public"."project_resources" TO "website_reader";



GRANT ALL ON TABLE "public"."project_sections" TO "anon";
GRANT ALL ON TABLE "public"."project_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."project_sections" TO "service_role";
GRANT SELECT ON TABLE "public"."project_sections" TO "website_reader";



GRANT ALL ON TABLE "public"."project_share_links" TO "anon";
GRANT ALL ON TABLE "public"."project_share_links" TO "authenticated";
GRANT ALL ON TABLE "public"."project_share_links" TO "service_role";
GRANT SELECT ON TABLE "public"."project_share_links" TO "website_reader";



GRANT ALL ON TABLE "public"."project_shared_comments" TO "anon";
GRANT ALL ON TABLE "public"."project_shared_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."project_shared_comments" TO "service_role";
GRANT SELECT ON TABLE "public"."project_shared_comments" TO "website_reader";



GRANT ALL ON TABLE "public"."project_template_members" TO "anon";
GRANT ALL ON TABLE "public"."project_template_members" TO "authenticated";
GRANT ALL ON TABLE "public"."project_template_members" TO "service_role";
GRANT SELECT ON TABLE "public"."project_template_members" TO "website_reader";



GRANT ALL ON TABLE "public"."project_template_sections" TO "anon";
GRANT ALL ON TABLE "public"."project_template_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."project_template_sections" TO "service_role";
GRANT SELECT ON TABLE "public"."project_template_sections" TO "website_reader";



GRANT ALL ON TABLE "public"."project_template_tasks" TO "anon";
GRANT ALL ON TABLE "public"."project_template_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."project_template_tasks" TO "service_role";
GRANT SELECT ON TABLE "public"."project_template_tasks" TO "website_reader";



GRANT ALL ON TABLE "public"."project_templates" TO "anon";
GRANT ALL ON TABLE "public"."project_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."project_templates" TO "service_role";
GRANT SELECT ON TABLE "public"."project_templates" TO "website_reader";



GRANT ALL ON TABLE "public"."projects" TO "anon";
GRANT ALL ON TABLE "public"."projects" TO "authenticated";
GRANT ALL ON TABLE "public"."projects" TO "service_role";
GRANT SELECT ON TABLE "public"."projects" TO "website_reader";



GRANT ALL ON TABLE "public"."quick_links" TO "anon";
GRANT ALL ON TABLE "public"."quick_links" TO "authenticated";
GRANT ALL ON TABLE "public"."quick_links" TO "service_role";
GRANT SELECT ON TABLE "public"."quick_links" TO "website_reader";



GRANT ALL ON TABLE "public"."release_notes" TO "anon";
GRANT ALL ON TABLE "public"."release_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."release_notes" TO "service_role";
GRANT SELECT ON TABLE "public"."release_notes" TO "website_reader";



GRANT ALL ON TABLE "public"."reporting_sync_alerts" TO "anon";
GRANT ALL ON TABLE "public"."reporting_sync_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."reporting_sync_alerts" TO "service_role";
GRANT SELECT ON TABLE "public"."reporting_sync_alerts" TO "website_reader";



GRANT ALL ON TABLE "public"."role_permissions" TO "anon";
GRANT ALL ON TABLE "public"."role_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."role_permissions" TO "service_role";
GRANT SELECT ON TABLE "public"."role_permissions" TO "website_reader";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";
GRANT SELECT ON TABLE "public"."roles" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_accounts" TO "anon";
GRANT ALL ON TABLE "public"."rtl_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_accounts" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_accounts" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_activities" TO "anon";
GRANT ALL ON TABLE "public"."rtl_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_activities" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_activities" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_contact_org_mapping" TO "anon";
GRANT ALL ON TABLE "public"."rtl_contact_org_mapping" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_contact_org_mapping" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_contact_org_mapping" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_contacts" TO "anon";
GRANT ALL ON TABLE "public"."rtl_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_firm_settings" TO "anon";
GRANT ALL ON TABLE "public"."rtl_firm_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_firm_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_firm_settings" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_notes" TO "anon";
GRANT ALL ON TABLE "public"."rtl_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_notes" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_notes" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_opportunities" TO "anon";
GRANT ALL ON TABLE "public"."rtl_opportunities" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_opportunities" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_opportunities" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_reminders" TO "anon";
GRANT ALL ON TABLE "public"."rtl_reminders" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_reminders" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_reminders" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_sync_log" TO "anon";
GRANT ALL ON TABLE "public"."rtl_sync_log" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_sync_log" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_sync_log" TO "website_reader";



GRANT ALL ON TABLE "public"."rtl_sync_state" TO "anon";
GRANT ALL ON TABLE "public"."rtl_sync_state" TO "authenticated";
GRANT ALL ON TABLE "public"."rtl_sync_state" TO "service_role";
GRANT SELECT ON TABLE "public"."rtl_sync_state" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_batches" TO "anon";
GRANT ALL ON TABLE "public"."sdr_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_batches" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_batches" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_contacts" TO "anon";
GRANT ALL ON TABLE "public"."sdr_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_firm_staff" TO "anon";
GRANT ALL ON TABLE "public"."sdr_firm_staff" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_firm_staff" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_firm_staff" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_known_acquisitions" TO "anon";
GRANT ALL ON TABLE "public"."sdr_known_acquisitions" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_known_acquisitions" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_known_acquisitions" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_research_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."sdr_research_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_research_dashboard" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_research_dashboard" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_seamless_imports" TO "anon";
GRANT ALL ON TABLE "public"."sdr_seamless_imports" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_seamless_imports" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_seamless_imports" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_import_pipeline_stats" TO "anon";
GRANT ALL ON TABLE "public"."sdr_import_pipeline_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_import_pipeline_stats" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_import_pipeline_stats" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_prospect_queues" TO "anon";
GRANT ALL ON TABLE "public"."sdr_prospect_queues" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_prospect_queues" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_prospect_queues" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_research_by_state" TO "anon";
GRANT ALL ON TABLE "public"."sdr_research_by_state" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_research_by_state" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_research_by_state" TO "website_reader";



GRANT ALL ON TABLE "public"."sdr_rule_sets" TO "anon";
GRANT ALL ON TABLE "public"."sdr_rule_sets" TO "authenticated";
GRANT ALL ON TABLE "public"."sdr_rule_sets" TO "service_role";
GRANT SELECT ON TABLE "public"."sdr_rule_sets" TO "website_reader";



GRANT ALL ON TABLE "public"."software_categories" TO "anon";
GRANT ALL ON TABLE "public"."software_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."software_categories" TO "service_role";
GRANT SELECT ON TABLE "public"."software_categories" TO "website_reader";



GRANT ALL ON TABLE "public"."software_products" TO "anon";
GRANT ALL ON TABLE "public"."software_products" TO "authenticated";
GRANT ALL ON TABLE "public"."software_products" TO "service_role";
GRANT SELECT ON TABLE "public"."software_products" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_advisors" TO "anon";
GRANT ALL ON TABLE "public"."ssg_advisors" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_advisors" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_advisors" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_calendar_events" TO "anon";
GRANT ALL ON TABLE "public"."ssg_calendar_events" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_calendar_events" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_calendar_events" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_emails" TO "anon";
GRANT ALL ON TABLE "public"."ssg_emails" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_emails" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_emails" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_engagement_contacts" TO "anon";
GRANT ALL ON TABLE "public"."ssg_engagement_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_engagement_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_engagement_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_engagements" TO "anon";
GRANT ALL ON TABLE "public"."ssg_engagements" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_engagements" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_engagements" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_functions" TO "anon";
GRANT ALL ON TABLE "public"."ssg_functions" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_functions" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_functions" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_insights" TO "anon";
GRANT ALL ON TABLE "public"."ssg_insights" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_insights" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_insights" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_meetings" TO "anon";
GRANT ALL ON TABLE "public"."ssg_meetings" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_meetings" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_meetings" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_member_assignments" TO "anon";
GRANT ALL ON TABLE "public"."ssg_member_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_member_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_member_assignments" TO "website_reader";



GRANT ALL ON TABLE "public"."ssg_outcomes" TO "anon";
GRANT ALL ON TABLE "public"."ssg_outcomes" TO "authenticated";
GRANT ALL ON TABLE "public"."ssg_outcomes" TO "service_role";
GRANT SELECT ON TABLE "public"."ssg_outcomes" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_businesses" TO "anon";
GRANT ALL ON TABLE "public"."tas_businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_businesses" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_businesses" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_consultant_profiles" TO "anon";
GRANT ALL ON TABLE "public"."tas_consultant_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_consultant_profiles" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_consultant_profiles" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_contacts" TO "anon";
GRANT ALL ON TABLE "public"."tas_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_sequences" TO "anon";
GRANT ALL ON TABLE "public"."tas_sequences" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_sequences" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_sequences" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_daily_action_queue" TO "anon";
GRANT ALL ON TABLE "public"."tas_daily_action_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_daily_action_queue" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_daily_action_queue" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_import_logs" TO "anon";
GRANT ALL ON TABLE "public"."tas_import_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_import_logs" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_import_logs" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_inmail_budget" TO "anon";
GRANT ALL ON TABLE "public"."tas_inmail_budget" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_inmail_budget" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_inmail_budget" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_inmail_budget_view" TO "anon";
GRANT ALL ON TABLE "public"."tas_inmail_budget_view" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_inmail_budget_view" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_inmail_budget_view" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_pipeline_summary" TO "anon";
GRANT ALL ON TABLE "public"."tas_pipeline_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_pipeline_summary" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_pipeline_summary" TO "website_reader";



GRANT ALL ON TABLE "public"."tas_sequence_steps" TO "anon";
GRANT ALL ON TABLE "public"."tas_sequence_steps" TO "authenticated";
GRANT ALL ON TABLE "public"."tas_sequence_steps" TO "service_role";
GRANT SELECT ON TABLE "public"."tas_sequence_steps" TO "website_reader";



GRANT ALL ON TABLE "public"."task_attachments" TO "anon";
GRANT ALL ON TABLE "public"."task_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."task_attachments" TO "service_role";
GRANT SELECT ON TABLE "public"."task_attachments" TO "website_reader";



GRANT ALL ON TABLE "public"."task_collaborators" TO "anon";
GRANT ALL ON TABLE "public"."task_collaborators" TO "authenticated";
GRANT ALL ON TABLE "public"."task_collaborators" TO "service_role";
GRANT SELECT ON TABLE "public"."task_collaborators" TO "website_reader";



GRANT ALL ON TABLE "public"."task_comments" TO "anon";
GRANT ALL ON TABLE "public"."task_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."task_comments" TO "service_role";
GRANT SELECT ON TABLE "public"."task_comments" TO "website_reader";



GRANT ALL ON TABLE "public"."task_custom_field_values" TO "anon";
GRANT ALL ON TABLE "public"."task_custom_field_values" TO "authenticated";
GRANT ALL ON TABLE "public"."task_custom_field_values" TO "service_role";
GRANT SELECT ON TABLE "public"."task_custom_field_values" TO "website_reader";



GRANT ALL ON TABLE "public"."task_history" TO "anon";
GRANT ALL ON TABLE "public"."task_history" TO "authenticated";
GRANT ALL ON TABLE "public"."task_history" TO "service_role";
GRANT SELECT ON TABLE "public"."task_history" TO "website_reader";



GRANT ALL ON TABLE "public"."task_notifications" TO "anon";
GRANT ALL ON TABLE "public"."task_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."task_notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."task_notifications" TO "website_reader";



GRANT ALL ON TABLE "public"."task_project_memberships" TO "anon";
GRANT ALL ON TABLE "public"."task_project_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."task_project_memberships" TO "service_role";
GRANT SELECT ON TABLE "public"."task_project_memberships" TO "website_reader";



GRANT ALL ON TABLE "public"."task_saved_views" TO "anon";
GRANT ALL ON TABLE "public"."task_saved_views" TO "authenticated";
GRANT ALL ON TABLE "public"."task_saved_views" TO "service_role";
GRANT SELECT ON TABLE "public"."task_saved_views" TO "website_reader";



GRANT ALL ON TABLE "public"."tasks" TO "anon";
GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";
GRANT SELECT ON TABLE "public"."tasks" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_categories" TO "anon";
GRANT ALL ON TABLE "public"."ticket_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_categories" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_categories" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_comments" TO "anon";
GRANT ALL ON TABLE "public"."ticket_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_comments" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_comments" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_field_definitions" TO "anon";
GRANT ALL ON TABLE "public"."ticket_field_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_field_definitions" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_field_definitions" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_field_values" TO "anon";
GRANT ALL ON TABLE "public"."ticket_field_values" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_field_values" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_field_values" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_messages" TO "anon";
GRANT ALL ON TABLE "public"."ticket_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_messages" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_messages" TO "website_reader";



GRANT ALL ON TABLE "public"."ticket_notifications" TO "anon";
GRANT ALL ON TABLE "public"."ticket_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_notifications" TO "website_reader";



GRANT ALL ON SEQUENCE "public"."ticket_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ticket_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ticket_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ticket_statuses" TO "anon";
GRANT ALL ON TABLE "public"."ticket_statuses" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_statuses" TO "service_role";
GRANT SELECT ON TABLE "public"."ticket_statuses" TO "website_reader";



GRANT ALL ON TABLE "public"."tickets" TO "anon";
GRANT ALL ON TABLE "public"."tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."tickets" TO "service_role";
GRANT SELECT ON TABLE "public"."tickets" TO "website_reader";



GRANT ALL ON TABLE "public"."training_courses" TO "anon";
GRANT ALL ON TABLE "public"."training_courses" TO "authenticated";
GRANT ALL ON TABLE "public"."training_courses" TO "service_role";
GRANT SELECT ON TABLE "public"."training_courses" TO "website_reader";



GRANT ALL ON TABLE "public"."training_lesson_progress" TO "anon";
GRANT ALL ON TABLE "public"."training_lesson_progress" TO "authenticated";
GRANT ALL ON TABLE "public"."training_lesson_progress" TO "service_role";
GRANT SELECT ON TABLE "public"."training_lesson_progress" TO "website_reader";



GRANT ALL ON TABLE "public"."training_lessons" TO "anon";
GRANT ALL ON TABLE "public"."training_lessons" TO "authenticated";
GRANT ALL ON TABLE "public"."training_lessons" TO "service_role";
GRANT SELECT ON TABLE "public"."training_lessons" TO "website_reader";



GRANT ALL ON TABLE "public"."training_resources" TO "anon";
GRANT ALL ON TABLE "public"."training_resources" TO "authenticated";
GRANT ALL ON TABLE "public"."training_resources" TO "service_role";
GRANT SELECT ON TABLE "public"."training_resources" TO "website_reader";



GRANT ALL ON TABLE "public"."transition_assessment_submissions" TO "anon";
GRANT ALL ON TABLE "public"."transition_assessment_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."transition_assessment_submissions" TO "service_role";
GRANT SELECT ON TABLE "public"."transition_assessment_submissions" TO "website_reader";



GRANT ALL ON SEQUENCE "public"."transition_assessment_submissions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transition_assessment_submissions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transition_assessment_submissions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_home_layouts" TO "anon";
GRANT ALL ON TABLE "public"."user_home_layouts" TO "authenticated";
GRANT ALL ON TABLE "public"."user_home_layouts" TO "service_role";
GRANT SELECT ON TABLE "public"."user_home_layouts" TO "website_reader";



GRANT ALL ON TABLE "public"."user_notification_preferences" TO "anon";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."user_notification_preferences" TO "service_role";
GRANT SELECT ON TABLE "public"."user_notification_preferences" TO "website_reader";



GRANT ALL ON TABLE "public"."user_role_assignments" TO "anon";
GRANT ALL ON TABLE "public"."user_role_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."user_role_assignments" TO "service_role";
GRANT SELECT ON TABLE "public"."user_role_assignments" TO "website_reader";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";
GRANT SELECT ON TABLE "public"."user_roles" TO "website_reader";



GRANT ALL ON TABLE "public"."vendor_contacts" TO "anon";
GRANT ALL ON TABLE "public"."vendor_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."vendor_contacts" TO "website_reader";



GRANT ALL ON TABLE "public"."vendors" TO "anon";
GRANT ALL ON TABLE "public"."vendors" TO "authenticated";
GRANT ALL ON TABLE "public"."vendors" TO "service_role";
GRANT SELECT ON TABLE "public"."vendors" TO "website_reader";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "website_reader";































