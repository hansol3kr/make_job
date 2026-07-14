import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('DisputeView.fromMap', () {
    test('open 분쟁 + 증거 배열 파싱', () {
      final d = DisputeView.fromMap({
        'id': '16c7cc95-d6d9-4518-b6e8-206dcf9ea0f5',
        'assignment_id': 'de000000-0000-0000-0000-000000000a51',
        'opened_by': 'de000000-0000-0000-0000-0000000000a1',
        'status': 'open',
        'evidence': [
          {
            'by': 'de000000-0000-0000-0000-0000000000a1',
            'category': 'no_show',
            'text': '정상 출근했어요',
            'at': '2026-07-14T08:11:55Z',
          },
          {
            'by': 'de000000-0000-0000-0000-0000000000e1',
            'text': 'GPS 기록 없음',
            'at': '2026-07-14T08:20:00Z',
          },
        ],
        'resolution': null,
        'sla_deadline': '2026-07-17T08:11:55Z',
        'created_at': '2026-07-14T08:11:55Z',
        'i_opened': true,
      });
      expect(d.status, 'open');
      expect(d.isOpen, true);
      expect(d.iOpened, true);
      expect(d.evidence.length, 2);
      expect(d.evidence.first.category, 'no_show');
      expect(d.evidence.first.by, isNotNull);
      expect(d.evidence[1].category, isNull); // 후속 증거엔 category 없음
      expect(d.slaDeadline, isNotNull);
      expect(d.resolution, isNull);
    });

    test('resolved 분쟁 + 빈 증거 graceful', () {
      final d = DisputeView.fromMap({
        'id': 'x',
        'assignment_id': 'y',
        'opened_by': 'z',
        'status': 'resolved',
        'evidence': null,
        'resolution': '증거불충분 종결',
        'sla_deadline': null,
        'created_at': null,
        'i_opened': false,
      });
      expect(d.isOpen, false);
      expect(d.iOpened, false);
      expect(d.evidence, isEmpty);
      expect(d.resolution, '증거불충분 종결');
      expect(d.slaDeadline, isNull);
    });
  });

  group('DisputeEvidence.fromMap', () {
    test('text null → 빈 문자열', () {
      final e = DisputeEvidence.fromMap({'by': 'a', 'at': null});
      expect(e.text, '');
      expect(e.at, isNull);
      expect(e.category, isNull);
    });
  });
}
