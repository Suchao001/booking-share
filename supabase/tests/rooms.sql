-- Room management tests. Runs after booking_flow.sql (reuses its fixtures and helpers).
-- Members: ...0a (สมชาย), ...0b (สมหญิง); outsider: ...0c. Existing booking b1 uses room 103.

set role authenticated;
select t.login('00000000-0000-0000-0000-00000000000a');

insert into t.ids select 'r1', public.create_room('  401  ', 1800);
select t.assert_eq('room name trimmed', (select name from public.rooms where id = (select v from t.ids where k='r1')), '401');
select t.assert_eq('room price saved', (select reference_price from public.rooms where id = (select v from t.ids where k='r1')), 1800::numeric);
insert into t.ids select 'r2', public.create_room('402');
select t.assert_eq('price optional', (select reference_price is null from public.rooms where id = (select v from t.ids where k='r2')), true);

select t.expect_error($$select public.create_room('401', 1)$$, 'BK002');
select t.expect_error($$select public.create_room('   ', 1)$$, 'BK002');
select t.expect_error($$select public.create_room('403', -5)$$, 'BK002');

select public.update_room((select v from t.ids where k='r1'), '401A', null, true);
select t.assert_eq('room renamed', (select name from public.rooms where id = (select v from t.ids where k='r1')), '401A');
select t.expect_error(format($$select public.update_room(%s, '402', 1, true)$$, (select v from t.ids where k='r1')), 'BK002');
select t.expect_error($$select public.update_room(99999, 'x', null, true)$$, 'BK005');
select t.expect_error(format($$select public.update_room(%s, 'x', null, null)$$, (select v from t.ids where k='r1')), 'BK002');

-- Deactivated rooms vanish from the picker and cannot be newly booked
select public.update_room((select v from t.ids where k='r2'), '402', null, false);
select t.assert_eq('inactive hidden from picker', (select count(*)::int from public.available_rooms('2027-01-01','2027-01-02') where name = '402'), 0);
select t.expect_error(format($$select public.create_booking('x','2027-01-01','2027-01-02',1,null,'[{"room_id":%s,"guests":1}]')$$, (select v from t.ids where k='r2')), 'BK002');

-- ...but existing bookings in a deactivated room stay intact
select public.update_room(3, '103', null, false);
select t.assert_eq('existing booking keeps its room', (select rooms -> 0 ->> 'name' from public.booking_overview where id = (select v from t.ids where k='b1')), '103');
select public.update_room(3, '103', null, true);

-- Outsiders and direct writes
select t.login('00000000-0000-0000-0000-00000000000c');
select t.expect_error($$select public.create_room('999')$$, 'BK003');
select t.expect_error($$select public.update_room(1, 'x', null, true)$$, 'BK003');
select t.login('00000000-0000-0000-0000-00000000000a');
select t.expect_error($$insert into public.rooms (name) values ('direct')$$, '42501');
select t.expect_error($$delete from public.rooms$$, '42501');

reset role;
\echo ROOM TESTS PASSED
