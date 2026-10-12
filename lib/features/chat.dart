import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db.dart';
import '../core/providers.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'dialer.dart';

/// One SIP MESSAGE conversation. With an empty [peer] it starts a new one.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.peer, required this.title});
  final String peer;
  final String title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late String _peer = widget.peer;
  final _to = TextEditingController();
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (_peer.isNotEmpty) ref.read(dbProvider).markRead(_peer);
  }

  @override
  void dispose() {
    _to.dispose();
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final body = _text.text.trim();
    final peer = _peer.isNotEmpty ? _peer : _to.text.trim();
    if (body.isEmpty || peer.isEmpty) return;
    ref.read(sipProvider).sendMessage(peer, body);
    _text.clear();
    if (_peer.isEmpty) setState(() => _peer = peer);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(dbProvider);
    final title = widget.title.isNotEmpty ? widget.title : (_peer.isNotEmpty ? _peer : 'newChat'.tr());
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          if (_peer.isNotEmpty) ...[Avatar(title, size: 34), const SizedBox(width: 10)],
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
        ]),
        actions: [
          if (_peer.isNotEmpty)
            IconButton(
              tooltip: 'call'.tr(),
              icon: Icon(Icons.call, color: t.success),
              onPressed: () => placeCall(context, ref, _peer, name: widget.title),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (_peer.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _to,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'to'.tr(), hintText: 'targetHint'.tr()),
              ),
            ),
          Expanded(
            child: _peer.isEmpty
                ? const SizedBox.shrink()
                : FutureBuilder<List<ChatMessage>>(
                    future: db.thread(_peer),
                    builder: (_, s) {
                      final items = s.data ?? const <ChatMessage>[];
                      if (items.isEmpty) return Center(child: Text('noMessages'.tr(), style: TextStyle(color: t.text2)));
                      return ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _Bubble(items[items.length - 1 - i]),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(color: t.nav, border: Border(top: BorderSide(color: t.border))),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: 'typeMessage'.tr()),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'send'.tr(),
                style: IconButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent),
                onPressed: _send,
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Align(
      alignment: m.outgoing ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: m.outgoing ? t.accent : t.surface,
          border: m.outgoing ? null : Border.all(color: t.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(m.body, style: TextStyle(color: m.outgoing ? t.onAccent : t.text, fontSize: 15)),
          const SizedBox(height: 2),
          Text(DateFormat.Hm().format(m.at),
              style: TextStyle(fontSize: 10, color: m.outgoing ? t.onAccent.withValues(alpha: 0.75) : t.text2)),
        ]),
      ),
    );
  }
}
