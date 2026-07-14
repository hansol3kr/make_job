/// 안전/신뢰 리포지토리 — 인앱 채팅 + 원터치 SOS (배정 당사자 공용).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class SafetyRepository {
  /// 배정의 메시지 실시간 스트림(오래된 순). RLS로 당사자만 열람.
  Stream<List<Message>> watchMessages(String assignmentId) {
    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('assignment_id', assignmentId)
        .order('created_at')
        .map((rows) => rows.map((m) => Message.fromMap(m)).toList());
  }

  /// 메시지 전송(RPC, 당사자 검증·본인 sender 강제).
  Future<void> sendMessage(String assignmentId, String body) =>
      supabase.rpc('send_message', params: {
        'p_assignment': assignmentId,
        'p_body': body,
      });

  /// SOS 발동(GPS 있으면 좌표 첨부). 배정 미지정도 허용.
  Future<void> triggerSos({
    String? assignmentId,
    double? lat,
    double? lng,
    String? note,
  }) =>
      supabase.rpc('trigger_sos', params: {
        'p_assignment': assignmentId,
        'p_lat': lat,
        'p_lng': lng,
        'p_note': note,
      });

  /// SOS 해제(신고자 또는 상대 당사자).
  Future<void> resolveSos(String id) =>
      supabase.rpc('resolve_sos', params: {'p_id': id});

  /// 이 배정의 open SOS 실시간 스트림(상대 발동 감지 → 배너).
  Stream<List<SosAlert>> watchActiveSos(String assignmentId) {
    return supabase
        .from('sos_alerts')
        .stream(primaryKey: ['id'])
        .eq('assignment_id', assignmentId)
        .map((rows) => rows
            .map((m) => SosAlert.fromMap(m))
            .where((s) => s.status == 'open')
            .toList());
  }

  /// 근무 중 위치 갱신(upsert, 근무지까지 거리 서버 계산). 당사자만.
  Future<void> updateLiveLocation(String assignmentId, double lat, double lng) =>
      supabase.rpc('update_live_location', params: {
        'p_assignment': assignmentId,
        'p_lat': lat,
        'p_lng': lng,
      });

  /// 위치 공유 종료(체크아웃 시 내 공유행 삭제).
  Future<void> stopLiveLocation(String assignmentId) =>
      supabase.rpc('stop_live_location', params: {'p_assignment': assignmentId});

  /// 이 배정의 실시간 위치 공유 스트림(상대 위치 지도/거리 표시용).
  Stream<List<LiveLocation>> watchLiveLocations(String assignmentId) {
    return supabase
        .from('live_locations')
        .stream(primaryKey: ['assignment_id', 'sharer_id'])
        .eq('assignment_id', assignmentId)
        .map((rows) => rows.map((m) => LiveLocation.fromMap(m)).toList());
  }
}

final safetyRepositoryProvider =
    Provider<SafetyRepository>((ref) => SafetyRepository());

/// 배정별 실시간 메시지.
final messagesProvider = StreamProvider.autoDispose
    .family<List<Message>, String>((ref, assignmentId) {
  return ref.watch(safetyRepositoryProvider).watchMessages(assignmentId);
});

/// 배정별 open SOS(상대 발동 배너용).
final activeSosProvider = StreamProvider.autoDispose
    .family<List<SosAlert>, String>((ref, assignmentId) {
  return ref.watch(safetyRepositoryProvider).watchActiveSos(assignmentId);
});

/// 배정별 실시간 위치 공유(상대 위치 카드용).
final liveLocationsProvider = StreamProvider.autoDispose
    .family<List<LiveLocation>, String>((ref, assignmentId) {
  return ref.watch(safetyRepositoryProvider).watchLiveLocations(assignmentId);
});
