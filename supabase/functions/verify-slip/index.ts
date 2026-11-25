// Edge Function: ตรวจสลิปด้วย SlipOK แล้วบันทึกรับเงินอัตโนมัติ
// Secrets ที่ต้องตั้ง: SLIPOK_API_KEY, SLIPOK_BRANCH_ID
// (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY มีให้อยู่แล้ว)
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const fail = (error: string, status = 400) => json({ ok: false, error }, status);

const SLIPOK_ERR: Record<number, string> = {
  1006: 'รูปภาพไม่ถูกต้อง',
  1007: 'ไม่พบ QR Code ในรูป ลองใช้สลิปที่เห็น QR ชัดเจน',
  1008: 'QR นี้ไม่ใช่ QR สำหรับตรวจสอบการชำระเงิน',
  1009: 'ระบบธนาคารขัดข้องชั่วคราว ลองใหม่ใน 15 นาที',
  1010: 'สลิปใหม่เกินไป รอสักครู่หลังโอนแล้วลองใหม่',
  1011: 'QR หมดอายุ หรือไม่มีรายการจริง',
  1012: 'สลิปนี้เคยถูกใช้แล้ว',
  1013: 'ยอดในสลิปไม่ตรงกับยอดที่ต้องชำระ',
};

// เทียบเลขที่ถูกปิดบังบางส่วน (เช่น 085-xxx-6106 หรือ xxx-x-x3109-x) กับเลขจริง
const norm = (s: string) => String(s ?? '').toLowerCase().replace(/[^0-9x]/g, '');
function maskedMatch(masked: string, real: string): boolean {
  let a = norm(masked);
  let b = norm(real).replace(/x/g, '');
  if (b.startsWith('66') && b.length === 11) b = '0' + b.slice(2);
  if (a.startsWith('66') && a.length === 11) a = '0' + a.slice(2);
  if (!a || !b || a.length !== b.length) return false;
  let visible = 0;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === 'x') continue;
    visible++;
    if (a[i] !== b[i]) return false;
  }
  return visible >= 3; // ต้องมีเลขที่มองเห็นอย่างน้อย 3 หลัก กันเทียบหลวมเกินไป
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail('method not allowed', 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // 1) ยืนยันตัวตนสมาชิกจาก JWT
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const { data: u, error: uerr } = await admin.auth.getUser(token);
  if (uerr || !u?.user) return fail('กรุณาเข้าสู่ระบบใหม่', 401);
  const { data: me } = await admin.from('members').select('id').eq('user_id', u.user.id).maybeSingle();
  if (!me) return fail('บัญชีนี้ยังไม่ได้ผูกกับสมาชิก', 403);

  // 2) รับไฟล์สลิป
  let file: File | null = null;
  try {
    const f = (await req.formData()).get('file');
    if (f instanceof File) file = f;
  } catch { /* ignore */ }
  if (!file || file.size === 0) return fail('ไม่พบไฟล์สลิป');
  if (file.size > 5 * 1024 * 1024) return fail('ไฟล์ใหญ่เกิน 5MB');

  // 3) ยอดที่ต้องจ่ายและบัญชีผู้รับ มาจากฐานข้อมูล ไม่เชื่อค่าจากหน้าเว็บ
  const { data: due } = await admin.rpc('amount_due', { p_member: me.id });
  if (!due || due <= 0) return fail('ไม่มียอดค้างชำระ');
  const { data: S } = await admin.from('settings').select('promptpay').eq('id', 1).single();
  if (!S?.promptpay) return fail('ยังไม่ได้ตั้งค่าพร้อมเพย์', 500);

  // 4) เรียก SlipOK (log: false = เราตรวจบัญชีผู้รับเอง)
  const form = new FormData();
  form.append('files', file, file.name || 'slip.jpg');
  form.append('log', 'false');
  form.append('amount', String(due));
  const r = await fetch(`https://api.slipok.com/api/line/apikey/${Deno.env.get('SLIPOK_BRANCH_ID')}`, {
    method: 'POST',
    headers: { 'x-authorization': Deno.env.get('SLIPOK_API_KEY')! },
    body: form,
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok || !body?.success) {
    const code = Number(body?.code);
    if ([1001, 1002, 1003, 1004, 1015].includes(code)) {
      console.error('SlipOK config/quota error', body); // ปัญหาฝั่งผู้ดูแล ไม่แสดงรายละเอียดให้สมาชิก
      return fail('ระบบตรวจสลิปขัดข้อง กรุณาแจ้งแอดมิน', 502);
    }
    return fail(SLIPOK_ERR[code] ?? body?.message ?? 'ตรวจสลิปไม่ผ่าน');
  }
  const d = body.data;

  // 5) ตรวจยอดและบัญชีผู้รับอีกครั้งฝั่งเรา
  if (Number(d.amount) !== Number(due)) return fail('ยอดในสลิปไม่ตรงกับยอดที่ต้องชำระ');
  const rc = d.receiver ?? {};
  const okRecv = [rc.proxy?.value, rc.account?.value].some((v) => v && maskedMatch(v, S.promptpay));
  if (!okRecv) return fail('บัญชีผู้รับในสลิปไม่ตรงกับบัญชีของร้าน');
  if (!d.transRef) return fail('ไม่พบเลขอ้างอิงในสลิป');

  // 6) บันทึกรับเงิน (unique index บน trans_ref กันสลิปซ้ำ)
  const { error: perr } = await admin.rpc('mark_paid_by_slip', {
    p_member: me.id, p_trans_ref: d.transRef, p_amount: due,
  });
  if (perr) {
    if (perr.code === '23505') return fail('สลิปนี้เคยถูกใช้แล้ว');
    console.error('mark_paid_by_slip', perr);
    return fail(perr.message || 'บันทึกไม่สำเร็จ', 500);
  }
  return json({ ok: true, amount: due, transRef: d.transRef });
});
