-- ราคาแบบมีผลตั้งแต่เดือนที่กำหนด (ราคาเดิมของเดือนที่ยังไม่จ่ายจะไม่ถูกเปลี่ยน)
-- รันใน Supabase Dashboard > SQL Editor (ลำดับ: slip_payments.sql -> price_changes.sql -> bill_day.sql)
-- หมายเหตุ: ไฟล์ที่รันทีหลังจะทับฟังก์ชัน mark_paid/amount_due/mark_paid_by_slip ของไฟล์ก่อนหน้า
-- ถ้ารันไฟล์นี้ซ้ำ ให้รัน bill_day.sql ตามหลังอีกครั้งเสมอ
--
-- แนวคิด: เก็บ "ราคาที่เริ่มใช้ตั้งแต่เดือน X" เป็นรายการ ราคาของเดือนใดคือรายการล่าสุดที่ from_m <= เดือนนั้น
-- ตัวอย่าง: (0, 87) และ (24324, 99) -> เดือนก่อน ม.ค. 70 คิด 87 ตั้งแต่ ม.ค. 70 คิด 99

create table if not exists public.price_changes (
  from_m integer primary key,            -- เลขเดือน (ปี*12 + เดือน 0-11) เหมือน paid_until / bill_until
  price integer not null check (price >= 0),
  created_at timestamptz not null default now()
);

-- ให้ผู้ล็อกอินเข้าถึงตารางได้ (ขอบเขตจริงคุมด้วย RLS ด้านล่าง: ทุกคนอ่านได้ เฉพาะแอดมินเขียนได้)
grant select, insert, update, delete on public.price_changes to authenticated;

alter table public.price_changes enable row level security;
drop policy if exists pc_read on public.price_changes;
drop policy if exists pc_admin on public.price_changes;
create policy pc_read on public.price_changes for select to authenticated using (true);
create policy pc_admin on public.price_changes for all to authenticated using (is_admin()) with check (is_admin());

-- ราคาเริ่มต้นจากค่าปัจจุบันใน settings (ใช้กับทุกเดือนก่อนหน้า)
insert into public.price_changes (from_m, price)
select 0, price from public.settings where id = 1
on conflict (from_m) do nothing;

-- ราคาของเดือนที่ i
create or replace function public.price_for(i integer)
returns integer
language sql stable set search_path = public
as $$
  select coalesce(
    (select price from price_changes where from_m <= i order by from_m desc limit 1),
    (select price from settings where id = 1));
$$;

-- ผลรวมราคาของเดือน p_from ถึง p_to (รวมปลายทั้งสองข้าง)
create or replace function public.price_sum(p_from integer, p_to integer)
returns integer
language sql stable set search_path = public
as $$
  select coalesce(sum(price_for(g)), 0)::integer from generate_series(p_from, p_to) g;
$$;

-- แอดมินกดรับเงินเอง: คิดยอดตามราคาของแต่ละเดือน
create or replace function public.mark_paid(p_member bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare m members; s settings; amt int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select * into m from members where id = p_member for update;
  select * into s from settings where id = 1;
  if m.paid_until is null then raise exception 'ยังไม่ได้ตั้งเดือนที่จ่ายถึง'; end if;
  amt := price_sum(m.paid_until + 1, s.bill_until) + m.adjust;
  if amt <= 0 then raise exception 'ไม่มียอดค้าง'; end if;
  insert into payments(member_id, amount, from_m, to_m, prev_paid_until, prev_adjust, prev_note)
  values (m.id, amt, m.paid_until + 1, s.bill_until, m.paid_until, m.adjust, m.note);
  update members set paid_until = s.bill_until, adjust = 0, note = '' where id = m.id;
end $$;

-- ยอดที่ต้องจ่าย (ใช้กับระบบตรวจสลิป)
create or replace function public.amount_due(p_member bigint)
returns integer
language plpgsql stable security definer set search_path = public
as $$
declare m members; s settings;
begin
  select * into m from members where id = p_member;
  select * into s from settings where id = 1;
  if m.id is null or not m.billed or m.paid_until is null then return 0; end if;
  return price_sum(m.paid_until + 1, s.bill_until) + m.adjust;
end $$;

-- บันทึกรับเงินจากสลิป
create or replace function public.mark_paid_by_slip(p_member bigint, p_trans_ref text, p_amount integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare m members; s settings; amt int;
begin
  select * into m from members where id = p_member for update;
  select * into s from settings where id = 1;
  if m.id is null then raise exception 'ไม่พบสมาชิก'; end if;
  if m.paid_until is null then raise exception 'ยังไม่ได้ตั้งเดือนที่จ่ายถึง'; end if;
  amt := price_sum(m.paid_until + 1, s.bill_until) + m.adjust;
  if amt <= 0 then raise exception 'ไม่มียอดค้าง'; end if;
  if amt <> p_amount then raise exception 'ยอดไม่ตรง'; end if;
  insert into payments(member_id, amount, from_m, to_m, prev_paid_until, prev_adjust, prev_note, trans_ref)
  values (m.id, amt, m.paid_until + 1, s.bill_until, m.paid_until, m.adjust, m.note, p_trans_ref);
  update members set paid_until = s.bill_until, adjust = 0, note = '' where id = m.id;
end $$;

-- สิทธิ์เหมือนเดิม (create or replace ไม่ล้างสิทธิ์ แต่ใส่ซ้ำเพื่อความชัดเจน)
revoke execute on function public.amount_due(bigint) from public, anon, authenticated;
revoke execute on function public.mark_paid_by_slip(bigint, text, integer) from public, anon, authenticated;
grant execute on function public.amount_due(bigint) to service_role;
grant execute on function public.mark_paid_by_slip(bigint, text, integer) to service_role;
