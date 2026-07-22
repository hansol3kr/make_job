/// 업주 매칭 상태 화면 위젯 테스트.
///
/// 커버 범위:
/// - 하단 수정/취소 버튼 노출 매트릭스(⋮ 메뉴 → bottomNavigationBar 상시 노출 전환)
/// - 취소 다이얼로그의 수수료 경고 판정(confirmed || filled>0)
/// - cancelled/expired 종료 뷰 렌더(과거 "취소됐는데 매칭 중 스피너" 회귀 방어)
/// - 요청 수정 시트 → editRequest → requestMatching 호출 순서
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/data/employer_repository.dart';
import 'package:jigeum/data/models.dart';
import 'package:jigeum/data/safety_repository.dart';
import 'package:jigeum/features/employer/matching_status_page.dart';

const _reqId = 'r1000000-0000-0000-0000-000000000001';
const _aid = 'a1000000-0000-0000-0000-0000000000a1';

class _MemStore extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
}

/// 목킹 라이브러리 없이 실제 리포지토리를 extends한 fake — 호출 기록만 남긴다.
class _FakeEmployerRepo extends EmployerRepository {
  final calls = <String>[];
  int? editedPay;
  int? editedHead;

  @override
  Future<List<JobRequest>> myRequests() async => [];

  @override
  Future<JobRequest> getRequest(String requestId) async {
    calls.add('getRequest');
    return JobRequest(
      id: requestId,
      title: '주방 보조',
      categoryId: null,
      payAmount: 100000,
      payType: 'daily',
      headcount: 1,
      filledCount: 0,
      status: 'matching',
      startAt: DateTime.now().add(const Duration(hours: 2)),
      endAt: DateTime.now().add(const Duration(hours: 8)),
      address: null,
    );
  }

  @override
  Future<void> editRequest(
    String requestId, {
    String? title,
    DateTime? startAt,
    DateTime? endAt,
    int? payAmount,
    int? headcount,
    String? payType,
    bool? requiresProfessional,
  }) async {
    calls.add('editRequest');
    editedPay = payAmount;
    editedHead = headcount;
  }

  @override
  Future<int> requestMatching(String requestId) async {
    calls.add('requestMatching');
    return 1;
  }

  @override
  Future<Map<String, dynamic>> cancelRequest(String requestId) async {
    calls.add('cancelRequest');
    return {'cancelled': true, 'fee_total': 0};
  }

  @override
  Future<Map<String, dynamic>> continueMatching(String requestId) async {
    calls.add('continueMatching');
    return {'state': 'searching', 'radius_m': 3000};
  }

  @override
  Future<void> archiveRequest(String requestId) async {
    calls.add('archiveRequest');
  }
}

MatchingSnapshot _snap(
  String status, {
  int headcount = 1,
  int filled = 0,
  int offered = 3,
  bool withWorker = false,
}) =>
    MatchingSnapshot.fromMap({
      'status': status,
      'headcount': headcount,
      'filled_count': filled,
      'offered_count': offered,
      'workers': withWorker
          ? [
              {
                'assignment_id': _aid,
                'status': 'confirmed',
                'display_name': '김근로',
                'reliability': 95,
                'dist_m': 800,
              }
            ]
          : <Map<String, dynamic>>[],
    });

Widget _app(MatchingSnapshot snap, _FakeEmployerRepo fake) {
  final router = GoRouter(
    initialLocation: '/employer/matching/$_reqId',
    routes: [
      GoRoute(
        path: '/employer',
        builder: (_, _) => const Scaffold(body: Text('사장님 홈')),
      ),
      GoRoute(
        path: '/employer/matching/:id',
        builder: (_, st) =>
            MatchingStatusPage(requestId: st.pathParameters['id']!),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      employerRepositoryProvider.overrideWithValue(fake),
      // matchingProvider만 덮으면 continuity 폴링이 실제 supabase.rpc를 때린다 — 둘 다 필수.
      matchingProvider(_reqId).overrideWith((ref) => Stream.value(snap)),
      matchingContinuityProvider(_reqId).overrideWith(
          (ref) => Stream.value(const <String, dynamic>{'state': 'waiting'})),
      // 확정 뷰의 SOS 배너/위치 카드가 실제 realtime 스트림을 열지 않도록 차단.
      activeSosProvider(_aid)
          .overrideWith((ref) => Stream.value(const <SosAlert>[])),
      liveLocationsProvider(_aid)
          .overrideWith((ref) => Stream.value(const <LiveLocation>[])),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _pumpPage(
    WidgetTester tester, MatchingSnapshot snap, _FakeEmployerRepo fake) async {
  await tester.pumpWidget(_app(snap, fake));
  await tester.pump(); // 스트림 첫 데이터 반영
  await tester.pump();
}

/// 무한 애니메이션(매칭 스피너)·스트림이 있어 pumpAndSettle 대신 명시 dispose.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabasePublishableKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: const EmptyLocalStorage(),
        pkceAsyncStorage: _MemStore(),
      ),
    );
  });

  group('하단 버튼 노출 매트릭스', () {
    testWidgets('matching·미충원 → 요청 수정 + 요청 취소 둘 다 노출', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('matching', filled: 0), fake);

      expect(find.text('실시간 매칭 중'), findsOneWidget); // AppBar
      expect(find.text('요청 수정'), findsOneWidget);
      expect(find.text('요청 취소'), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('matching·부분충원(filled>0) → 취소만 노출, 수정 숨김', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester,
          _snap('matching', headcount: 2, filled: 1, withWorker: true), fake);

      expect(find.text('요청 수정'), findsNothing);
      expect(find.text('요청 취소'), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('confirmed → 취소만 노출', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(
          tester, _snap('confirmed', filled: 1, withWorker: true), fake);

      expect(find.text('확정됐어요!'), findsOneWidget); // 확정 뷰 렌더
      expect(find.text('요청 수정'), findsNothing);
      expect(find.text('요청 취소'), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('completed·cancelled·expired → 하단 버튼 영역 자체가 없다', (tester) async {
      for (final status in ['completed', 'cancelled', 'expired']) {
        final fake = _FakeEmployerRepo();
        await _pumpPage(
            tester,
            _snap(status,
                filled: status == 'completed' ? 1 : 0,
                withWorker: status == 'completed'),
            fake);

        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(scaffold.bottomNavigationBar, isNull, reason: status);
        expect(find.text('요청 수정'), findsNothing, reason: status);
        expect(find.text('요청 취소'), findsNothing, reason: status);
      }
      await _dispose(tester);
    });
  });

  group('취소 다이얼로그 수수료 판정', () {
    testWidgets('부분충원(filled=1) 취소 → 보상 수수료 경고 + 닫기 시 cancelRequest 미호출',
        (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester,
          _snap('matching', headcount: 2, filled: 1, withWorker: true), fake);

      await tester.tap(find.text('요청 취소'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('보상 수수료'), findsOneWidget);
      expect(find.textContaining('확정된 근로자가 있어요'), findsOneWidget);

      await tester.tap(find.text('닫기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(fake.calls, isNot(contains('cancelRequest')));
      await _dispose(tester);
    });

    testWidgets('matching·미충원 취소 → 무료 취소 안내 + 닫기 시 cancelRequest 미호출',
        (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('matching', filled: 0), fake);

      await tester.tap(find.text('요청 취소'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('대기 중인 제안이 모두 취소돼요'), findsOneWidget);
      expect(find.textContaining('보상 수수료'), findsNothing);

      await tester.tap(find.text('닫기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(fake.calls, isNot(contains('cancelRequest')));
      await _dispose(tester);
    });
  });

  group('종료 상태 뷰', () {
    testWidgets('cancelled → 취소된 요청 뷰 렌더 + 매칭 스피너 없음(회귀 방어)', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('cancelled'), fake);

      expect(find.text('요청 취소됨'), findsOneWidget); // AppBar
      expect(find.text('취소된 요청이에요'), findsOneWidget);
      expect(find.text('목록에서 삭제'), findsOneWidget);
      // 과거 버그: cancelled 분기가 없어 "매칭 중" 스피너가 계속 돌았다.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _dispose(tester);
    });

    testWidgets('cancelled → 목록에서 삭제 탭 시 archiveRequest 호출 + 홈 이동', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('cancelled'), fake);

      await tester.tap(find.text('목록에서 삭제'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(fake.calls, contains('archiveRequest'));
      expect(find.text('사장님 홈'), findsOneWidget); // context.go('/employer')
      await _dispose(tester);
    });

    testWidgets('expired → 다시 찾기 렌더 + 탭 시 continueMatching 호출', (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('expired'), fake);

      expect(find.text('매칭 실패'), findsOneWidget); // AppBar
      expect(find.text('다시 찾기'), findsOneWidget);
      expect(find.textContaining('수수료는 0원'), findsOneWidget);

      await tester.tap(find.text('다시 찾기'));
      await tester.pump();
      await tester.pump();

      expect(fake.calls, contains('continueMatching'));
      await _dispose(tester);
    });
  });

  group('요청 수정 시트', () {
    testWidgets('급여 +5,000 스테퍼 후 확정 → editRequest(payAmount+5000) → requestMatching 순서',
        (tester) async {
      final fake = _FakeEmployerRepo();
      await _pumpPage(tester, _snap('matching', filled: 0), fake);

      await tester.tap(find.text('요청 수정'));
      await tester.pump(); // getRequest 완료 → 시트 push
      await tester.pump(const Duration(milliseconds: 400)); // 시트 애니메이션

      expect(fake.calls, ['getRequest']);
      expect(find.text('₩100,000'), findsOneWidget); // 프리필 급여

      // 첫 번째 + 아이콘 = 급여 스테퍼 (두 번째는 인원)
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded).first);
      await tester.pump();
      expect(find.text('₩105,000'), findsOneWidget);

      await tester.tap(find.text('수정하고 다시 매칭'));
      await tester.pump(); // pop → editRequest → requestMatching
      await tester.pump(const Duration(milliseconds: 400));

      expect(fake.calls, ['getRequest', 'editRequest', 'requestMatching']);
      expect(fake.editedPay, 105000);
      expect(fake.editedHead, 1);
      expect(find.text('수정하고 새 조건으로 다시 매칭했어요.'), findsOneWidget); // 스낵바
      await _dispose(tester);
    });
  });
}
