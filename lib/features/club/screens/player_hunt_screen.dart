import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_form_widgets.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../hunt/player_hunt_controller.dart';

enum HuntTab {
  find('Find Players'),
  available('Available Players');

  const HuntTab(this.label);
  final String label;

  static HuntTab parse(String? raw) => values.where((t) => t.name == raw).firstOrNull ?? find;

  String get location => this == find ? Routes.playerHunt : '${Routes.playerHunt}?tab=$name';
}

/// Prototype `roleIcons` for Player Hunt roles.
String huntRoleIcon(HuntRole r) => switch (r) {
      HuntRole.batsman => 'circle-dot',
      HuntRole.bowler => 'radio',
      HuntRole.allRounder => 'footprints',
      HuntRole.wicketKeeper => 'hand',
    };

String _time(String hhmm) {
  final parts = hhmm.split(':');
  return CeFormat.time(DateTime(2000, 1, 1, int.parse(parts[0]), int.parse(parts[1])));
}

/// Open Players / Player Hunt (prototype `screens.openPlayers`, :7500).
/// Find Players and Available Players live in `?tab=`. The prototype's bottom
/// nav is dropped (club modules are drawer destinations, architecture §4).
class PlayerHuntScreen extends ConsumerWidget {
  const PlayerHuntScreen({super.key, this.tab = HuntTab.find});
  final HuntTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: const CeTopBar(title: 'Open Players', fallbackLocation: Routes.clubHome),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          CeChipRow<HuntTab>(
            values: HuntTab.values,
            selected: tab,
            labelOf: (t) => t.label,
            onSelected: (t) {
              if (t != tab) context.go(t.location);
            },
          ),
          if (tab == HuntTab.find) const _FindPlayersTab() else const _AvailablePlayersTab(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Find Players (prototype `renderPlayerHuntTab`)
// ---------------------------------------------------------------------------

class _FindPlayersTab extends ConsumerStatefulWidget {
  const _FindPlayersTab();

  @override
  ConsumerState<_FindPlayersTab> createState() => _FindPlayersTabState();
}

class _FindPlayersTabState extends ConsumerState<_FindPlayersTab> {
  String? _error;
  bool _posting = false;

  HuntDraftController get _draft => ref.read(huntDraftProvider.notifier);

  Future<void> _post() async {
    setState(() => _posting = true);
    final error = await ref.read(playerHuntProvider.notifier).publish(ref.read(huntDraftProvider));
    if (!mounted) return;
    setState(() {
      _posting = false;
      _error = error;
    });
    if (error != null) return;
    _draft.reset();
    showCeToast(context, 'Player requirement posted!');
  }

  Future<void> _pickLocation(HuntDraft d) async {
    final picked = await showCeActionSheet(context, title: 'Location', actions: [
      const CeSheetAction(icon: 'map-pin', label: 'All', id: ''),
      for (final c in kPakistanCities) CeSheetAction(icon: 'building-2', label: c, id: c),
    ]);
    if (picked == null) return;
    _draft.set(ref.read(huntDraftProvider).copyWith(location: () => picked.isEmpty ? null : picked));
  }

  Future<void> _pickBudget() async {
    final picked = await showCeActionSheet(context, title: 'Budget', actions: [
      for (final b in HuntBudget.values) CeSheetAction(icon: 'banknote', label: b.label, id: b.name),
    ]);
    if (picked == null) return;
    _draft.set(ref.read(huntDraftProvider).copyWith(budget: HuntBudget.values.byName(picked)));
  }

  Future<void> _pickDate(HuntDraft d) async {
    final today = CeFormat.dateOnly(ref.read(clockProvider).now());
    final picked = await showCeSheet<DateTime?>(
      context,
      builder: (ctx) => _DateSheet(today: today, selected: d.date),
    );
    if (picked == null) return;
    // A far-past sentinel means "Flexible" (clear).
    _draft.set(ref.read(huntDraftProvider).copyWith(date: () => picked.year < 2000 ? null : picked));
  }

  Future<void> _pickTime(HuntDraft d) async {
    final initial = d.time == null
        ? const TimeOfDay(hour: 14, minute: 0)
        : TimeOfDay(hour: int.parse(d.time!.split(':')[0]), minute: int.parse(d.time!.split(':')[1]));
    final picked = await showTimePicker(context: context, initialTime: initial, helpText: 'Match time');
    if (picked == null || !mounted) return;
    final hhmm = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    _draft.set(ref.read(huntDraftProvider).copyWith(time: () => hhmm));
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(huntDraftProvider);
    final mine = ref.watch(myHuntPostsProvider);
    Widget head(String t) => CeSectionHeader(t, padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 10));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // `.ph-info-banner`
      Container(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
        child: const Row(children: [
          CeIconWell('search', size: 36, iconSize: 17, background: Colors.white),
          SizedBox(width: 10),
          Expanded(
            child: Text('Post your requirement and get matched with available players.',
                style: TextStyle(fontSize: 12.5, color: CeColors.primaryDark, fontWeight: FontWeight.w600, height: 1.35)),
          ),
        ]),
      ),

      head('Role Needed'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: Column(children: [
          for (final pair in [
            [HuntRole.batsman, HuntRole.bowler],
            [HuntRole.allRounder, HuntRole.wicketKeeper],
          ]) ...[
            Row(children: [
              for (final (i, r) in pair.indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _RoleOption(
                    role: r,
                    selected: d.role == r,
                    onTap: () {
                      _draft.set(d.copyWith(role: r));
                      if (_error != null) setState(() => _error = null);
                    },
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 10),
          ],
        ]),
      ),
      if (_error != null)
        Padding(padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter), child: CeInlineError(_error)),

      head('Match Format'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: CeChoiceGroup<MatchFormat>(
          values: MatchFormat.hunt,
          selected: d.format,
          labelOf: (f) => f.label,
          onSelected: (f) => _draft.set(d.copyWith(format: f)),
        ),
      ),

      head('Players Needed'),
      CeCard(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(children: [
          const CeIconWell('users', size: 40, iconSize: 18, circle: true),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d.playersNeeded} Player${d.playersNeeded > 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const Text('How many players do you need?', style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
            ]),
          ),
          _RoundButton(
            icon: 'minus',
            tooltip: 'Fewer players',
            onTap: d.playersNeeded > PlayerHuntPost.minPlayers ? () => _draft.step(-1) : null,
          ),
          SizedBox(
            width: 32,
            child: Text('${d.playersNeeded}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink)),
          ),
          _RoundButton(
            icon: 'plus',
            tooltip: 'More players',
            onTap: d.playersNeeded < PlayerHuntPost.maxPlayers ? () => _draft.step(1) : null,
          ),
        ]),
      ),

      head('Additional Filters'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: Column(children: [
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: _FilterCard(icon: 'map-pin', label: 'Location', value: d.location ?? 'All', onTap: () => _pickLocation(d)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _FilterCard(
                  icon: 'calendar',
                  label: 'Date',
                  value: d.date == null ? 'Select' : CeFormat.dayMonth(d.date!),
                  onTap: () => _pickDate(d),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: _FilterCard(
                  icon: 'clock',
                  label: 'Time',
                  value: d.time == null ? 'Anytime' : _time(d.time!),
                  onTap: () => _pickTime(d),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _FilterCard(icon: 'banknote', label: 'Budget', value: d.budget.label, onTap: _pickBudget)),
            ]),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
        child: CeButton(label: 'Post Player Requirement', loading: _posting, onPressed: _posting ? null : _post),
      ),

      if (mine.isNotEmpty) ...[
        head('Your Published Slots · ${mine.length}'),
        for (final p in mine) _PublishedSlot(post: p),
      ],
    ]);
  }
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({required this.role, required this.selected, required this.onTap});
  final HuntRole role;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: role.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? CeColors.mint : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CeRadius.row),
            side: BorderSide(color: selected ? CeColors.primary : CeColors.line, width: selected ? 1.6 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.row),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 78),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Stack(children: [
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of(huntRoleIcon(role)),
                        size: 22, color: selected ? CeColors.primary : CeColors.primaryDark),
                    const SizedBox(height: 6),
                    Text(role.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: selected ? CeColors.primaryDark : CeColors.ink2)),
                  ]),
                ),
                if (selected)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle),
                      child: Icon(CeIcons.of('check'), size: 12, color: Colors.white),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap});
  final String icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: CeColors.mint,
          disabledBackgroundColor: CeColors.historySoft,
          minimumSize: const Size(CeSize.touchTarget, CeSize.touchTarget),
        ),
        icon: Icon(CeIcons.of(icon), size: 17, color: onTap == null ? CeColors.muted2 : CeColors.primaryDark),
      );
}

/// `.ph-filter-card`
class _FilterCard extends StatelessWidget {
  const _FilterCard({required this.icon, required this.label, required this.value, required this.onTap});
  final String icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '$label, $value',
        excludeSemantics: true,
        child: CeCard(
          padding: const EdgeInsets.all(12),
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CeIconWell(icon, size: 30, iconSize: 15),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 11, color: CeColors.muted)),
            const SizedBox(height: 2),
            Row(children: [
              Expanded(
                child: Text(value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
              ),
              Icon(CeIcons.of('chevron-down'), size: 14, color: CeColors.muted),
            ]),
          ]),
        ),
      );
}

class _DateSheet extends StatefulWidget {
  const _DateSheet({required this.today, required this.selected});
  final DateTime today;
  final DateTime? selected;

  @override
  State<_DateSheet> createState() => _DateSheetState();
}

class _DateSheetState extends State<_DateSheet> {
  late DateTime _month = widget.selected ?? widget.today;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Date', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        CeMonthCalendar(
          visibleMonth: _month,
          today: widget.today,
          selected: widget.selected,
          isEnabled: (d) => !d.isBefore(widget.today),
          onMonthChanged: (m) => setState(() => _month = m),
          onSelected: (d) => Navigator.of(context).pop(d),
        ),
        const SizedBox(height: 12),
        CeButton.soft(label: 'Flexible date', onPressed: () => Navigator.of(context).pop(DateTime(1900))),
      ]);
}

/// `.ph-slot-card`
class _PublishedSlot extends ConsumerWidget {
  const _PublishedSlot({required this.post});
  final PlayerHuntPost post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = post;
    Widget detail(String icon, String value) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CeIcons.of(icon), size: 13, color: CeColors.muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink)),
          ),
        ]);
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CeIconWell(huntRoleIcon(p.role), size: 40, iconSize: 18),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Looking for ${p.playersNeeded} ${p.role.countLabel(p.playersNeeded)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text('${p.format.label} · ${p.location ?? 'Any location'}',
                  style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
          const SizedBox(width: 8),
          const CeStatusChip('Open'),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 6, children: [
          detail('calendar', p.date == null ? 'Flexible' : CeFormat.dayMonth(p.date!)),
          detail('clock', p.time == null ? 'Anytime' : _time(p.time!)),
          detail('banknote', p.budget == HuntBudget.any ? 'Any budget' : p.budget.label),
        ]),
        const SizedBox(height: 12),
        CeButton.danger(
          label: 'Remove Slot',
          onPressed: () async {
            await ref.read(playerHuntProvider.notifier).remove(p.id);
            if (context.mounted) showCeToast(context, 'Slot removed');
          },
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Available Players (prototype `renderAvailablePlayersTab` / `renderPlayerList`)
// ---------------------------------------------------------------------------

class _AvailablePlayersTab extends ConsumerWidget {
  const _AvailablePlayersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(openPlayersProvider);
    final cities = ref.watch(openPlayerCitiesProvider);
    final city = ref.watch(openPlayersCityProvider);
    final role = ref.watch(openPlayersRoleProvider);
    final invited = ref.watch(invitedPlayersProvider);
    final players = [
      for (final p in async.value ?? const <OpenPlayer>[])
        if (p.city == city && p.role == role) p,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(0, 6, 0, 14),
          child: Text('Players who are free and available for matches',
              style: TextStyle(fontSize: 12, color: CeColors.muted)),
        ),
        const CeFieldLabel('City'),
        CeSelectField<String>(
          fieldKey: const Key('hunt.city'),
          items: cities,
          value: cities.contains(city) ? city : null,
          labelOf: (c) => c,
          onChanged: ref.read(openPlayersCityProvider.notifier).select,
          sheetTitle: 'City',
          hint: 'Select City',
          icon: 'map-pin',
          itemIcon: 'building-2',
        ),
        const CeFieldLabel('Role'),
        CeSelectField<HuntRole>(
          fieldKey: const Key('hunt.role'),
          items: HuntRole.values,
          value: role,
          labelOf: (r) => r.label,
          onChanged: ref.read(openPlayersRoleProvider.notifier).select,
          sheetTitle: 'Role',
          hint: 'Select Role',
          icon: 'target',
          itemIcon: 'user',
        ),
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
        else if (city == null || role == null)
          const CeEmptyState(
            icon: 'circle-dot',
            title: 'Choose a city and role',
            body: 'Select both above to browse available players.',
          )
        else if (players.isEmpty)
          CeEmptyState(
            icon: 'circle-dot',
            title: 'No ${role.label} available',
            body: 'No players in $city have listed themselves as available for this role right now.',
          )
        else
          for (final p in players)
            _OpenPlayerRow(
              player: p,
              invited: invited.contains(p.id),
              onInvite: () {
                if (ref.read(invitedPlayersProvider.notifier).invite(p.id)) {
                  showCeToast(context, 'Invite sent to ${p.name}');
                }
              },
            ),
      ]),
    );
  }
}

class _OpenPlayerRow extends StatelessWidget {
  const _OpenPlayerRow({required this.player, required this.invited, required this.onInvite});
  final OpenPlayer player;
  final bool invited;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final p = player;
    return CeCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(children: [
        CeAvatar(p.name, size: 42, background: CeColors.primary, foreground: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
              ),
              if (p.isMe) ...[const SizedBox(width: 6), const CeStatusChip('You')],
            ]),
            const SizedBox(height: 2),
            Text('${p.role.label} · ${p.availabilityLabel}', style: const TextStyle(fontSize: 12, color: CeColors.muted)),
          ]),
        ),
        if (!p.isMe) ...[
          const SizedBox(width: 8),
          invited
              ? const CeStatusChip('Invited', icon: 'check')
              : FilledButton(
                  onPressed: onInvite,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, CeSize.touchTarget),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  child: const Text('Invite'),
                ),
        ],
      ]),
    );
  }
}
