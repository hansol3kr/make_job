/// 전자 근로계약서 화면 — 확정 조건 표시 + 내 역할 측 서명.
/// 당사자(사용자)는 요청자임을 명문화(근로자성 방어). 소득유형 = 일용근로소득.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
import '../../core/supabase_client.dart';
import '../../core/logger.dart';
import '../../data/models.dart';
import '../../data/contract_repository.dart';

class ContractPage extends ConsumerStatefulWidget {
  final String assignmentId;
  const ContractPage({super.key, required this.assignmentId});

  @override
  ConsumerState<ContractPage> createState() => _ContractPageState();
}

class _ContractPageState extends ConsumerState<ContractPage> {
  bool _signing = false;

  Future<void> _sign() async {
    setState(() => _signing = true);
    try {
      await ref.read(contractRepositoryProvider).sign(widget.assignmentId);
      ref.invalidate(contractProvider(widget.assignmentId));
      AppLog.i('contract_signed', context: {'assignment_id': widget.assignmentId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('근로계약서에 서명했어요 ✍️')));
      }
    } catch (e, s) {
      AppLog.e('contract_sign_failed', error: e, stack: s);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('서명 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = supabase.auth.currentUser?.id;
    final async = ref.watch(contractProvider(widget.assignmentId));
    return Scaffold(
      appBar: AppBar(title: const Text('전자 근로계약서')),
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('계약서를 불러오지 못했어요.\n$e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.inkSub)),
            ),
          ),
          data: (c) => _document(c, myId),
        ),
      ),
    );
  }

  Widget _document(WorkContract c, String? myId) {
    final isWorker = myId != null && myId == c.workerId;
    final isEmployer = myId != null && myId == c.employerId;
    final mySigned = isWorker ? c.workerSigned : c.employerSigned;
    final canSign = (isWorker || isEmployer) && !mySigned;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Text(c.title.isEmpty ? '근로계약' : c.title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text('소득유형 · ${c.incomeTypeLabel}',
            style: const TextStyle(color: AppColors.inkSub)),
        const SizedBox(height: 20),

        _section('당사자', [
          _row('사용자(요청자)', c.employerName),
          _row('근로자', c.workerName),
        ]),
        _section('근무 조건', [
          if (c.startAt != null && c.endAt != null)
            _row('근무 일시', timeRangeLabel(c.startAt!, c.endAt!)),
          if (c.address != null && c.address!.isNotEmpty)
            _row('장소', c.address!),
          _row('급여',
              '${formatWon(c.payAmount)}원 (${c.payType == 'hourly' ? '시급' : '일급'})'),
        ]),

        // 근로자성 방어 명문화
        if (c.brokerNote != null && c.brokerNote!.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              const Icon(Icons.gavel_rounded,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(c.brokerNote!,
                      style: const TextStyle(
                          fontSize: 12, height: 1.5, color: AppColors.inkSub))),
            ]),
          ),

        _section('서명', [
          _signRow('근로자', c.workerSigned, c.signedWorkerAt),
          _signRow('사용자(요청자)', c.employerSigned, c.signedEmployerAt),
        ]),

        const SizedBox(height: 20),
        if (c.fullySigned)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(children: [
              Icon(Icons.verified_rounded, color: AppColors.accent),
              SizedBox(width: 8),
              Text('양측 서명이 완료된 계약이에요.',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
          )
        else if (canSign)
          FilledButton.icon(
            onPressed: _signing ? null : _sign,
            icon: _signing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.draw_rounded),
            label: const Text('계약서에 서명하기'),
          )
        else if (mySigned)
          const Text('내 서명은 완료됐어요. 상대 서명을 기다리는 중이에요.',
              style: TextStyle(color: AppColors.inkSub)),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.inkSub)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(children: children),
          ),
          const SizedBox(height: 16),
        ],
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 96,
                child: Text(k,
                    style: const TextStyle(color: AppColors.inkSub))),
            Expanded(
                child: Text(v,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Widget _signRow(String who, bool signed, DateTime? at) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(signed ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 18,
                color: signed ? AppColors.accent : AppColors.inkSub),
            const SizedBox(width: 8),
            SizedBox(width: 96, child: Text(who)),
            Expanded(
              child: Text(
                signed && at != null
                    ? '서명 완료 · ${at.year}.${at.month}.${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'
                    : '미서명',
                style: TextStyle(
                    color: signed ? AppColors.ink : AppColors.inkSub,
                    fontWeight: signed ? FontWeight.w600 : FontWeight.normal),
              ),
            ),
          ],
        ),
      );
}
