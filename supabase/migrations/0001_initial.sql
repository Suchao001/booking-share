-- Booking Share — schema (single-company MVP).
-- See SCOPE.md. Add users to team_members after creating them in Supabase Auth.
--
-- Design notes
-- * A booking has many rooms (booking_rooms) sharing one check_in/check_out. Stay is [check_in, check_out):
--   the check-out day is bookable again.
-- * "No double booking" is enforced by an EXCLUDE constraint on booking_rooms. Exclusion constraints cannot
--   look at other tables, so booking_rooms keeps a synced copy of dates and an is_active flag (triggers).
-- * Clients never write tables directly. All writes go through RPC functions (security definer) that check
--   membership, validate input, write audit columns and create in-app notifications atomically.
-- * RPC error codes (SQLSTATE) the app should map to messages:
--     BK001 room_unavailable  detail = human readable list of conflicts
--     BK002 invalid_input     detail = reason
--     BK003 forbidden         caller is not an active team member
--     BK004 invalid_status    e.g. editing a cancelled booking, restoring an active one
--     BK005 not_found

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.team_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) > 0),
  is_active boolean not null default true,
  joined_at timestamptz not null default now()
);

create table public.rooms (
  id bigint generated always as identity primary key,
  name text not null unique check (length(btrim(name)) > 0),
  -- Optional per-night hint shown while entering the total. Never used for calculation.
  reference_price numeric(10, 2) check (reference_price is null or reference_price >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id bigint generated always as identity primary key,
  title text not null check (length(btrim(title)) > 0),
  check_in date not null,
  check_out date not null,
  -- Entered by the user for the whole booking; not calculated.
  total_amount numeric(12, 2) not null check (total_amount >= 0),
  note text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  created_by uuid not null references public.team_members (user_id),
  created_at timestamptz not null default now(),
  updated_by uuid not null references public.team_members (user_id),
  updated_at timestamptz not null default now(),
  cancelled_by uuid references public.team_members (user_id),
  cancelled_at timestamptz,
  restored_by uuid references public.team_members (user_id),
  restored_at timestamptz,
  constraint stay_order check (check_out > check_in),
  constraint cancel_fields_match_status check (
    (status = 'cancelled') = (cancelled_at is not null and cancelled_by is not null)
  )
);

create index bookings_active_stay_idx on public.bookings (check_in, check_out) where status = 'active';

create table public.booking_rooms (
  id bigint generated always as identity primary key,
  booking_id bigint not null references public.bookings (id) on delete cascade,
  room_id bigint not null references public.rooms (id),
  guests integer not null check (guests > 0),
  -- Synced copies of the parent booking (see triggers) so the exclusion constraint can use them.
  check_in date not null,
  check_out date not null,
  is_active boolean not null,
  unique (booking_id, room_id),
  constraint no_room_double_booking exclude using gist (
    room_id with =,
    daterange(check_in, check_out, '[)') with &&
  ) where (is_active)
);

create index booking_rooms_booking_idx on public.booking_rooms (booking_id);

create table public.notifications (
  id bigint generated always as identity primary key,
  booking_id bigint not null references public.bookings (id) on delete cascade,
  type text not null check (type in ('booking_created', 'booking_cancelled', 'booking_restored')),
  actor_id uuid not null references public.team_members (user_id),
  -- Snapshot used to render the message without joins: title, dates, rooms, total_guests, actor_name.
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create index notifications_created_idx on public.notifications (created_at desc);

create table public.notification_reads (
  user_id uuid not null references public.team_members (user_id) on delete cascade,
  notification_id bigint not null references public.notifications (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (user_id, notification_id)
);

-- ---------------------------------------------------------------------------
-- Sync triggers
-- ---------------------------------------------------------------------------

create function public.booking_rooms_fill_from_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select b.check_in, b.check_out, b.status = 'active'
    into new.check_in, new.check_out, new.is_active
  from public.bookings b
  where b.id = new.booking_id;
  return new;
end;
$$;

create trigger booking_rooms_fill
before insert on public.booking_rooms
for each row execute function public.booking_rooms_fill_from_booking();

create function public.bookings_sync_rooms()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.booking_rooms
  set check_in = new.check_in,
      check_out = new.check_out,
      is_active = (new.status = 'active')
  where booking_id = new.id;
  return null;
end;
$$;

create trigger bookings_sync_rooms
after update of check_in, check_out, status on public.bookings
for each row execute function public.bookings_sync_rooms();

-- ---------------------------------------------------------------------------
-- Helpers (internal)
-- ---------------------------------------------------------------------------

create function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.team_members m
    where m.user_id = (select auth.uid()) and m.is_active
  );
$$;

create function public.bk_fail(p_code text, p_message text, p_detail text default null)
returns void
language plpgsql
as $$
begin
  raise exception using errcode = p_code, message = p_message, detail = p_detail;
end;
$$;

create function public.bk_require_member()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_member() then
    perform public.bk_fail('BK003', 'forbidden', 'บัญชีนี้ไม่ได้รับสิทธิ์ใช้งาน');
  end if;
  return (select auth.uid());
end;
$$;

-- Validates and returns the requested rooms. No queries here, so output names cannot clash.
create function public.bk_parse_rooms(p_rooms jsonb)
returns table (room_id bigint, guests integer)
language plpgsql
as $$
declare
  e jsonb;
  v_id bigint;
  v_guests integer;
  v_seen bigint[] := '{}';
begin
  if p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ต้องเลือกอย่างน้อย 1 ห้อง');
  end if;

  for e in select * from jsonb_array_elements(p_rooms) loop
    begin
      v_id := (e ->> 'room_id')::bigint;
      v_guests := (e ->> 'guests')::integer;
    exception when others then
      perform public.bk_fail('BK002', 'invalid_input', 'ข้อมูลห้องไม่ถูกต้อง');
    end;
    if v_id is null or v_guests is null or v_guests < 1 then
      perform public.bk_fail('BK002', 'invalid_input', 'ต้องระบุห้องและจำนวนคนอย่างน้อย 1 คน');
    end if;
    if v_id = any (v_seen) then
      perform public.bk_fail('BK002', 'invalid_input', 'เลือกห้องซ้ำ');
    end if;
    v_seen := v_seen || v_id;
    room_id := v_id;
    guests := v_guests;
    return next;
  end loop;
end;
$$;

create function public.bk_check_input(
  p_title text, p_check_in date, p_check_out date, p_total numeric, p_rooms jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_title is null or length(btrim(p_title)) = 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ต้องระบุชื่อรายการ');
  end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    perform public.bk_fail('BK002', 'invalid_input', 'วันออกต้องหลังวันเข้าอย่างน้อย 1 วัน');
  end if;
  if p_total is null or p_total < 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ยอดรวมต้องไม่ติดลบ');
  end if;
  if exists (
    select 1
    from public.bk_parse_rooms(p_rooms) pr
    left join public.rooms r on r.id = pr.room_id
    where r.id is null or not r.is_active
  ) then
    perform public.bk_fail('BK002', 'invalid_input', 'มีห้องที่ไม่พบหรือปิดใช้งาน');
  end if;
end;
$$;

-- Raises BK001 listing every conflicting room/night range, if any.
create function public.bk_assert_rooms_available(
  p_room_ids bigint[], p_check_in date, p_check_out date, p_exclude_booking_id bigint default null
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_detail text;
begin
  select string_agg(
           format('%s ไม่ว่าง %s ถึง %s (%s โดย %s)',
                  r.name,
                  to_char(greatest(br.check_in, p_check_in), 'YYYY-MM-DD'),
                  to_char(least(br.check_out, p_check_out), 'YYYY-MM-DD'),
                  b.title, m.display_name),
           E'\n' order by r.name, br.check_in)
    into v_detail
  from public.booking_rooms br
  join public.bookings b on b.id = br.booking_id
  join public.rooms r on r.id = br.room_id
  join public.team_members m on m.user_id = b.created_by
  where br.is_active
    and br.room_id = any (p_room_ids)
    and br.booking_id is distinct from p_exclude_booking_id
    and daterange(br.check_in, br.check_out, '[)') && daterange(p_check_in, p_check_out, '[)');

  if v_detail is not null then
    perform public.bk_fail('BK001', 'room_unavailable', v_detail);
  end if;
end;
$$;

create function public.bk_notify(p_booking_id bigint, p_type text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.notifications (booking_id, type, actor_id, payload)
  select b.id, p_type, m.user_id,
         jsonb_build_object(
           'title', b.title,
           'check_in', b.check_in,
           'check_out', b.check_out,
           'total_guests', (select coalesce(sum(br.guests), 0) from public.booking_rooms br where br.booking_id = b.id),
           'rooms', (select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'guests', br.guests) order by r.name), '[]'::jsonb)
                     from public.booking_rooms br join public.rooms r on r.id = br.room_id
                     where br.booking_id = b.id),
           'actor_name', m.display_name)
  from public.bookings b
  join public.team_members m on m.user_id = (select auth.uid())
  where b.id = p_booking_id
  returning id into v_id;

  -- The actor already knows about their own action.
  insert into public.notification_reads (user_id, notification_id)
  values ((select auth.uid()), v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: writes
-- ---------------------------------------------------------------------------

-- p_rooms: [{"room_id": 1, "guests": 2}, ...]
create function public.create_booking(
  p_title text, p_check_in date, p_check_out date, p_total_amount numeric, p_note text, p_rooms jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
  v_id bigint;
begin
  perform public.bk_check_input(p_title, p_check_in, p_check_out, p_total_amount, p_rooms);
  perform public.bk_assert_rooms_available(
    array(select room_id from public.bk_parse_rooms(p_rooms)), p_check_in, p_check_out);

  begin
    insert into public.bookings (title, check_in, check_out, total_amount, note, created_by, updated_by)
    values (btrim(p_title), p_check_in, p_check_out, p_total_amount, nullif(btrim(p_note), ''), v_uid, v_uid)
    returning id into v_id;

    insert into public.booking_rooms (booking_id, room_id, guests)
    select v_id, room_id, guests from public.bk_parse_rooms(p_rooms);
  exception when exclusion_violation then
    -- Lost a race with a concurrent booking: report the real conflict.
    perform public.bk_assert_rooms_available(
      array(select room_id from public.bk_parse_rooms(p_rooms)), p_check_in, p_check_out);
    perform public.bk_fail('BK001', 'room_unavailable', 'ห้องถูกจองแล้ว');
  end;

  perform public.bk_notify(v_id, 'booking_created');
  return v_id;
end;
$$;

create function public.update_booking(
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
  if v_status <> 'active' then
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

create function public.cancel_booking(p_booking_id bigint)
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
  if v_status <> 'active' then
    perform public.bk_fail('BK004', 'invalid_status', 'รายการนี้ถูกยกเลิกไปแล้ว');
  end if;

  update public.bookings
  set status = 'cancelled', cancelled_by = v_uid, cancelled_at = now(),
      updated_by = v_uid, updated_at = now()
  where id = p_booking_id;

  perform public.bk_notify(p_booking_id, 'booking_cancelled');
end;
$$;

-- All rooms must be free for the whole stay, otherwise nothing is restored (BK001 lists why).
create function public.restore_booking(p_booking_id bigint)
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
    set status = 'active', cancelled_by = null, cancelled_at = null,
        restored_by = v_uid, restored_at = now(), updated_by = v_uid, updated_at = now()
    where id = p_booking_id;
  exception when exclusion_violation then
    perform public.bk_assert_rooms_available(v_room_ids, v_booking.check_in, v_booking.check_out, p_booking_id);
    perform public.bk_fail('BK001', 'room_unavailable', 'ห้องถูกจองแล้ว');
  end;

  perform public.bk_notify(p_booking_id, 'booking_restored');
end;
$$;

create function public.mark_notification_read(p_notification_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
begin
  insert into public.notification_reads (user_id, notification_id)
  select v_uid, n.id from public.notifications n where n.id = p_notification_id
  on conflict do nothing;
end;
$$;

create function public.mark_all_notifications_read()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.bk_require_member();
begin
  insert into public.notification_reads (user_id, notification_id)
  select v_uid, n.id from public.notifications n
  on conflict do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: reads (security invoker, so RLS applies)
-- ---------------------------------------------------------------------------

-- Daily numbers for the calendar. staying = check_in <= day < check_out; check-in guests are a subset.
create function public.get_daily_stats(p_from date, p_to date)
returns table (day date, bookings_count integer, checkin_guests integer, staying_guests integer)
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
         count(distinct b.id)::integer,
         coalesce(sum(br.guests) filter (where b.check_in = d::date), 0)::integer,
         coalesce(sum(br.guests), 0)::integer
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  left join public.bookings b
    on b.status = 'active' and b.check_in <= d::date and d::date < b.check_out
  left join public.booking_rooms br on br.booking_id = b.id
  group by d
  order by d;
end;
$$;

-- Room picker: every active room with availability for the requested stay.
create function public.available_rooms(
  p_check_in date, p_check_out date, p_exclude_booking_id bigint default null
)
returns table (
  room_id bigint, name text, reference_price numeric, is_available boolean,
  conflict_booking_id bigint, conflict_check_in date, conflict_check_out date
)
language sql
stable
set search_path = ''
as $$
  select r.id, r.name, r.reference_price, c.booking_id is null,
         c.booking_id, c.check_in, c.check_out
  from public.rooms r
  left join lateral (
    select br.booking_id, br.check_in, br.check_out
    from public.booking_rooms br
    where br.room_id = r.id
      and br.is_active
      and br.booking_id is distinct from p_exclude_booking_id
      and daterange(br.check_in, br.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
    order by br.check_in
    limit 1
  ) c on true
  where r.is_active
  order by r.name;
$$;

-- ---------------------------------------------------------------------------
-- Views for reading
-- ---------------------------------------------------------------------------

create view public.booking_overview with (security_invoker = true) as
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
  b.restored_by, rm.display_name as restored_by_name, b.restored_at
from public.bookings b
join public.team_members cm on cm.user_id = b.created_by
join public.team_members um on um.user_id = b.updated_by
left join public.team_members xm on xm.user_id = b.cancelled_by
left join public.team_members rm on rm.user_id = b.restored_by;

create view public.notification_feed with (security_invoker = true) as
select n.id, n.booking_id, n.type, n.actor_id, n.payload, n.created_at,
       (nr.notification_id is not null) as is_read
from public.notifications n
left join public.notification_reads nr
  on nr.notification_id = n.id and nr.user_id = (select auth.uid());

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------

alter table public.team_members enable row level security;
alter table public.rooms enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_rooms enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_reads enable row level security;

-- Members can read everything the app shows; nobody writes tables directly (RPC only).
create policy "Members read members" on public.team_members for select to authenticated using (public.is_member());
create policy "Members read rooms" on public.rooms for select to authenticated using (public.is_member());
create policy "Members read bookings" on public.bookings for select to authenticated using (public.is_member());
create policy "Members read booking rooms" on public.booking_rooms for select to authenticated using (public.is_member());
create policy "Members read notifications" on public.notifications for select to authenticated using (public.is_member());
create policy "Members read own reads" on public.notification_reads for select to authenticated
  using (public.is_member() and user_id = (select auth.uid()));

revoke all on public.team_members, public.rooms, public.bookings, public.booking_rooms,
  public.notifications, public.notification_reads, public.booking_overview, public.notification_feed
  from anon, authenticated;

grant select on public.team_members, public.rooms, public.bookings, public.booking_rooms,
  public.notifications, public.notification_reads, public.booking_overview, public.notification_feed
  to authenticated;

-- Functions: nothing is executable by default; expose only the app API.
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.is_member(),
  public.create_booking(text, date, date, numeric, text, jsonb),
  public.update_booking(bigint, text, date, date, numeric, text, jsonb),
  public.cancel_booking(bigint),
  public.restore_booking(bigint),
  public.mark_notification_read(bigint),
  public.mark_all_notifications_read(),
  public.get_daily_stats(date, date),
  public.available_rooms(date, date, bigint)
to authenticated;
