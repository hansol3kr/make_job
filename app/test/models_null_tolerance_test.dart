import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/data/models.dart';

/// fromMap null-tolerance 실측 — AppCategory·MyProfile·JobRequest·Assignment·
/// ConfirmedWorker·Message·SosAlert 7종.
///
/// 각 모델마다 ① 전체 필드 파싱(타임스탬프 toLocal 포함) ② 옵션 필드 전부 누락
/// 시 기본값 ③ 하드 캐스트(필수 키) 누락 시 throws — 서버 응답 계약을 테스트로
/// 명세화한다. 필수 키를 서버가 빼면 앱은 TypeError로 크래시한다는 뜻이다.
void main() {
  /// full에서 [key] 하나를 뺀 사본 — 필수 키 누락 시나리오용.
  Map<String, dynamic> without(Map<String, dynamic> full, String key) =>
      Map.of(full)..remove(key);

  group('AppCategory.fromMap', () {
    final full = <String, dynamic>{
      'id': 'c0000000-0000-0000-0000-000000000001',
      'slug': 'store-cafe',
      'name': '카페',
    };

    test('전체 필드 파싱 + slug 이모지 매핑', () {
      final c = AppCategory.fromMap(full);
      expect(c.id, 'c0000000-0000-0000-0000-000000000001');
      expect(c.slug, 'store-cafe');
      expect(c.name, '카페');
      expect(c.emoji, '☕');
    });

    test('미등록 slug → 기본 이모지', () {
      final c = AppCategory.fromMap(
          {'id': 'c2', 'slug': 'unknown-slug', 'name': '기타'});
      expect(c.emoji, '🧰');
    });

    test('필수 키 계약: id·slug·name 누락 시 각각 throws (옵션 필드 없음)', () {
      for (final key in ['id', 'slug', 'name']) {
        expect(() => AppCategory.fromMap(without(full, key)),
            throwsA(isA<TypeError>()),
            reason: '$key 는 하드 캐스트 필수 키');
      }
    });
  });

  group('MyProfile.fromMap', () {
    final full = <String, dynamic>{
      'id': 'u0000000-0000-0000-0000-000000000001',
      'role': 'employer',
      'display_name': '김사장',
      'phone': '01012342222',
    };

    test('전체 필드 파싱', () {
      final p = MyProfile.fromMap(full);
      expect(p.id, 'u0000000-0000-0000-0000-000000000001');
      expect(p.role, 'employer');
      expect(p.displayName, '김사장');
      expect(p.phone, '01012342222');
    });

    test('최소 맵(id만) → role 기본값 worker, 나머지 null', () {
      final p = MyProfile.fromMap({'id': 'u2'});
      expect(p.role, 'worker'); // 기본값
      expect(p.displayName, isNull);
      expect(p.phone, isNull);
    });

    test('필수 키 계약: id 누락 시 throws', () {
      expect(() => MyProfile.fromMap(without(full, 'id')),
          throwsA(isA<TypeError>()));
    });
  });

  group('JobRequest.fromMap', () {
    final full = <String, dynamic>{
      'id': 'r0000000-0000-0000-0000-000000000001',
      'title': '카페 홀서빙',
      'category_id': 'c0000000-0000-0000-0000-000000000001',
      'pay_amount': 120000,
      'pay_type': 'hourly',
      'headcount': 3,
      'filled_count': 2,
      'status': 'matching',
      'start_at': '2026-07-14T09:00:00Z',
      'end_at': '2026-07-14T18:30:00Z',
      'address': '서울 강남구 테헤란로 1',
    };

    test('전체 필드 파싱 + 타임스탬프 toLocal 변환', () {
      final r = JobRequest.fromMap(full);
      expect(r.id, 'r0000000-0000-0000-0000-000000000001');
      expect(r.title, '카페 홀서빙');
      expect(r.categoryId, 'c0000000-0000-0000-0000-000000000001');
      expect(r.payAmount, 120000);
      expect(r.payType, 'hourly');
      expect(r.headcount, 3);
      expect(r.filledCount, 2);
      expect(r.status, 'matching');
      expect(r.startAt, DateTime.utc(2026, 7, 14, 9).toLocal());
      expect(r.startAt.isUtc, isFalse, reason: 'toLocal 변환됨');
      expect(r.endAt, DateTime.utc(2026, 7, 14, 18, 30).toLocal());
      expect(r.endAt.isUtc, isFalse);
      expect(r.address, '서울 강남구 테헤란로 1');
      expect(r.isConfirmed, isFalse, reason: 'matching은 확정 전');
    });

    test('숫자 필드 num→int 캐스팅 (double로 와도 안전)', () {
      final r = JobRequest.fromMap(Map.of(full)
        ..['pay_amount'] = 120000.0
        ..['headcount'] = 3.0
        ..['filled_count'] = 2.0);
      expect(r.payAmount, 120000);
      expect(r.headcount, 3);
      expect(r.filledCount, 2);
    });

    test('최소 맵(id·start_at·end_at만) → 기본값 적용', () {
      final r = JobRequest.fromMap({
        'id': 'r2',
        'start_at': '2026-07-14T09:00:00Z',
        'end_at': '2026-07-14T18:00:00Z',
      });
      expect(r.title, ''); // 기본값
      expect(r.categoryId, isNull);
      expect(r.payAmount, 0); // 기본값
      expect(r.payType, 'daily'); // 기본값
      expect(r.headcount, 1); // 기본값
      expect(r.filledCount, 0); // 기본값
      expect(r.status, 'open'); // 기본값
      expect(r.address, isNull);
    });

    test('필수 키 계약: id·start_at·end_at 누락 시 각각 throws', () {
      for (final key in ['id', 'start_at', 'end_at']) {
        expect(() => JobRequest.fromMap(without(full, key)),
            throwsA(isA<TypeError>()),
            reason: '$key 는 하드 캐스트 필수 키');
      }
    });
  });

  group('Assignment.fromMap', () {
    final full = <String, dynamic>{
      'id': 'a0000000-0000-0000-0000-000000000001',
      'request_id': 'r0000000-0000-0000-0000-000000000001',
      'worker_id': 'w0000000-0000-0000-0000-000000000001',
      'status': 'checked_in',
      'check_in_at': '2026-07-14T09:05:00Z',
      'check_out_at': '2026-07-14T18:02:00Z',
    };

    test('전체 필드 파싱 + 체크인/아웃 toLocal 변환', () {
      final a = Assignment.fromMap(full);
      expect(a.id, 'a0000000-0000-0000-0000-000000000001');
      expect(a.requestId, 'r0000000-0000-0000-0000-000000000001');
      expect(a.workerId, 'w0000000-0000-0000-0000-000000000001');
      expect(a.status, 'checked_in');
      expect(a.checkInAt, DateTime.utc(2026, 7, 14, 9, 5).toLocal());
      expect(a.checkInAt!.isUtc, isFalse);
      expect(a.checkOutAt, DateTime.utc(2026, 7, 14, 18, 2).toLocal());
      expect(a.checkOutAt!.isUtc, isFalse);
    });

    test('최소 맵(id·request_id·worker_id만) → 기본값 적용', () {
      final a = Assignment.fromMap({
        'id': 'a2',
        'request_id': 'r2',
        'worker_id': 'w2',
      });
      expect(a.status, 'confirmed'); // 기본값
      expect(a.checkInAt, isNull);
      expect(a.checkOutAt, isNull);
    });

    test('필수 키 계약: id·request_id·worker_id 누락 시 각각 throws', () {
      for (final key in ['id', 'request_id', 'worker_id']) {
        expect(() => Assignment.fromMap(without(full, key)),
            throwsA(isA<TypeError>()),
            reason: '$key 는 하드 캐스트 필수 키');
      }
    });
  });

  group('ConfirmedWorker.fromMap', () {
    final full = <String, dynamic>{
      'assignment_id': 'a0000000-0000-0000-0000-000000000001',
      'status': 'checked_in',
      'display_name': '박근로',
      'reliability': 4.7,
      'dist_m': 850,
    };

    test('전체 필드 파싱 (dist_m → distanceM 키 매핑)', () {
      final w = ConfirmedWorker.fromMap(full);
      expect(w.assignmentId, 'a0000000-0000-0000-0000-000000000001');
      expect(w.status, 'checked_in');
      expect(w.displayName, '박근로');
      expect(w.reliability, 4.7);
      expect(w.distanceM, 850);
    });

    test('최소 맵(assignment_id만) → 기본값 적용', () {
      final w = ConfirmedWorker.fromMap({'assignment_id': 'a2'});
      expect(w.status, 'confirmed'); // 기본값
      expect(w.displayName, isNull);
      expect(w.reliability, isNull);
      expect(w.distanceM, isNull);
    });

    test('필수 키 계약: assignment_id 누락 시 throws', () {
      expect(() => ConfirmedWorker.fromMap(without(full, 'assignment_id')),
          throwsA(isA<TypeError>()));
    });
  });

  group('Message.fromMap', () {
    final full = <String, dynamic>{
      'id': 'm0000000-0000-0000-0000-000000000001',
      'assignment_id': 'a0000000-0000-0000-0000-000000000001',
      'sender_id': 'u0000000-0000-0000-0000-000000000001',
      'body': '지금 출발했습니다',
      'created_at': '2026-07-14T08:40:00Z',
    };

    test('전체 필드 파싱 + created_at toLocal 변환', () {
      final msg = Message.fromMap(full);
      expect(msg.id, 'm0000000-0000-0000-0000-000000000001');
      expect(msg.assignmentId, 'a0000000-0000-0000-0000-000000000001');
      expect(msg.senderId, 'u0000000-0000-0000-0000-000000000001');
      expect(msg.body, '지금 출발했습니다');
      expect(msg.createdAt, DateTime.utc(2026, 7, 14, 8, 40).toLocal());
      expect(msg.createdAt.isUtc, isFalse);
    });

    test('body 누락 → 빈 문자열 기본값', () {
      final msg = Message.fromMap(without(full, 'body'));
      expect(msg.body, '');
    });

    test('필수 키 계약: id·assignment_id·sender_id·created_at 누락 시 각각 throws',
        () {
      for (final key in ['id', 'assignment_id', 'sender_id', 'created_at']) {
        expect(() => Message.fromMap(without(full, key)),
            throwsA(isA<TypeError>()),
            reason: '$key 는 하드 캐스트 필수 키');
      }
    });
  });

  group('SosAlert.fromMap', () {
    final full = <String, dynamic>{
      'id': 's0000000-0000-0000-0000-000000000001',
      'assignment_id': 'a0000000-0000-0000-0000-000000000001',
      'reporter_id': 'u0000000-0000-0000-0000-000000000001',
      'status': 'resolved',
      'note': '오배송 신고',
      'created_at': '2026-07-14T13:00:00Z',
    };

    test('전체 필드 파싱 + created_at toLocal 변환', () {
      final s = SosAlert.fromMap(full);
      expect(s.id, 's0000000-0000-0000-0000-000000000001');
      expect(s.assignmentId, 'a0000000-0000-0000-0000-000000000001');
      expect(s.reporterId, 'u0000000-0000-0000-0000-000000000001');
      expect(s.status, 'resolved');
      expect(s.note, '오배송 신고');
      expect(s.createdAt, DateTime.utc(2026, 7, 14, 13).toLocal());
      expect(s.createdAt.isUtc, isFalse);
    });

    test('최소 맵(id·reporter_id·created_at만) → 기본값 적용', () {
      final s = SosAlert.fromMap({
        'id': 's2',
        'reporter_id': 'u2',
        'created_at': '2026-07-14T13:00:00Z',
      });
      expect(s.assignmentId, isNull, reason: '배정 밖 SOS 허용(nullable)');
      expect(s.status, 'open'); // 기본값
      expect(s.note, isNull);
    });

    test('필수 키 계약: id·reporter_id·created_at 누락 시 각각 throws', () {
      for (final key in ['id', 'reporter_id', 'created_at']) {
        expect(() => SosAlert.fromMap(without(full, key)),
            throwsA(isA<TypeError>()),
            reason: '$key 는 하드 캐스트 필수 키');
      }
    });
  });
}
