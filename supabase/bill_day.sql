-- วันสรุปยอดประจำเดือน: เลื่อน "เก็บถึงเดือน" (settings.bill_until) อัตโนมัติ
-- รันใน Supabase Dashboard > SQL Editor (ลำดับ: slip_payments.sql -> price_changes.sql -> bill_day.sql)
-- ไฟล์นี้ต้องรันเป็นไฟล์สุดท้ายเสมอ เพราะกำหนดเวอร์ชันล่าสุดของ mark_paid/amount_due/mark_paid_by_slip
--
-- กติกา (เวลาไทย): ตั้งแต่วันสรุปยอดเป็นต้นไป เก็บถึงเดือนปัจจุบัน / ก่อนวันสรุปยอด เก็บถึงเดือนก่อนหน้า
-- ตัวอย่าง วันสรุปยอด = 1: ทุกวัน เก็บถึงเดือนปัจจุบัน (วันที่ 1 ธ.ค. ยอด ธ.ค. จึงขึ้น)
-- ตัวอย่าง วันสรุปยอด = 25: วันที่ 24 พ.ย. -> เก็บถึง ต.ค. / วันที่ 25 พ.ย. -> เก็บถึง พ.ย.
-- bill_day = null หมายถึงปิดอัตโนมัติ (แอดมินเลือกเดือนเอง)
-- เมื่อเปิดอัตโนมัติ ค่า bill_until จะถูกคำนวณตามวันที่จริงทั้งหมด (ถอยหลังได้ถ้าเดือนยังไม่ถึงวันสรุปยอด)

alter table public.settings add column if not exists bill_day integer
  check (bill_day is null or bill_day between 1 and 28);

-- เดือนที่ควรเก็บถึง ณ ตอนนี้
create or replace function public.eff_bill_until()
returns integer
language sql stable set search_path = public
as $$
  select case when s.bill_day is null then s.bill_until
    else (extract(year from x.t) * 12 + extract(month from x.t) - 1)::int
      - case when extract(day from x.t) >= s.bill_day then 0 else 1 end
    end
  from settings s, (select (now() at time zone 'Asia/Bangkok') as t) x
  where s.id = 1;
$$;

-- บันทึกค่าที่คำนวณลง settings หน้าเว็บเรียกทุกครั้งที่เปิด (ทำงานเมื่อเปิดโหมดอัตโนมัติเท่านั้น)
create or replace function public.roll_bill_until()
returns integer
language plpgsql security definer set search_path = public
as $$
declare e int;
begin
  e := eff_bill_until();
  update settings set bill_until = e where id = 1 and bill_day is not null and bill_until <> e;
  return e;
end $$;

revoke execute on function public.roll_bill_until() from public, anon;
grant execute on function public.roll_bill_until() to authenticated, service_role;

-- ฟังก์ชันคิดยอด/บันทึกรับเงิน ใช้เดือนที่เก็บถึงตามวันสรุปยอดด้วย (ตรงกับที่หน้าเว็บแสดง)
create or replace function public.mark_paid(p_member bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare m members; b int; amt int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  perform roll_bill_until();
  select * into m from members where id = p_member for update;
  select bill_until into b from settings where id = 1;
  if m.paid_until is null then raise exception 'ยังไม่ได้ตั้งเดือนที่จ่ายถึง'; end if;
  amt := price_sum(m.paid_until + 1, b) + m.adjust;
  if amt <= 0 then raise exception 'ไม่มียอดค้าง'; end if;
  insert into payments(member_id, amount, from_m, to_m, prev_paid_until, prev_adjust, prev_note)
  values (m.id, amt, m.paid_until + 1, b, m.paid_until, m.adjust, m.note);
  update members set paid_until = b, adjust = 0, note = '' where id = m.id;
end $$;

create or replace function public.amount_due(p_member bigint)
returns integer
language plpgsql security definer set search_path = public
as $$
declare m members; b int;
begin
  perform roll_bill_until();
  select * into m from members where id = p_member;
  select bill_until into b from settings where id = 1;
  if m.id is null or not m.billed or m.paid_until is null then return 0; end if;
  return price_sum(m.paid_until + 1, b) + m.adjust;
end $$;

create or replace function public.mark_paid_by_slip(p_member bigint, p_trans_ref text, p_amount integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare m members; b int; amt int;
begin
  perform roll_bill_until();
  select * into m from members where id = p_member for update;
  select bill_until into b from settings where id = 1;
  if m.id is null then raise exception 'ไม่พบสมาชิก'; end if;
  if m.paid_until is null then raise exception 'ยังไม่ได้ตั้งเดือนที่จ่ายถึง'; end if;
  amt := price_sum(m.paid_until + 1, b) + m.adjust;
  if amt <= 0 then raise exception 'ไม่มียอดค้าง'; end if;
  if amt <> p_amount then raise exception 'ยอดไม่ตรง'; end if;
  insert into payments(member_id, amount, from_m, to_m, prev_paid_until, prev_adjust, prev_note, trans_ref)
  values (m.id, amt, m.paid_until + 1, b, m.paid_until, m.adjust, m.note, p_trans_ref);
  update members set paid_until = b, adjust = 0, note = '' where id = m.id;
end $$;

revoke execute on function public.amount_due(bigint) from public, anon, authenticated;
revoke execute on function public.mark_paid_by_slip(bigint, text, integer) from public, anon, authenticated;
grant execute on function public.amount_due(bigint) to service_role;
grant execute on function public.mark_paid_by_slip(bigint, text, integer) to service_role;
