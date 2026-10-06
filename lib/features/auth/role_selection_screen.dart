import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
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

  /// Confirm, then clear the session and return to Login.
  Future<void> _logout() async {
    final ok = await showCeConfirmSheet(
      context,
      title: 'Log out?',
      body: 'You will be signed out of this account and returned to Login.',
      confirmLabel: 'Log out',
      destructive: true,
      icon: 'power',
    );
    if (!ok || !mounted) return;
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
        backgroundColor: CeColors.bg,
        body: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AuthBanner(
              title: 'Choose your role',
              subtitle: firstName.isEmpty
                  ? 'One CricEco account — pick how you want to start'
                  : 'Hi $firstName · one account, every role',
              stadiumPhoto: true,
              showLogo: false,
              // Compact logout, top-right: easy to find, out of the cards' way.
              trailing: AuthGlassButton(tooltip: 'Log out', icon: 'power', onPressed: _logout),
            ),
            AuthPanel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _RoleCard(
                  key: _playerKey,
                  icon: 'user',
                  title: 'Player',
                  body: 'Play matches, track performance, manage availability and view statistics.',
                  status: playerReady ? _CardStatus.ready : _CardStatus.expandable,
                  expanded: _playerOpen,
                  onTap: _tapPlayer,
                ),
                // The Player details open right under the Player card.
                AnimatedSize(
                  duration: CeMotion.slow,
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _playerOpen
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _PlayerDetails(showErrors: _showErrors, saving: _saving, onContinue: _continueAsPlayer),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                const SizedBox(height: 12),
                _RoleCard(
                  icon: 'shield',
                  title: 'Club Owner',
                  body: 'Create your club to manage teams, members, matches, tournaments and requests.',
                  status: clubReady ? _CardStatus.ready : _CardStatus.setup,
                  onTap: _tapClubOwner,
                ),
                const SizedBox(height: 14),
                const CeInfoNote(
                  margin: EdgeInsets.zero,
                  text: 'One account, no second login — you can set up the other role any time from the menu.',
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

enum _CardStatus { ready, expandable, setup }

/// Role card (reference role picker): radius 20, 1.5 px border, 44 px icon
/// well, Sora title. The Player card fills #12544F while its details are
/// open (selected), with the radio checked.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.status,
    required this.onTap,
    this.expanded = false,
  });

  final String icon;
  final String title;
  final String body;
  final _CardStatus status;
  final VoidCallback onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final on = expanded;
    final (tag, tagBg, tagFg) = switch (status) {
      _CardStatus.ready => ('Ready', CeColors.mint, CeColors.primaryDark),
      _CardStatus.setup => ('Club setup', CeColors.amberSoft, CeColors.amberInk),
      _CardStatus.expandable => (null, null, null),
    };
    final trailing = status == _CardStatus.expandable || on
        ? AnimatedContainer(
            duration: CeMotion.base,
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? CeColors.sage : Colors.transparent,
              border: Border.all(color: on ? CeColors.sage : CeColors.line2, width: 2),
            ),
            child: on ? Icon(CeIcons.of('check'), size: 12, color: CeColors.ink) : null,
          )
        : Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.muted2);

    return Semantics(
      button: true,
      expanded: status == _CardStatus.expandable ? expanded : null,
      label: '$title. $body${tag == null ? '' : ' $tag.'}',
      excludeSemantics: true,
      child: Material(
        color: on ? CeColors.primary : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.xl),
          side: BorderSide(color: on ? CeColors.primary : CeColors.line2, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedContainer(
                duration: CeMotion.base,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: on ? CeColors.primaryPressed : CeColors.mint,
                  borderRadius: BorderRadius.circular(CeRadius.input),
                ),
                child: Icon(CeIcons.of(icon), size: 21, color: on ? CeColors.sage : CeColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: CeType.cardTitle.copyWith(fontSize: 17, color: on ? Colors.white : CeColors.ink)),
                  const SizedBox(height: 4),
                  Text(body, style: CeType.bodySmall.copyWith(color: on ? CeColors.sage : CeColors.muted)),
                  if (tag != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: tagBg, borderRadius: BorderRadius.circular(CeRadius.xs)),
                      child: Text(tag.toUpperCase(), style: CeType.micro.copyWith(letterSpacing: 0.3, color: tagFg)),
                    ),
                  ],
                ]),
              ),
              const SizedBox(width: 10),
              trailing,
            ]),
          ),
        ),
      ),
    );
  }
}

/// The Player setup under the Player card (reference details card: white,
/// radius 20, option grids, the keeper switch row, then the CTA).
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

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.xl),
        border: Border.all(color: CeColors.line2, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CeFieldLabel('Playing Role', required: true),
        CeChoiceGroup<PlayerRole>(
          columns: 3,
          values: PlayerRole.values,
          selected: d.role,
          labelOf: (r) => r.label,
          onSelected: n.setRole,
        ),
        CeInlineError(err(d.role == null, 'Please select your playing role')),
        const SizedBox(height: 18),
        const CeFieldLabel('Batting Style', required: true),
        CeChoiceGroup<BattingStyle>(
          columns: 2,
          values: BattingStyle.values,
          selected: d.battingStyle,
          labelOf: (s) => s.label,
          onSelected: n.setBattingStyle,
        ),
        CeInlineError(err(d.battingStyle == null, 'Please select your batting style')),
        const SizedBox(height: 18),
        const CeFieldLabel('Bowling Style', required: true),
        CeChoiceGroup<BowlingStyle>(
          columns: 2,
          values: BowlingStyle.values,
          selected: d.bowlingStyle,
          labelOf: (s) => s.label,
          onSelected: n.setBowlingStyle,
        ),
        CeInlineError(err(d.bowlingStyle == null, 'Please select your bowling style')),
        const SizedBox(height: 18),
        // Optional, on top of the primary playing role (reference keeper row).
        Material(
          color: CeColors.bg,
          borderRadius: BorderRadius.circular(CeRadius.input),
          child: InkWell(
            borderRadius: BorderRadius.circular(CeRadius.input),
            onTap: () => n.setWicketkeeper(!d.isWicketkeeper),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Wicket Keeper', style: CeType.listTitle),
                    const SizedBox(height: 3),
                    Text('I can also keep wicket (optional)', style: CeType.bodySmall),
                  ]),
                ),
                const SizedBox(width: 12),
                CeSwitch(value: d.isWicketkeeper, onChanged: n.setWicketkeeper),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 18),
        CeButton(label: 'Continue as Player', loading: saving, onPressed: saving ? null : onContinue),
      ]),
    );
  }
}
