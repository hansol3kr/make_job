/// 인앱 채팅 — 확정 배정 당사자(근로자↔업주) 간 소통. 번호 노출 없이 소통.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme.dart';
import '../../core/supabase_client.dart';
import '../../data/models.dart';
import '../../data/safety_repository.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String assignmentId;
  const ChatPage({super.key, required this.assignmentId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(safetyRepositoryProvider)
          .sendMessage(widget.assignmentId, body);
      _input.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('메시지를 보내지 못했어요: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final myId = supabase.auth.currentUser?.id;
    final msgs = ref.watch(messagesProvider(widget.assignmentId));
    return Scaffold(
      appBar: AppBar(title: const Text('채팅')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: msgs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                    child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('메시지를 불러오지 못했어요.\n$e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.inkSub)),
                )),
                data: (list) {
                  _scrollToEnd();
                  if (list.isEmpty) {
                    return const Center(
                      child: Text('아직 메시지가 없어요.\n먼저 인사를 건네보세요 👋',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.inkSub)),
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _bubble(list[i], list[i].senderId == myId),
                  );
                },
              ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _bubble(Message m, bool mine) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: mine ? null : Border.all(color: AppColors.line),
        ),
        child: Text(
          m.body,
          style: TextStyle(
              color: mine ? Colors.white : AppColors.ink, fontSize: 15),
        ),
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: '메시지를 입력하세요',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
