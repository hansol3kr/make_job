/// 분쟁 리포지토리 — 배정 당사자의 문제 신고·증거·조회 (RPC 경유).
/// 해소(status/resolution)는 운영자(service_role) 처리 — 앱 범위 밖.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class DisputeRepository {
  /// 이 배정의 분쟁(가장 최근 1건, 없으면 null). 당사자만.
  Future<DisputeView?> forAssignment(String assignmentId) async {
    final res = await supabase
        .rpc('dispute_for_assignment', params: {'p_assignment_id': assignmentId});
    if (res == null) return null;
    return DisputeView.fromMap((res as Map).cast<String, dynamic>());
  }

  /// 분쟁 열기(카테고리+사유). 반환: 생성된 분쟁.
  Future<DisputeView> open(
      String assignmentId, String category, String reason) async {
    final res = await supabase.rpc('open_dispute', params: {
      'p_assignment_id': assignmentId,
      'p_category': category,
      'p_reason': reason,
    });
    return DisputeView.fromMap((res as Map).cast<String, dynamic>());
  }

  /// 열린 분쟁에 증거 추가. 반환: 갱신된 분쟁.
  Future<DisputeView> addEvidence(String disputeId, String text) async {
    final res = await supabase.rpc('add_dispute_evidence', params: {
      'p_dispute_id': disputeId,
      'p_text': text,
    });
    return DisputeView.fromMap((res as Map).cast<String, dynamic>());
  }
}

final disputeRepositoryProvider =
    Provider<DisputeRepository>((ref) => DisputeRepository());

/// 배정별 분쟁(조회). 신고/증거 후 invalidate 로 갱신.
final disputeForAssignmentProvider = FutureProvider.autoDispose
    .family<DisputeView?, String>((ref, assignmentId) {
  return ref.watch(disputeRepositoryProvider).forAssignment(assignmentId);
});
