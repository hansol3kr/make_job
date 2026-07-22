/// 매장 관리 — 사장님의 여러 매장을 등록·기본전환·삭제. 위치는 현재 GPS 기준.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/models.dart';
import '../../data/location_service.dart';
import '../../data/store_repository.dart';

class StoreManagementPage extends ConsumerStatefulWidget {
  const StoreManagementPage({super.key});

  @override
  ConsumerState<StoreManagementPage> createState() =>
      _StoreManagementPageState();
}

class _StoreManagementPageState extends ConsumerState<StoreManagementPage> {
  bool _busy = false;

  Future<void> _addStore() async {
    final name = TextEditingController();
    final addr = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('매장 추가'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '매장 이름 (예: 강남점)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addr,
              decoration: const InputDecoration(labelText: '주소 (선택)'),
            ),
            const SizedBox(height: 12),
            const Row(children: [
              Icon(Icons.my_location_rounded, size: 16, color: AppColors.primary),
              SizedBox(width: 6),
              Expanded(
                child: Text('현재 위치를 매장 위치로 저장해요. 매장에서 등록해주세요.',
                    style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
              ),
            ]),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('추가')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final loc = await currentOrFallback();
      await ref.read(storeRepositoryProvider).addStore(
            name: name.text.trim(),
            lat: loc.lat,
            lng: loc.lng,
            address: addr.text.trim().isEmpty ? null : addr.text.trim(),
          );
      ref.invalidate(myStoresProvider);
      AppLog.i('store_added');
    } catch (e, s) {
      AppLog.e('store_add_failed', error: e, stack: s);
      if (mounted) _snack('매장 추가 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDefault(Store s) async {
    try {
      await ref.read(storeRepositoryProvider).setDefault(s.id);
      ref.invalidate(myStoresProvider);
    } catch (e) {
      if (mounted) _snack('기본 매장 변경 실패: $e');
    }
  }

  Future<void> _delete(Store s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("'${s.name}' 삭제"),
        content: const Text('이 매장을 삭제할까요? 기존 요청 이력은 그대로 남아요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(storeRepositoryProvider).deleteStore(s.id);
      ref.invalidate(myStoresProvider);
    } catch (e) {
      if (mounted) _snack('삭제 실패: $e');
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final stores = ref.watch(myStoresProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('매장 관리'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/employer'),
        ),
      ),
      body: stores.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('매장을 불러오지 못했어요: $e')),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Text('등록된 매장이 없어요.\n아래 버튼으로 추가하세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.inkSub)),
              ),
            for (final s in list) _storeTile(s),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addStore,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.add_business_rounded),
        label: const Text('매장 추가'),
      ),
    );
  }

  Widget _storeTile(Store s) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: s.isDefault ? AppColors.primary : AppColors.line),
        ),
        child: Row(
          children: [
            Icon(Icons.store_rounded,
                color: s.isDefault ? AppColors.primary : AppColors.inkSub),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(s.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    if (s.isDefault) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('기본',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary)),
                      ),
                    ],
                  ]),
                  if (s.address != null && s.address!.isNotEmpty)
                    Text(s.address!,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.inkSub)),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'default') _setDefault(s);
                if (v == 'delete') _delete(s);
              },
              itemBuilder: (_) => [
                if (!s.isDefault)
                  const PopupMenuItem(value: 'default', child: Text('기본 매장으로')),
                const PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
          ],
        ),
      );
}
