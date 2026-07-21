/// 근로자 홈(WorkerHomePage) 코어 루프 위젯 테스트 — 오퍼 수신/만료 필터/수락/거절,
/// 본인확인 게이트, 계약서 서명 게이트(체크인 차단).
///
/// Supabase 플러그인 우회는 chat_page_test.dart 관례를 그대로 따른다.
/// 주의: 페이지에 1초 Timer.periodic(오퍼 카운트다운)이 있어 pumpAndSettle 금지,
/// 각 테스트 끝에 pumpWidget(SizedBox())로 dispose한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/data/contract_repository.dart';
import 'package:jigeum/data/models.dart';
import 'package:jigeum/data/safety_repository.dart';
import 'package:jigeum/data/worker_repository.dart';
import 'package:jigeum/features/worker/worker_home_page.dart';

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

/// 기존 리포지토리를 extends한 fake — RPC 호출을 기록만 하고 서버로 안 나간다.
class _FakeWorkerRepository extends WorkerRepository {
  final acceptedOfferIds = <String>[];
  final declinedOfferIds = <String>[];
  final checkInIds = <String>[];
  final availabilityCalls = <bool>[];

  @override
  Future<void> setAvailability(bool available,
      {double? lng, double? lat}) async {
    availabilityCalls.add(available);
  }

  @override
  Future<String> acceptOffer(String offerId) async {
    acceptedOfferIds.add(offerId);
    return 'a-1';
  }

  @override
  Future<void> declineOffer(String offerId) async {
    declinedOfferIds.add(offerId);
  }

  @override
  Future<void> checkIn(String assignmentId, double lng, double lat) async {
    checkInIds.add(assignmentId);
  }
}

OfferView _offer({DateTime? expiresAt}) => OfferView(
      offerId: 'o-1',
      requestId: 'r-1',
      status: 'offered',
      rank: 1,
      distanceM: 800,
      reliability: 72,
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 30)),
      title: '카페 홀 마감',
      categoryId: null,
      payAmount: 96000,
      payType: 'daily',
      startAt: DateTime.now().add(const Duration(hours: 1)),
      endAt: DateTime.now().add(const Duration(hours: 7)),
      address: '서울 강남구',
    );

Map<String, dynamic> _rel({bool verified = true}) => {
      'identity_verified': verified,
      'reliability': 72,
      'tier': 'standard',
      'professional': false,
      'penalties': const [],
    };

const _assignment = Assignment(
  id: 'a-1',
  requestId: 'r-1',
  workerId: 'w-1',
  status: 'confirmed',
  checkInAt: null,
  checkOutAt: null,
);

WorkContract _contract({required bool workerSigned}) => WorkContract(
      id: 'c-1',
      assignmentId: 'a-1',
      terms: const {'title': '카페 홀 마감', 'pay_amount': 96000},
      incomeType: 'daily_wage',
      signedWorkerAt: workerSigned ? DateTime.now() : null,
      signedEmployerAt: null,
      workerId: 'w-1',
      employerId: 'e-1',
    );

/// 홈을 GoRouter 하네스로 띄운다. push 목적지는 더미 페이지.
Future<void> _pumpHome(
  WidgetTester tester, {
  required _FakeWorkerRepository repo,
  List<OfferView> offers = const [],
  Assignment? assignment,
  WorkContract? contract,
  Map<String, dynamic>? reliability,
}) async {
  // 세로로 긴 화면 — 오퍼 카드/배정 뷰가 스크롤 없이 다 보이게(RenderFlex overflow 방지).
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  // geolocator 채널 mock — 미등록 채널은 응답이 영영 안 와서 _toggle/_checkIn의
  // await가 멈춘다(_busy 고착). 위치서비스 꺼짐으로 응답하면 currentDeviceLocation이
  // null을 반환하고 currentOrFallback이 kFallbackPoint로 대체한다.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/geolocator'),
    (call) async => call.method == 'isLocationServiceEnabled' ? false : null,
  );

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const WorkerHomePage()),
      GoRoute(
          path: '/contract/:aid',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('계약서 화면')))),
      GoRoute(
          path: '/verify-identity',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('본인확인 화면')))),
      GoRoute(
          path: '/history',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('내역 화면')))),
    ],
  );

  await tester.pumpWidget(ProviderScope(
    overrides: [
      workerRepositoryProvider.overrideWithValue(repo),
      myOffersProvider.overrideWith((ref) => Stream.value(offers)),
      myAssignmentProvider
          .overrideWith((ref) => Stream<Assignment?>.value(assignment)),
      myReliabilityProvider.overrideWith((ref) async => reliability ?? _rel()),
      if (assignment != null)
        activeSosProvider(assignment.id)
            .overrideWith((ref) => Stream.value(const <SosAlert>[])),
      if (assignment != null && contract != null)
        contractProvider(assignment.id).overrideWith((ref) async => contract),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump(); // 첫 프레임
  await tester.pump(const Duration(milliseconds: 50)); // 스트림/퓨처 값 반영
}

/// 탭 이후 비동기(geolocator fallback → fake RPC) 완료까지 프레임 진행.
/// pumpAndSettle은 1초 ticker 때문에 금지 — 유한 pump만 사용.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 가용 스위치 ON — 오퍼 카드 노출을 위한 "셋업"(토글 자체는 검증 대상 아님).
/// _available은 State 내부 private 필드라 외부 주입이 불가능해 스위치 탭으로 켠다.
/// 테스트 환경에서 geolocator는 MissingPluginException → currentDeviceLocation이
/// null을 반환 → kFallbackPoint로 대체되고, setAvailability는 fake가 흡수한다.
Future<void> _switchOn(WidgetTester tester) async {
  await tester.tap(find.byType(Switch));
  await _settle(tester);
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

  testWidgets('유효 오퍼: 카드에 제목·급여·수락/거절 버튼이 렌더된다', (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester, repo: repo, offers: [_offer()]);
    await _switchOn(tester);

    expect(find.text('카페 홀 마감'), findsOneWidget);
    expect(find.text('₩96,000'), findsOneWidget); // formatWon(96000)
    expect(find.textContaining('일급'), findsOneWidget); // payType daily
    expect(find.text('수락'), findsOneWidget);
    expect(find.text('지금은 안 함'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // 1초 ticker dispose
  });

  testWidgets('만료 오퍼만 있으면: 카드가 안 뜨고 대기 뷰가 보인다(만료 필터)', (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester, repo: repo, offers: [
      _offer(expiresAt: DateTime.now().subtract(const Duration(minutes: 5))),
    ]);
    await _switchOn(tester);

    expect(find.text('수락'), findsNothing);
    expect(find.text('카페 홀 마감'), findsNothing);
    expect(find.text('오퍼를 기다리는 중...'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('수락 탭: workerRepository.acceptOffer(offerId)가 호출된다', (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester, repo: repo, offers: [_offer()]);
    await _switchOn(tester);

    await tester.ensureVisible(find.text('수락'));
    await tester.tap(find.text('수락'));
    await _settle(tester);

    expect(repo.acceptedOfferIds, ['o-1']);
    expect(repo.declinedOfferIds, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('거절 탭: workerRepository.declineOffer(offerId)가 호출된다', (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester, repo: repo, offers: [_offer()]);
    await _switchOn(tester);

    await tester.ensureVisible(find.text('지금은 안 함'));
    await tester.tap(find.text('지금은 안 함'));
    await _settle(tester);

    expect(repo.declinedOfferIds, ['o-1']);
    expect(repo.acceptedOfferIds, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('미인증 근로자: 본인확인 안내가 뜨고 가용 스위치는 비활성', (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester, repo: repo, reliability: _rel(verified: false));

    expect(find.text('본인확인이 필요해요'), findsOneWidget);
    expect(find.text('완료하면 실시간 일감을 받을 수 있어요'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('확정 배정 + 계약서 미서명: GPS 체크인 탭 시 checkIn 미호출, 계약서로 유도',
      (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester,
        repo: repo,
        assignment: _assignment,
        contract: _contract(workerSigned: false));

    expect(find.text('확정됐어요!'), findsOneWidget);
    expect(find.text('근로계약서 서명하기'), findsOneWidget); // needsSign 라벨

    await tester.ensureVisible(find.text('GPS 체크인'));
    await tester.tap(find.text('GPS 체크인'));
    await tester.pump();

    expect(repo.checkInIds, isEmpty); // 서명 게이트가 체크인 차단
    expect(find.text('먼저 근로계약서에 서명해주세요.'), findsOneWidget); // 스낵바
    await tester.pump(const Duration(milliseconds: 400)); // push 전환
    expect(find.text('계약서 화면'), findsOneWidget); // /contract/a-1 유도

    await tester.pump(const Duration(seconds: 5)); // 스낵바 타이머 소진
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('확정 배정 + 계약서 서명 완료: GPS 체크인 탭 시 checkIn(assignmentId) 호출',
      (tester) async {
    final repo = _FakeWorkerRepository();
    await _pumpHome(tester,
        repo: repo,
        assignment: _assignment,
        contract: _contract(workerSigned: true));

    expect(find.text('근로계약서 보기'), findsOneWidget); // 서명 완료 라벨

    await tester.ensureVisible(find.text('GPS 체크인'));
    await tester.tap(find.text('GPS 체크인'));
    await _settle(tester); // geolocator 실패 → fallback 좌표로 checkIn

    expect(repo.checkInIds, ['a-1']);

    await tester.pumpWidget(const SizedBox());
  });
}
