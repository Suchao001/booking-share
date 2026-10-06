-- Check-in lifecycle tests. Runs after booking_flow.sql and rooms.sql (reuses fixtures and helpers).
-- Booking b2 (room 102, 8-10 Oct, 3 guests, by ...0b) is reserved. Room 103 / booking b1 exist (6-7 Oct, 5 guests).

set role authenticated;
select t.login('00000000-0000-0000-0000-00000000000a');

select public.check_in_booking((select v from t.ids where k='b2'));
select t.assert_eq('status checked_in', (select status from public.booking_overview where id = (select v from t.ids where k='b2')), 'checked_in');
select t.assert_eq('checked_in_by name', (select checked_in_by_name from public.booking_overview where id = (select v from t.ids where k='b2')), 'สมชาย');
select t.assert_eq('checked_in_at set', (select checked_in_at is not null from public.booking_overview where id = (select v from t.ids where k='b2')), true);

-- Stats move from reserved to checked-in on the check-in day
select t.assert_eq('8 Oct reserved drops', (select reserved_guests from public.get_daily_stats('2026-10-08','2026-10-08')), 0);
select t.assert_eq('8 Oct checked-in guests', (select checked_in_guests from public.get_daily_stats('2026-10-08','2026-10-08')), 3);
select t.assert_eq('8 Oct checked-in bookings', (select checked_in_bookings from public.get_daily_stats('2026-10-08','2026-10-08')), 1);

-- Rooms stay blocked while checked in
select t.expect_error($$select public.create_booking('x','2026-10-09','2026-10-10',1,null,'[{"room_id":2,"guests":1}]')$$, 'BK001');

-- Guards
select t.expect_error(format('select public.check_in_booking(%s)', (select v from t.ids where k='b2')), 'BK004');
select t.expect_error(format('select public.cancel_booking(%s)', (select v from t.ids where k='b2')), 'BK004');
select t.expect_error(format('select public.undo_check_in_booking(%s)', (select v from t.ids where k='b1')), 'BK004');
select t.expect_error('select public.check_in_booking(99999)', 'BK005');

-- Editing after check-in is still allowed
select public.update_booking((select v from t.ids where k='b2'), 'แก้หลังเช็กอิน', '2026-10-08', '2026-10-10', 2500, null, '[{"room_id":2,"guests":4}]');
select t.assert_eq('still checked_in after edit', (select status from public.booking_overview where id = (select v from t.ids where k='b2')), 'checked_in');
select t.assert_eq('edited guests counted', (select checked_in_guests from public.get_daily_stats('2026-10-08','2026-10-08')), 4);

-- Undo, then cancel and restore go back to reserved
select public.undo_check_in_booking((select v from t.ids where k='b2'));
select t.assert_eq('undo -> reserved', (select status from public.booking_overview where id = (select v from t.ids where k='b2')), 'reserved');
select t.assert_eq('undo clears check-in info', (select checked_in_by is null and checked_in_at is null from public.booking_overview where id = (select v from t.ids where k='b2')), true);
select public.cancel_booking((select v from t.ids where k='b2'));
select t.expect_error(format('select public.check_in_booking(%s)', (select v from t.ids where k='b2')), 'BK004');
select public.restore_booking((select v from t.ids where k='b2'));
select t.assert_eq('restore -> reserved', (select status from public.booking_overview where id = (select v from t.ids where k='b2')), 'reserved');

-- Outsider cannot check in; no direct writes
select t.login('00000000-0000-0000-0000-00000000000c');
select t.expect_error(format('select public.check_in_booking(%s)', (select v from t.ids where k='b2')), 'BK003');
select t.login('00000000-0000-0000-0000-00000000000a');
select t.expect_error($$update public.bookings set status = 'checked_in'$$, '42501');

-- Check-in does not notify (only create / cancel / restore do)
select t.assert_eq('no check-in notification type', (select count(*)::int from public.notifications where type not in ('booking_created','booking_cancelled','booking_restored')), 0);

reset role;
\echo CHECKIN TESTS PASSED
