import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/history_repository.dart';

void main() {
  group('ActivitySummary.fromMap', () {
    test('필드 파싱 + null 안전', () {
      final s = ActivitySummary.fromMap({
        'completed_count': 2,
        'total_earned': 200000,
        'no_show_count': 1,
        'cancelled_count': 0,
        'upcoming_count': 3,
      });
      expect(s.completedCount, 2);
      expect(s.totalEarned, 200000);
      expect(s.noShowCount, 1);
      expect(s.upcomingCount, 3);
    });

    test('빈 맵이면 0으로 처리', () {
      final s = ActivitySummary.fromMap({});
      expect(s.completedCount, 0);
      expect(s.totalEarned, 0);
    });
  });

  group('ActivityItem.fromMap', () {
    ActivityItem make(String status) => ActivityItem.fromMap({
          'assignment_id': 'a1',
          'title': '카페 홀서빙',
          'pay_amount': 90000,
          'pay_type': 'daily',
          'status': status,
          'worked_at': '2026-07-13T06:00:00Z',
          'employer_name': '블루보틀',
          'my_rating': 5,
          'received_rating': 4,
        });

    test('완료 항목 파싱', () {
      final it = make('completed');
      expect(it.title, '카페 홀서빙');
      expect(it.payAmount, 90000);
      expect(it.employerName, '블루보틀');
      expect(it.myRating, 5);
      expect(it.receivedRating, 4);
      expect(it.isCompleted, isTrue);
      expect(it.isNoShow, isFalse);
    });

    test('상태 헬퍼 분류', () {
      expect(make('no_show').isNoShow, isTrue);
      expect(make('cancelled_worker').isCancelled, isTrue);
      expect(make('cancelled_employer').isCancelled, isTrue);
      expect(make('confirmed').isUpcoming, isTrue);
      expect(make('checked_in').isUpcoming, isTrue);
    });

    test('평점 없으면 null (미공개/미제출)', () {
      final it = ActivityItem.fromMap({
        'assignment_id': 'a2',
        'title': '편의점',
        'pay_amount': 100000,
        'pay_type': 'daily',
        'status': 'completed',
        'worked_at': '2026-07-12T06:00:00Z',
        'employer_name': null,
        'my_rating': null,
        'received_rating': null,
      });
      expect(it.myRating, isNull);
      expect(it.receivedRating, isNull);
      expect(it.employerName, isNull);
    });
  });
}
