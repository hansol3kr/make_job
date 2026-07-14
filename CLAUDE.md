# CLAUDE.md — 지금인력 (jigeum)

이 파일은 이 리포에서 작업하는 Claude의 **작동 원칙(사고·행동·표현 알고리즘)** 과 **프로젝트 규칙**을 정의한다.
여기 적힌 규칙은 기본 동작보다 우선한다. 아래 내용은 전부 실제 코드베이스에서 실측·검증한 사실이다.

**프로젝트:** 지금인력 — 고용주와 근로자를 실시간 매칭하는 인력 아웃소싱 앱.
핵심 약속: "지원자가 아니라 **확정된 사람**, 취소 시 **자동 백필**". Flutter(Android 우선) + Supabase(매니지드).
현재 상태: M0~M1b + P1(전국 위치)·P2(실데이터)·P3(신뢰/안전) 완료. **P4 결제/정산(PG 에스크로) 미착수.**
미구현: 카카오·네이버·토스·애플 로그인 **서버 설정**(버튼은 5종 다 있으나 `ENABLED_OAUTH` 게이트로 미설정분은 "준비 중" 표시 — 현재 구글만 실동작), APNs 푸시, 실 SMS(현재 test_otp), 결제.

---

## 1. 작동 알고리즘 — 모든 작업의 공통 사고 절차

모든 작업은 이 파이프라인을 따른다. 단계를 건너뛰지 않는다.

1. **파악** — 요구가 모호하면 임의로 해석하지 말고 선택지를 제시한다. **1번 = 추천안 + 추천 이유**, 이어서 2~3개 대안. 명확하면 바로 진행.
2. **조사** — 추측으로 코드를 쓰지 않는다. 관련 파일·설계 문서·마이그레이션을 먼저 읽는다.
   독립적인 조사는 병렬로 실행한다. 대규모 탐색·검증은 서브에이전트를 병렬로 띄운다.
3. **설계 → 승인** — **큰 갈림길은 설계(문서/목업/마이그레이션 초안)를 먼저 보여주고 승인받은 뒤 구현**한다.
   **판정 기준 — 하나라도 해당하면 승인 필요:** ①`supabase/migrations/` 새 파일 ②새 화면·새 라우트(`lib/features/` 새 디렉터리) ③pubspec 의존성 추가·제거·메이저 업 ④`codemagic.yaml`·`config.toml`·클라우드 설정 변경 ⑤외부 서비스 연동 ⑥기존에 없던 패턴 도입.
   해당 없으면(기존 파일 내 수정·버그 수정·테스트 추가) 바로 진행하고 결과를 보고한다.
4. **구현** — 기존 관례(아래 5·6절)를 그대로 따른다. 새 패턴·새 의존성 도입은 그 자체가 "큰 갈림길"이므로 승인 대상.
5. **검증** — **실측 없이 "됐다"고 말하지 않는다.** 검증 사다리를 낮은 곳부터 오른다:
   `flutter analyze` 0건 → `flutter test` 통과 → (서버 변경 시) 로컬 스택 SQL/HTTP E2E → (플로우 변경 시) REST 실호출 → (UI 확인 필요 시) 에뮬/실기기.
6. **정직 보고** — 결론을 첫 문장에. 실패는 출력 그대로 보여준다. 리스크·트레이드오프는 표로 정직하게.
   검증 못 한 항목은 반드시 **"(미검증)"** 이라고 명시한다. 낙관 편향 금지.

**병렬성 원칙:** 서로 의존성 없는 툴 호출은 한 응답에서 동시에 실행한다. 넓은 탐색·다관점 검증·대량 반복 작업은 멀티에이전트로 분해한다(이 프로젝트의 256개 시군구 시드가 그 방식으로 만들어졌고, 적대적 검증 패스가 행정개편 2건을 잡아냈다).

**컷오프 원칙:** 모델 지식 컷오프 이후 바뀔 수 있는 사실(행정구역, 요금, API 스펙, 라이브러리 버전)은 웹으로 확정한 뒤 반영한다.

## 2. 표현 규칙

- **한국어로 소통.** 기술 용어는 영어 원어 그대로(예: migration, RLS, dart-define).
- **결론 먼저.** 첫 문장이 "무엇이 됐고 / 안 됐고"에 답해야 한다. 근거·과정은 그 뒤에.
- 사용자는 30년차 개발자다. 기초 설명은 생략하고 트레이드오프·실패 시나리오 중심으로 말한다.
- 표는 열거 가능한 사실(옵션 비교, 리스크, 상태)에만 쓰고, 설명은 표 밖 문장으로.
- 숫자·통계는 출처와 함께. 미검증 리서치 수치는 미검증이라고 그대로 표시한다.
- 완료 보고 형식: ①무엇이 됐는지 ②어떻게 검증했는지(실행한 명령·결과) ③남은 것/미검증/리스크.

## 3. 리포 구조와 설계 문서

```
app/          Flutter 앱 (package: jigeum, applicationId: kr.jigeum.jigeum)
supabase/     마이그레이션·Edge Function·테스트·시드 (로컬 project_id: job_project)
docs/         설계 문서 — 코드보다 먼저 읽는다
secrets/      자격증명 (gitignore) — 읽기·출력·커밋 절대 금지
codemagic.yaml  iOS TestFlight CI (워크플로우 id: ios-testflight)
package.json  supabase CLI devDependency (^2.109.1) — npm test는 스텁(exit 1), Node 테스트 없음
```

설계 문서(`docs/`): `README.md`(**source of truth** — 전략·차별점·리스크), `architecture.md`, `data-model.md`, `mvp-and-roadmap.md`, `ios-release.md`(Mac 없는 iOS 출시 런북), `mockup.html`(M0 화면 목업).
**주의:** `docs/README.md:87`의 "Android SDK/JDK 미설치"는 낡은 정보 — 현재 둘 다 설치돼 있다(아래 4절).

git: 로컬 브랜치 `job_main` → 원격 `main` (upstream 미설정, origin/job_main 없음).
**push는 반드시 `git push origin job_main:main`** (bare `git push`는 실패/오배송). push는 사용자 요청 시에만.
커밋 스타일: conventional commit + 한국어 요약 (예: `feat(ui): 신뢰/안전 UI — 본인확인·평점`).

## 4. 환경/툴체인 — 매 세션 필수

**Flutter·JDK·Android SDK는 PATH에 없다** (~/.bashrc엔 nvm의 node/npx·python3만 잡혀 있어 `npx supabase`는 바로 동작). 매 세션 처음에:

```bash
export JAVA_HOME=$HOME/jdk-17
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH="$HOME/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
```

- Flutter **3.44.6 stable** (Dart 3.12.2) = `~/flutter/bin/flutter`. CI(codemagic.yaml)도 3.44.6 핀 — **로컬만 업그레이드하면 재현성 깨짐.**
- JDK 17(Temurin) = `~/jdk-17`, Android SDK = `~/Android/Sdk` (platform 34/36, AVD `jigeum` pixel_6/android-34).
  `flutter build apk`만이면 PATH에 flutter만 있어도 됨(`~/.config/flutter/settings`에 jdk/sdk 핀). raw SDK 도구(avdmanager 등)는 JAVA_HOME 필수.
- **KVM 차단 상태**: 사용자가 kvm 그룹 미소속 → 에뮬레이터는 `-accel off`(극도로 느림, 크래시 잦음). 해제: `sudo gpasswd -a $USER kvm` 후 `sg kvm -c "emulator ..."`. 무-KVM 에뮬은 게스트 네트워크가 안 떠서 10.0.2.2 도달 불가 → `adb reverse tcp:54321 tcp:54321` + 앱을 127.0.0.1로 빌드해 우회.
- Supabase CLI는 리포 루트에서 `npx supabase ...`. Docker 로컬 스택: API :54321 / DB :54322(postgres:postgres) / Studio :54323.
- node v22(nvm), python3 3.14. Chrome/Chromium 없음(Firefox만 있음 — Flutter web 디버깅용 Chrome 부재), sudo 무암호 불가. iOS 로컬 빌드 불가(리눅스) — Codemagic 클라우드만.

## 5. 자주 쓰는 명령

| 목적 | 명령 (리포 루트 기준) |
|---|---|
| 정적 분석 (앱 변경 시 필수) | `cd app && flutter analyze` |
| 위젯 테스트 | `cd app && flutter test` |
| 디버그 APK (로컬 스택 연결) | `cd app && flutter build apk --debug` |
| 실기기용 APK (클라우드 연결) | `cd app && flutter build apk --debug --dart-define=SUPABASE_URL=https://umwueaahepuynhbkrnme.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_HxePxLiDk8QVdOUEpsXbCg_CEA1p4gA` — dart-define 없이 빌드하면 127.0.0.1 기본값이라 실기기에서 동작 불가, client_logs도 안 쌓임 |
| 로컬 스택 상태/키 | `npx supabase status` (다운 가능성 있으면 `timeout 45` 래핑) |
| 새 마이그레이션만 적용(데이터 보존) | `npx supabase migration up` — pending만 적용, seed 재실행 없음. 일상적 서버 작업의 기본 경로 |
| 로컬 DB 리셋(마이그레이션+시드 전체 재구축) | `npx supabase db reset` — **로컬 데이터 전부 삭제됨, 사용자 확인 후 실행** |
| DB 검증 SQL | `docker exec -i supabase_db_job_project psql -U postgres -d postgres -f - < supabase/tests/db_verify.sql` |
| 코어루프 E2E(SQL) | 같은 방식으로 `supabase/tests/e2e_core_loop.sql` |
| 코어루프 E2E(HTTP 실토큰) | `bash supabase/tests/http_core_loop.sh` (로컬 전용) |
| 앱 전구간 E2E(폰OTP→매칭→체크아웃) | `bash supabase/tests/http_app_flow.sh` (로컬 전용) |
| 클라우드 SQL 실행 | `curl -s -X POST https://api.supabase.com/v1/projects/umwueaahepuynhbkrnme/database/query -H "Authorization: Bearer $SBP" -H 'Content-Type: application/json' -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36' -d '{"query":"..."}'` |
| 폰 원격 로그 확인 | 위 클라우드 SQL로 `select * from public.client_logs order by created_at desc limit 30` |
| iOS TestFlight 빌드 트리거 | `git push origin job_main:main` (Codemagic이 main 감지) — 사용자 승인 후 |

SQL 테스트 스크립트는 superuser 전용 `session_replication_role`로 FK/트리거를 끄고 `request.jwt.claims`를 직접 설정하므로 **docker exec psql(superuser)로만** 실행 가능(PostgREST 불가). HTTP 스크립트는 로컬 데모 JWT 하드코딩 — 클라우드에 못 쓴다.
`$SBP`(Management API 토큰)는 `secrets/appstore/claud_key`의 `sbp_` 줄에 있다. **값을 화면에 출력하지 않는 방식으로만 로드**: `SBP=$(grep -m1 -o 'sbp_[A-Za-z0-9_]*' secrets/appstore/claud_key)` — 이후 변수로만 사용(10절 예외 규정).

## 6. Flutter 앱 관례 (`app/`)

- **구조 3분할 고정:** `lib/core/`(env·supabase_client·router·theme·logger) · `lib/data/`(models + 리포지토리 + 프로바이더) · `lib/features/<도메인>/<페이지>.dart`. 새 화면은 이 구조를 따른다.
- **Riverpod 3.x 수동 선언.** 코드젠 없음 — freezed/.g.dart/annotation **도입 금지**(도입하려면 승인 필요). 프로바이더는 해당 리포지토리 파일 끝에 선언. 화면 상태는 `FutureProvider/StreamProvider.autoDispose`(+`.family`).
- **라우팅:** `core/router.dart`의 전역 `appRouter`(GoRouter 17). 인증 가드는 top-level `redirect` — 보호 접두사 `/employer`, `/worker`, `/onboarding`. **새 인증 필요 화면은 이 접두사 아래 경로로 만들고**, top-level로 만들 수밖에 없으면 접두사 목록도 갱신한다. (주의: 기존 `/verify-identity`는 로그인 필요 화면인데 가드 밖 — 알려진 구멍, 전례로 삼지 말 것.) redirect가 `AppLog.setRoute()`도 담당.
- **도메인 DB 쓰기는 전부 RPC 경유**(`supabase.rpc('...')`) — 클라이언트 직접 insert/update 금지. **유일한 예외: `core/logger.dart`의 `client_logs` 직접 insert**(0006이 insert-only 정책으로 의도 허용 — 그대로 두고, 다른 테이블로 확대 금지). 읽기는 `from().select()`, 실시간은 `.stream(primaryKey:['id'])`.
- **모델:** `data/models.dart`에 수동 immutable 클래스 + `factory X.fromMap()`. snake_case 키 수동 매핑, null-tolerant 캐스팅(`(m['x'] as num?)?.toInt() ?? 0`), timestamptz는 `DateTime.parse(...).toLocal()`.
- **원격 로그:** `AppLog.d/i/w/e(message, context:)` → 클라우드 `client_logs` 테이블(3초 배치, 에러는 즉시, 실패는 삼킴). 새 화면·핵심 액션에는 로그를 심는다. 미처리 에러는 이미 전역 포착됨(FlutterError.onError + PlatformDispatcher + runZonedGuarded).
- **환경 주입:** `core/env.dart`의 `String.fromEnvironment` — 기본값은 로컬(127.0.0.1:54321), 클라우드 값은 `--dart-define`으로 주입(codemagic.yaml이 iOS 빌드에 주입).
- 디버그 Android manifest에 `usesCleartextTraffic=true`(로컬 HTTP용) — release에는 없음, 옮기지 말 것.

## 7. Supabase 백엔드 관례 (`supabase/`)

- **마이그레이션은 번호 연속 증가** — `ls supabase/migrations/`로 마지막 번호를 확인하고 +1로 만든다(예: 마지막이 0009면 `0010_<이름>.sql`). 기존 마이그레이션 수정 금지, 고칠 것도 새 마이그레이션으로.
- **RPC 패턴:** `SECURITY DEFINER` + `grant execute on function ... to authenticated` 명시. 테이블도 **명시 GRANT 필수** — 로컬 스택은 authenticated에 자동 GRANT를 안 준다(0004·0005·0009가 전례). 빠뜨리면 정책이 맞아도 401/permission-denied.
- **RLS 상호참조 금지:** 두 테이블 정책이 서로를 서브쿼리하면 무한재귀(42P17) — SECURITY DEFINER 헬퍼 함수로 우회(0003이 전례).
- `payments`·`reliability_events`·`penalties`·`disputes`는 **RLS만 켜고 정책 없음(의도)** — 클라이언트 직접 조회는 설계상 차단, service_role/RPC로만 접근.
- 클라우드에 새 테이블·**RPC·뷰**를 만들면 **`notify pgrst, 'reload schema';`** 실행해야 REST(`/rpc/` 포함)에 노출된다 — 빠뜨리면 404를 GRANT 문제로 오인하기 쉽다.
- **로컬 폰 OTP:** config.toml에 더미 `[auth.sms.twilio] enabled=true` + `[auth.sms.test_otp]` **둘 다** 필요(없으면 phone_provider_disabled). config 변경은 `npx supabase stop && npx supabase start`로 재적용.
- 매칭 본체는 SQL RPC `run_match`(앱은 `request_matching` RPC 경유로만 시작). Edge Function `match`는 run_match를 호출하지 않는 **독립 TS 중복 구현**(현재 호출처 없음, 푸시는 TODO 주석뿐) — 매칭 정책을 run_match에만 반영하면 조용히 드리프트한다. EF 수렴/삭제는 승인 후 진행.
- `complete_worker_onboarding`은 **identity_verified를 주지 않는다**(0009에서 제거) — `submit_identity_verification` 호출 전까지 근로자는 `nearby_candidates`에 안 잡힌다. "매칭이 안 잡혀요" 디버깅 1순위.

## 8. 로컬 vs 클라우드 — 두 개의 Supabase

| | 로컬 (에뮬/E2E) | 클라우드 (실기기/TestFlight) |
|---|---|---|
| URL | `http://127.0.0.1:54321` | `https://umwueaahepuynhbkrnme.supabase.co` (서울) |
| 데이터 | 마이그레이션+`seed.sql` 전체 | 스키마+regions+**전국 54근로자 시드만**(`seed_cloud_workers.py`), seed.sql 미적용 |
| 적용 방법 | `npx supabase db reset` | Management API SQL 엔드포인트 (아래 UA 주의) |
| 앱 연결 | env.dart 기본값 | `--dart-define` (codemagic.yaml) |

- **User-Agent 함정(상반):** Management API(`api.supabase.com/.../database/query`)는 **브라우저 UA 필수**(없으면 Cloudflare 1010 차단). 반대로 `sb_secret_` 키를 쓰는 Auth Admin API는 **비브라우저 UA 필수**. `seed_cloud_workers.py`에 둘 다 구현돼 있다.
- 테스트 계정: 근로자 `010-1234-1111` / 사장님 `010-1234-2222` / 예비 `-9999`, OTP `123456` — 로컬은 config.toml test_otp, 클라우드는 Auth 설정에 API로 동일 등록(리포 밖 설정). 실 SMS(SOLAPI/알리고)는 출시 직전 — **건당 유료이므로 그 전엔 test_otp 유지.**
- **소셜 로그인 5종**(카카오·네이버·토스·애플·구글) 버튼은 `phone_login_page.dart`의 `_oauthOptions` 리스트로 렌더. **`Env.enabledOAuth`(dart-define `ENABLED_OAUTH`, 기본 `google`)에 든 provider만 실제 OAuth 실행**, 나머지는 "준비 중" 뱃지 + 탭 시 앱 내 안내(미설정 provider를 실행하면 실패가 외부 브라우저 에러로 빠져 앱 catch에 안 잡히기 때문). provider를 켜려면 ①서버 설정 완료 후 ②그 빌드의 `ENABLED_OAUTH`에 추가. 네이버·토스는 Supabase 기본 미지원 → **커스텀 OAuth provider**로 설정(`OAuthProvider('naver'/'toss')`). 애플은 카카오/구글이 있는 한 App Store 심사 필수.
- OAuth는 **클라우드 전용** — 로컬 config.toml엔 provider가 없어 로컬 스택에선 실패(로컬 로그인은 test_otp 폰 번호만). 복귀 딥링크 `kr.jigeum.jigeum://login-callback`(iOS CFBundleURLTypes + Android intent-filter).
- 클라우드 마이그레이션 적용은 스키마 변경이므로 **사용자 승인 후** 실행.

## 9. 빌드/배포

- **"빌드 아끼기" 방침:** Codemagic 무료 500분/월 — 변경사항을 모아 1빌드로 배치한다. 빌드 전 로컬 검증 사다리를 전부 통과시킨다.
- iOS: push → Codemagic `ios-testflight`(mac_mini_m2) → 자동 서명 → TestFlight. 빌드번호는 ASC 최신+1 자동.
- **codemagic.yaml 서명 블록을 "단순화"하지 말 것.** 자동 `ios_signing:`은 첫 빌드에서 3연속 실패한 전력 — 현재의 명시적 `fetch-signing-files --create` + `CERTIFICATE_PRIVATE_KEY`(secure var, 그룹 `ios_signing`) 방식을 유지한다.
- `SUPABASE_PUBLISHABLE_KEY`가 yaml에 커밋돼 있는 것은 **의도된 것**(공개 클라이언트 키) — 유출로 오판하지 말 것.
- Codemagic API 자동화 가능: 트리거 `POST /builds`, 상태 `GET /builds/{id}`, 로그 `GET /builds/{id}/step/{stepId}`. appId `6a5481a55306b7a0ce3c1222`.
- 애플: Bundle ID `kr.jigeum.jigeum`, 앱명 job_works, APP_STORE_APPLE_ID `6790293137`. Account Holder는 `hansol4kr@naver.com`(GitHub 계정과 다름).

## 10. 보안 절대 규칙

- **`secrets/` 파일 내용을 로그·대화·보고·커밋·코드 어디에도 노출하지 않는다.** 파일명 참조는 허용. 명령 실행에 필요한 토큰은 **값이 화면에 찍히지 않는 방식으로만** 셸 변수에 로드해 쓴다(5절 `$SBP` 절차가 유일한 표준 경로). 스크립트가 내부에서 읽는 것(`seed_cloud_workers.py`)은 허용. `cat`/`echo`로 값을 드러내는 것은 금지.
- `sb_publishable_` 키만 공개 가능. `sb_secret_`·`sbp_`·service_role JWT·`.p8`·`.pem`은 코드/yaml/로그/대화 어디에도 금지.
- 사용자 승인 없이 금지: **git commit·push**, 클라우드 스키마/설정 변경, 로컬 `db reset`(데이터 삭제 — 마이그레이션만 붙일 땐 `migration up`), 외부 서비스에 데이터 게시, 과금 유발 행위(실 SMS, 유료 빌드 남발).

## 11. Definition of Done — 이걸 통과해야 "됐다"

- [ ] `flutter analyze` 0건 (앱 변경 시)
- [ ] `flutter test` 통과 (앱 변경 시)
- [ ] 서버 변경: 로컬 스택에 적용 + 해당 E2E(SQL/HTTP) 통과
- [ ] 플로우 변경: `http_app_flow.sh` 또는 REST 실호출로 전구간 재검증
- [ ] UI 변경: 에뮬/실기기에서 렌더 확인 — KVM 차단 등으로 불가하면 "(미검증: UI 렌더)"로 명시
- [ ] 실행한 검증 명령과 결과를 보고에 포함
- [ ] 검증 못 한 것·알려진 리스크를 "(미검증)"으로 정직하게 명시
- [ ] 커밋은 사용자 요청 시에만, conventional + 한국어 요약
