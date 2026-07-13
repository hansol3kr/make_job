// Edge Function: match
// 요청(request_id)에 대해 반경 내 후보를 조회·랭킹하고 상위 N명에게 오퍼를 생성한다.
// 설명가능 랭킹(reason) 포함. 거절/만료 시 backfill 함수가 다음 후보로 이어간다.
//
// 로컬 호출 예:
//   curl -i -X POST http://127.0.0.1:54321/functions/v1/match \
//     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
//     -H "Content-Type: application/json" \
//     -d '{"request_id":"...", "radius_m":3000, "wave":3, "ttl_seconds":60}'

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

interface MatchBody {
  request_id: string;
  radius_m?: number;
  min_reliability?: number;
  wave?: number; // 이번 웨이브에 오퍼 보낼 상위 후보 수
  ttl_seconds?: number; // 오퍼 수락 타이머
}

interface Candidate {
  worker_id: string;
  dist_m: number;
  reliability_score: number;
  tier: string;
}

// 설명가능 스코어: 근접성 60% + 신뢰도 40% (추후 수락예측확률·급여적합 추가)
function scoreOf(c: Candidate, radiusM: number) {
  const proximity = Math.max(0, 1 - c.dist_m / radiusM);
  const reliability = Math.min(1, c.reliability_score / 100);
  const score = 0.6 * proximity + 0.4 * reliability;
  return {
    score: Number(score.toFixed(4)),
    reason: {
      distance_m: Math.round(c.dist_m),
      reliability: c.reliability_score,
      proximity: Number(proximity.toFixed(3)),
      tier: c.tier,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const body = (await req.json()) as MatchBody;
    const {
      request_id,
      radius_m = 3000,
      min_reliability = 0,
      wave = 3,
      ttl_seconds = 60,
    } = body;

    if (!request_id) {
      return json({ error: "request_id required" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // 1) 이미 오퍼 받은 근로자 제외 목록
    const { data: existing } = await admin
      .from("match_offers")
      .select("worker_id")
      .eq("request_id", request_id);
    const excluded = new Set((existing ?? []).map((r) => r.worker_id));

    // 2) 반경 내 후보 조회 (PostGIS)
    const { data: candidates, error: candErr } = await admin.rpc(
      "nearby_candidates",
      {
        p_request_id: request_id,
        p_radius_m: radius_m,
        p_min_reliability: min_reliability,
        p_limit: 50,
      },
    );
    if (candErr) return json({ error: candErr.message }, 500);

    // 3) 랭킹 → 아직 오퍼 안 간 상위 wave명 선정
    const ranked = (candidates as Candidate[])
      .filter((c) => !excluded.has(c.worker_id))
      .map((c) => ({ ...c, ...scoreOf(c, radius_m) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, wave);

    if (ranked.length === 0) {
      // 후보 소진: 요청 상태는 유지(백필 대기). 운영 알림 대상.
      return json({ request_id, offered: 0, candidates: 0, exhausted: true });
    }

    const expires_at = new Date(Date.now() + ttl_seconds * 1000).toISOString();
    const rows = ranked.map((c, i) => ({
      request_id,
      worker_id: c.worker_id,
      rank: i + 1,
      score: c.score,
      reason: c.reason,
      status: "offered",
      expires_at,
    }));

    // 4) 오퍼 생성 (동시 매칭 충돌은 unique(request_id,worker_id)로 방지)
    const { data: inserted, error: insErr } = await admin
      .from("match_offers")
      .insert(rows)
      .select("id, worker_id, rank, score, expires_at, reason");
    if (insErr) return json({ error: insErr.message }, 500);

    // 5) 요청 상태 → matching
    await admin
      .from("job_requests")
      .update({ status: "matching" })
      .eq("id", request_id)
      .eq("status", "open");

    // TODO(M2): FCM/APNs 푸시로 백그라운드 근로자에게 오퍼 도달
    return json({ request_id, offered: inserted?.length ?? 0, offers: inserted });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
