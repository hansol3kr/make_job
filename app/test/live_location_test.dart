import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('LiveLocation 파싱/신선도', () {
    test('필드 파싱 + 거리', () {
      final l = LiveLocation.fromMap({
        'assignment_id': 'a-1',
        'sharer_id': 'w-1',
        'dist_to_site_m': 182,
        'updated_at': DateTime.now().toIso8601String(),
      });
      expect(l.assignmentId, 'a-1');
      expect(l.sharerId, 'w-1');
      expect(l.distToSiteM, 182);
      expect(l.isStale, isFalse); // 방금 갱신 → 신선
    });

    test('오래된 갱신은 stale', () {
      final old = LiveLocation.fromMap({
        'assignment_id': 'a-1',
        'sharer_id': 'w-1',
        'dist_to_site_m': null,
        'updated_at':
            DateTime.now().subtract(const Duration(minutes: 2)).toIso8601String(),
      });
      expect(old.isStale, isTrue);
      expect(old.secondsAgo, greaterThan(45));
      expect(old.distToSiteM, isNull); // 거리 없음 안전 처리
    });
  });
}
