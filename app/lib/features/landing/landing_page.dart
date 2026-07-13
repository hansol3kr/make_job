import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';

/// 역할 선택 진입 화면.
class LandingPage extends StatelessWidget {
  const LandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.bolt_rounded,
                        color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 12),
                  const Text('지금인력',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 40),
              const Text(
                '지원자 말고,\n확정된 사람.',
                style: TextStyle(
                    fontSize: 34,
                    height: 1.25,
                    fontWeight: FontWeight.w900,
                    color: AppColors.ink),
              ),
              const SizedBox(height: 14),
              const Text(
                '필요한 순간, 검증된 사람을 실시간으로.\n못 채우면 자동으로 대체 인력까지.',
                style: TextStyle(
                    fontSize: 16, height: 1.5, color: AppColors.inkSub),
              ),
              const Spacer(),
              _RoleCard(
                emoji: '🧑‍🍳',
                title: '사장님이에요',
                subtitle: '지금 당장 일손이 필요해요',
                color: AppColors.primary,
                onTap: () => context.go('/login/employer'),
              ),
              const SizedBox(height: 14),
              _RoleCard(
                emoji: '🙋',
                title: '일하고 싶어요',
                subtitle: '가까운 일감을 실시간으로 받을래요',
                color: AppColors.accent,
                onTap: () => context.go('/login/worker'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _RoleCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 28)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.inkSub)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.inkSub),
          ],
        ),
      ),
    );
  }
}
