import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

void main() {
  group('종료 상태 판정 (isClosedRequestStatus)', () {
    test('종료 상태 → 삭제(보관) 가능', () {
      expect(isClosedRequestStatus('completed'), isTrue);
      expect(isClosedRequestStatus('cancelled'), isTrue);
      expect(isClosedRequestStatus('expired'), isTrue);
    });

    test('진행 중 상태 → 삭제 불가(취소 메뉴 노출)', () {
      expect(isClosedRequestStatus('open'), isFalse);
      expect(isClosedRequestStatus('matching'), isFalse);
      expect(isClosedRequestStatus('confirmed'), isFalse);
      expect(isClosedRequestStatus('in_progress'), isFalse);
      expect(isClosedRequestStatus('draft'), isFalse);
    });
  });

  group('MatchingSnapshot 상태 게터', () {
    MatchingSnapshot snap(String status) =>
        MatchingSnapshot.fromMap({'status': status});

    test('cancelled → isCancelled만 참', () {
      final s = snap('cancelled');
      expect(s.isCancelled, isTrue);
      expect(s.isExpired, isFalse);
      expect(s.isConfirmed, isFalse);
      expect(s.isCompleted, isFalse);
    });

    test('다른 상태는 isCancelled 거짓', () {
      for (final st in ['open', 'matching', 'confirmed', 'completed', 'expired']) {
        expect(snap(st).isCancelled, isFalse, reason: st);
      }
    });
  });
}
