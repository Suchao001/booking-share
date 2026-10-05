-- Development seed: sample rooms. Team members must be added after creating users in Supabase Auth:
--   insert into public.team_members (user_id, display_name) values ('<auth user id>', 'ชื่อที่แสดง');
insert into public.rooms (name, reference_price) values
  ('101', 1200), ('102', 1200), ('201', 1500), ('202', 1500), ('301', null)
on conflict (name) do nothing;
