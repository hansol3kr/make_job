import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/location_service.dart';
import '../../data/region_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/consent_repository.dart';

/// 온보딩: 역할별 프로필 생성. 위치는 실 GPS 우선, 없으면 전국 지역(시/도→시/군/구) 선택.
class OnboardingPage extends ConsumerStatefulWidget {
  final String role;
  const OnboardingPage({super.key, required this.role});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _name = TextEditingController();
  bool _busy = false;
  bool _gpsBusy = false;
  String? _error;

  // 확정된 위치
  double? _lat;
  double? _lng;
  String? _locLabel;

  // 지역 선택 상태
  String? _selSido;
  String? _selSigungu;

  bool get _isEmployer => widget.role == 'employer';
  bool get _hasLocation => _lat != null && _lng != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _useGps(List<Region> regions) async {
    setState(() {
      _gpsBusy = true;
      _error = null;
    });
    final p = await currentDeviceLocation();
    if (!mounted) return;
    if (p == null) {
      setState(() {
        _gpsBusy = false;
        _error = '위치 권한이 거부되었어요. 아래에서 지역을 직접 선택해 주세요.';
      });
      return;
    }
    final near = nearestRegion(regions, p.lat, p.lng);
    setState(() {
      _lat = p.lat;
      _lng = p.lng;
      _locLabel = near?.label ?? '현재 위치';
      _selSido = null;
      _selSigungu = null;
      _gpsBusy = false;
    });
    AppLog.i('onboarding_gps_set', context: {'label': _locLabel});
  }

  void _pickSigungu(Region r) {
    setState(() {
      _selSigungu = r.sigungu;
      _lat = r.lat;
      _lng = r.lng;
      _locLabel = r.label;
    });
    AppLog.i('onboarding_region_set', context: {'label': r.label});
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = _isEmployer ? '상호를 입력하세요' : '이름을 입력하세요');
      return;
    }
    if (!_hasLocation) {
      setState(() => _error = '현재 위치를 켜거나 활동 지역을 선택하세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (_isEmployer) {
        await repo.completeEmployerOnboarding(
          businessName: name,
          lng: _lng!,
          lat: _lat!,
          address: _locLabel ?? '',
        );
      } else {
        await repo.completeWorkerOnboarding(
          displayName: name,
          lng: _lng!,
          lat: _lat!,
        );
      }
      AppLog.i('onboarding_done', context: {'role': widget.role});
      if (!mounted) return;
      context.go(_isEmployer ? '/employer' : '/worker');
    } catch (e, s) {
      AppLog.e('onboarding_failed', error: e, stack: s);
      if (mounted) setState(() => _error = '저장 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 법적 필수 동의 게이트: 확인 중이면 로더, 미동의면 동의 화면으로 보낸다.
    final consentAsync = ref.watch(consentRequiredMetProvider);
    if (consentAsync.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (consentAsync.value != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/consent/${widget.role}');
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final regionsAsync = ref.watch(regionsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(_isEmployer ? '매장 정보' : '내 정보')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            Text(
              _isEmployer ? '매장을 등록해요' : '프로필을 만들어요',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              _isEmployer ? '요청 위치와 상호로 사용됩니다.' : '가까운 일감 매칭에 위치가 사용됩니다.',
              style: const TextStyle(fontSize: 14, color: AppColors.inkSub),
            ),
            const SizedBox(height: 24),
            Text(_isEmployer ? '상호(매장명)' : '이름',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                hintText: _isEmployer ? '예: 강남 블루보틀' : '예: 김성실',
                prefixIcon: Icon(
                    _isEmployer ? Icons.store_rounded : Icons.person_rounded),
              ),
            ),
            const SizedBox(height: 24),
            Text(_isEmployer ? '매장 위치' : '주요 활동 지역',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            regionsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('지역 정보를 불러오지 못했어요: $e',
                  style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              data: (regions) => _locationSection(regions),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('시작하기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locationSection(List<Region> regions) {
    final sidos = sidoList(regions);
    final sigungus = _selSido == null ? <Region>[] : sigunguOf(regions, _selSido!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 현재 위치(GPS)
        OutlinedButton.icon(
          onPressed: _gpsBusy ? null : () => _useGps(regions),
          icon: _gpsBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location_rounded),
          label: Text(_gpsBusy ? '위치 확인 중…' : '현재 위치로 설정'),
        ),
        if (_hasLocation) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('설정됨 · ${_locLabel ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('또는 지역 선택',
                style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
          ),
          const Expanded(child: Divider()),
        ]),
        const SizedBox(height: 12),
        // 시/도
        _dropdown<String>(
          hint: '시/도',
          value: _selSido,
          items: [
            for (final s in sidos) DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) => setState(() {
            _selSido = v;
            _selSigungu = null;
          }),
        ),
        const SizedBox(height: 10),
        // 시/군/구
        _dropdown<String>(
          hint: '시/군/구',
          value: _selSigungu,
          items: [
            for (final r in sigungus)
              DropdownMenuItem(value: r.sigungu, child: Text(r.sigungu)),
          ],
          onChanged: _selSido == null
              ? null
              : (v) {
                  if (v == null) return;
                  final r = sigungus.firstWhere((e) => e.sigungu == v);
                  _pickSigungu(r);
                },
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required String hint,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: onChanged == null ? AppColors.line.withValues(alpha: 0.3) : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          hint: Text(hint, style: const TextStyle(color: AppColors.inkSub)),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
