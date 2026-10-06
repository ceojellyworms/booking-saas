-- Apply together with the matching frontend release.
-- This revokes every existing admin session and replaces policies on these
-- three public tables so no older permissive policy can override the new rules.
begin;

create or replace function public.admin_request_token()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select nullif(
    coalesce(current_setting('request.headers', true), '{}')::jsonb
      ->> 'x-admin-session-token',
    ''
  );
$$;

create or replace function public.admin_session_project_id()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.project_id::text
  from public.admin_sessions s
  where s.token::text = public.admin_request_token()
    and s.expires_at > now()
  limit 1;
$$;

create or replace function public.is_super_admin_session()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.admin_sessions s
    where s.token::text = public.admin_request_token()
      and s.expires_at > now()
      and s.project_id is null
  );
$$;

create or replace function public.admin_can_access_project(p_project_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_super_admin_session()
    or (
      public.admin_session_project_id() is not null
      and public.admin_session_project_id() = p_project_id
    );
$$;

create or replace function public.is_public_project(p_project_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.projects p
    where p.id::text = p_project_id
      and p.is_active is true
  );
$$;

create or replace function public.create_admin_session(
  p_project_id text,
  p_login text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_valid boolean;
  v_token public.admin_sessions.token%type;
  v_expires_at timestamptz := now() + interval '24 hours';
begin
  if p_project_id is null then
    select public.verify_super_admin(p_login, p_password) into v_valid;
  else
    select public.verify_project_admin(p_project_id, p_login, p_password) into v_valid;
  end if;

  if not coalesce(v_valid, false) then
    return null;
  end if;

  v_token := pg_catalog.gen_random_uuid();
  insert into public.admin_sessions (token, project_id, expires_at)
  values (v_token, p_project_id, v_expires_at);

  return jsonb_build_object(
    'token', v_token::text,
    'project_id', p_project_id,
    'expires_at', v_expires_at
  );
end;
$$;

create or replace function public.validate_admin_session(
  p_token text,
  p_project_id text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.admin_sessions s
    where s.token::text = p_token
      and s.expires_at > now()
      and case
        when p_project_id is null then s.project_id is null
        else s.project_id is null or s.project_id::text = p_project_id
      end
  );
$$;

create or replace function public.admin_create_project(
  p_id text,
  p_business_name text,
  p_admin_login text,
  p_admin_password text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_super_admin_session() then
    raise exception 'Super-administrator session required';
  end if;

  perform public.create_project(p_id, p_business_name, p_admin_login, p_admin_password);
end;
$$;

create or replace function public.admin_update_project_password(
  p_id text,
  p_new_password text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.admin_can_access_project(p_id) then
    raise exception 'Project administrator session required';
  end if;

  perform public.update_project_password(p_id, p_new_password);
end;
$$;

revoke all on function public.create_admin_session(text, text, text) from public;
revoke all on function public.validate_admin_session(text, text) from public;
revoke all on function public.admin_create_project(text, text, text, text) from public;
revoke all on function public.admin_update_project_password(text, text) from public;
revoke all on function public.admin_request_token() from public;
revoke all on function public.admin_session_project_id() from public;
revoke all on function public.is_super_admin_session() from public;
revoke all on function public.admin_can_access_project(text) from public;
revoke all on function public.is_public_project(text) from public;

grant execute on function public.create_admin_session(text, text, text) to anon, authenticated;
grant execute on function public.validate_admin_session(text, text) to anon, authenticated;
grant execute on function public.admin_create_project(text, text, text, text) to anon, authenticated;
grant execute on function public.admin_update_project_password(text, text) to anon, authenticated;
grant execute on function public.admin_request_token() to anon, authenticated;
grant execute on function public.admin_session_project_id() to anon, authenticated;
grant execute on function public.is_super_admin_session() to anon, authenticated;
grant execute on function public.admin_can_access_project(text) to anon, authenticated;
grant execute on function public.is_public_project(text) to anon, authenticated;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('verify_project_admin', 'verify_super_admin',
                        'create_project', 'update_project_password')
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      f.signature
    );
  end loop;
end;
$$;

revoke all on public.admin_sessions from anon, authenticated;
alter table public.admin_sessions enable row level security;
delete from public.admin_sessions;

do $$
declare
  p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('projects', 'services', 'bookings')
  loop
    execute format(
      'drop policy %I on %I.%I',
      p.policyname,
      p.schemaname,
      p.tablename
    );
  end loop;
end;
$$;

alter table public.projects enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;

revoke all on public.projects from anon, authenticated;
grant select (id) on public.projects to anon, authenticated;
grant update (
  business_name, phone, address, accent_color, background_color,
  logo_url, banner_url, social_links, work_hours
) on public.projects to anon, authenticated;
grant delete on public.projects to anon, authenticated;

create policy projects_select_id
on public.projects for select to anon, authenticated
using (
  public.is_public_project(id::text)
  or public.admin_can_access_project(id::text)
);

create policy projects_update
on public.projects for update to anon, authenticated
using (public.admin_can_access_project(id::text))
with check (public.admin_can_access_project(id::text));

create policy projects_delete
on public.projects for delete to anon, authenticated
using (public.is_super_admin_session());

create or replace view public.projects_public
with (security_barrier = true)
as
select
  p.id,
  p.business_name,
  case when public.is_super_admin_session() then p.admin_login else null end as admin_login,
  p.phone,
  p.address,
  p.accent_color,
  p.background_color,
  p.logo_url,
  p.banner_url,
  p.social_links,
  p.work_hours,
  p.is_active,
  p.created_at
from public.projects p
where p.is_active is true or public.admin_can_access_project(p.id::text);

grant select on public.projects_public to anon, authenticated;

revoke all on public.services from anon, authenticated;
grant select, insert, update, delete on public.services to anon, authenticated;

create policy services_select
on public.services for select to anon, authenticated
using (
  public.is_public_project(project_id::text)
  or public.admin_can_access_project(project_id::text)
);

create policy services_insert
on public.services for insert to anon, authenticated
with check (public.admin_can_access_project(project_id::text));

create policy services_update
on public.services for update to anon, authenticated
using (public.admin_can_access_project(project_id::text))
with check (public.admin_can_access_project(project_id::text));

create policy services_delete
on public.services for delete to anon, authenticated
using (public.admin_can_access_project(project_id::text));

revoke all on public.bookings from anon, authenticated;
grant select, insert, update, delete on public.bookings to anon, authenticated;

create policy bookings_select
on public.bookings for select to anon, authenticated
using (public.admin_can_access_project(project_id::text));

create policy bookings_insert
on public.bookings for insert to anon, authenticated
with check (
  public.is_public_project(project_id::text)
  or public.admin_can_access_project(project_id::text)
);

create policy bookings_update
on public.bookings for update to anon, authenticated
using (public.admin_can_access_project(project_id::text))
with check (public.admin_can_access_project(project_id::text));

create policy bookings_delete
on public.bookings for delete to anon, authenticated
using (public.admin_can_access_project(project_id::text));

commit;
