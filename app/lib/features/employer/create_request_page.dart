import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/logger.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/store_repository.dart';

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
  bool _requiresPro = false;
  late DateTime _start;
  late DateTime _end;
  bool _busy = false;
  String? _error;
  String? _storeId; // 선택한 매장(없으면 기본 매장)

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

  /// 시작/종료 시간 선택(TimePicker). 종료가 시작보다 빠르면 다음날로 간주하지 않고
  /// 최소 1시간 근무로 자동 보정해 40~50대가 헷갈리지 않게 한다.
  Future<void> _pickTime(bool isStart) async {
    final base = isStart ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: base.hour, minute: base.minute),
      helpText: isStart ? '근무 시작 시간' : '근무 종료 시간',
      builder: (ctx, child) => MediaQuery(
        // 24시간 표기 강제(오전/오후 혼동 방지)
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      final d = isStart ? _start : _end;
      final next = DateTime(d.year, d.month, d.day, picked.hour, picked.minute);
      if (isStart) {
        _start = next;
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1)); // 종료가 시작 이하면 +1시간
        }
      } else {
        _end = next;
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1));
        }
      }
    });
  }

  Widget _timeButton(String label, DateTime t, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 13, color: AppColors.inkSub)),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                const Icon(Icons.edit_calendar_rounded,
                    size: 20, color: AppColors.primary),
              ],
            ),
          ],
        ),
      ),
    );
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
        title: '${_requiresPro ? '[전문] ' : ''}${cat.name} 대타',
        startAt: _start,
        endAt: _end,
        payAmount: _pay,
        headcount: _headcount,
        categoryId: cat.id,
        requiresProfessional: _requiresPro,
        storeId: _storeId,
      );
      await repo.requestMatching(requestId);
      ref.invalidate(myRequestsProvider);
      if (!mounted) return;
      context.go('/employer/matching/$requestId');
    } catch (e, s) {
      AppLog.e('create_request_failed',
          context: {'requires_pro': _requiresPro}, error: e, stack: s);
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
    if (s.contains('below_minimum_wage')) {
      return '급여가 최저임금(2026년 시급 10,320원)에 못 미쳐요. 근무시간 대비 급여를 올려주세요.';
    }
    return '요청을 만들지 못했어요: $e';
  }

  @override
  Widget build(BuildContext context) {
    final catsAsync = ref.watch(storeCategoriesProvider);
    final stores = ref.watch(myStoresProvider).asData?.value ?? const <Store>[];
    // 기본 선택: 기본 매장(없으면 첫 매장). 사용자가 고르면 그 값 유지.
    if (_storeId == null && stores.isNotEmpty) {
      _storeId = stores.firstWhere((s) => s.isDefault, orElse: () => stores.first).id;
    }
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
        error: (e, _) => Center(child: Text('카테고리를 불러오지 못했어요: $e')),
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
              Row(
                children: [
                  Expanded(
                    child: _timeButton('시작', _start, () => _pickTime(true)),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('~',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  Expanded(
                    child: _timeButton('종료', _end, () => _pickTime(false)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('총 ${_end.difference(_start).inMinutes ~/ 60}시간 근무',
                  style: const TextStyle(
                      fontSize: 14, color: AppColors.inkSub)),
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
              _label('급여 (일급, 총액 미리 공개)'),
              _StepperRow(
                text: '₩${formatWon(_pay)}',
                onMinus: () =>
                    setState(() => _pay = (_pay - 5000).clamp(0, 2000000)),
                onPlus: () =>
                    setState(() => _pay = (_pay + 5000).clamp(0, 2000000)),
              ),
              const SizedBox(height: 24),
              _label('전문인력'),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: _requiresPro ? AppColors.primary : AppColors.line),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.workspace_premium_rounded,
                        color: AppColors.primary),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('전문인력만 부르기',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          Text('인증된 전문인력에게만 매칭돼요',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.inkSub)),
                        ],
                      ),
                    ),
                    Switch(
                      value: _requiresPro,
                      onChanged: (v) => setState(() => _requiresPro = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _label('매장 (위치 기준)'),
                  TextButton.icon(
                    onPressed: () => context.push('/employer/stores'),
                    icon: const Icon(Icons.add_business_rounded, size: 18),
                    label: const Text('매장 관리'),
                  ),
                ],
              ),
              if (stores.isEmpty)
                _tile(Icons.location_on_rounded, '기본 매장 위치 기준', '반경 3km 매칭')
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _storeId,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      items: [
                        for (final s in stores)
                          DropdownMenuItem(
                            value: s.id,
                            child: Text(
                                '${s.name}${s.isDefault ? '  · 기본' : ''}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _storeId = v),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text('선택한 매장 반경 3km에서 매칭돼요.',
                    style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
              ),
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
                    style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
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
