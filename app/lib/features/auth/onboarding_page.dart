import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../data/location_service.dart';
import '../../data/profile_repository.dart';

/// 온보딩: 역할별 프로필 생성. 위치는 M1b 프리셋(추후 실 GPS).
class OnboardingPage extends ConsumerStatefulWidget {
  final String role;
  const OnboardingPage({super.key, required this.role});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _name = TextEditingController();
  int _presetIndex = 0;
  bool _busy = false;
  String? _error;

  bool get _isEmployer => widget.role == 'employer';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = _isEmployer ? '상호를 입력하세요' : '이름을 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final preset = kLocationPresets[_presetIndex];
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (_isEmployer) {
        await repo.completeEmployerOnboarding(
          businessName: name,
          lng: preset.point.lng,
          lat: preset.point.lat,
          address: preset.address,
        );
      } else {
        await repo.completeWorkerOnboarding(
          displayName: name,
          lng: preset.point.lng,
          lat: preset.point.lat,
        );
      }
      if (!mounted) return;
      context.go(_isEmployer ? '/employer' : '/worker');
    } catch (e) {
      if (mounted) setState(() => _error = '저장 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _presetIndex,
                  items: [
                    for (var i = 0; i < kLocationPresets.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                            '${kLocationPresets[i].label} · ${kLocationPresets[i].address}',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _presetIndex = v ?? 0),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text('※ 데모용 프리셋 위치입니다. 실 GPS는 다음 단계에서 연결돼요.',
                style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
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
}
