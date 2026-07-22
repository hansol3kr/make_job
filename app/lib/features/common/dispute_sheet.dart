import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/logger.dart';
import '../../core/supabase_client.dart';
import '../../core/theme.dart';
import '../../data/dispute_repository.dart';
import '../../data/models.dart';

/// 배정 분쟁 시트 진입점. 어느 화면(근로자/업주)에서든 assignmentId 로 호출.
Future<void> showDisputeSheet(BuildContext context, String assignmentId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DisputeSheet(assignmentId: assignmentId),
  );
}

const _categories = <(String, String)>[
  ('pay', '급여 문제'),
  ('no_show', '무단 불참 이의'),
  ('mistreatment', '부당한 대우'),
  ('other', '기타'),
];

class _DisputeSheet extends ConsumerStatefulWidget {
  final String assignmentId;
  const _DisputeSheet({required this.assignmentId});

  @override
  ConsumerState<_DisputeSheet> createState() => _DisputeSheetState();
}

class _DisputeSheetState extends ConsumerState<_DisputeSheet> {
  late Future<DisputeView?> _future;
  final _reason = TextEditingController();
  final _evidence = TextEditingController();
  String _category = 'other';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _future = ref.read(disputeRepositoryProvider).forAssignment(widget.assignmentId);
  }

  @override
  void dispose() {
    _reason.dispose();
    _evidence.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = ref.read(disputeRepositoryProvider).forAssignment(widget.assignmentId);
    });
    // 진입점 배지(있다면)도 갱신되도록 provider 무효화.
    ref.invalidate(disputeForAssignmentProvider(widget.assignmentId));
  }

  Future<void> _open() async {
    final text = _reason.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '어떤 문제인지 적어주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(disputeRepositoryProvider)
          .open(widget.assignmentId, _category, text);
      if (mounted) {
        _reason.clear();
        _reload();
      }
    } catch (e, s) {
      AppLog.e('dispute_open_failed',
          context: {'assignment_id': widget.assignmentId}, error: e, stack: s);
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addEvidence(String disputeId) async {
    final text = _evidence.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(disputeRepositoryProvider).addEvidence(disputeId, text);
      if (mounted) {
        _evidence.clear();
        _reload();
      }
    } catch (e, s) {
      AppLog.e('dispute_evidence_failed',
          context: {'dispute_id': disputeId}, error: e, stack: s);
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('already_open')) return '이미 접수된 신고가 있어요';
    if (s.contains('not_a_party')) return '이 일에 직접 관련된 분만 신고할 수 있어요';
    if (s.contains('not_open')) return '이미 처리가 끝난 신고예요';
    if (s.contains('empty_reason') || s.contains('empty_text')) return '내용을 적어주세요';
    return '지금은 처리하지 못했어요. 잠시 후 다시 시도해 주세요';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          left: 20,
          right: 20,
          top: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: FutureBuilder<DisputeView?>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return _errorBody('신고 내용을 불러오지 못했어요\n${snap.error}');
            }
            final dispute = snap.data;
            return dispute == null ? _openForm() : _detail(dispute);
          },
        ),
      ),
    );
  }

  Widget _openForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('문제 신고',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        const Text('무슨 일이 있었는지 알려주세요. 담당자가 72시간 안에 확인해요.',
            style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _categories)
              ChoiceChip(
                label: Text(c.$2),
                selected: _category == c.$1,
                onSelected: (_) => setState(() => _category = c.$1),
                showCheckmark: false,
                selectedColor: AppColors.primary.withValues(alpha: 0.12),
                labelStyle: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _category == c.$1
                        ? AppColors.primary
                        : AppColors.inkSub),
                side: BorderSide(
                    color: _category == c.$1 ? AppColors.primary : AppColors.line),
                backgroundColor: AppColors.surface,
              ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _reason,
          maxLength: 1000,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: '예) 정상 출근했는데 무단 불참으로 처리됐어요. 매장 CCTV 확인 부탁드려요.'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!,
              style: const TextStyle(color: AppColors.danger, fontSize: 13)),
        ],
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _open,
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('신고 접수'),
          ),
        ),
      ],
    );
  }

  Widget _detail(DisputeView d) {
    final myId = supabase.auth.currentUser?.id ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('신고 진행 상황',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(width: 10),
            _statusChip(d),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          d.isOpen
              ? _slaLabel(d.slaDeadline)
              : (d.resolution ?? '담당자가 처리를 끝냈어요.'),
          style: const TextStyle(fontSize: 13, color: AppColors.inkSub),
        ),
        const SizedBox(height: 16),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: d.evidence.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _evidenceTile(d.evidence[i], myId),
          ),
        ),
        if (d.isOpen) ...[
          const Divider(height: 24),
          TextField(
            controller: _evidence,
            maxLength: 1000,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: '증거나 설명 더 남기기',
              suffixIcon: IconButton(
                icon: const Icon(Icons.send_rounded, color: AppColors.primary),
                onPressed: _busy ? null : () => _addEvidence(d.id),
              ),
            ),
          ),
          if (_error != null)
            Text(_error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 13)),
        ],
      ],
    );
  }

  Widget _evidenceTile(DisputeEvidence e, String myId) {
    final mine = e.by != null && e.by == myId;
    final who = mine ? '나' : '상대';
    final catLabel = e.category == null
        ? ''
        : ' · ${_categories.firstWhere((c) => c.$1 == e.category, orElse: () => ('', '기타')).$2}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: mine
            ? AppColors.primary.withValues(alpha: 0.06)
            : AppColors.bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$who$catLabel',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.inkSub)),
          const SizedBox(height: 4),
          Text(e.text, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _statusChip(DisputeView d) {
    final (label, color) =
        d.isOpen ? ('검토 중', AppColors.warn) : ('처리 완료', AppColors.inkSub);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: color)),
    );
  }

  String _slaLabel(DateTime? deadline) {
    if (deadline == null) return '담당자가 확인하고 있어요.';
    final remain = deadline.difference(DateTime.now());
    if (remain.isNegative) return '검토 기한이 지났어요. 곧 처리해 드릴게요.';
    final h = remain.inHours;
    return h >= 1 ? '검토 기한이 약 $h시간 남았어요' : '검토 기한이 곧 끝나요';
  }

  Widget _errorBody(String msg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(msg,
            style: const TextStyle(color: AppColors.danger, fontSize: 13)),
      );
}
