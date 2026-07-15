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

/// 휴대폰 번호 형식 검증. 유효하면 null, 아니면 사용자 안내 메시지.
/// 한국 휴대폰(01X-XXXX-XXXX) 기준 — '+82'/'0'/'82' 접두 입력도 정규화 후 검사한다.
String? validateKoreanPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '휴대폰 번호를 입력해주세요.';
  final e164 = normalizeKoreanPhone(raw);
  // +82 + 01X에서 앞 0을 뗀 형태 = +82 1[016789] + 7~8자리.
  if (!RegExp(r'^\+821[016789]\d{7,8}$').hasMatch(e164)) {
    return '올바른 휴대폰 번호가 아니에요. 010으로 시작하는 번호를 확인해주세요.';
  }
  return null;
}

/// 인증번호(6자리 숫자) 형식 검증. 유효하면 null, 아니면 안내 메시지.
String? validateOtpToken(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '인증번호를 입력해주세요.';
  if (!RegExp(r'^\d{6}$').hasMatch(t)) {
    return '인증번호는 숫자 6자리예요. 문자로 받은 6자리를 확인해주세요.';
  }
  return null;
}

/// 인증 관련 예외 → 오류 종류별 한국어 안내. gotrue error [code]로 우선 분기하고,
/// 코드가 없으면 statusCode·메시지로 보강한다. 알 수 없는 인증 오류는 원문을 노출(디버깅 겸).
String authErrorMessage(Object e) {
  if (e is AuthRetryableFetchException) {
    return '네트워크 연결이 불안정해요. 연결 상태를 확인하고 다시 시도해주세요.';
  }
  if (e is AuthException) {
    switch (e.code) {
      case 'otp_expired':
        return '인증번호가 만료됐거나 올바르지 않아요. 다시 확인하거나 재발송해주세요.';
      case 'validation_failed':
        return '휴대폰 번호 형식을 다시 확인해주세요.';
      case 'over_sms_send_rate_limit':
      case 'over_request_rate_limit':
        return '요청이 너무 잦아요. 잠시 후 다시 시도해주세요.';
      case 'sms_send_failed':
        return '인증번호를 보내지 못했어요. 번호를 확인하고 다시 시도해주세요.';
      case 'phone_provider_disabled':
      case 'otp_disabled':
        return '지금은 휴대폰 인증을 사용할 수 없어요. 잠시 후 다시 시도해주세요.';
    }
    final msg = e.message.toLowerCase();
    if (e.statusCode == '429' || msg.contains('rate limit')) {
      return '요청이 너무 잦아요. 잠시 후 다시 시도해주세요.';
    }
    if (msg.contains('expired') || msg.contains('invalid') || msg.contains('token')) {
      return '인증번호가 만료됐거나 올바르지 않아요. 다시 확인하거나 재발송해주세요.';
    }
    if (msg.contains('phone') || msg.contains('number')) {
      return '휴대폰 번호를 다시 확인해주세요.';
    }
    return e.message;
  }
  final s = e.toString().toLowerCase();
  if (s.contains('socket') ||
      s.contains('network') ||
      s.contains('connection') ||
      s.contains('failed host')) {
    return '네트워크 연결을 확인해주세요.';
  }
  return '알 수 없는 오류가 발생했어요. 잠시 후 다시 시도해주세요.';
}

/// 소셜 로그인 실패 → provider 이름을 붙인 한국어 안내. 사용자가 창을 닫은 경우엔 빈 문자열
/// (에러로 취급하지 않음). provider 미설정/미지원은 '준비 중'으로 안내한다.
String oauthErrorMessage(String providerLabel, Object e) {
  if (e is AuthRetryableFetchException) {
    return '네트워크 연결이 불안정해요. 연결 상태를 확인하고 다시 시도해주세요.';
  }
  if (e is AuthException) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();
    if (msg.contains('cancel')) return '';
    if (code == 'validation_failed' ||
        code.contains('disabled') ||
        msg.contains('not enabled') ||
        msg.contains('is not enabled') ||
        msg.contains('unsupported provider') ||
        msg.contains('provider')) {
      return '$providerLabel 로그인은 아직 준비 중이에요. 다른 방법으로 로그인해주세요.';
    }
  }
  return '$providerLabel 로그인에 실패했어요. 잠시 후 다시 시도해주세요.';
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

  /// 소셜 로그인(카카오/네이버/토스/애플/구글). 외부 브라우저 → 딥링크
  /// (kr.jigeum.jigeum://login-callback)로 복귀하면 supabase_flutter가 세션을 자동 수립하고
  /// onAuthStateChange(signedIn) 발생. 네이버·토스는 Supabase 커스텀 OAuth provider로 설정.
  /// 카카오는 이메일 동의항목 미설정 시 에러 → 닉네임 스코프만 요청해 회피.
  Future<bool> signInWithOAuth(OAuthProvider provider) => supabase.auth.signInWithOAuth(
        provider,
        redirectTo: 'kr.jigeum.jigeum://login-callback',
        scopes: provider.name == 'kakao' ? 'profile_nickname' : null,
        // iOS 기본값(platformDefault=인앱 SFSafariViewController)은 OAuth 초기 로드에
        // 실패(_failedSafariViewControllerLoadException)한다. SDK는 Google-Android만
        // 외부브라우저로 우회하고 iOS는 안 하므로, 여기서 외부 브라우저로 강제한다.
        authScreenLaunchMode: LaunchMode.externalApplication,
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
