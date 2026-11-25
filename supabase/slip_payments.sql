-- ระบบตรวจสลิปอัตโนมัติ (SlipOK)
-- รันไฟล์นี้ใน Supabase Dashboard > SQL Editor (ครั้งเดียว)

-- 1) เก็บเลขอ้างอิงสลิป เพื่อกันใช้สลิปซ้ำ
alter table public.payments add column if not exists trans_ref text;
create unique index if not exists payments_trans_ref_key on public.payments (trans_ref) where trans_ref is not null;

-- 2) ยอดที่สมาชิกต้องจ่ายตอนนี้ (สูตรเดียวกับ mark_paid) เรียกโดย Edge Function เท่านั้น
create or replace function public.amount_due(p_member bigint)
returns integer
language plpgsql stable security definer set search_path = public
as $$
declare m members; s settings;
begin
  select * into m from members where id = p_member;
  select * into s from settings where id = 1;
  if m.id is null or not m.billed or m.paid_until is null then return 0; end if;
  return greatest(0, s.bill_until - m.paid_until) * s.price + m.adjust;
end $$;

-- 3) บันทึกรับเงินจากสลิปที่ตรวจผ่านแล้ว (ตรวจยอดซ้ำในฐานข้อมูล + กันสลิปซ้ำด้วย unique index)
create or replace function public.mark_paid_by_slip(p_member bigint, p_trans_ref text, p_amount integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare m members; s settings; n int; amt int;
begin
  select * into m from members where id = p_member for update;
  select * into s from settings where id = 1;
  if m.id is null then raise exception 'ไม่พบสมาชิก'; end if;
  if m.paid_until is null then raise exception 'ยังไม่ได้ตั้งเดือนที่จ่ายถึง'; end if;
  n := greatest(0, s.bill_until - m.paid_until);
  amt := n * s.price + m.adjust;
  if amt <= 0 then raise exception 'ไม่มียอดค้าง'; end if;
  if amt <> p_amount then raise exception 'ยอดไม่ตรง'; end if;
  insert into payments(member_id, amount, from_m, to_m, prev_paid_until, prev_adjust, prev_note, trans_ref)
  values (m.id, amt, m.paid_until + 1, s.bill_until, m.paid_until, m.adjust, m.note, p_trans_ref);
  update members set paid_until = s.bill_until, adjust = 0, note = '' where id = m.id;
end $$;

-- 4) ให้เรียกได้เฉพาะ service_role (Edge Function) ห้ามเรียกจากหน้าเว็บโดยตรง
revoke execute on function public.amount_due(bigint) from public, anon, authenticated;
revoke execute on function public.mark_paid_by_slip(bigint, text, integer) from public, anon, authenticated;
grant execute on function public.amount_due(bigint) to service_role;
grant execute on function public.mark_paid_by_slip(bigint, text, integer) to service_role;
