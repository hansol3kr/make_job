import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('PenaltyView.fromMap', () {
    test('신 백엔드 필드 파싱 + 시각 로컬 변환', () {
      final p = PenaltyView.fromMap({
        'id': 'a0000000-0000-0000-0000-000000000001',
        'kind': 'no_show',
        'reason': '노쇼(근무 미이행)',
        'waived': false,
        'appeal_status': 'none',
        'at': '2026-07-14T00:00:00Z',
      });
      expect(p.id, isNotNull);
      expect(p.kind, 'no_show');
      expect(p.reason, '노쇼(근무 미이행)');
      expect(p.waived, false);
      expect(p.appealStatus, 'none');
      expect(p.at, isNotNull);
    });

    test('구 백엔드(id·appeal_status 미노출) graceful defaults', () {
      final p = PenaltyView.fromMap({
        'kind': 'late_cancel',
        'reason': '근무 임박 취소',
        'waived': false,
        'at': null,
      });
      expect(p.id, isNull);
      expect(p.appealStatus, 'none'); // 기본값
      expect(p.at, isNull);
      expect(p.canAppeal, false, reason: 'id 없으면 이의신청 불가');
    });
  });

  group('PenaltyView.canAppeal', () {
    PenaltyView make({
      String? id = 'a0000000-0000-0000-0000-000000000001',
      bool waived = false,
      String appealStatus = 'none',
    }) =>
        PenaltyView(
          id: id,
          kind: 'no_show',
          reason: '노쇼',
          waived: waived,
          appealStatus: appealStatus,
          at: null,
        );

    test('본인·미면제·미신청 → 가능', () {
      expect(make().canAppeal, true);
    });
    test('id 없음(구 백엔드) → 불가', () {
      expect(make(id: null).canAppeal, false);
    });
    test('이미 면제됨 → 불가', () {
      expect(make(waived: true).canAppeal, false);
    });
    test('이미 신청함(requested) → 불가', () {
      expect(make(appealStatus: 'requested').canAppeal, false);
    });
    test('처리 완료(다른 상태) → 불가', () {
      expect(make(appealStatus: 'rejected').canAppeal, false);
    });
  });
}
