# 본인확인기관 EF 설계 (Step A 실연동)

0031의 `apply_identity_verification`(provider-무관 적재 계약)에 **실 본인확인 결과**를 물리는
Edge Function 설계. 스텁(`submit_identity_verification`)을 실연동으로 교체하는 마지막 조각.

> 상태: **설계안(미승인·미구현)**. provider 선택 + 계약/자격증명은 사용자 결정. 승인 후 스캐폴딩.
> API 세부(엔드포인트·필드명)는 컷오프 이후 바뀔 수 있어 구현 시 공급자 최신 문서로 확정.

## 1. provider 추천

**추천: PortOne(구 아임포트) 본인인증** — 이유:
- 다날·KG이니시스·NICE 등 여러 본인확인사(CP)를 **단일 API/SDK로 추상화** → CP 교체 시 코드 무변경.
- Flutter SDK(`portone_flutter`) 존재 → 클라이언트 연동 간단.
- **P4 결제(에스크로)도 같은 PortOne로 통합** 가능 → 신원+정산 vendor 일원화, 계약·정산·CS 창구 하나.
- CI(`unique_key`)·DI(`unique_in_site`)를 표준 반환 → 0031 스키마에 그대로 매핑.

대안: **토스페이먼츠 본인확인**(토스 결제 쓸 경우 시너지), **다날/KG 직접 연동**(중간 마진 절감이나 CP별 스펙 직접 관리 부담). 어느 쪽이든 EF 아키텍처(아래)는 동일 — provider 어댑터만 교체.

## 2. 아키텍처 — 흐름

```
[Flutter]  PortOne SDK로 본인인증 웹뷰 실행 → 사용자가 휴대폰 본인인증 완료
   │        → SDK가 identityVerificationId(=imp_uid) 반환 (검증 결과 자체는 안 받음)
   ▼
[Flutter]  POST /functions/v1/verify-identity   (Authorization: 사용자 Supabase JWT,
   │        body: { identityVerificationId })     body엔 신원 데이터 없음 — id만)
   ▼
[EF verify-identity]
   1) Supabase JWT 검증 → profile uid 확정 (auth.getUser)
   2) PortOne REST로 결과 조회 (서버가 API secret으로 직접 fetch — 클라 데이터 불신)
      GET identity-verifications/{id}  → { name, birthDate, gender, phone, ci, di, verified }
   3) verified=true 확인 + id 재사용 방지(멱등)
   4) service_role로 apply_identity_verification(uid, ci, di, name, birthDate, gender, 'portone')
      → 0031이 DI중복(identity_duplicate_account)·연령(underage) 게이트 적용
   5) 결과 매핑 반환: { ok } | { error: {code} }  (duplicate_account/underage/verify_failed)
   ▼
[Flutter]  성공 → 본인확인 상태 새로고침(매칭 자격). 실패코드별 안내 문구.
```

**핵심 보안 원칙:** 클라이언트는 **참조 id만** 넘긴다. 실명·CI/DI 같은 신원 데이터는 **EF가 서버에서 직접 조회**한다(클라가 보낸 신원 값은 절대 신뢰 안 함 — 위조 방지). `apply_identity_verification`은 이미 service_role 전용(authenticated 차단)이라 이 경로로만 신원이 적재된다.

## 3. EF 계약 (verify-identity)

- **요청**: `POST /functions/v1/verify-identity`, 헤더 `Authorization: Bearer <supabase user jwt>`, 바디 `{ "identityVerificationId": "<portone id>" }`.
- **응답 성공**: `200 { "ok": true }`.
- **응답 실패**: `4xx { "error": { "code": "duplicate_account|underage|verify_failed|unauthorized" } }`.
- **시크릿(EF env)**: `PORTONE_API_SECRET`(서버 조회용), `SUPABASE_SERVICE_ROLE_KEY`(RPC 호출), `SUPABASE_URL`. 클라이언트엔 PortONE **채널/스토어 식별자(공개)**만.
- **관례 준수**: `Deno.serve`, `_shared/cors.ts`, `Deno.env.get`, 외부 의존성 없이 fetch, 에러 `{error:{message|code}}`(send-sms 전례).
- **멱등**: 처리한 `identityVerificationId`를 기록(신규 `identity_verification_refs` 테이블 또는 verifications.ref에 id 저장 + unique)해 재요청·중복 적재 차단.

## 4. 데이터·정책 결정 (사용자 확정 필요)

1. **phone_verified**: 본인인증 결과의 phone은 통신사가 검증한 값 → `profiles.phone` + `phone_verified=true`로 승격할지. (현재 phone_verified는 우리 OTP 전용) — 승격 권장(중복 OTP 불필요).
2. **업주 신원**: 업주도 같은 EF로 **대표자 본인확인**을 받게 할지(권장 — 낯선 사람 대면노동 신뢰의 절반). **사업자등록 진위확인**은 별개 국세청 API(EF 분리) — `submit_business_verification` 스텁을 국세청 연동으로 교체.
3. **게이트 배치**: 근로자는 이미 매칭 진입 게이트(identity_verified). 업주는 **요청 등록 전 하드게이트** vs **미인증 시 뱃지만** — 하드게이트는 공급측 온보딩 퍼널을 막으므로, `platform_settings` 플래그로 파일럿 때 토글(기본 off + 오퍼에 "인증 사업장" 뱃지 노출) 권장.
4. **최저연령**: 0031 기본 15세(근로기준법). 13~14세 취직인허증 예외를 앱에서 다룰지(대개 제외).
5. **재확인 주기**: 본인확인 1회 후 영구 유지 vs 기간 만료(예: 이직·명의변경 대비 N년). MVP는 1회 영구 권장.

## 5. 롤아웃 (스텁→실연동 교체 패턴)

- `Env`에 `IDENTITY_PROVIDER`(dart-define, 기본 `stub`) 추가 — `stub`이면 현 `submit_identity_verification`(시뮬 CI/DI), `portone`이면 PortOne SDK→verify-identity EF.
- 로컬 스택엔 EF 미배포 → 로컬은 계속 스텁(OTP·OAuth와 동일 정책). 클라우드 빌드에만 `IDENTITY_PROVIDER=portone` 주입.
- 순서: PortOne 계약·키 발급 → EF 배포(`supabase functions deploy verify-identity`) + 시크릿 설정 → Flutter SDK 연동 + 화면 교체 → 클라우드 빌드에 플래그 주입 → 소수 실기기 검증(과금 발생) → 확대.

## 6. 비용·운영

- 본인인증은 **건당 과금**(무료 건수 없음, CP·계약별 상이 — 대략 수십~수백원/건). 그래서 **1인 1회**만 수행하고 `identity_verified_at`로 캐시(재요청 차단)가 비용 핵심.
- 결제 웹훅과 달리 본인인증은 **동기 조회**라 웹훅 불필요 → send-sms보다 단순.
- 실패·이탈 로깅: EF에서 client_logs 아닌 EF 로그 + verifications(status)로 관측.

## 7. 사용자가 준비할 것

1. PortOne(또는 택1) 가입 + **본인인증 상품 계약** + 하위 CP(다날 등) 계약.
2. `PORTONE_API_SECRET` 발급 → Supabase EF 시크릿으로 등록(값은 저장소에 커밋 금지).
3. 위 4절 정책 5개 확정.

결정(provider + 4절 정책)만 주면 EF 스캐폴딩(스텁 어댑터 + PortOne 어댑터 골격) + `IDENTITY_PROVIDER` 플래그 + 화면 교체 초안까지 만들어 로컬 스텁 경로로 검증하겠습니다. 실 키·배포·과금 검증은 그다음 단계.
