import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../player_providers.dart';
import '../screens/availability_screen.dart' show resolveUntil;

/// Player bottom nav → center status button: two quick switches on the one
/// availability record ([playerAvailabilityProvider]) — no separate system.
///  * Available This Week: ON ⇔ status Available. ON sets Available; OFF sets
///    Unavailable until this weekend ("This Weekend", as on Availability).
///    Limited / Injured / Other show as OFF with the detailed status named;
///    switching ON from them sets Available. Details stay on Availability.
///  * Open for Matches: the existing "open to offers" listing (also "Available
///    for Playing Opportunities" on Availability) — clubs see you in
///    Available Players while it is on.
/// Each switch saves at once and confirms inline.
Future<void> showPlayerStatusSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _PlayerStatusSheet());

class _PlayerStatusSheet extends ConsumerStatefulWidget {
  const _PlayerStatusSheet();

  @override
  ConsumerState<_PlayerStatusSheet> createState() => _PlayerStatusSheetState();
}

class _PlayerStatusSheetState extends ConsumerState<_PlayerStatusSheet> {
  String? _saved; // inline confirmation of the last change
  bool _listing = false;

  PlayerAvailabilityController get _availability => ref.read(playerAvailabilityProvider.notifier);

  void _setAvailable(bool on) {
    if (on) {
      _availability.update(status: PlayerAvailability.available);
    } else {
      final today = ref.read(clockProvider).now();
      _availability.update(
        status: PlayerAvailability.unavailable,
        until: AvailabilityUntil.weekend,
        untilDate: resolveUntil(AvailabilityUntil.weekend, today, null),
      );
    }
    setState(() => _saved = on ? 'You’re available this week' : 'Marked unavailable this week');
  }

  Future<void> _setOpen(bool on) async {
    setState(() => _listing = true);
    await _availability.setOpenToOffers(on);
    if (!mounted) return;
    setState(() {
      _listing = false;
      _saved = on ? 'You’re open for matches' : 'You’re no longer listed for matches';
    });
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(playerAvailabilityProvider);
    final available = record.status == PlayerAvailability.available;
    final detailed = record.status != PlayerAvailability.available && record.status != PlayerAvailability.unavailable;
    final availableNote = available
        ? 'Clubs can pick you this week'
        : detailed
            ? 'Currently: ${record.status.label}'
            : record.untilDate != null
                ? 'Unavailable until ${CeFormat.dayDate(record.untilDate!)}'
                : 'Not available right now';

    return Column(
      key: const Key('status.sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of('user-check'), size: 18, color: CeColors.primaryDark),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('Set Your Status', style: Theme.of(context).textTheme.titleLarge)),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(CeRadius.lg),
            border: Border.all(color: CeColors.line),
          ),
          child: Column(children: [
            _StatusSwitch(
              key: const Key('status.available'),
              icon: 'calendar-check',
              title: 'Available This Week',
              subtitle: availableNote,
              value: available,
              onChanged: _setAvailable,
            ),
            const Divider(height: 1, color: CeColors.hairline),
            _StatusSwitch(
              key: const Key('status.openForMatches'),
              icon: 'circle-dot',
              title: 'Open for Matches',
              subtitle: record.openToOffers
                  ? 'Clubs see you in Available Players'
                  : 'Turn on to be found for playing opportunities',
              value: record.openToOffers,
              onChanged: _listing ? null : _setOpen,
            ),
          ]),
        ),
        AnimatedSwitcher(
          duration: CeMotion.base,
          child: _saved == null
              ? const SizedBox(height: 12)
              : Padding(
                  key: ValueKey(_saved),
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(children: [
                    Icon(CeIcons.of('check-circle'), size: 14, color: CeColors.primaryDark),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Saved · $_saved',
                          key: const Key('status.saved'),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: CeColors.primaryDark)),
                    ),
                  ]),
                ),
        ),
      ],
    );
  }
}

/// A row with an icon, title, one line of state and a CricEco switch.
class _StatusSwitch extends StatelessWidget {
  const _StatusSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
                child: Icon(CeIcons.of(icon), size: 16, color: CeColors.primaryDark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.3)),
                ]),
              ),
              const SizedBox(width: 8),
              CeSwitch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      );
}
