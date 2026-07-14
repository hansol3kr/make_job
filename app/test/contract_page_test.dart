import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('WorkContract 파싱/헬퍼', () {
    Map<String, dynamic> raw({String? worker, String? employer}) => {
          'id': 'c-1',
          'assignment_id': 'a-1',
          'income_type': 'daily_wage',
          'signed_worker_at': worker,
          'signed_employer_at': employer,
          'worker_id': 'w-1',
          'employer_id': 'e-1',
          'terms': {
            'employer_name': '강남편의점',
            'worker_name': '이근로',
            'title': '편의점 야간 대타',
            'pay_type': 'daily',
            'pay_amount': 96000,
            'address': '서울 강남구',
            'start_at': '2026-07-14T22:00:00+09:00',
            'end_at': '2026-07-15T06:00:00+09:00',
            'employer_is_user': true,
            'broker_note': '사용자(당사자)는 요청자이며 플랫폼은 직업소개입니다.',
          },
        };

    test('terms 접근자 + 소득유형 라벨', () {
      final c = WorkContract.fromMap(raw());
      expect(c.employerName, '강남편의점');
      expect(c.workerName, '이근로');
      expect(c.title, '편의점 야간 대타');
      expect(c.payAmount, 96000);
      expect(c.payType, 'daily');
      expect(c.incomeTypeLabel, '일용근로소득');
      expect(c.brokerNote, contains('직업소개'));
      expect(c.startAt, isNotNull);
      expect(c.endAt, isNotNull);
    });

    test('서명 상태 전이', () {
      expect(WorkContract.fromMap(raw()).workerSigned, isFalse);
      expect(WorkContract.fromMap(raw()).fullySigned, isFalse);

      final workerOnly =
          WorkContract.fromMap(raw(worker: '2026-07-14T21:00:00+09:00'));
      expect(workerOnly.workerSigned, isTrue);
      expect(workerOnly.employerSigned, isFalse);
      expect(workerOnly.fullySigned, isFalse);

      final both = WorkContract.fromMap(raw(
          worker: '2026-07-14T21:00:00+09:00',
          employer: '2026-07-14T21:05:00+09:00'));
      expect(both.fullySigned, isTrue);
    });

    test('null terms 안전 처리', () {
      final c = WorkContract.fromMap({
        'id': 'c',
        'assignment_id': 'a',
        'income_type': 'daily_wage',
        'signed_worker_at': null,
        'signed_employer_at': null,
        'worker_id': null,
        'employer_id': null,
        'terms': null,
      });
      expect(c.employerName, '요청자');
      expect(c.payAmount, 0);
      expect(c.startAt, isNull);
    });
  });
}
