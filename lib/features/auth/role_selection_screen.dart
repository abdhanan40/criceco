import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_rows.dart';
import '../../shared/widgets/ce_surfaces.dart';
import 'onboarding_controller.dart';
import 'widgets/auth_widgets.dart';

/// Role Selection — one CricEco account, two ways to use it.
///
/// * **Player**: the card expands in place (progressive disclosure) with
///   Playing Role, Batting Style, Bowling Style and an optional Wicket Keeper
///   switch; Continue saves the Player profile and enters the Player Dashboard.
///   Role Selection + Player details are one interaction — no extra screens.
/// * **Club Owner**: opens the dedicated Club Setup Details screen.
///
/// A role that is already set up shows "Ready" and enters its dashboard
/// directly (this screen also replaces the old Continue As chooser).
/// System Back collapses the expanded Player card first.
class RoleSelectionScreen extends ConsumerStatefulWidget {
  const RoleSelectionScreen({super.key, this.expandPlayer = false});

  /// Open with the Player details expanded (legacy Playing Style links).
  final bool expandPlayer;

  @override
  ConsumerState<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends ConsumerState<RoleSelectionScreen> {
  late bool _playerOpen = widget.expandPlayer;
  final _playerKey = GlobalKey();
  bool _showErrors = false;
  bool _saving = false;

  @override
  void didUpdateWidget(covariant RoleSelectionScreen old) {
    super.didUpdateWidget(old);
    // Same page, new `?expand=player` (e.g. a legacy Playing Style link).
    if (widget.expandPlayer && !old.expandPlayer && !_playerOpen) setState(() => _playerOpen = true);
  }

  bool get _playerReady => ref.read(currentAccountProvider)?.playerProfile.isComplete ?? false;

  void _tapPlayer() {
    if (_playerReady && !_playerOpen) {
      _enter(UserRole.player);
      return;
    }
    setState(() => _playerOpen = !_playerOpen);
    if (_playerOpen) {
      // Bring the revealed fields into view once they have laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _playerKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: CeMotion.slow, curve: Curves.easeOut, alignment: 0.05);
      });
    }
  }

  void _tapClubOwner() {
    switch (ref.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner)) {
      // Pushed, so Back from Club Setup Details returns here.
      case NeedsClubSetup(:final location):
        context.push(location);
      case GoToLocation(:final location):
        context.go(location);
    }
  }

  void _enter(UserRole role) {
    switch (ref.read(roleControllerProvider.notifier).continueAs(role)) {
      case NeedsClubSetup(:final location):
      case GoToLocation(:final location):
        context.go(location);
    }
  }

  Future<void> _continueAsPlayer() async {
    final d = ref.read(onboardingProvider);
    if (d.role == null || d.battingStyle == null || d.bowlingStyle == null) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() => _saving = true);
    await ref.read(onboardingProvider.notifier).completePlayerSetup();
    if (!mounted) return;
    // `go` replaces the stack: Back from the dashboard never reopens onboarding.
    context.go(Routes.playerHome);
  }

  void _logout() {
    ref.read(sessionProvider.notifier).logout();
    context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final account = session.account;
    final playerReady = account?.playerProfile.isComplete ?? false;
    final clubReady = session.hasClubOwnerProfile;
    final firstName = (account?.fullName ?? '').trim().split(' ').first;

    return PopScope(
      canPop: !_playerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _playerOpen) setState(() => _playerOpen = false);
      },
      child: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            AuthBanner(
              title: 'Choose your role',
              subtitle: firstName.isEmpty
                  ? 'One CricEco account — pick how you want to start'
                  : 'Hi $firstName · one account, every role',
              bottomPadding: 26,
            ),
            Padding(
              padding: const EdgeInsets.all(CeSpace.gutter),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _RoleCard(
                  key: _playerKey,
                  icon: 'user',
                  title: 'Player',
                  body: 'Play matches, track performance, manage availability and view statistics.',
                  status: playerReady ? _CardStatus.ready : _CardStatus.expandable,
                  expanded: _playerOpen,
                  onTap: _tapPlayer,
                  details: _playerOpen
                      ? _PlayerDetails(showErrors: _showErrors, saving: _saving, onContinue: _continueAsPlayer)
                      : null,
                ),
                const SizedBox(height: 12),
                _RoleCard(
                  icon: 'shield',
                  title: 'Club Owner',
                  body: 'Create your club to manage teams, members, matches, tournaments and requests.',
                  status: clubReady ? _CardStatus.ready : _CardStatus.setup,
                  onTap: _tapClubOwner,
                ),
                const SizedBox(height: 12),
                const CeInfoNote(
                  margin: EdgeInsets.zero,
                  text: 'One account, no second login — you can set up the other role any time from the menu.',
                ),
                const SizedBox(height: 8),
                CeSwitchLine(prompt: 'Not you?', action: 'Log out', onTap: _logout),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

enum _CardStatus { ready, expandable, setup }

/// Role card: a tappable header (icon, title, description, status) and —
/// for the Player — the details revealed underneath. Only the header is the
/// tap target, so taps inside the revealed form never collapse it.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.status,
    required this.onTap,
    this.expanded = false,
    this.details,
  });

  final String icon;
  final String title;
  final String body;
  final _CardStatus status;
  final VoidCallback onTap;
  final bool expanded;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final (tag, tagBg, tagFg) = switch (status) {
      _CardStatus.ready => ('Ready', CeColors.mint, CeColors.primaryDark),
      _CardStatus.setup => ('Club setup', CeColors.amberSoft, CeColors.amberInk),
      _CardStatus.expandable => (null, null, null),
    };
    final trailing = status == _CardStatus.expandable || expanded
        ? AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: CeMotion.base,
            child: Icon(CeIcons.of('chevron-down'), size: 18, color: expanded ? CeColors.primary : CeColors.muted2),
          )
        : Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2);

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(CeRadius.lg), boxShadow: CeShadows.card),
      child: Material(
        color: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.lg),
          side: BorderSide(color: expanded ? CeColors.primary : CeColors.line, width: expanded ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            button: true,
            expanded: status == _CardStatus.expandable ? expanded : null,
            label: '$title. $body${tag == null ? '' : ' $tag.'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  CeIconWell(icon, size: 44, iconSize: 21),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                      const SizedBox(height: 3),
                      Text(body,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.45, color: CeColors.muted)),
                      if (tag != null) ...[
                        const SizedBox(height: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(color: tagBg, borderRadius: BorderRadius.circular(CeRadius.pill)),
                          child: Text(tag.toUpperCase(),
                              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: tagFg)),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 8),
                  trailing,
                ]),
              ),
            ),
          ),
          AnimatedSize(
            duration: CeMotion.slow,
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: details == null
                ? const SizedBox(width: double.infinity)
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Divider(height: 1, color: CeColors.line),
                    Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 16), child: details),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// The Player setup revealed inside the Player card.
class _PlayerDetails extends ConsumerWidget {
  const _PlayerDetails({required this.showErrors, required this.saving, required this.onContinue});
  final bool showErrors;
  final bool saving;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(onboardingProvider);
    final n = ref.read(onboardingProvider.notifier);
    String? err(bool missing, String message) => showErrors && missing ? message : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const CeFieldLabel('Playing Role', required: true),
      CeChoiceGroup<PlayerRole>(
        values: PlayerRole.values,
        selected: d.role,
        labelOf: (r) => r.label,
        onSelected: n.setRole,
      ),
      CeInlineError(err(d.role == null, 'Please select your playing role')),
      const SizedBox(height: 14),
      const CeFieldLabel('Batting Style', required: true),
      CeChoiceGroup<BattingStyle>(
        values: BattingStyle.values,
        selected: d.battingStyle,
        labelOf: (s) => s.label,
        onSelected: n.setBattingStyle,
      ),
      CeInlineError(err(d.battingStyle == null, 'Please select your batting style')),
      const SizedBox(height: 14),
      const CeFieldLabel('Bowling Style', required: true),
      CeChoiceGroup<BowlingStyle>(
        values: BowlingStyle.values,
        selected: d.bowlingStyle,
        labelOf: (s) => s.label,
        onSelected: n.setBowlingStyle,
      ),
      CeInlineError(err(d.bowlingStyle == null, 'Please select your bowling style')),
      const SizedBox(height: 10),
      // Optional, on top of the primary playing role.
      CeToggleRow(
        icon: 'hand',
        title: 'Wicket Keeper',
        subtitle: 'I can also keep wicket (optional)',
        value: d.isWicketkeeper,
        showDivider: false,
        onChanged: n.setWicketkeeper,
      ),
      const SizedBox(height: 12),
      CeButton(label: 'Continue as Player', loading: saving, onPressed: saving ? null : onContinue),
    ]);
  }
}
