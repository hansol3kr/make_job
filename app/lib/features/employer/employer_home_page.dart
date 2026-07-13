import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';
import '../../data/profile_repository.dart';

class EmployerHomePage extends ConsumerWidget {
  const EmployerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(myRequestsProvider);
    final profile = ref.watch(myProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('사장님 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: '로그아웃',
            onPressed: () async {
              await ref.read(authRepositoryProvider).signOut();
              if (context.mounted) context.go('/');
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myRequestsProvider),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.asData?.value?.displayName ?? '사장님',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text('필요한 순간, 확정된 사람을 실시간으로.',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('최근 요청',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            requests.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _ErrorBox(message: '요청을 불러오지 못했어요\n$e'),
              data: (list) => list.isEmpty
                  ? const _EmptyBox()
                  : Column(
                      children: [
                        for (final r in list) ...[
                          _RequestTile(
                            request: r,
                            onTap: () =>
                                context.go('/employer/matching/${r.id}'),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
          width: double.infinity,
          child: FloatingActionButton.extended(
            onPressed: () => context.go('/employer/new'),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text('지금 사람 찾기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class _RequestTile extends StatelessWidget {
  final JobRequest request;
  final VoidCallback onTap;
  const _RequestTile({required this.request, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _statusStyle(request);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${request.title} · ${timeRangeLabel(request.startAt, request.endAt)}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              fontSize: 13,
                              color: color,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.inkSub),
          ],
        ),
      ),
    );
  }

  (String, Color) _statusStyle(JobRequest r) {
    switch (r.status) {
      case 'confirmed':
      case 'in_progress':
        return ('확정 · ${r.filledCount}/${r.headcount}명', AppColors.accent);
      case 'completed':
        return ('완료', AppColors.inkSub);
      case 'cancelled':
      case 'expired':
        return ('종료', AppColors.inkSub);
      default:
        return ('매칭 중 · ${r.filledCount}/${r.headcount}명', AppColors.warn);
    }
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
        alignment: Alignment.center,
        child: const Column(
          children: [
            Text('📭', style: TextStyle(fontSize: 44)),
            SizedBox(height: 12),
            Text('아직 요청이 없어요.\n아래 버튼으로 지금 사람을 찾아보세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkSub)),
          ],
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message,
            style: const TextStyle(color: AppColors.danger, fontSize: 13)),
      );
}
