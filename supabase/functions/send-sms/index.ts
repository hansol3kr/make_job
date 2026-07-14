// Edge Function: send-sms (Supabase Auth "Send SMS Hook")
// GoTrue가 OTP 발송이 필요할 때 이 함수를 호출한다. 국내 공급자 SOLAPI로 SMS 발송.
// - 웹훅 서명(Standard Webhooks) 자체 검증(외부 의존성 없음)으로 위조/남용 차단.
// - E.164(+8210...) → 국내형식(0210...) 변환 후 SOLAPI 발송.
// - 테스트 번호(sms_test_otp)는 GoTrue가 이 훅을 호출하지 않으므로 무료 유지.
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";

const SOLAPI_KEY = Deno.env.get("SOLAPI_API_KEY")!;
const SOLAPI_SECRET = Deno.env.get("SOLAPI_API_SECRET")!;
const SENDER = Deno.env.get("SOLAPI_SENDER")!; // 01083301141
const HOOK_SECRET = Deno.env.get("SEND_SMS_HOOK_SECRET")!; // v1,whsec_<base64>

// Standard Webhooks 서명 검증 (라이브러리 없이 직접)
function verifyWebhook(raw: string, headers: Headers): boolean {
  const id = headers.get("webhook-id");
  const ts = headers.get("webhook-timestamp");
  const sigHeader = headers.get("webhook-signature");
  if (!id || !ts || !sigHeader) return false;
  const key = Buffer.from(HOOK_SECRET.replace(/^v1,whsec_/, ""), "base64");
  const expected = createHmac("sha256", key).update(`${id}.${ts}.${raw}`).digest("base64");
  const expBuf = Buffer.from(expected);
  // "v1,<sig> v2,<sig>" 중 하나라도 일치
  for (const part of sigHeader.split(" ")) {
    const sig = part.split(",")[1] ?? "";
    const sigBuf = Buffer.from(sig);
    if (sigBuf.length === expBuf.length && timingSafeEqual(sigBuf, expBuf)) return true;
  }
  return false;
}

function solapiAuth(): string {
  const date = new Date().toISOString();
  const salt = randomUUID().replace(/-/g, "");
  const sig = createHmac("sha256", SOLAPI_SECRET).update(date + salt).digest("hex");
  return `HMAC-SHA256 apiKey=${SOLAPI_KEY}, date=${date}, salt=${salt}, signature=${sig}`;
}

Deno.serve(async (req) => {
  const raw = await req.text();

  if (!verifyWebhook(raw, req.headers)) {
    return new Response(JSON.stringify({ error: { message: "invalid signature" } }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const payload = JSON.parse(raw);
  const phone: string = payload?.user?.phone ?? "";
  const otp: string = payload?.sms?.otp ?? "";
  // GoTrue는 '+' 없이 '821083301141' 형태로 넘김 → 국내형식 '01083301141'로 변환.
  let to = phone.replace(/[^0-9]/g, "");
  if (to.startsWith("82")) to = "0" + to.slice(2);
  const text = `[지금인력] 인증번호 ${otp} 를 입력해주세요.`;

  const res = await fetch("https://api.solapi.com/messages/v4/send", {
    method: "POST",
    headers: { "Authorization": solapiAuth(), "Content-Type": "application/json" },
    body: JSON.stringify({ message: { to, from: SENDER, text } }),
  });
  const body = await res.json();

  if (!res.ok) {
    return new Response(
      JSON.stringify({ error: { message: `solapi: ${JSON.stringify(body)}` } }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
