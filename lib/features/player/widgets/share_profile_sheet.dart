import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../shared/media/photo_picker.dart';
import '../../../shared/media/share_service.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../player_providers.dart';

/// Share Profile (Player Dashboard quick action): a compact player card from
/// the player's own data, and one button that hands a text summary (plus the
/// profile picture, when set) to the device share sheet. Read-only — editing
/// stays on My Profile.
Future<void> showShareProfileSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _ShareProfileSheet());

/// The player card as plain text (what is shared). Only fields the player
/// actually has are included; nothing is made up.
String playerCardText({
  required UserAccount account,
  String? clubName,
  PerformanceSummary? performance,
}) {
  final p = account.playerProfile;
  final lines = <String>[
    '${account.fullName} — CricEco Player',
    if (p.role != null) 'Role: ${p.role!.label}${p.isWicketkeeper ? ' · Wicket Keeper' : ''}',
    if (p.role == null && p.isWicketkeeper) 'Wicket Keeper',
    if (p.battingStyle != null) 'Batting: ${p.battingStyle!.label}',
    if (p.bowlingStyle != null) 'Bowling: ${p.bowlingStyle!.label}',
    if (clubName != null) 'Club: $clubName',
    if (account.city != null) 'City: ${account.city}',
    if (performance != null)
      'Rating ${performance.rating} · ${performance.matches} matches · ${performance.runs} runs · ${performance.wickets} wickets',
  ];
  return lines.join('\n');
}

class _ShareProfileSheet extends ConsumerStatefulWidget {
  const _ShareProfileSheet();

  @override
  ConsumerState<_ShareProfileSheet> createState() => _ShareProfileSheetState();
}

class _ShareProfileSheetState extends ConsumerState<_ShareProfileSheet> {
  bool _sharing = false;

  Future<void> _share(String text, String? imagePath) async {
    setState(() => _sharing = true);
    var ok = false;
    try {
      ok = await ref.read(shareServiceProvider).share(text: text, subject: 'My CricEco player profile', imagePath: imagePath);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _sharing = false);
    if (!ok) showCeToast(context, 'Sharing isn’t available on this device right now.');
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    if (account == null) return const SizedBox.shrink();
    // The club the player belongs to: a joined club, else the club they own
    // (and play in). None → no club line (the dashboard's KRC001 is a
    // placeholder, not the player's club).
    final membership = account.memberships.firstOrNull;
    final clubName = membership != null
        ? membership.clubName
        : ref.watch(currentClubProvider)?.name;
    final perf = ref.watch(performanceProvider).value;
    final p = account.playerProfile;
    final text = playerCardText(account: account, clubName: clubName, performance: perf);

    Widget detail(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5, color: CeColors.muted))),
            const SizedBox(width: 12),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
            ),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Share Profile', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      // ---- Player card ----
      Container(
        key: const Key('shareProfile.card'),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            decoration: const BoxDecoration(gradient: CeColors.brandGradient),
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              CePhotoImage(
                path: account.photoPath,
                size: 52,
                fallback: Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.2),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2),
                  ),
                  child: Text(account.initial,
                      style: const TextStyle(fontFamily: CeType.display, fontSize: 21, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(account.fullName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: CeType.display, fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                  if (p.role != null || p.isWicketkeeper)
                    Text(
                      [if (p.role != null) p.role!.label, if (p.isWicketkeeper) 'Wicket Keeper'].join(' · '),
                      style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)),
                    ),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Column(children: [
              if (p.battingStyle != null) detail('Batting', p.battingStyle!.label),
              if (p.bowlingStyle != null) detail('Bowling', p.bowlingStyle!.label),
              if (clubName != null) detail('Club', clubName),
              if (account.city != null) detail('City', account.city!),
              if (perf != null) ...[
                detail('Rating', perf.rating),
                detail('Matches · Runs · Wickets', '${perf.matches} · ${perf.runs} · ${perf.wickets}'),
              ],
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Close', onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            label: 'Share Profile',
            icon: CeIcons.of('share-2'),
            loading: _sharing,
            onPressed: _sharing ? null : () => _share(text, account.photoPath),
          ),
        ),
      ]),
    ]);
  }
}
