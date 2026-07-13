import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';
import '../../data/profile_repository.dart';

/// 원터치 요청 생성 — 카테고리·시간·인원·급여. 위치는 매장 기본 위치.
class CreateRequestPage extends ConsumerStatefulWidget {
  const CreateRequestPage({super.key});

  @override
  ConsumerState<CreateRequestPage> createState() => _CreateRequestPageState();
}

class _CreateRequestPageState extends ConsumerState<CreateRequestPage> {
  int _catIndex = 0;
  int _headcount = 1;
  int _pay = 95000;
  late DateTime _start;
  late DateTime _end;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    var start = DateTime(now.year, now.month, now.day, 14, 0);
    if (start.isBefore(now.add(const Duration(minutes: 30)))) {
      start = now.add(const Duration(hours: 2));
    }
    _start = start;
    _end = start.add(const Duration(hours: 6));
  }

  Future<void> _startMatching(List<AppCategory> cats) async {
    if (cats.isEmpty) return;
    final cat = cats[_catIndex.clamp(0, cats.length - 1)];
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(employerRepositoryProvider);
      final requestId = await repo.createRequest(
        title: '${cat.name} 대타',
        startAt: _start,
        endAt: _end,
        payAmount: _pay,
        headcount: _headcount,
        categoryId: cat.id,
      );
      await repo.requestMatching(requestId);
      ref.invalidate(myRequestsProvider);
      if (!mounted) return;
      context.go('/employer/matching/$requestId');
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('no_location')) {
      return '매장 위치가 없어요. 매장 정보를 먼저 등록해 주세요.';
    }
    return '요청 생성 실패: $e';
  }

  @override
  Widget build(BuildContext context) {
    final catsAsync = ref.watch(storeCategoriesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('지금 사람 찾기'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/employer'),
        ),
      ),
      body: catsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('카테고리 로드 실패: $e')),
        data: (cats) {
          if (_catIndex >= cats.length) _catIndex = 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              _label('어떤 일인가요?'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < cats.length; i++)
                    ChoiceChip(
                      label: Text('${cats[i].emoji}  ${cats[i].name}'),
                      selected: _catIndex == i,
                      onSelected: (_) => setState(() => _catIndex = i),
                      showCheckmark: false,
                      selectedColor: AppColors.primary.withValues(alpha: 0.12),
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _catIndex == i
                            ? AppColors.primary
                            : AppColors.inkSub,
                      ),
                      side: BorderSide(
                          color: _catIndex == i
                              ? AppColors.primary
                              : AppColors.line),
                      backgroundColor: AppColors.surface,
                    ),
                ],
              ),
              const SizedBox(height: 24),
              _label('언제 필요하세요?'),
              _tile(Icons.schedule_rounded, timeRangeLabel(_start, _end),
                  '${_end.difference(_start).inHours}시간'),
              const SizedBox(height: 24),
              _label('몇 분 필요하세요?'),
              _StepperRow(
                text: '$_headcount명',
                onMinus: () =>
                    setState(() => _headcount = (_headcount - 1).clamp(1, 20)),
                onPlus: () =>
                    setState(() => _headcount = (_headcount + 1).clamp(1, 20)),
              ),
              const SizedBox(height: 24),
              _label('급여 (일급, 총액 선공개)'),
              _StepperRow(
                text: '₩${formatWon(_pay)}',
                onMinus: () =>
                    setState(() => _pay = (_pay - 5000).clamp(0, 2000000)),
                onPlus: () =>
                    setState(() => _pay = (_pay + 5000).clamp(0, 2000000)),
              ),
              const SizedBox(height: 24),
              _label('위치'),
              _tile(Icons.location_on_rounded, '등록된 매장 위치 기준', '반경 3km 매칭'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_user_rounded,
                        color: AppColors.accent, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '못 채우면 자동으로 대체 인력을 찾고, 그래도 실패하면 수수료 0원.',
                        style: TextStyle(
                            fontSize: 13,
                            color: AppColors.ink,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    style:
                        const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(
            onPressed: _busy
                ? null
                : () => _startMatching(catsAsync.asData?.value ?? const []),
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('실시간 매칭 시작'),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 4),
        child: Text(t,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      );

  Widget _tile(IconData icon, String main, String sub) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(main,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Text(sub,
                style: const TextStyle(fontSize: 13, color: AppColors.inkSub)),
          ],
        ),
      );
}

class _StepperRow extends StatelessWidget {
  final String text;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _StepperRow(
      {required this.text, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
              onPressed: onMinus,
              icon: const Icon(Icons.remove_circle_outline_rounded)),
          Text(text,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          IconButton(
              onPressed: onPlus,
              icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
    );
  }
}
