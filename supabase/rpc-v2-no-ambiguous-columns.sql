begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create or replace function public.create_cloud_pantry_household_v2(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
set row_security = off
as $$
declare
  v_user uuid := auth.uid();
  v_household uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_code text;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if v_name = '' then raise exception 'household_name_required'; end if;

  loop
    v_code := upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 8));
    exit when not exists (
      select 1 from public.cloud_pantry_households as h where h.invite_code = v_code
    );
  end loop;

  insert into public.cloud_pantry_households(name, invite_code, created_by)
  values (v_name, v_code, v_user)
  returning id into v_household;

  insert into public.cloud_pantry_household_members(household_id, user_id, role)
  values (v_household, v_user, 'owner');

  insert into public.cloud_pantry_household_state(household_id, state, revision, updated_by)
  values (v_household, '{}'::jsonb, 0, v_user);

  return jsonb_build_object(
    'household_id', v_household,
    'household_name', v_name,
    'invite_code', v_code,
    'member_role', 'owner',
    'revision', 0
  );
end;
$$;

create or replace function public.join_cloud_pantry_household_v2(p_invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(trim(coalesce(p_invite_code, '')));
  v_household uuid;
  v_name text;
  v_revision bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if v_code = '' then raise exception 'invite_code_required'; end if;

  select h.id, h.name
    into v_household, v_name
  from public.cloud_pantry_households as h
  where h.invite_code = v_code;

  if v_household is null then raise exception 'invite_code_not_found'; end if;

  insert into public.cloud_pantry_household_members(household_id, user_id, role)
  values (v_household, v_user, 'member')
  on conflict (household_id, user_id) do nothing;

  select s.revision
    into v_revision
  from public.cloud_pantry_household_state as s
  where s.household_id = v_household;

  return jsonb_build_object(
    'household_id', v_household,
    'household_name', v_name,
    'invite_code', v_code,
    'member_role', 'member',
    'revision', coalesce(v_revision, 0)
  );
end;
$$;

create or replace function public.list_cloud_pantry_households_v2()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'household_id', h.id,
        'household_name', h.name,
        'invite_code', h.invite_code,
        'member_role', m.role,
        'revision', s.revision,
        'updated_at', s.updated_at
      ) order by m.joined_at
    ),
    '[]'::jsonb
  )
  from public.cloud_pantry_household_members as m
  inner join public.cloud_pantry_households as h on h.id = m.household_id
  inner join public.cloud_pantry_household_state as s on s.household_id = h.id
  where m.user_id = auth.uid();
$$;

create or replace function public.pull_cloud_pantry_state_v2(p_household_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
declare
  v_user uuid := auth.uid();
  v_name text;
  v_code text;
  v_state jsonb;
  v_revision bigint;
  v_updated_at timestamptz;
begin
  if v_user is null then raise exception 'authentication_required'; end if;

  if not exists (
    select 1
    from public.cloud_pantry_household_members as m
    where m.household_id = p_household_id and m.user_id = v_user
  ) then
    raise exception 'household_access_denied';
  end if;

  select h.name, h.invite_code, s.state, s.revision, s.updated_at
    into v_name, v_code, v_state, v_revision, v_updated_at
  from public.cloud_pantry_households as h
  inner join public.cloud_pantry_household_state as s on s.household_id = h.id
  where h.id = p_household_id;

  if v_name is null then raise exception 'household_not_found'; end if;

  return jsonb_build_object(
    'household_id', p_household_id,
    'household_name', v_name,
    'invite_code', v_code,
    'state', coalesce(v_state, '{}'::jsonb),
    'revision', coalesce(v_revision, 0),
    'updated_at', v_updated_at
  );
end;
$$;

create or replace function public.push_cloud_pantry_state_v2(
  p_household_id uuid,
  p_state jsonb,
  p_base_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
set row_security = off
as $$
declare
  v_user uuid := auth.uid();
  v_state jsonb;
  v_revision bigint;
  v_updated_at timestamptz;
begin
  if v_user is null then raise exception 'authentication_required'; end if;

  if not exists (
    select 1
    from public.cloud_pantry_household_members as m
    where m.household_id = p_household_id and m.user_id = v_user
  ) then
    raise exception 'household_access_denied';
  end if;

  if coalesce((p_state ->> 'version')::integer, 0) not in (1, 2) then
    raise exception 'unsupported_snapshot_version';
  end if;

  update public.cloud_pantry_household_state as s
  set state = p_state,
      revision = s.revision + 1,
      updated_at = now(),
      updated_by = v_user
  where s.household_id = p_household_id and s.revision = p_base_revision
  returning s.state, s.revision, s.updated_at
    into v_state, v_revision, v_updated_at;

  if v_revision is null then raise exception 'revision_conflict'; end if;

  return jsonb_build_object(
    'state', v_state,
    'revision', v_revision,
    'updated_at', v_updated_at
  );
end;
$$;

revoke all on function public.create_cloud_pantry_household_v2(text) from public, anon;
revoke all on function public.join_cloud_pantry_household_v2(text) from public, anon;
revoke all on function public.list_cloud_pantry_households_v2() from public, anon;
revoke all on function public.pull_cloud_pantry_state_v2(uuid) from public, anon;
revoke all on function public.push_cloud_pantry_state_v2(uuid, jsonb, bigint) from public, anon;

grant execute on function public.create_cloud_pantry_household_v2(text) to authenticated;
grant execute on function public.join_cloud_pantry_household_v2(text) to authenticated;
grant execute on function public.list_cloud_pantry_households_v2() to authenticated;
grant execute on function public.pull_cloud_pantry_state_v2(uuid) to authenticated;
grant execute on function public.push_cloud_pantry_state_v2(uuid, jsonb, bigint) to authenticated;

commit;
