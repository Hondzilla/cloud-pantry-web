begin;

-- Recreate read policies with fully qualified outer-table references.
drop policy if exists "members can read their households"
on public.cloud_pantry_households;

create policy "members can read their households"
on public.cloud_pantry_households
for select
to authenticated
using (
  exists (
    select 1
    from public.cloud_pantry_household_members as m
    where m.household_id = public.cloud_pantry_households.id
      and m.user_id = auth.uid()
  )
);

drop policy if exists "members can read household state"
on public.cloud_pantry_household_state;

create policy "members can read household state"
on public.cloud_pantry_household_state
for select
to authenticated
using (
  exists (
    select 1
    from public.cloud_pantry_household_members as m
    where m.household_id = public.cloud_pantry_household_state.household_id
      and m.user_id = auth.uid()
  )
);

-- Replace the pull RPC and force ambiguous PL/pgSQL names to resolve as columns.
create or replace function public.pull_cloud_pantry_state(
  p_household_id uuid
)
returns table(
  household_id uuid,
  household_name text,
  invite_code text,
  state jsonb,
  revision bigint,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
#variable_conflict use_column
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'authentication_required';
  end if;

  if not exists (
    select 1
    from public.cloud_pantry_household_members as m
    where m.household_id = p_household_id
      and m.user_id = v_user
  ) then
    raise exception 'household_access_denied';
  end if;

  return query
  select
    h.id as household_id,
    h.name as household_name,
    h.invite_code as invite_code,
    s.state as state,
    s.revision as revision,
    s.updated_at as updated_at
  from public.cloud_pantry_households as h
  inner join public.cloud_pantry_household_state as s
    on s.household_id = h.id
  where h.id = p_household_id;
end;
$$;

revoke execute on function public.pull_cloud_pantry_state(uuid)
from public, anon;

grant execute on function public.pull_cloud_pantry_state(uuid)
to authenticated;

commit;
