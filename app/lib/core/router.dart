import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'supabase_client.dart';
import 'logger.dart';
import '../features/landing/landing_page.dart';
import '../features/auth/phone_login_page.dart';
import '../features/auth/onboarding_page.dart';
import '../features/employer/employer_home_page.dart';
import '../features/employer/create_request_page.dart';
import '../features/employer/matching_status_page.dart';
import '../features/worker/worker_home_page.dart';
import '../features/worker/identity_verification_page.dart';
import '../features/worker/professional_registration_page.dart';
import '../features/worker/history_page.dart';
import '../features/auth/consent_agreement_page.dart';
import '../features/common/chat_page.dart';
import '../features/common/contract_page.dart';

/// go_router를 Supabase 인증 상태 변화에 맞춰 갱신하기 위한 브리지.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _sub = stream.asBroadcastStream().listen((_) => notifyListeners());
  }
  late final StreamSubscription<dynamic> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable:
      GoRouterRefreshStream(supabase.auth.onAuthStateChange),
  redirect: (context, state) {
    AppLog.setRoute(state.matchedLocation); // 원격 로그에 현재 화면 기록
    final loggedIn = supabase.auth.currentSession != null;
    final loc = state.matchedLocation;
    final isProtected = loc.startsWith('/employer') ||
        loc.startsWith('/worker') ||
        loc.startsWith('/onboarding') ||
        loc.startsWith('/chat') ||
        loc.startsWith('/contract');
    // 미로그인 상태에서 보호 경로 접근 → 랜딩으로
    if (!loggedIn && isProtected) return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, _) => const LandingPage()),
    GoRoute(
      path: '/login/:role',
      builder: (_, s) =>
          PhoneLoginPage(role: s.pathParameters['role'] ?? 'worker'),
    ),
    GoRoute(
      path: '/onboarding/:role',
      builder: (_, s) =>
          OnboardingPage(role: s.pathParameters['role'] ?? 'worker'),
    ),
    GoRoute(path: '/employer', builder: (_, _) => const EmployerHomePage()),
    GoRoute(
        path: '/employer/new', builder: (_, _) => const CreateRequestPage()),
    GoRoute(
      path: '/employer/matching/:rid',
      builder: (_, s) =>
          MatchingStatusPage(requestId: s.pathParameters['rid']!),
    ),
    GoRoute(path: '/worker', builder: (_, _) => const WorkerHomePage()),
    GoRoute(
        path: '/verify-identity',
        builder: (_, _) => const IdentityVerificationPage()),
    GoRoute(
        path: '/register-professional',
        builder: (_, _) => const ProfessionalRegistrationPage()),
    GoRoute(path: '/history', builder: (_, _) => const HistoryPage()),
    GoRoute(
      path: '/consent/:role',
      builder: (_, s) =>
          ConsentAgreementPage(role: s.pathParameters['role'] ?? 'worker'),
    ),
    GoRoute(
      path: '/chat/:aid',
      builder: (_, s) => ChatPage(assignmentId: s.pathParameters['aid']!),
    ),
    GoRoute(
      path: '/contract/:aid',
      builder: (_, s) => ContractPage(assignmentId: s.pathParameters['aid']!),
    ),
  ],
);
