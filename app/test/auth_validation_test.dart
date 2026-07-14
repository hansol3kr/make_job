import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/data/auth.dart';

void main() {
  group('normalizeKoreanPhone', () {
    test('010 국내표기 → E.164', () {
      expect(normalizeKoreanPhone('010-1234-1111'), '+821012341111');
      expect(normalizeKoreanPhone('01012341111'), '+821012341111');
    });
    test('+82/82 접두 유지', () {
      expect(normalizeKoreanPhone('+821012341111'), '+821012341111');
      expect(normalizeKoreanPhone('821012341111'), '+821012341111');
    });
  });

  group('validateKoreanPhone', () {
    test('유효한 번호는 null', () {
      expect(validateKoreanPhone('010-1234-1111'), isNull);
      expect(validateKoreanPhone('01012345678'), isNull);
      expect(validateKoreanPhone('+821012341111'), isNull);
      expect(validateKoreanPhone('011-234-5678'), isNull); // 레거시 허용
    });
    test('빈 값 → 입력 안내', () {
      expect(validateKoreanPhone(''), contains('입력'));
      expect(validateKoreanPhone('---'), contains('입력'));
    });
    test('형식 오류 → 형식 안내', () {
      expect(validateKoreanPhone('010123'), contains('올바른'));
      expect(validateKoreanPhone('12345'), contains('올바른'));
      expect(validateKoreanPhone('0101234111199'), contains('올바른')); // 너무 김
    });
  });

  group('validateOtpToken', () {
    test('6자리 숫자는 null', () {
      expect(validateOtpToken('123456'), isNull);
      expect(validateOtpToken(' 123456 '), isNull); // trim
    });
    test('빈 값 → 입력 안내', () {
      expect(validateOtpToken(''), contains('입력'));
    });
    test('자릿수 오류 → 6자리 안내', () {
      expect(validateOtpToken('123'), contains('6자리'));
      expect(validateOtpToken('1234567'), contains('6자리'));
    });
  });

  group('authErrorMessage', () {
    test('otp_expired 코드 → 만료 안내', () {
      final e = const AuthApiException('Token has expired or is invalid',
          statusCode: '403', code: 'otp_expired');
      expect(authErrorMessage(e), contains('만료'));
    });
    test('rate limit 코드 → 잠시 후 안내', () {
      final e = const AuthApiException('over sms send rate limit',
          statusCode: '429', code: 'over_sms_send_rate_limit');
      expect(authErrorMessage(e), contains('잠시'));
    });
    test('provider disabled → 사용 불가 안내', () {
      final e = const AuthApiException('phone provider disabled',
          statusCode: '422', code: 'phone_provider_disabled');
      expect(authErrorMessage(e), contains('사용할 수 없'));
    });
    test('코드 없이 message로 만료 추론', () {
      final e = const AuthApiException('Token has expired or is invalid',
          statusCode: '403');
      expect(authErrorMessage(e), contains('만료'));
    });
    test('네트워크 재시도 예외 → 연결 안내', () {
      final e = AuthRetryableFetchException(message: 'boom', statusCode: '503');
      expect(authErrorMessage(e), contains('연결'));
    });
    test('비-Auth 예외 폴백', () {
      expect(authErrorMessage(Exception('unknown')), contains('알 수 없는'));
    });
  });

  group('oauthErrorMessage', () {
    test('provider 미설정/미지원 → 준비 중 안내(+라벨)', () {
      final e = const AuthApiException('Unsupported provider: provider is not enabled',
          statusCode: '400', code: 'validation_failed');
      final m = oauthErrorMessage('네이버', e);
      expect(m, contains('네이버'));
      expect(m, contains('준비 중'));
    });
    test('사용자가 창을 닫으면 빈 문자열(무시)', () {
      final e = const AuthException('User cancelled login');
      expect(oauthErrorMessage('카카오', e), isEmpty);
    });
    test('네트워크 예외 → 연결 안내', () {
      final e = AuthRetryableFetchException(message: 'boom');
      expect(oauthErrorMessage('Apple', e), contains('연결'));
    });
    test('일반 실패 → provider 라벨 붙은 안내', () {
      expect(oauthErrorMessage('토스', Exception('boom')), contains('토스'));
    });
  });

  group('Env.enabledOAuth', () {
    test('기본값은 google 포함', () {
      expect(Env.enabledOAuth, contains('google'));
    });
    test('소문자·trim 정규화된 집합', () {
      expect(Env.enabledOAuth, isA<Set<String>>());
      for (final p in Env.enabledOAuth) {
        expect(p, p.toLowerCase());
        expect(p.trim(), p);
      }
    });
  });
}
