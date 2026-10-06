-- Simplified lifecycle: reserved (จอง/รอเช็กอิน) -> checked_in (เช็กอินแล้ว), plus cancelled.
-- Replaces the "staying" idea: the calendar counts guests by their check-in date only.
-- Rooms stay blocked for the whole stay while a booking is reserved or checked in.
-- Rules: only reserved bookings can be cancelled (undo the check-in first); restoring returns to reserved.
-- New errors reuse BK004 invalid_status.

-- 1. Trigger functions first: they used to treat 'active' as the live status.
create or replace function public.booking_rooms_fill_from_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select b.check_in, b.check_out, b.status <> 'cancelled'
    into new.check_in, new.check_out, new.is_active
  from public.bookings b
  where b.id = new.booking_id;
  return new;
end;
$$;

create or replace function public.bookings_sync_rooms()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.booking_rooms
  set check_in = new.check_in,
      check_out = new.check_out,
      is_active = (new.status <> 'cancelled')
  where booking_id = new.id;
  return null;
end;
$$;

-- 2. Status model
alter table public.bookings drop constraint bookings_status_check;
alter table public.bookings drop constraint cancel_fields_match_status;

alter table public.bookings
  add column checked_in_by uuid references public.team_members (user_id),
  add column checked_in_at timestamptz;

update public.bookings set status = 'reserved' where status = 'active';

alter table public.bookings alter column status set default 'reserved';
alter table public.bookings
  add constraint bookings_status_check check (status in ('reserved', 'checked_in', 'cancelled')),
  add constraint cancel_fields_match_status check (
    (status = 'cancelled') = (cancelled_at is not null and cancelled_by is not null)
  ),
  add constraint checkin_fields_match_status check (
    (status = 'checked_in') = (checked_in_at is not null and checked_in_by is not null)
  );

drop index public.bookings_active_stay_idx;
create index bookings_live_checkin_idx on public.bookings (check_in) where status <> 'cancelled';

-- 3. Writes
create or replace function public.update_booking(
  p_booking_id bigint, p_title text, p_check_in date, p_check_out date,
  p_total_amount numeric, p_note text, p_rooms jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_status text;
begin
  select status into v_status from public.bookings where id = p_booking_id for update;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบรายการจอง');
  end if;
  if v_status = 'cancelled' then
    perform public.bk_fail('BK004', 'invalid_status', 'แก้ไขรายการที่ยกเลิกแล้วไม่ได้ ให้คืนรายการก่อน');
  end if;

  perform public.bk_check_input(p_title, p_check_in, p_check_out, p_total_amount, p_rooms);
  perform public.bk_assert_rooms_available(
    array(select room_id from public.bk_parse_rooms(p_rooms)), p_check_in, p_check_out, p_booking_id);

  begin
    -- Remove rooms first so the old rows never clash while dates change.
    delete from public.booking_rooms where booking_id = p_booking_id;

    update public.bookings
    set title = btrim(p_title), check_in = p_check_in, check_out = p_check_out,
        total_amount = p_total_amount, note = nullif(btrim(p_note), ''),
        updated_by = v_uid, updated_at = now()
    where id = p_booking_id;

    insert into public.booking_rooms (booking_id, room_id, guests)
    select p_booking_id, room_id, guests from public.bk_parse_rooms(p_rooms);
  exception when exclusion_violation then
    perform public.bk_assert_rooms_available(
      array(select room_id from public.bk_parse_rooms(p_rooms)), p_check_in, p_check_out, p_booking_id);
    perform public.bk_fail('BK001', 'room_unavailable', 'ห้องถูกจองแล้ว');
  end;
end;
$$;

create or replace function public.cancel_booking(p_booking_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_status text;
begin
  select status into v_status from public.bookings where id = p_booking_id for update;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบรายการจอง');
  end if;
  if v_status = 'checked_in' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้เช็กอินแล้ว ต้องยกเลิกเช็กอินก่อนจึงจะยกเลิกการจองได้');
  elsif v_status = 'cancelled' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้ถูกยกเลิกไปแล้ว');
  end if;

  update public.bookings
  set status = 'cancelled', cancelled_by = v_uid, cancelled_at = now(),
      updated_by = v_uid, updated_at = now()
  where id = p_booking_id;

  perform public.bk_notify(p_booking_id, 'booking_cancelled');
end;
$$;

create or replace function public.restore_booking(p_booking_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_booking public.bookings;
  v_room_ids bigint[];
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบรายการจอง');
  end if;
  if v_booking.status <> 'cancelled' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้ยังไม่ได้ยกเลิก');
  end if;

  v_room_ids := array(select br.room_id from public.booking_rooms br where br.booking_id = p_booking_id);
  perform public.bk_assert_rooms_available(v_room_ids, v_booking.check_in, v_booking.check_out, p_booking_id);

  begin
    update public.bookings
    set status = 'reserved', cancelled_by = null, cancelled_at = null,
        restored_by = v_uid, restored_at = now(), updated_by = v_uid, updated_at = now()
    where id = p_booking_id;
  exception when exclusion_violation then
    perform public.bk_assert_rooms_available(v_room_ids, v_booking.check_in, v_booking.check_out, p_booking_id);
    perform public.bk_fail('BK001', 'room_unavailable', 'ห้องถูกจองแล้ว');
  end;

  perform public.bk_notify(p_booking_id, 'booking_restored');
end;
$$;

-- Check-in has no date restriction (guests may arrive early) and creates no notification.
create function public.check_in_booking(p_booking_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_status text;
begin
  select status into v_status from public.bookings where id = p_booking_id for update;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบรายการจอง');
  end if;
  if v_status = 'checked_in' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้เช็กอินแล้ว');
  elsif v_status = 'cancelled' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้ถูกยกเลิก ต้องคืนรายการก่อน');
  end if;

  update public.bookings
  set status = 'checked_in', checked_in_by = v_uid, checked_in_at = now(),
      updated_by = v_uid, updated_at = now()
  where id = p_booking_id;
end;
$$;

create function public.undo_check_in_booking(p_booking_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_status text;
begin
  select status into v_status from public.bookings where id = p_booking_id for update;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบรายการจอง');
  end if;
  if v_status <> 'checked_in' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้ยังไม่ได้เช็กอิน');
  end if;

  update public.bookings
  set status = 'reserved', checked_in_by = null, checked_in_at = null,
      updated_by = v_uid, updated_at = now()
  where id = p_booking_id;
end;
$$;

-- 4. Reads
drop function public.get_daily_stats(date, date);

-- Per check-in day: guests/bookings still waiting vs already checked in. Cancelled bookings are excluded.
create function public.get_daily_stats(p_from date, p_to date)
returns table (
  day date,
  reserved_bookings integer, reserved_guests integer,
  checked_in_bookings integer, checked_in_guests integer
)
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 100 then
    raise exception using errcode = 'BK002', message = 'invalid_input',
      detail = 'ช่วงวันที่ไม่ถูกต้อง (สูงสุด 100 วัน)';
  end if;

  return query
  select d::date,
         count(distinct b.id) filter (where b.status = 'reserved')::integer,
         coalesce(sum(br.guests) filter (where b.status = 'reserved'), 0)::integer,
         count(distinct b.id) filter (where b.status = 'checked_in')::integer,
         coalesce(sum(br.guests) filter (where b.status = 'checked_in'), 0)::integer
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  left join public.bookings b on b.check_in = d::date and b.status <> 'cancelled'
  left join public.booking_rooms br on br.booking_id = b.id
  group by d
  order by d;
end;
$$;

create or replace view public.booking_overview with (security_invoker = true) as
select
  b.id, b.title, b.check_in, b.check_out, b.total_amount, b.note, b.status,
  (b.check_out - b.check_in) as nights,
  coalesce((select sum(br.guests) from public.booking_rooms br where br.booking_id = b.id), 0)::integer as total_guests,
  coalesce((
    select jsonb_agg(jsonb_build_object('room_id', r.id, 'name', r.name, 'guests', br.guests) order by r.name)
    from public.booking_rooms br join public.rooms r on r.id = br.room_id
    where br.booking_id = b.id
  ), '[]'::jsonb) as rooms,
  b.created_by, cm.display_name as created_by_name, b.created_at,
  b.updated_by, um.display_name as updated_by_name, b.updated_at,
  b.cancelled_by, xm.display_name as cancelled_by_name, b.cancelled_at,
  b.restored_by, rm.display_name as restored_by_name, b.restored_at,
  b.checked_in_by, km.display_name as checked_in_by_name, b.checked_in_at
from public.bookings b
join public.team_members cm on cm.user_id = b.created_by
join public.team_members um on um.user_id = b.updated_by
left join public.team_members xm on xm.user_id = b.cancelled_by
left join public.team_members rm on rm.user_id = b.restored_by
left join public.team_members km on km.user_id = b.checked_in_by;

-- 5. Grants for the new functions
revoke execute on function
  public.check_in_booking(bigint), public.undo_check_in_booking(bigint), public.get_daily_stats(date, date)
  from public, anon, authenticated;
grant execute on function
  public.check_in_booking(bigint), public.undo_check_in_booking(bigint), public.get_daily_stats(date, date)
  to authenticated;
