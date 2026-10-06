begin;

alter table public.bookings
  add column if not exists service_duration_minutes integer;

update public.bookings b
set service_duration_minutes = coalesce(s.duration_minutes, 60)
from public.services s
where b.service_duration_minutes is null
  and b.service_id::text = s.id::text
  and b.project_id::text = s.project_id::text;

update public.bookings
set service_duration_minutes = 60
where service_duration_minutes is null;

alter table public.bookings
  alter column service_duration_minutes set default 60,
  alter column service_duration_minutes set not null;

create or replace function public.guard_booking_schedule()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_booking_date date;
  v_work_hours jsonb;
  v_open time;
  v_close time;
  v_start_minute integer;
  v_open_minute integer;
  v_close_minute integer;
  v_duration integer;
begin
  v_booking_date := new.booking_date::date;

  if v_booking_date < current_date or v_booking_date > current_date + 30 then
    raise exception using errcode = '23514', message = 'Booking date must be within the next 30 days';
  end if;

  select pg_catalog.to_jsonb(p.work_hours)
  into v_work_hours
  from public.projects p
  where p.id::text = new.project_id::text;

  if v_work_hours is null
     or coalesce(v_work_hours->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
     or coalesce(v_work_hours->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
    raise exception using errcode = '23514', message = 'Booking schedule is unavailable';
  end if;

  v_open := (v_work_hours->>'start')::time;
  v_close := (v_work_hours->>'end')::time;
  v_open_minute := extract(hour from v_open)::integer * 60 + extract(minute from v_open)::integer;
  v_close_minute := extract(hour from v_close)::integer * 60 + extract(minute from v_close)::integer;
  v_start_minute := extract(hour from new.booking_time)::integer * 60
    + extract(minute from new.booking_time)::integer;

  if v_close_minute <= v_open_minute
     or not exists (
       select 1
       from pg_catalog.jsonb_array_elements_text(coalesce(v_work_hours->'days', '[]'::jsonb)) d(value)
       where d.value = extract(dow from v_booking_date)::integer::text
     ) then
    raise exception using errcode = '23514', message = 'Booking schedule is unavailable';
  end if;

  if new.service_id is null then
    v_duration := 60;
  else
    select coalesce(s.duration_minutes, 60)
    into v_duration
    from public.services s
    where s.id::text = new.service_id::text
      and s.project_id::text = new.project_id::text;

    if not found then
      raise exception using errcode = '23514', message = 'Invalid booking service';
    end if;
  end if;

  if v_duration < 1 or v_duration > 1440
     or v_start_minute < v_open_minute
     or v_start_minute + v_duration > v_close_minute
     or mod(v_start_minute - v_open_minute, 30) <> 0
     or extract(second from new.booking_time) <> 0 then
    raise exception using errcode = '23514', message = 'Invalid booking time';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(new.project_id::text),
    (v_booking_date - date '2000-01-01')
  );

  if exists (
    select 1
    from public.bookings b
    where b.project_id::text = new.project_id::text
      and b.booking_date::text::date = v_booking_date
      and b.status is distinct from 'cancelled'
      and extract(epoch from b.booking_time) / 60
        < v_start_minute + v_duration
      and v_start_minute
        < extract(epoch from b.booking_time) / 60 + coalesce(b.service_duration_minutes, 60)
  ) then
    raise exception using errcode = '23P01', message = 'This time is no longer available';
  end if;

  new.service_duration_minutes := v_duration;
  return new;
end;
$$;

drop trigger if exists guard_booking_schedule_before_insert on public.bookings;

create trigger guard_booking_schedule_before_insert
before insert on public.bookings
for each row
execute function public.guard_booking_schedule();

revoke all on function public.guard_booking_schedule() from public, anon, authenticated;

create or replace function public.guard_booking_reactivation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if old.status is distinct from 'cancelled'
     or new.status is not distinct from 'cancelled' then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(new.project_id::text),
    (new.booking_date::date - date '2000-01-01')
  );

  if exists (
    select 1
    from public.bookings b
    where b.id <> new.id
      and b.project_id::text = new.project_id::text
      and b.booking_date::text::date = new.booking_date::text::date
      and b.status is distinct from 'cancelled'
      and extract(epoch from b.booking_time) / 60
        < extract(epoch from new.booking_time) / 60 + coalesce(new.service_duration_minutes, 60)
      and extract(epoch from new.booking_time) / 60
        < extract(epoch from b.booking_time) / 60 + coalesce(b.service_duration_minutes, 60)
  ) then
    raise exception using errcode = '23P01', message = 'This time is no longer available';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_booking_reactivation_before_update on public.bookings;

create trigger guard_booking_reactivation_before_update
before update of status on public.bookings
for each row
execute function public.guard_booking_reactivation();

revoke all on function public.guard_booking_reactivation() from public, anon, authenticated;

drop function if exists public.get_public_booking_slots(text, date, text);

create function public.get_public_booking_slots(
  p_project_id text,
  p_booking_date date,
  p_service_id text
)
returns table(slot_time time)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_work_hours jsonb;
  v_open time;
  v_close time;
  v_duration integer;
begin
  if p_project_id is null
     or p_booking_date is null
     or p_booking_date < current_date
     or p_booking_date > current_date + 30
     or not public.is_public_project(p_project_id) then
    return;
  end if;

  select pg_catalog.to_jsonb(p.work_hours)
  into v_work_hours
  from public.projects p
  where p.id::text = p_project_id;

  if v_work_hours is null
     or coalesce(v_work_hours->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
     or coalesce(v_work_hours->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
     or not exists (
       select 1
       from pg_catalog.jsonb_array_elements_text(coalesce(v_work_hours->'days', '[]'::jsonb)) d(value)
       where d.value = extract(dow from p_booking_date)::integer::text
     ) then
    return;
  end if;

  v_open := (v_work_hours->>'start')::time;
  v_close := (v_work_hours->>'end')::time;
  if v_close <= v_open then
    return;
  end if;

  if p_service_id is null then
    v_duration := 60;
  else
    select coalesce(s.duration_minutes, 60)
    into v_duration
    from public.services s
    where s.id::text = p_service_id
      and s.project_id::text = p_project_id;

    if not found then
      return;
    end if;
  end if;

  if v_duration < 1 or v_duration > 1440 then
    return;
  end if;

  return query
  select candidate.slot::time
  from pg_catalog.generate_series(
    p_booking_date + v_open,
    p_booking_date + v_close - (v_duration * interval '1 minute'),
    interval '30 minutes'
  ) as candidate(slot)
  where not exists (
      select 1
      from public.bookings b
      where b.project_id::text = p_project_id
        and b.booking_date::text::date = p_booking_date
        and b.status is distinct from 'cancelled'
        and extract(epoch from b.booking_time) / 60
          < extract(epoch from candidate.slot::time) / 60 + v_duration
        and extract(epoch from candidate.slot::time) / 60
          < extract(epoch from b.booking_time) / 60 + coalesce(b.service_duration_minutes, 60)
    )
  order by candidate.slot;
end;
$$;

revoke all on function public.get_public_booking_slots(text, date, text) from public;
grant execute on function public.get_public_booking_slots(text, date, text) to anon, authenticated;

create or replace function public.get_public_booking_calendar(
  p_project_id text,
  p_start_date date,
  p_service_id text
)
returns table(booking_date date, slot_time time)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_work_hours jsonb;
  v_open time;
  v_close time;
  v_duration integer;
begin
  if p_project_id is null
     or p_start_date is null
     or p_start_date < current_date
     or p_start_date > current_date + 30
     or not public.is_public_project(p_project_id) then
    return;
  end if;

  select pg_catalog.to_jsonb(p.work_hours)
  into v_work_hours
  from public.projects p
  where p.id::text = p_project_id;

  if v_work_hours is null
     or coalesce(v_work_hours->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
     or coalesce(v_work_hours->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$' then
    return;
  end if;

  v_open := (v_work_hours->>'start')::time;
  v_close := (v_work_hours->>'end')::time;
  if v_close <= v_open then
    return;
  end if;

  if p_service_id is null then
    v_duration := 60;
  else
    select coalesce(s.duration_minutes, 60)
    into v_duration
    from public.services s
    where s.id::text = p_service_id
      and s.project_id::text = p_project_id;

    if not found then
      return;
    end if;
  end if;

  if v_duration < 1 or v_duration > 1440 then
    return;
  end if;

  return query
  select calendar_day.day_value::date, candidate.slot::time
  from pg_catalog.generate_series(
    p_start_date::timestamp,
    least(p_start_date + 30, current_date + 30)::timestamp,
    interval '1 day'
  ) as calendar_day(day_value)
  cross join lateral pg_catalog.generate_series(
    calendar_day.day_value::date + v_open,
    calendar_day.day_value::date + v_close - (v_duration * interval '1 minute'),
    interval '30 minutes'
  ) as candidate(slot)
  where exists (
      select 1
      from pg_catalog.jsonb_array_elements_text(coalesce(v_work_hours->'days', '[]'::jsonb)) d(value)
      where d.value = extract(dow from calendar_day.day_value)::integer::text
    )
    and not exists (
      select 1
      from public.bookings b
      where b.project_id::text = p_project_id
        and b.booking_date::text::date = calendar_day.day_value::date
        and b.status is distinct from 'cancelled'
        and extract(epoch from b.booking_time) / 60
          < extract(epoch from candidate.slot::time) / 60 + v_duration
        and extract(epoch from candidate.slot::time) / 60
          < extract(epoch from b.booking_time) / 60 + coalesce(b.service_duration_minutes, 60)
    )
  order by calendar_day.day_value, candidate.slot;
end;
$$;

revoke all on function public.get_public_booking_calendar(text, date, text) from public;
grant execute on function public.get_public_booking_calendar(text, date, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';
