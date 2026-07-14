/// 안전 위젯 공용 — SOS 발동 플로우 + 상대 SOS 배너 (근로자·업주 공통).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/location_service.dart';
import '../../data/safety_repository.dart';

/// SOS 확인 다이얼로그 → GPS 첨부 → trigger_sos. 성공/실패 스낵바.
Future<void> sosConfirmAndSend(
  BuildContext context,
  WidgetRef ref, {
  String? assignmentId,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('🚨 긴급 SOS'),
      content: const Text(
          '긴급 상황인가요?\nSOS를 보내면 상대방에게 즉시 알림이 가고, 현재 위치가 함께 기록돼요.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('SOS 보내기'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  try {
    final loc = await currentDeviceLocation(); // 실패해도 SOS는 보냄(좌표 없이)
    await ref.read(safetyRepositoryProvider).triggerSos(
          assignmentId: assignmentId,
          lat: loc?.lat,
          lng: loc?.lng,
        );
    AppLog.w('sos_triggered', context: {'assignment_id': assignmentId});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('🚨 SOS를 보냈어요. 안전에 유의하세요.'),
          backgroundColor: AppColors.danger));
    }
  } catch (e, s) {
    AppLog.e('sos_failed', error: e, stack: s);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('SOS 전송 실패: $e')));
    }
  }
}

/// 빨간 SOS 버튼(근무 화면용).
class SosButton extends ConsumerWidget {
  final String? assignmentId;
  const SosButton({super.key, this.assignmentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OutlinedButton.icon(
      onPressed: () => sosConfirmAndSend(context, ref, assignmentId: assignmentId),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.danger,
        side: const BorderSide(color: AppColors.danger),
        minimumSize: const Size.fromHeight(48),
      ),
      icon: const Icon(Icons.sos_rounded),
      label: const Text('긴급 SOS', style: TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

/// 상대가 실시간 위치를 공유 중이면 표시하는 카드(근무지까지 거리 + 갱신 경과).
class LiveLocationCard extends ConsumerWidget {
  final String assignmentId;
  final String myUserId;
  const LiveLocationCard(
      {super.key, required this.assignmentId, required this.myUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shares =
        ref.watch(liveLocationsProvider(assignmentId)).asData?.value ?? [];
    final fromOther = shares.where((s) => s.sharerId != myUserId).toList();
    if (fromOther.isEmpty) return const SizedBox.shrink();
    final s = fromOther.first;
    final live = !s.isStale;
    final color = live ? AppColors.accent : AppColors.inkSub;
    final ago = s.secondsAgo < 60
        ? '${s.secondsAgo}초 전'
        : '${(s.secondsAgo / 60).floor()}분 전';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(live ? Icons.my_location_rounded : Icons.location_disabled_rounded,
            color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(live ? '실시간 위치 공유 중' : '위치 공유 (연결 지연)',
                style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            Text(
              s.distToSiteM != null
                  ? '근무지에서 약 ${s.distToSiteM}m · $ago 업데이트'
                  : '$ago 업데이트',
              style: const TextStyle(fontSize: 12, color: AppColors.inkSub),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// 상대가 발동한 open SOS가 있으면 표시하는 배너(+해제).
class SosBanner extends ConsumerWidget {
  final String assignmentId;
  final String myUserId;
  const SosBanner({super.key, required this.assignmentId, required this.myUserId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(activeSosProvider(assignmentId)).asData?.value ?? [];
    // 내가 보낸 SOS는 배너로 다시 안 띄움(상대 발동만 경보).
    final fromOther = alerts.where((a) => a.reporterId != myUserId).toList();
    if (fromOther.isEmpty) return const SizedBox.shrink();
    final a = fromOther.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: AppColors.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('상대방이 SOS를 보냈어요',
                style: TextStyle(
                    fontWeight: FontWeight.w900, color: AppColors.danger)),
            if (a.note != null && a.note!.isNotEmpty)
              Text(a.note!, style: const TextStyle(fontSize: 13)),
          ]),
        ),
        TextButton(
          onPressed: () =>
              ref.read(safetyRepositoryProvider).resolveSos(a.id),
          child: const Text('해제'),
        ),
      ]),
    );
  }
}
