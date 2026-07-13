/// 인증: 폰 OTP 발송/검증 + 세션 스트림. (프로덕션 정석 = 폰 인증)
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';

/// 한국 휴대폰 번호 → E.164(+82...). "010-1234-1111" → "+821012341111".
/// 이미 +로 시작하면 숫자만 남겨 그대로 사용.
String normalizeKoreanPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (digits.startsWith('+')) return '+${digits.substring(1).replaceAll('+', '')}';
  if (digits.startsWith('0')) return '+82${digits.substring(1)}';
  if (digits.startsWith('82')) return '+$digits';
  return '+82$digits';
}

class AuthRepository {
  /// OTP 발송(= 없으면 가입). 로컬은 test_otp 고정코드로 즉시 "발송" 처리.
  Future<void> sendOtp(String phoneE164) =>
      supabase.auth.signInWithOtp(phone: phoneE164);

  /// OTP 검증 → 세션 발급. 실패 시 AuthException throw.
  Future<void> verifyOtp(String phoneE164, String token) =>
      supabase.auth.verifyOTP(
        phone: phoneE164,
        token: token,
        type: OtpType.sms,
      );

  Future<void> signOut() => supabase.auth.signOut();

  String? get currentUserId => supabase.auth.currentUser?.id;
  bool get isLoggedIn => supabase.auth.currentSession != null;
}

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository());

/// 인증 상태 변화 스트림 (로그인/로그아웃 → 라우터 갱신).
final authStateProvider = StreamProvider<AuthState>((ref) {
  return supabase.auth.onAuthStateChange;
});
