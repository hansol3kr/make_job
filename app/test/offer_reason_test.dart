import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  OfferView build(int? prox, int? rel) {
    final reason = <String, dynamic>{'distance_m': 174, 'reliability': 80};
    if (prox != null) reason['prox_pct'] = prox;
    if (rel != null) reason['rel_pct'] = rel;
    return OfferView.from(
        {
          'id': 'o1',
          'request_id': 'r1',
          'status': 'offered',
          'rank': 1,
          'expires_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
          'reason': reason,
        },
        {
          'title': '카페 대타',
          'pay_amount': 95000,
          'pay_type': 'daily',
          'start_at': DateTime.now().toIso8601String(),
          'end_at': DateTime.now().add(const Duration(hours: 6)).toIso8601String(),
        },
      );
  }

  group('OfferView 설명가능 랭킹', () {
    test('reason 점수분해 파싱', () {
      final o = build(64, 36);
      expect(o.distanceM, 174);
      expect(o.proxPct, 64);
      expect(o.relPct, 36);
    });
    test('근접 우세 → 거리 근거', () {
      expect(build(64, 36).matchReason, contains('가까운 거리'));
    });
    test('신뢰 우세 → 신뢰 근거', () {
      expect(build(40, 60).matchReason, contains('신뢰'));
    });
    test('근거 없으면 null', () {
      expect(build(null, null).matchReason, isNull);
    });
  });

  group('재예약 지명 오퍼 (0025)', () {
    test('reason.rebook → isRebook + 지명 문구', () {
      final o = OfferView.from(
        {
          'id': 'o2',
          'request_id': 'r2',
          'status': 'offered',
          'expires_at':
              DateTime.now().add(const Duration(minutes: 10)).toIso8601String(),
          'reason': {'rebook': true},
        },
        {
          'title': '재예약 대타',
          'pay_amount': 96000,
          'pay_type': 'daily',
          'start_at': DateTime.now().toIso8601String(),
          'end_at':
              DateTime.now().add(const Duration(hours: 8)).toIso8601String(),
        },
      );
      expect(o.isRebook, isTrue);
      expect(o.matchReason, contains('지명'));
    });
  });

  group('MatchingSnapshot 상태 (0024)', () {
    MatchingSnapshot snap(String s) => MatchingSnapshot.fromMap(
        {'status': s, 'headcount': 1, 'filled_count': 0, 'offered_count': 0, 'workers': []});
    test('expired/completed 판별', () {
      expect(snap('expired').isExpired, isTrue);
      expect(snap('completed').isCompleted, isTrue);
      expect(snap('matching').isExpired, isFalse);
      expect(snap('confirmed').isConfirmed, isTrue);
    });
  });
}

