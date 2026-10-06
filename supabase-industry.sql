begin;

alter table public.projects
  add column if not exists industry text;

grant update (industry) on public.projects to anon, authenticated;

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
  p.created_at,
  p.industry
from public.projects p
where p.is_active is true or public.admin_can_access_project(p.id::text);

grant select on public.projects_public to anon, authenticated;

commit;

notify pgrst, 'reload schema';
