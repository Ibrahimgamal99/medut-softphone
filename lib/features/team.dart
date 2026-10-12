import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'chat.dart';
import 'dialer.dart';

/// Design E · Team & status: your own status (PUBLISH) on top, then the
/// colleagues you watch (SUBSCRIBE), or the phone's contacts.
class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});

  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  bool _contacts = false;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final status = settings.status;
    final help = switch (settings.effectiveStatus()) {
      MyStatus.available => 'helpAvailable'.tr(),
      MyStatus.silent => 'helpSilent'.tr(),
      MyStatus.dnd => 'helpDnd'.tr(),
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text('tabTeam'.tr(), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ECard(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('yourStatus'.tr(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StatusRulesScreen())),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    settings.officeHours
                        ? '${'officeHoursOn'.tr()} · ${settings.officeStart}–${settings.officeEnd}'
                        : 'officeHoursOff'.tr(),
                    style: TextStyle(fontSize: 12, color: t.accent, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              for (final s in MyStatus.values)
                Expanded(
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(end: s == MyStatus.dnd ? 0 : 6),
                    child: _StatusButton(status: s, selected: status == s, onTap: () => settings.status = s),
                  ),
                ),
            ]),
            const SizedBox(height: 10),
            Text(help, style: TextStyle(fontSize: 12, color: t.text2)),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'searchTeam'.tr()),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Pill(label: 'colleagues'.tr(), selected: !_contacts, onTap: () => setState(() => _contacts = false)),
          const SizedBox(width: 8),
          Pill(label: 'phoneContacts'.tr(), selected: _contacts, onTap: () => setState(() => _contacts = true)),
          const Spacer(),
          if (!_contacts)
            RoundIcon(icon: Icons.person_add_alt, tooltip: 'addColleague'.tr(), size: 40, onTap: () => _addColleague(context)),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(child: _contacts ? _ContactsList(query: _q) : _ColleagueList(query: _q, sipPresence: sip.presence.length)),
    ]);
  }

  Future<void> _addColleague(BuildContext context) async {
    final name = TextEditingController();
    final ext = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('addColleague'.tr()),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: 'name'.tr())),
          const SizedBox(height: 10),
          TextField(controller: ext, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: 'extension'.tr())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('add'.tr())),
        ],
      ),
    );
    if (ok == true && ext.text.trim().isNotEmpty) {
      final s = ref.read(settingsProvider);
      s.watched = [...s.watched.where((w) => w.ext != ext.text.trim()), Watched(name: name.text.trim().isEmpty ? ext.text.trim() : name.text.trim(), ext: ext.text.trim())];
    }
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({required this.status, required this.selected, required this.onTap});
  final MyStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (label, color) = switch (status) {
      MyStatus.available => ('statusAvailable'.tr(), t.success),
      MyStatus.silent => ('statusSilent'.tr(), t.warn),
      MyStatus.dnd => ('statusDnd'.tr(), t.danger),
    };
    return Material(
      color: selected ? t.text : t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: selected ? t.text : t.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 42,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Dot(color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? t.bg : t.text)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ColleagueList extends ConsumerWidget {
  const _ColleagueList({required this.query, required this.sipPresence});
  final String query;
  final int sipPresence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final sip = ref.watch(sipProvider);
    final settings = ref.watch(settingsProvider);
    final list = settings.watched
        .where((w) => query.isEmpty || w.name.toLowerCase().contains(query) || w.ext.contains(query))
        .toList();
    if (settings.watched.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text('noColleagues'.tr(), textAlign: TextAlign.center, style: TextStyle(color: t.text2)),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Row(children: [
          Text('watched'.tr(namedArgs: {'n': '${settings.watched.length}'}),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: t.text2)),
          const Spacer(),
          Text('SUBSCRIBE presence', style: mono(context)),
        ]),
      ),
      ECard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) Divider(height: 1, color: t.border),
            _ColleagueRow(name: list[i].name, ext: list[i].ext, presence: sip.presence[list[i].ext]),
          ],
        ]),
      ),
    ]);
  }
}

class _ColleagueRow extends ConsumerWidget {
  const _ColleagueRow({required this.name, required this.ext, required this.presence});
  final String name, ext;
  final dynamic presence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.read(settingsProvider);
    final fav = settings.favourites.contains(ext);
    return InkWell(
      onLongPress: () async {
        final remove = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: Icon(fav ? Icons.star : Icons.star_border, color: t.warn),
                title: Text('favourites'.tr()),
                onTap: () => Navigator.pop(ctx, 'fav'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: t.danger),
                title: Text('removeColleague'.tr()),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            ]),
          ),
        );
        if (remove == 'remove') settings.watched = settings.watched.where((w) => w.ext != ext).toList();
        if (remove == 'fav') {
          final f = {...settings.favourites};
          fav ? f.remove(ext) : f.add(ext);
          settings.favourites = f;
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Avatar(name, size: 40, dot: presenceColor(t, presence)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                if (fav) ...[const SizedBox(width: 4), Icon(Icons.star, size: 14, color: t.warn)],
              ]),
              Text.rich(TextSpan(children: [
                TextSpan(text: ext, style: mono(context, size: 12)),
                TextSpan(text: ' · ${presenceText(presence)}', style: TextStyle(fontSize: 12, color: presenceColor(t, presence))),
              ])),
            ]),
          ),
          RoundIcon(
            icon: Icons.chat_bubble_outline,
            size: 40,
            tooltip: 'message'.tr(),
            color: t.accent,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: ext, title: name))),
          ),
          const SizedBox(width: 8),
          RoundIcon(
            icon: Icons.call,
            size: 40,
            tooltip: 'call'.tr(),
            bg: t.successSoft,
            color: t.success,
            onTap: () => placeCall(context, ref, ext, name: name),
          ),
        ]),
      ),
    );
  }
}

class _ContactsList extends ConsumerWidget {
  const _ContactsList({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final contacts = ref.watch(contactsProvider);
    if (!contacts.permitted) {
      return Center(
        child: SecondaryButton(label: 'allowContacts'.tr(), onPressed: () => contacts.load(ask: true)),
      );
    }
    final list = contacts.contacts
        .where((c) => query.isEmpty || c.name.toLowerCase().contains(query) || c.numbers.any((n) => n.contains(query)))
        .toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final c = list[i];
        final first = i == 0 || list[i - 1].name.characters.first.toUpperCase() != c.name.characters.first.toUpperCase();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (first && c.name.isNotEmpty) SectionLabel(c.name.characters.first.toUpperCase()),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Avatar(c.name, size: 40),
            title: Text(c.name),
            subtitle: Text(c.numbers.first, style: TextStyle(color: t.text2)),
            trailing: RoundIcon(
              icon: Icons.call,
              size: 40,
              tooltip: 'call'.tr(),
              bg: t.successSoft,
              color: t.success,
              onTap: () => placeCall(context, ref, c.numbers.first, name: c.name),
            ),
            onTap: c.numbers.length < 2
                ? null
                : () => showModalBottomSheet<void>(
                      context: context,
                      builder: (ctx) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final n in c.numbers)
                            ListTile(
                              leading: const Icon(Icons.call),
                              title: Text(n),
                              onTap: () {
                                Navigator.pop(ctx);
                                placeCall(context, ref, n, name: c.name);
                              },
                            ),
                        ]),
                      ),
                    ),
          ),
        ]);
      },
    );
  }
}

/// Office hours and who gets through on Do not disturb.
class StatusRulesScreen extends ConsumerWidget {
  const StatusRulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(settingsProvider);
    final days = s.officeDays;
    // Short weekday names, Sunday first (7 Jan 2024 was a Sunday).
    final names = List.generate(7, (i) => DateFormat.E(context.locale.languageCode).format(DateTime(2024, 1, 7 + i)));

    Future<void> pickTime(bool start) async {
      final cur = (start ? s.officeStart : s.officeEnd).split(':');
      final r = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: int.parse(cur[0]), minute: int.parse(cur[1])),
      );
      if (r == null) return;
      final v = '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}';
      start ? s.officeStart = v : s.officeEnd = v;
    }

    return Scaffold(
      appBar: AppBar(title: Text('statusRules'.tr())),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ECard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('followOfficeHours'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('followOfficeHoursSub'.tr()),
              value: s.officeHours,
              onChanged: (v) => s.officeHours = v,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              // DateTime.weekday: Monday = 1 … Sunday = 7; SHORTWEEKDAYS starts at Sunday.
              for (final d in [7, 1, 2, 3, 4, 5, 6])
                FilterChip(
                  label: Text(names[d % 7]),
                  selected: days.contains(d),
                  onSelected: (on) => s.officeDays = on ? [...days, d] : days.where((x) => x != d).toList(),
                  selectedColor: t.accentSoft,
                  checkmarkColor: t.accent,
                ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('hoursFrom'.tr()),
                  subtitle: Text(s.officeStart, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  onTap: () => pickTime(true),
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('hoursTo'.tr()),
                  subtitle: Text(s.officeEnd, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  onTap: () => pickTime(false),
                ),
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        ECard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('letThrough'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('favourites'.tr()),
              value: s.letFavourites,
              onChanged: (v) => s.letFavourites = v,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('repeatCallers'.tr()),
              value: s.letRepeat,
              onChanged: (v) => s.letRepeat = v,
            ),
          ]),
        ),
      ]),
    );
  }
}
