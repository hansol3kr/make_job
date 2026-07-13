/// 근로자 리포지토리 — 가용 상태, 실시간 오퍼, 수락/거절, 체크인/아웃.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class WorkerRepository {
  String? get _uid => supabase.auth.currentUser?.id;

  /// 가용 토글(+위치 갱신). lng/lat 미지정 시 서버는 기존 current_geog 유지.
  Future<void> setAvailability(bool available, {double? lng, double? lat}) =>
      supabase.rpc('set_availability', params: {
        'p_available': available,
        'p_lng': lng,
        'p_lat': lat,
      });

  /// 내게 온 유효 오퍼(offered, 미만료) 실시간 스트림.
  /// match_offers 스트림 → 각 오퍼의 job_requests를 배치 조회해 결합.
  Stream<List<OfferView>> watchOffers() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    final stream =
        supabase.from('match_offers').stream(primaryKey: ['id']).eq('worker_id', uid);
    return stream.asyncMap((rows) async {
      final now = DateTime.now();
      final open = rows.where((o) {
        if ((o['status'] as String?) != 'offered') return false;
        final exp = DateTime.tryParse(o['expires_at'] as String? ?? '');
        return exp != null && exp.toLocal().isAfter(now);
      }).toList();
      if (open.isEmpty) return <OfferView>[];

      final reqIds =
          open.map((o) => o['request_id'] as String).toSet().toList();
      final reqRows = await supabase
          .from('job_requests')
          .select(
              'id, title, category_id, pay_amount, pay_type, start_at, end_at, address')
          .inFilter('id', reqIds);
      final byId = <String, Map<String, dynamic>>{
        for (final r in reqRows) r['id'] as String: r,
      };

      final views = <OfferView>[];
      for (final o in open) {
        final req = byId[o['request_id'] as String];
        if (req != null) {
          views.add(OfferView.from(o, req));
        }
      }
      views.sort((a, b) => (a.rank ?? 999).compareTo(b.rank ?? 999));
      return views;
    });
  }

  /// 오퍼 수락 → assignment_id 반환.
  Future<String> acceptOffer(String offerId) async {
    final res = await supabase.rpc('accept_offer', params: {'p_offer_id': offerId});
    return res as String;
  }

  /// 오퍼 거절(불이익 없음).
  Future<void> declineOffer(String offerId) =>
      supabase.rpc('decline_offer', params: {'p_offer_id': offerId});

  /// 내 배정 실시간 스트림 — 활성(확정/체크인) 중 가장 최근 1건.
  Stream<Assignment?> watchMyAssignment() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    final stream =
        supabase.from('assignments').stream(primaryKey: ['id']).eq('worker_id', uid);
    return stream.map((rows) {
      final active = rows
          .map((m) => Assignment.fromMap(m))
          .where((a) => a.status == 'confirmed' || a.status == 'checked_in')
          .toList();
      if (active.isEmpty) return null;
      active.sort((a, b) => b.id.compareTo(a.id)); // 최근 우선(대략)
      return active.first;
    });
  }

  Future<void> checkIn(String assignmentId, double lng, double lat) =>
      supabase.rpc('check_in', params: {
        'p_assignment_id': assignmentId,
        'p_lng': lng,
        'p_lat': lat,
      });

  Future<void> checkOut(String assignmentId) =>
      supabase.rpc('check_out', params: {'p_assignment_id': assignmentId});
}

final workerRepositoryProvider =
    Provider<WorkerRepository>((ref) => WorkerRepository());

/// 실시간 오퍼 목록.
final myOffersProvider = StreamProvider.autoDispose<List<OfferView>>((ref) {
  return ref.watch(workerRepositoryProvider).watchOffers();
});

/// 내 활성 배정.
final myAssignmentProvider = StreamProvider.autoDispose<Assignment?>((ref) {
  return ref.watch(workerRepositoryProvider).watchMyAssignment();
});
