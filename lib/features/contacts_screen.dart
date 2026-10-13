import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medut/medut.dart' show PresenceStatus;

import '../core/contacts.dart';
import '../core/db.dart';
import '../core/people.dart';
import '../core/providers.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../ui/widgets.dart';
import 'chat.dart';
import 'dialer.dart';
import 'keypad_sheets.dart';
import 'status.dart';

/// Pocket · Contacts: your status, favourites, the extensions on the phone
/// system with their presence (learned from calls and contacts, so nobody has
/// to know one), then the phone's contacts A–Z.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final contacts = ref.watch(contactsProvider);
    final db = ref.watch(dbProvider);
    final q = _search.text.trim();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 12, 10),
        child: Row(children: [
          Expanded(
            child: Text('tabContacts'.tr(), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
          ),
          RoundIcon(icon: Icons.add, size: 40, tooltip: 'addExtension'.tr(), onTap: () => _addExtension(context)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'searchContacts'.tr(),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'close'.tr(),
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
      ),
      Expanded(
        child: FutureBuilder<List<CallRecord>>(
          future: db.calls(),
          builder: (context, snap) {
            final book = _AddressBook(settings: settings, contacts: contacts, history: snap.data ?? const []);
            // Who can take a call first; most recent first within each group.
            final order = sip.presenceList;
            final system = [
              for (final n in order)
                if (q.isEmpty || matchesQuery(q, [n, book.nameOf(n)])) n,
            ]..sort((a, b) {
                final byPresence = _presenceRank(sip.presence[a]).compareTo(_presenceRank(sip.presence[b]));
                return byPresence != 0 ? byPresence : order.indexOf(a).compareTo(order.indexOf(b));
              });
            final favourites = q.isEmpty ? settings.favourites.toList() : const <String>[];
            final phone = q.isEmpty
                ? contacts.contacts
                : contacts.contacts.where((c) => matchesQuery(q, [c.name, ...c.numbers])).toList();
            final nothing = q.isNotEmpty && system.isEmpty && phone.isEmpty;

            return CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (q.isEmpty) const _YouLine(),
                  if (favourites.isNotEmpty)
                    SizedBox(
                      height: 86,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          for (final n in favourites)
                            _Favourite(
                              name: book.nameOf(n),
                              number: n,
                              presence: isExtension(n) ? sip.presence[n] : null,
                              onTap: () => placeCall(context, ref, n, name: book.nameOf(n)),
                              onLongPress: () => showPersonSheet(context, number: n),
                            ),
                        ],
                      ),
                    ),
                  if (q.isEmpty || system.isNotEmpty) _Section('onPhoneSystem'.tr()),
                  if (system.isEmpty && q.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                      child: Text('phoneSystemHelp'.tr(), style: TextStyle(fontSize: 12.5, color: t.text2, height: 1.4)),
                    ),
                  for (final n in system)
                    _PersonRow(
                      name: book.nameOf(n),
                      number: n,
                      presence: sip.presence[n],
                      fromCalls: !book.isKnown(n),
                      onTap: () => showPersonSheet(context, number: n),
                    ),
                  if (!contacts.permitted && q.isEmpty) _AllowContacts(onAllow: () => contacts.load(ask: true)),
                  if (nothing)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('noMatches'.tr(), textAlign: TextAlign.center, style: TextStyle(color: t.text2)),
                    ),
                ]),
              ),
              SliverList.builder(
                itemCount: phone.length,
                itemBuilder: (context, i) {
                  final c = phone[i];
                  final letter = c.name.isEmpty ? '#' : c.name.characters.first.toUpperCase();
                  final first = i == 0 || (phone[i - 1].name.isEmpty ? '#' : phone[i - 1].name.characters.first.toUpperCase()) != letter;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (first)
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 20, 0),
                        child: Text(letter, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: t.accent)),
                      ),
                    _PersonRow(
                      name: c.name,
                      number: c.numbers.first,
                      subtitle: c.numbers.length > 1 ? 'nNumbers'.plural(c.numbers.length) : c.numbers.first,
                      onTap: () => showPersonSheet(context, number: c.numbers.first, numbers: c.numbers, name: c.name),
                      onCall: c.numbers.length > 1
                          ? () => showPersonSheet(context, number: c.numbers.first, numbers: c.numbers, name: c.name)
                          : null,
                    ),
                  ]);
                },
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
            ]);
          },
        ),
      ),
    ]);
  }

  Future<void> _addExtension(BuildContext context) async {
    final name = TextEditingController();
    final ext = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('addExtension'.tr()),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: 'name'.tr())),
          const SizedBox(height: 10),
          TextField(
            controller: ext,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: 'extension'.tr(), helperText: 'extensionHelp'.tr()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('cancel'.tr())),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('add'.tr())),
        ],
      ),
    );
    if (ok != true) return;
    final number = ext.text.replaceAll(RegExp(r'\D'), '');
    if (!isExtension(number)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('notExtension'.tr())));
      }
      return;
    }
    final s = ref.read(settingsProvider);
    s.watched = [
      ...s.watched.where((w) => w.ext != number),
      Watched(name: name.text.trim().isEmpty ? number : name.text.trim(), ext: number),
    ];
    s.hiddenExts = s.hiddenExts.difference({number});
  }
}

/// Names for numbers: a hand-added name, then the phone's contacts, then the
/// name the last call carried.
class _AddressBook {
  _AddressBook({required this.settings, required this.contacts, required this.history});
  final AppSettings settings;
  final ContactsService contacts;
  final List<CallRecord> history;

  String nameOf(String number) {
    for (final w in settings.watched) {
      if (w.ext == number) return w.name;
    }
    final c = contacts.nameFor(number);
    if (c.isNotEmpty) return c;
    for (final r in history) {
      if (r.number == number && r.name.isNotEmpty) return r.name;
    }
    return '';
  }

  /// In the phone's contacts or added by hand, rather than only seen in calls.
  bool isKnown(String number) => settings.watched.any((w) => w.ext == number) || contacts.nameFor(number).isNotEmpty;
}

int _presenceRank(PresenceStatus? p) => switch (p) {
      PresenceStatus.open => 0,
      PresenceStatus.busy => 1,
      PresenceStatus.closed => 3,
      _ => 2,
    };

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 20, 2),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: context.t.text2)),
      );
}

/// You, your status and office hours, in one line; opens the status sheet.
class _YouLine extends ConsumerWidget {
  const _YouLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final def = ref.watch(accountsProvider).defaultAccount;
    final me = def == null ? '?' : (def.displayName.isNotEmpty ? def.displayName : def.user);
    final status = settings.effectiveStatus();
    final color = statusColor(t, status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: t.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showMeSheet(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(children: [
              Avatar(me, size: 38, dot: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('you'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(officeHoursText(settings), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.text2)),
                ]),
              ),
              const StatusPill(),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Office hours on · 09:00–17:00", or off.
String officeHoursText(AppSettings s) =>
    s.officeHours ? '${'officeHoursOn'.tr()} · ${s.officeStart}–${s.officeEnd}' : 'officeHoursOff'.tr();

class _Favourite extends StatelessWidget {
  const _Favourite({required this.name, required this.number, required this.presence, required this.onTap, required this.onLongPress});
  final String name, number;
  final PresenceStatus? presence;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final label = name.isNotEmpty ? name.split(' ').first : number;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 66,
        child: Column(children: [
          const SizedBox(height: 4),
          Avatar(name.isNotEmpty ? name : number, size: 52, dot: presence == null ? null : presenceColor(t, presence)),
          const SizedBox(height: 5),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// A person: avatar (with presence for an extension), name, number or status,
/// message and call.
class _PersonRow extends ConsumerWidget {
  const _PersonRow({
    required this.name,
    required this.number,
    required this.onTap,
    this.presence,
    this.subtitle,
    this.fromCalls = false,
    this.onCall,
  });

  final String name, number;
  final PresenceStatus? presence;
  final String? subtitle;
  final bool fromCalls;
  final VoidCallback onTap;

  /// Instead of calling [number] straight away (a contact with two numbers).
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final ext = subtitle == null && isExtension(number);
    final title = name.isNotEmpty ? name : number;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 8, 6),
        child: Row(children: [
          Avatar(title, size: 42, dot: ext ? presenceColor(t, presence) : null),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                if (fromCalls) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(6)),
                    child: Text('fromCalls'.tr(), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: t.text2)),
                  ),
                ],
              ]),
              ext
                  ? Text.rich(
                      TextSpan(children: [
                        TextSpan(text: name.isNotEmpty ? '$number · ' : '', style: TextStyle(color: t.text2)),
                        TextSpan(
                          text: presenceText(presence),
                          style: TextStyle(color: presenceColor(t, presence), fontWeight: FontWeight.w600),
                        ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    )
                  : Text(subtitle ?? number, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: t.text2)),
            ]),
          ),
          if (ext)
            IconButton(
              tooltip: 'message'.tr(),
              icon: Icon(Icons.chat_bubble_outline, size: 19, color: t.text2),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peer: number, title: title))),
            ),
          IconButton(
            tooltip: 'call'.tr(),
            icon: Icon(Icons.call_outlined, size: 21, color: t.accent),
            onPressed: onCall ?? () => placeCall(context, ref, number, name: name),
          ),
        ]),
      ),
    );
  }
}

class _AllowContacts extends StatelessWidget {
  const _AllowContacts({required this.onAllow});
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ECard(
        padding: const EdgeInsets.all(18),
        child: Column(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: t.accentSoft, shape: BoxShape.circle),
            child: Icon(Icons.contacts_outlined, color: t.accent),
          ),
          const SizedBox(height: 10),
          Text('phoneContactsTitle'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('allowContactsSub'.tr(), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.text2, height: 1.4)),
          const SizedBox(height: 12),
          PrimaryButton(label: 'allowContacts'.tr(), onPressed: onAllow),
        ]),
      ),
    );
  }
}

/// Call, message, favourite; save an extension seen in calls to the phone's
/// contacts, or hide it; remove one added by hand.
Future<void> showPersonSheet(BuildContext context, {required String number, List<String>? numbers, String? name}) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _PersonSheet(number: number, numbers: numbers ?? [number], name: name),
    );

class _PersonSheet extends ConsumerWidget {
  const _PersonSheet({required this.number, required this.numbers, this.name});
  final String number;
  final List<String> numbers;
  final String? name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(settingsProvider);
    final sip = ref.watch(sipProvider);
    final contacts = ref.watch(contactsProvider);
    final nav = Navigator.of(context);
    final watched = settings.watched.where((w) => w.ext == number).firstOrNull;
    final inContacts = contacts.nameFor(number).isNotEmpty;
    final display = name ?? watched?.name ?? (inContacts ? contacts.nameFor(number) : sip.nameFor(number));
    final title = display.isNotEmpty ? display : number;
    final ext = isExtension(number);
    final presence = ext ? sip.presence[number] : null;
    final fav = settings.favourites.contains(number);

    Widget option(IconData icon, String label, {String? sub, Color? color, Widget? trailing, VoidCallback? onTap}) => ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: onTap,
          leading: Icon(icon, color: color ?? t.text2),
          title: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          subtitle: sub == null ? null : Text(sub, style: TextStyle(fontSize: 12.5, color: t.text2)),
          trailing: trailing,
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(width: 38, height: 5, decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(3))),
        ),
        const SizedBox(height: 14),
        Center(child: Avatar(title, size: 72, dot: ext ? presenceColor(t, presence) : null)),
        const SizedBox(height: 10),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: number, style: TextStyle(color: t.text2)),
            if (ext)
              TextSpan(
                text: ' · ${presenceText(presence)}',
                style: TextStyle(color: presenceColor(t, presence), fontWeight: FontWeight.w600),
              ),
          ]),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: PrimaryButton(
              label: 'call'.tr(),
              onPressed: () {
                nav.pop();
                placeCall(context, ref, number, name: display);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SecondaryButton(
              label: 'message'.tr(),
              onPressed: () {
                nav.pop();
                nav.push(MaterialPageRoute(builder: (_) => ChatScreen(peer: number, title: title)));
              },
            ),
          ),
        ]),
        if (numbers.length > 1) ...[
          const SizedBox(height: 8),
          for (final n in numbers)
            option(Icons.call_outlined, n, color: null, onTap: () {
              nav.pop();
              placeCall(context, ref, n, name: display);
            }),
        ],
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(fav ? Icons.star : Icons.star_border, color: fav ? t.warn : t.text2),
          title: Text('favourite'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('favouriteSub'.tr(), style: TextStyle(fontSize: 12.5, color: t.text2)),
          value: fav,
          onChanged: (on) => settings.favourites = on ? {...settings.favourites, number} : settings.favourites.difference({number}),
        ),
        if (ext && !inContacts && watched == null)
          option(Icons.person_add_alt, 'saveToContacts'.tr(), sub: 'saveToContactsSub'.tr(namedArgs: {'n': number}), onTap: () async {
            nav.pop();
            await FlutterContacts.openExternalInsert(Contact(phones: [Phone(number)]));
            await contacts.load();
          }),
        if (watched != null)
          option(Icons.delete_outline, 'removeColleague'.tr(), color: t.danger, onTap: () {
            nav.pop();
            settings.watched = settings.watched.where((w) => w.ext != number).toList();
          })
        else if (ext && !inContacts)
          option(Icons.visibility_off_outlined, 'hideFromContacts'.tr(), color: t.danger, onTap: () {
            nav.pop();
            settings.hiddenExts = {...settings.hiddenExts, number};
            settings.favourites = settings.favourites.difference({number});
          }),
      ]),
    );
  }
}

/// One of Available / Silent / Do not disturb, with its colour dot.
class StatusButton extends StatelessWidget {
  const StatusButton({super.key, required this.status, required this.selected, required this.onTap});
  final MyStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final (label, color) = switch (status) {
      MyStatus.available => ('statusAvailable'.tr(), t.info),
      MyStatus.ready => ('statusReady'.tr(), t.success),
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
