begin;

create or replace function public.join_cloud_pantry_household(p_invite_code text)
returns table(
  household_id uuid,
  household_name text,
  invite_code text,
  revision bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_household public.cloud_pantry_households%rowtype;
begin
  if v_user is null then
    raise exception 'authentication_required';
  end if;

  select h.*
  into v_household
  from public.cloud_pantry_households as h
  where h.invite_code = upper(trim(p_invite_code));

  if not found then
    raise exception 'invite_code_not_found';
  end if;

  insert into public.cloud_pantry_household_members(
    household_id,
    user_id,
    role
  )
  values(
    v_household.id,
    v_user,
    'member'
  )
  on conflict (household_id, user_id) do nothing;

  return query
  select
    v_household.id,
    v_household.name,
    v_household.invite_code,
    coalesce(
      (
        select s.revision
        from public.cloud_pantry_household_state as s
        where s.household_id = v_household.id
      ),
      0::bigint
    );
end;
$$;

revoke execute on function public.join_cloud_pantry_household(text)
from public, anon;

grant execute on function public.join_cloud_pantry_household(text)
to authenticated;

commit;
