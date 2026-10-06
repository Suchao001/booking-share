-- Room management from the app (previously Supabase Dashboard only).
-- Any active team member can add/edit/deactivate rooms. Rooms are never deleted: bookings reference them.
-- Deactivating hides a room from the picker for new bookings; existing bookings are unaffected.
-- Errors: BK002 invalid_input (blank name, negative price, duplicate name), BK003 forbidden, BK005 not_found.

create function public.create_room(p_name text, p_reference_price numeric default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  perform public.bk_require_member();
  if p_name is null or length(btrim(p_name)) = 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ต้องระบุชื่อห้อง');
  end if;
  if p_reference_price is not null and p_reference_price < 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ราคาอ้างอิงต้องไม่ติดลบ');
  end if;

  insert into public.rooms (name, reference_price)
  values (btrim(p_name), p_reference_price)
  returning id into v_id;
  return v_id;
exception when unique_violation then
  perform public.bk_fail('BK002', 'invalid_input', 'มีห้องชื่อนี้อยู่แล้ว');
end;
$$;

create function public.update_room(
  p_room_id bigint, p_name text, p_reference_price numeric, p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bk_require_member();
  if p_name is null or length(btrim(p_name)) = 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ต้องระบุชื่อห้อง');
  end if;
  if p_reference_price is not null and p_reference_price < 0 then
    perform public.bk_fail('BK002', 'invalid_input', 'ราคาอ้างอิงต้องไม่ติดลบ');
  end if;
  if p_is_active is null then
    perform public.bk_fail('BK002', 'invalid_input', 'ต้องระบุสถานะเปิด/ปิดใช้งาน');
  end if;

  update public.rooms
  set name = btrim(p_name), reference_price = p_reference_price, is_active = p_is_active
  where id = p_room_id;
  if not found then
    perform public.bk_fail('BK005', 'not_found', 'ไม่พบห้อง');
  end if;
exception when unique_violation then
  perform public.bk_fail('BK002', 'invalid_input', 'มีห้องชื่อนี้อยู่แล้ว');
end;
$$;

revoke execute on function public.create_room(text, numeric), public.update_room(bigint, text, numeric, boolean)
  from public, anon, authenticated;
grant execute on function public.create_room(text, numeric), public.update_room(bigint, text, numeric, boolean)
  to authenticated;
