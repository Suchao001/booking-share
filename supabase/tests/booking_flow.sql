-- Behaviour tests for 0001_initial.sql. Run on a scratch database:
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/stubs.sql -f supabase/migrations/0001_initial.sql -f supabase/tests/booking_flow.sql
-- Any failed assertion aborts the script.

create schema t;
grant usage on schema t to authenticated;

create function t.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), false);
$$;

create function t.expect_error(p_sql text, p_sqlstate text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'expected % but statement succeeded: %', p_sqlstate, p_sql;
exception when others then
  if sqlstate <> p_sqlstate then
    raise exception 'expected % got % (%): %', p_sqlstate, sqlstate, sqlerrm, p_sql;
  end if;
end;
$$;

create function t.assert_eq(p_what text, p_actual anyelement, p_expected anyelement) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_what, p_expected, p_actual;
  end if;
  raise notice 'ok   %', p_what;
end;
$$;

grant execute on all functions in schema t to authenticated;

-- Fixtures (as superuser)
insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-00000000000c');
insert into public.team_members (user_id, display_name) values
  ('00000000-0000-0000-0000-00000000000a', 'สมชาย'),
  ('00000000-0000-0000-0000-00000000000b', 'สมหญิง');
insert into public.rooms (name, reference_price) values ('101', 1200), ('102', 1200), ('103', null);

create table t.ids (k text primary key, v bigint);
grant all on t.ids to authenticated;

set role authenticated;

-- 1. Member creates a two-room booking (6-8 Oct)
select t.login('00000000-0000-0000-0000-00000000000a');
insert into t.ids select 'b1', public.create_booking('คุณสมชาย', '2026-10-06', '2026-10-08', 5400, 'note',
  '[{"room_id":1,"guests":2},{"room_id":2,"guests":2}]');
select t.assert_eq('total guests', (select total_guests from public.booking_overview where id = (select v from t.ids where k='b1')), 4);
select t.assert_eq('nights', (select nights from public.booking_overview where id = (select v from t.ids where k='b1')), 2);

-- 2. Overlap on a shared room is rejected with a readable reason
select t.login('00000000-0000-0000-0000-00000000000b');
select t.expect_error($$select public.create_booking('x','2026-10-07','2026-10-09',100,null,'[{"room_id":2,"guests":1}]')$$, 'BK001');

-- 3. Check-out day is bookable again
insert into t.ids select 'b2', public.create_booking('คุณสมหญิง', '2026-10-08', '2026-10-10', 2000, null,
  '[{"room_id":2,"guests":3}]');

-- 4. Daily numbers are counted by check-in date only (not by every night of the stay)
select t.assert_eq('6 Oct reserved guests', (select reserved_guests from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-06'), 4);
select t.assert_eq('6 Oct reserved bookings', (select reserved_bookings from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-06'), 1);
select t.assert_eq('6 Oct checked-in guests', (select checked_in_guests from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-06'), 0);
select t.assert_eq('7 Oct no arrivals', (select reserved_guests from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-07'), 0);
select t.assert_eq('8 Oct arrivals (other booking)', (select reserved_guests from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-08'), 3);
select t.assert_eq('5 Oct empty', (select reserved_bookings from public.get_daily_stats('2026-10-05','2026-10-10') where day = '2026-10-05'), 0);

-- 5. Room picker availability
select t.assert_eq('room 102 unavailable', (select is_available from public.available_rooms('2026-10-07','2026-10-09') where name = '102'), false);
select t.assert_eq('room 103 available', (select is_available from public.available_rooms('2026-10-07','2026-10-09') where name = '103'), true);
select t.assert_eq('own booking excluded when editing', (select is_available from public.available_rooms('2026-10-06','2026-10-08', (select v from t.ids where k='b1')) where name = '101'), true);

-- 6. Cancel frees the rooms and drops the numbers
select public.cancel_booking((select v from t.ids where k='b1'));
select t.assert_eq('cancelled status', (select status from public.booking_overview where id = (select v from t.ids where k='b1')), 'cancelled');
select t.assert_eq('6 Oct reserved after cancel', (select reserved_guests from public.get_daily_stats('2026-10-06','2026-10-06')), 0);
select t.expect_error(format('select public.cancel_booking(%s)', (select v from t.ids where k='b1')), 'BK004');
select t.expect_error(format($$select public.update_booking(%s,'x','2026-10-06','2026-10-08',1,null,'[{"room_id":1,"guests":1}]')$$, (select v from t.ids where k='b1')), 'BK004');

-- 7. Someone else takes room 101, so restoring all-or-nothing fails
select t.login('00000000-0000-0000-0000-00000000000a');
insert into t.ids select 'b3', public.create_booking('คนอื่น', '2026-10-07', '2026-10-09', 900, null, '[{"room_id":1,"guests":1}]');
select t.expect_error(format('select public.restore_booking(%s)', (select v from t.ids where k='b1')), 'BK001');
select t.assert_eq('still cancelled after failed restore', (select status from public.booking_overview where id = (select v from t.ids where k='b1')), 'cancelled');
select t.assert_eq('rooms still inactive', (select count(*)::int from public.booking_rooms where booking_id = (select v from t.ids where k='b1') and is_active), 0);

-- 8. Restore succeeds once the room is free again
select public.cancel_booking((select v from t.ids where k='b3'));
select public.restore_booking((select v from t.ids where k='b1'));
select t.assert_eq('restored status', (select status from public.booking_overview where id = (select v from t.ids where k='b1')), 'reserved');
select t.assert_eq('restored_by name', (select restored_by_name from public.booking_overview where id = (select v from t.ids where k='b1')), 'สมชาย');
select t.assert_eq('cancel info cleared', (select cancelled_at is null from public.booking_overview where id = (select v from t.ids where k='b1')), true);

-- 9. Edit: move to another room/dates; audit columns update
select public.update_booking((select v from t.ids where k='b1'), 'แก้ไข', '2026-10-06', '2026-10-07', 1000, null, '[{"room_id":3,"guests":5}]');
select t.assert_eq('edited guests', (select total_guests from public.booking_overview where id = (select v from t.ids where k='b1')), 5);
select t.assert_eq('edited rooms', (select rooms -> 0 ->> 'name' from public.booking_overview where id = (select v from t.ids where k='b1')), '103');
select t.assert_eq('rooms 101 free again', (select is_available from public.available_rooms('2026-10-06','2026-10-07') where name = '101'), true);

-- 10. Validation
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-08',1,null,'[{"room_id":1,"guests":1}]')$$, 'BK002');
select t.expect_error($$select public.create_booking('  ','2026-10-08','2026-10-09',1,null,'[{"room_id":1,"guests":1}]')$$, 'BK002');
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-09',-1,null,'[{"room_id":1,"guests":1}]')$$, 'BK002');
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-09',1,null,'[]')$$, 'BK002');
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-09',1,null,'[{"room_id":1,"guests":0}]')$$, 'BK002');
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-09',1,null,'[{"room_id":1,"guests":1},{"room_id":1,"guests":2}]')$$, 'BK002');
select t.expect_error($$select public.create_booking('x','2026-10-08','2026-10-09',1,null,'[{"room_id":999,"guests":1}]')$$, 'BK002');

-- 11. Notifications: actor's own are read, others unread; mark read works
select t.login('00000000-0000-0000-0000-00000000000b');
select t.assert_eq('B unread = A actions', (select count(*)::int from public.notification_feed where not is_read), 4);
select public.mark_notification_read((select min(id) from public.notification_feed where not is_read));
select t.assert_eq('B unread after one read', (select count(*)::int from public.notification_feed where not is_read), 3);
select public.mark_all_notifications_read();
select t.assert_eq('B unread after read all', (select count(*)::int from public.notification_feed where not is_read), 0);
select t.assert_eq('payload actor', (select payload ->> 'actor_name' from public.notification_feed order by id limit 1), 'สมชาย');

-- 12. Security: outsiders and direct writes
select t.login('00000000-0000-0000-0000-00000000000c');
select t.expect_error($$select public.create_booking('x','2026-11-01','2026-11-02',1,null,'[{"room_id":1,"guests":1}]')$$, 'BK003');
select t.assert_eq('outsider sees no bookings', (select count(*)::int from public.bookings), 0);
select t.assert_eq('outsider sees no rooms', (select count(*)::int from public.rooms), 0);
select t.login('00000000-0000-0000-0000-00000000000a');
select t.expect_error($$insert into public.bookings (title, check_in, check_out, total_amount, created_by, updated_by) values ('x','2026-11-01','2026-11-02',1,'00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000a')$$, '42501');
select t.expect_error($$update public.bookings set total_amount = 0$$, '42501');
select t.expect_error($$delete from public.booking_rooms$$, '42501');
select t.expect_error($$select public.bk_fail('BK001','x')$$, '42501');

-- 13. The constraint itself holds even if the RPC were bypassed (concurrency backstop)
reset role;
select t.expect_error($$insert into public.booking_rooms (booking_id, room_id, guests) values ((select v from t.ids where k='b2'), 2, 1)$$, '23505');
insert into public.bookings (title, check_in, check_out, total_amount, created_by, updated_by)
  values ('raw', '2026-10-09', '2026-10-11', 1, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a')
  returning id \gset raw_
select t.expect_error(format('insert into public.booking_rooms (booking_id, room_id, guests) values (%s, 2, 1)', :raw_id), '23P01');

\echo ALL TESTS PASSED
