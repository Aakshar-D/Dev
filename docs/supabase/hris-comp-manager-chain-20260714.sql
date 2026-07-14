-- 2026-07-14: HRIS compensation visibility
-- Requirement: employee sees own comp; managers (full management chain) and
-- HR/Admin (desks.hris.comp / admin.access) see comp of employees below them.
-- Applied to prod via Supabase MCP apply_migration (hris_comp_manager_chain_read).

-- Walks up profiles.manager_id from _employee; true if _viewer appears in the
-- chain above. Depth-capped at 20 to guard against manager-graph cycles.
create or replace function public.hris_in_management_chain(_viewer uuid, _employee uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  with recursive chain as (
    select p.manager_id, 1 as depth
    from public.profiles p
    where p.id = _employee
    union all
    select p.manager_id, c.depth + 1
    from public.profiles p
    join chain c on p.id = c.manager_id
    where c.depth < 20
  )
  select exists (
    select 1 from chain where manager_id = _viewer
  );
$$;

drop policy if exists "hris comp read" on public.hris_compensation;
create policy "hris comp read" on public.hris_compensation
  for select
  using (
    employee_id = auth.uid()
    or public.has_permission(auth.uid(), 'desks.hris.comp')
    or public.has_permission(auth.uid(), 'admin.access')
    or public.hris_in_management_chain(auth.uid(), employee_id)
  );
