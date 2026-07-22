import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/data/models.dart';
import 'package:jigeum/data/employer_repository.dart';
import 'package:jigeum/data/profile_repository.dart';
import 'package:jigeum/features/employer/employer_home_page.dart';

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

/// 목킹 라이브러리 없이 실제 리포지토리를 extends한 fake — RPC 호출만 기록.
class _FakeEmployerRepository extends EmployerRepository {
  final archiveCalls = <String>[];
  final cancelCalls = <String>[];
  Map<String, dynamic> cancelResult = {'cancelled': true, 'fee_total': 0};

  @override
  Future<Map<String, dynamic>> cancelRequest(String requestId) async {
    cancelCalls.add(requestId);
    return cancelResult;
  }

  @override
  Future<void> archiveRequest(String requestId) async {
    archiveCalls.add(requestId);
  }
}

/// 서버 row 형태 그대로 fromMap으로 생성 — 파싱 경로도 함께 커버.
JobRequest _req({
  String id = 'r-1',
  String status = 'matching',
  int filled = 0,
  int headcount = 1,
}) =>
    JobRequest.fromMap({
      'id': id,
      'title': '주방 보조',
      'category_id': null,
      'pay_amount': 100000,
      'pay_type': 'daily',
      'headcount': headcount,
      'filled_count': filled,
      'status': status,
      'start_at': '2026-07-21T18:00:00+09:00',
      'end_at': '2026-07-21T22:00:00+09:00',
      'address': '서울 강남구',
    });

Future<_FakeEmployerRepository> _pumpHome(
    WidgetTester tester, List<JobRequest> requests) async {
  final fake = _FakeEmployerRepository();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      employerRepositoryProvider.overrideWithValue(fake),
      myRequestsProvider.overrideWith((ref) async => requests),
      myProfileProvider.overrideWith((ref) async =>
          const MyProfile(id: 'u-1', role: 'employer', displayName: '테스트 사장님')),
    ],
    child: const MaterialApp(home: EmployerHomePage()),
  ));
  await tester.pump(); // FutureProvider resolve
  await tester.pump();
  return fake;
}

Future<void> _openTileMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert_rounded));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); // 메뉴 열림 애니메이션
}

Future<void> _tapMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); // 메뉴 닫힘 + 다이얼로그 열림
  await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets('진행 중(matching) 타일 ⋮ 메뉴: 요청 취소만 노출, 목록에서 삭제 없음',
      (tester) async {
    await _pumpHome(tester, [_req(status: 'matching')]);

    expect(find.text('테스트 사장님'), findsOneWidget); // 프로필 헤더
    expect(find.textContaining('매칭 중 · 0/1명'), findsOneWidget);

    await _openTileMenu(tester);
    expect(find.text('요청 취소'), findsOneWidget);
    expect(find.text('목록에서 삭제'), findsNothing);

    await tester.tapAt(const Offset(10, 10)); // 메뉴 닫기
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox()); // dispose
  });

  testWidgets('종료(completed) 타일 ⋮ 메뉴: 목록에서 삭제만 노출, 요청 취소 없음',
      (tester) async {
    await _pumpHome(tester, [_req(status: 'completed', filled: 1)]);

    await _openTileMenu(tester);
    expect(find.text('목록에서 삭제'), findsOneWidget);
    expect(find.text('요청 취소'), findsNothing);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('목록에서 삭제: 확인 다이얼로그 → 닫기는 no-op, 삭제 확정 시 archiveRequest 호출',
      (tester) async {
    final fake =
        await _pumpHome(tester, [_req(id: 'r-done', status: 'completed')]);

    // 1) 닫기 → 호출 없음
    await _openTileMenu(tester);
    await _tapMenuItem(tester, '목록에서 삭제');
    expect(find.textContaining('근무·정산 기록은 안전하게 보관'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(fake.archiveCalls, isEmpty);

    // 2) 삭제 확정 → archiveRequest 호출 + 스낵바
    await _openTileMenu(tester);
    await _tapMenuItem(tester, '목록에서 삭제');
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pump();
    await tester.pump();
    expect(fake.archiveCalls, ['r-done']);
    expect(find.text('목록에서 삭제했어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // 스낵바 타이머 dispose
  });

  testWidgets('홈 카드 취소: 확정 인원(filledCount>0) 있으면 보상 수수료 경고 — 상세 화면과 동일 규칙',
      (tester) async {
    // 부분충원(matching + filled>0)도 서버는 배정 기준 수수료 부과 — 경고 필요.
    final fake = await _pumpHome(
        tester, [_req(id: 'r-fee', status: 'matching', filled: 1, headcount: 2)]);
    fake.cancelResult = {'cancelled': true, 'fee_total': 30000};

    await _openTileMenu(tester);
    await _tapMenuItem(tester, '요청 취소');

    // matching_status_page._cancel과 문구 공유 — 드리프트 감시.
    expect(find.textContaining('확정된 근로자가 있어요'), findsOneWidget);
    expect(find.textContaining('보상 수수료'), findsOneWidget);
    expect(find.textContaining('0~50%'), findsOneWidget);
    expect(find.textContaining('대기 중인 제안'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '요청 취소'));
    await tester.pump();
    await tester.pump();
    expect(fake.cancelCalls, ['r-fee']);
    expect(find.textContaining('보상 수수료 30,000원이 붙었어요'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('홈 카드 취소: 확정 인원 0명이면 수수료 언급 없이 무료 취소 안내', (tester) async {
    final fake = await _pumpHome(
        tester, [_req(id: 'r-free', status: 'matching', filled: 0)]);

    await _openTileMenu(tester);
    await _tapMenuItem(tester, '요청 취소');

    expect(find.textContaining('대기 중인 제안이 모두 취소돼요'), findsOneWidget);
    expect(find.textContaining('수수료'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '요청 취소'));
    await tester.pump();
    await tester.pump();
    expect(fake.cancelCalls, ['r-free']);
    expect(find.text('요청을 취소했어요.'), findsOneWidget); // fee 0 → 수수료 문구 없음

    await tester.pumpWidget(const SizedBox());
  });
}
