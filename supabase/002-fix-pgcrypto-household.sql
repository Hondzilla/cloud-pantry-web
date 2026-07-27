begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create or replace function public.create_cloud_pantry_household(p_name text)
returns table(household_id uuid, invite_code text, revision bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_household uuid;
  v_code text;
begin
  if v_user is null then
    raise exception 'authentication_required';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'household_name_required';
  end if;

  loop
    v_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 8));
    exit when not exists (
      select 1
      from public.cloud_pantry_households h
      where h.invite_code = v_code
    );
  end loop;

  insert into public.cloud_pantry_households(name, invite_code, created_by)
  values(trim(p_name), v_code, v_user)
  returning id into v_household;

  insert into public.cloud_pantry_household_members(household_id, user_id, role)
  values(v_household, v_user, 'owner');

  insert into public.cloud_pantry_household_state(household_id, state, revision, updated_by)
  values(v_household, '{}'::jsonb, 0, v_user);

  return query
  select v_household, v_code, 0::bigint;
end;
$$;

revoke execute on function public.create_cloud_pantry_household(text)
from public, anon;

grant execute on function public.create_cloud_pantry_household(text)
to authenticated;

commit;
