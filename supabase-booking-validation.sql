begin;

alter table public.bookings
  add column if not exists website text;

create or replace function public.validate_public_booking()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_phone_digits text;
  v_booking_date date;
begin
  if nullif(btrim(coalesce(new.website, '')), '') is not null then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  if char_length(btrim(coalesce(new.client_name::text, ''))) not between 1 and 120 then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  v_phone_digits := regexp_replace(coalesce(new.client_phone::text, ''), '[^0-9]', '', 'g');
  if length(v_phone_digits) <> 11
     or substring(v_phone_digits from 1 for 1) <> '7'
     or substring(v_phone_digits from 2 for 1) not in ('8', '9') then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  if new.booking_date is null or new.booking_time is null then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  v_booking_date := new.booking_date::text::date;
  if v_booking_date < current_date then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  if char_length(coalesce(new.notes::text, '')) > 1000
     or char_length(coalesce(new.car_info::text, '')) > 200 then
    raise exception using errcode = '23514', message = 'Invalid booking request';
  end if;

  return new;
end;
$$;

drop trigger if exists validate_public_booking_before_insert on public.bookings;

create trigger validate_public_booking_before_insert
before insert on public.bookings
for each row
execute function public.validate_public_booking();

revoke all on function public.validate_public_booking() from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';
