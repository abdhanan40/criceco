import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_widgets.dart';

String _initials(String name) =>
    name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).take(2).join();

/// Opponent Club Profile (prototype `screens.clubProfile`, :6073), keyed by
/// club id (the prototype used a global abbreviation).
///
/// The pinned bottom area is the one place a challenge with this club is
/// acted on: a pending incoming challenge shows Decline / Accept, a resolved
/// one shows its status, and otherwise the CTA starts a new one ("Challenge
/// This Club", or "Send Match Request" when opened from Find Opponent).
class ClubProfileScreen extends ConsumerStatefulWidget {
  const ClubProfileScreen({super.key, required this.clubId, this.challengeId, this.fromFind = false});
  final String clubId;

  /// The challenge this profile was opened from (My Challenges), if any.
  final String? challengeId;

  /// Opened from Find Opponent: the CTA reads "Send Match Request".
  final bool fromFind;

  @override
  ConsumerState<ClubProfileScreen> createState() => _ClubProfileScreenState();
}

class _ClubProfileScreenState extends ConsumerState<ClubProfileScreen> {
  bool _busy = false;

  /// A challenge answered on this screen: keeps showing its status afterwards.
  String? _answeredId;

  Future<void> _respond(Challenge challenge, {required bool accept}) async {
    if (_busy) return;
    await respondToChallenge(context, ref, challenge,
        accept: accept,
        onResponding: () => setState(() {
              _busy = true;
              _answeredId = challenge.id;
            }));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final dirAsync = ref.watch(clubDirectoryProvider);
    final c = dirAsync.value?[widget.clubId];
    const bar = CeTopBar(title: 'Club Profile', fallbackLocation: Routes.challenges);
    if (dirAsync.isLoading) return const Scaffold(appBar: bar, body: Center(child: CircularProgressIndicator()));
    if (c == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'shield',
          title: 'Club not found',
          body: 'This club is no longer available.',
          primaryLabel: 'Back to Challenges',
          onPrimary: () => context.go(Routes.challenges),
        ),
      );
    }
    final waiting = ref.watch(pendingSentClubIdsProvider).contains(c.id);
    final now = ref.read(clockProvider).now();
    // The challenge in focus: the one this profile was opened from (or just
    // answered here); failing that, a pending incoming challenge from this
    // club — so it is answered rather than crossed with a new one.
    final focusId = _answeredId ?? widget.challengeId;
    final linked = focusId == null ? null : ref.watch(challengeProvider(focusId));
    final challenge = linked != null && linked.opponentClubId == c.id
        ? linked
        : ref.watch(myChallengeSectionsProvider).awaitingDecision.where((x) => x.opponentClubId == c.id).firstOrNull;

    Widget stat(String n, String l, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
            child: Column(children: [
              Text(n, style: TextStyle(fontFamily: CeType.display, fontSize: 19, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(height: 2),
              Text(l, style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
            ]),
          ),
        );

    // Missing owner / coach: say so plainly rather than guess a name.
    Widget person(String? name) => name == null || name.trim().isEmpty
        ? CeSummaryCard.value(context, 'Not listed', color: CeColors.muted)
        : CeSummaryCard.value(context, name.trim());

    final Widget action;
    if (challenge != null && challenge.direction == ChallengeDirection.received) {
      action = challenge.statusAt(now) == ChallengeStatus.pending
          ? _IncomingChallengeActions(
              challenge: challenge,
              busy: _busy,
              onDecline: () => _respond(challenge, accept: false),
              onAccept: () => _respond(challenge, accept: true),
            )
          : _ChallengeStatusLine(challenge: challenge, status: challenge.statusAt(now));
    } else if (challenge != null && challenge.statusAt(now) != ChallengeStatus.pending) {
      action = _ChallengeStatusLine(challenge: challenge, status: challenge.statusAt(now));
    } else if (waiting) {
      action = CeButton.soft(label: 'Challenge Sent', icon: CeIcons.of('hourglass'));
    } else {
      action = CeButton(
        label: widget.fromFind ? 'Send Match Request' : 'Challenge This Club',
        icon: CeIcons.of('swords'),
        loading: _busy,
        onPressed: _busy
            ? null
            : () async {
                await sendChallenge(context, ref, c,
                    matchRequest: widget.fromFind, onSending: () => setState(() => _busy = true));
                if (mounted) setState(() => _busy = false);
              },
      );
    }

    return Scaffold(
      appBar: bar,
      // Pinned, so the decision / CTA is in reach without scrolling the profile.
      bottomNavigationBar: Container(
        key: const Key('clubProfile.actions'),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: CeColors.line))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 10),
            // Column(min): a full-width button must not stretch the bar's height.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [action],
            ),
          ),
        ),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 20), children: [
        // ---- Identity, form, win rate ----
        CeCard(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(CeRadius.lg),
                  border: Border.all(color: c.color.withValues(alpha: 0.4), width: 1.5),
                ),
                child: Text(c.abbr, style: TextStyle(fontFamily: CeType.display, fontSize: 17, fontWeight: FontWeight.w700, color: c.color)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.name, style: const TextStyle(fontFamily: CeType.display, fontSize: 16, fontWeight: FontWeight.w700, color: CeColors.ink)),
                  const SizedBox(height: 2),
                  Text(c.meta, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                  Text('Est. ${c.established} · Squad of ${c.squadSize}',
                      style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            const Text('Recent Form', style: TextStyle(fontSize: 12, color: CeColors.muted)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: CeFormDots(c.recentForm, size: 24)),
            const SizedBox(height: 16),
            Row(children: [
              const Expanded(child: Text('Win Rate', style: TextStyle(fontSize: 12, color: CeColors.muted))),
              Text('${c.winRate}%', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
            ]),
            const SizedBox(height: 6),
            Semantics(
              label: 'Win rate ${c.winRate} percent',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: c.winRate / 100,
                  minHeight: 7,
                  backgroundColor: CeColors.mint2,
                  color: CeColors.primaryDark,
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          child: Row(children: [
            stat('${c.wins}', 'Wins', CeColors.primaryDark),
            const SizedBox(width: 10),
            stat('${c.losses}', 'Losses', CeColors.red),
            const SizedBox(width: 10),
            stat('${c.played}', 'Played', CeColors.ink),
          ]),
        ),

        // ---- Owner / coach (names only, never contact details) ----
        const CeSectionHeader('Club Management'),
        CeSummaryCard(rows: [
          ('Club Owner', person(c.ownerName)),
          ('Club Coach', person(c.coachName)),
        ]),
        const CeSectionHeader('Match Preferences'),
        CeSummaryCard(rows: [
          ('Formats', CeSummaryCard.value(context, c.formats)),
          ('Home Ground', CeSummaryCard.value(context, c.homeGround)),
          ('City', CeSummaryCard.value(context, c.city)),
          ('Level', CeSummaryCard.value(context, c.level)),
        ]),

        // ---- Captain ----
        const CeSectionHeader('Club Captain'),
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Row(children: [
            CircleAvatar(
              radius: 21,
              backgroundColor: c.color,
              child: Text(_initials(c.captain.name),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.captain.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text('Captain · ${c.name}', style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                Text(c.captain.phone, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
            Icon(CeIcons.of('shield'), size: 18, color: CeColors.primaryDark),
          ]),
        ),

        // ---- Key players ----
        CeSectionHeader('Key Players · Squad of ${c.squadSize}'),
        for (final p in c.keyPlayers)
          Container(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(CeRadius.row),
              border: Border.all(color: CeColors.line),
            ),
            child: Row(children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: CeColors.line,
                child: Text(_initials(p.name),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  Text(p.position, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                ]),
              ),
              if (p.isCaptain) const CeStatusChip('Captain', tone: CeTone.amber),
            ]),
          ),
      ]),
    );
  }
}

String _challengeLine(Challenge c) => [
      if (c.format != null) c.format!.display(),
      if (c.proposedAt != null) CeFormat.dayDate(c.proposedAt!),
      if (c.groundName != null) c.groundName!,
    ].join(' · ');

/// A pending incoming challenge from this club: Decline / Accept (each
/// confirmed before anything changes).
class _IncomingChallengeActions extends StatelessWidget {
  const _IncomingChallengeActions({
    required this.challenge,
    required this.busy,
    required this.onDecline,
    required this.onAccept,
  });
  final Challenge challenge;
  final bool busy;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final line = _challengeLine(challenge);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(CeIcons.of('swords'), size: 13, color: CeColors.amberInk),
        const SizedBox(width: 6),
        Expanded(
          child: Text(line.isEmpty ? 'This club has challenged you' : 'Challenge received · $line',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CeColors.amberInk)),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: CeButton.danger(label: 'Decline', onPressed: busy ? null : onDecline)),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(label: 'Accept', icon: CeIcons.of('check'), loading: busy, onPressed: busy ? null : onAccept),
        ),
      ]),
    ]);
  }
}

/// A challenge that is no longer open: its status, no actions.
class _ChallengeStatusLine extends StatelessWidget {
  const _ChallengeStatusLine({required this.challenge, required this.status});
  final Challenge challenge;
  final ChallengeStatus status;

  @override
  Widget build(BuildContext context) {
    final received = challenge.direction == ChallengeDirection.received;
    final text = switch (status) {
      ChallengeStatus.accepted => received ? 'You accepted this challenge' : 'Your challenge was accepted',
      ChallengeStatus.declined => received ? 'You declined this challenge' : 'Your challenge was declined',
      ChallengeStatus.expired => 'This challenge has expired',
      ChallengeStatus.pending => 'Awaiting a reply',
    };
    final line = _challengeLine(challenge);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
          if (line.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ],
        ]),
      ),
      const SizedBox(width: 10),
      challengeStatusChip(status, challenge.direction),
    ]);
  }
}
