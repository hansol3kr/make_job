import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/auth.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('normalizeKoreanPhone', () {
    test('0으로 시작 → +82', () {
      expect(normalizeKoreanPhone('010-1234-1111'), '+821012341111');
      expect(normalizeKoreanPhone('01012342222'), '+821012342222');
    });
    test('이미 +82', () {
      expect(normalizeKoreanPhone('+82 10 1234 9999'), '+821012349999');
    });
    test('82로 시작', () {
      expect(normalizeKoreanPhone('821012341111'), '+821012341111');
    });
  });

  test('formatWon 콤마', () {
    expect(formatWon(95000), '95,000');
    expect(formatWon(0), '0');
    expect(formatWon(1200000), '1,200,000');
  });

  test('timeRangeLabel 6시간', () {
    final start = DateTime(2026, 7, 13, 14, 0);
    final end = DateTime(2026, 7, 13, 20, 0);
    final label = timeRangeLabel(start, end);
    expect(label.contains('14:00'), true);
    expect(label.contains('20:00'), true);
    expect(label.contains('6시간'), true);
  });
}
