import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('Store 파싱', () {
    test('필드 파싱 + 기본 매장 플래그', () {
      final s = Store.fromMap({
        'id': 's1',
        'name': '강남점',
        'address': '서울 강남구',
        'is_default': true,
      });
      expect(s.id, 's1');
      expect(s.name, '강남점');
      expect(s.address, '서울 강남구');
      expect(s.isDefault, isTrue);
    });

    test('누락 필드 안전 처리', () {
      final s = Store.fromMap({'id': 's2', 'is_default': false});
      expect(s.name, '매장'); // 기본값
      expect(s.address, isNull);
      expect(s.isDefault, isFalse);
    });
  });
}
