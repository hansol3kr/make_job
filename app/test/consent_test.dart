import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/consent_repository.dart';

void main() {
  group('법적 동의 정의', () {
    test('필수 동의 5종이 0014 required_met 기준과 일치', () {
      final required = kConsents
          .where((c) => c.required)
          .map((c) => c.type)
          .toSet();
      // 0014 my_consent_status가 요구하는 필수 집합과 동일해야 게이트가 정확히 동작.
      expect(required, {'tos', 'privacy', 'privacy_3rd', 'location', 'age14'});
    });

    test('마케팅은 선택', () {
      final marketing = kConsents.firstWhere((c) => c.type == 'marketing');
      expect(marketing.required, isFalse);
    });

    test('모든 항목에 제목·본문이 있다(빈 약관 금지)', () {
      for (final c in kConsents) {
        expect(c.title.trim(), isNotEmpty, reason: '${c.type} 제목');
        expect(c.text.trim().length, greaterThan(20), reason: '${c.type} 본문');
      }
    });

    test('중복 type 없음', () {
      final types = kConsents.map((c) => c.type).toList();
      expect(types.toSet().length, types.length);
    });

    test('이용약관에 핵심 방어 문구(비사용자/중개자) 포함', () {
      final tos = kConsents.firstWhere((c) => c.type == 'tos');
      expect(tos.text.contains('사용자'), isTrue);
      expect(tos.text.contains('중개'), isTrue);
    });
  });
}
