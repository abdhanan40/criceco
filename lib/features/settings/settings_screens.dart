import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/config/demo_mode.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_rows.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';

/// Back target when Settings has nothing to pop to: the active role's home.
String _roleHome(WidgetRef ref) {
  final role = ref.read(activeRoleProvider);
  return role == null ? Routes.continueAs : Routes.home(role);
}

// ---------------------------------------------------------------------------
// Settings (prototype `screens.settings`, :8126): shared and role-aware.
// ---------------------------------------------------------------------------

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// "Account" stays inside the active role (prototype `ceGoAccount`):
  /// Player → My Profile, Club Owner → My Club.
  static String accountLocation(UserRole role) => role == UserRole.player ? Routes.playerProfile : Routes.myClub;

  Future<void> _chooseProfile(BuildContext context, WidgetRef ref, UserRole current) async {
    final hasClub = ref.read(sessionProvider).hasClubOwnerProfile;
    final picked = await showCeActionSheet(context, title: 'Active profile', actions: [
      CeSheetAction(
        icon: current == UserRole.player ? 'check-circle' : 'user',
        label: current == UserRole.player ? 'Player Profile (active)' : 'Switch to Player profile',
        id: UserRole.player.name,
      ),
      CeSheetAction(
        icon: current == UserRole.clubOwner ? 'check-circle' : (hasClub ? 'shield' : 'plus'),
        label: current == UserRole.clubOwner
            ? 'Club Owner (active)'
            : (hasClub ? 'Switch to Club Owner' : 'Set up Club Owner profile'),
        id: UserRole.clubOwner.name,
      ),
    ]);
    if (picked == null || !context.mounted) return;
    final role = UserRole.values.byName(picked);
    if (role == current) return;
    // The same switch as the drawer row: the stack is replaced, so Back
    // can't undo it.
    switch (ref.read(roleControllerProvider.notifier).switchTo(role)) {
      case NeedsClubSetup(:final location):
        context.go(location);
      case GoToLocation(:final location):
        context.go(location);
        showCeToast(context, 'Switched to ${role.label}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(activeRoleProvider);
    final demo = ref.watch(demoModeProvider);
    final canToggleDemo = ref.read(demoModeProvider.notifier).canToggle;
    return Scaffold(
      appBar: CeTopBar(title: 'Settings', fallbackLocation: _roleHome(ref)),
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        const CeSectionHeader('Account'),
        CeGroupCard(children: [
          CeSettingsRow(
            icon: 'user',
            title: 'Account',
            subtitle: 'Name, phone and personal details',
            onTap: role == null ? null : () => context.go(accountLocation(role)),
          ),
          CeSettingsRow(
            icon: 'repeat',
            title: 'Active profile',
            subtitle: role?.label ?? 'Not chosen',
            showDivider: false,
            onTap: role == null ? () => context.go(Routes.continueAs) : () => _chooseProfile(context, ref, role),
          ),
        ]),
        const CeSectionHeader('Preferences'),
        CeGroupCard(children: [
          // P15: opens the inbox (no separate preferences screen exists).
          CeSettingsRow(
            icon: 'bell',
            title: 'Notifications',
            subtitle: 'Match, club and booking alerts',
            onTap: () => context.push(Routes.notifications),
          ),
          CeSettingsRow(
            icon: 'lock',
            title: 'Privacy',
            subtitle: 'Who can see your profile and stats',
            onTap: () => context.go(Routes.privacySettings),
          ),
          CeSettingsRow(
            icon: 'key',
            title: 'Password & security',
            subtitle: 'Change password, sign-in alerts',
            showDivider: false,
            onTap: () => context.go(Routes.securitySettings),
          ),
        ]),
        // P25: the Demo Mode switch exists only in a demo build.
        if (canToggleDemo) ...[
          const CeSectionHeader('Prototype controls'),
          CeGroupCard(children: [
            CeToggleRow(
              icon: 'flask-conical',
              title: 'Demo Mode',
              subtitle: demo ? 'Simulation controls are shown' : 'Simulation controls are hidden',
              value: demo,
              showDivider: false,
              onChanged: (v) {
                ref.read(demoModeProvider.notifier).set(v);
                showCeToast(context, v ? 'Demo Mode on' : 'Demo Mode off');
              },
            ),
          ]),
          const CeInfoNote(
            margin: EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
            icon: 'info',
            text: 'Demo Mode simulates the other side of the app: instant challenge replies, the opponent\'s '
                'payment, organizer decisions and match results. With it off, those wait for real responses.',
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 22, CeSpace.gutter, 0),
          child: CeButton.danger(
            label: 'Log out',
            onPressed: () {
              ref.read(sessionProvider.notifier).logout();
              context.go(Routes.login);
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text('CricEco v1.0 · Made for Pakistan Cricket',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: CeColors.muted2)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Privacy (prototype `screens.privacySettings`, :8198): account preferences.
// ---------------------------------------------------------------------------

class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(currentAccountProvider.select((a) => a?.settings)) ?? const AccountSettings();
    final session = ref.read(sessionProvider.notifier);
    return Scaffold(
      appBar: const CeTopBar(title: 'Privacy', fallbackLocation: Routes.settings),
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        const CeSectionHeader('Visibility'),
        CeGroupCard(children: [
          CeToggleRow(
            icon: 'eye',
            title: 'Public profile',
            subtitle: 'Clubs can find you in Player Hunt',
            value: s.publicProfile,
            onChanged: (v) => session.updateSettings((x) => x.copyWith(publicProfile: v)),
          ),
          CeToggleRow(
            icon: 'bar-chart',
            title: 'Show my stats',
            subtitle: 'Owners can view your performance',
            value: s.showStats,
            onChanged: (v) => session.updateSettings((x) => x.copyWith(showStats: v)),
          ),
          CeToggleRow(
            icon: 'phone',
            title: 'Show phone number',
            subtitle: 'Visible to your club members only',
            value: s.showPhone,
            showDivider: false,
            onChanged: (v) => session.updateSettings((x) => x.copyWith(showPhone: v)),
          ),
        ]),
        CeInfoNote(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          icon: s.publicProfile ? 'eye' : 'eye-off',
          text: s.publicProfile
              ? 'When you list yourself as available, clubs see you under Player Hunt → Available Players.'
              : 'Hidden: clubs won\'t see you under Player Hunt → Available Players, even when you\'re available.',
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Password & security (prototype `screens.securitySettings`, :8207).
// ---------------------------------------------------------------------------

/// Prototype hint: "At least 8 characters".
const kNewPasswordMinLength = 8;

String? validateNewPassword(String? v, String current) {
  if (v == null || v.isEmpty) return 'Enter a new password';
  if (v.length < kNewPasswordMinLength) return 'Use at least $kNewPasswordMinLength characters';
  if (v == current) return 'Choose a password different from the current one';
  return null;
}

class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends ConsumerState<SecuritySettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  String? _currentError;
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    FocusScope.of(context).unfocus();
    setState(() => _currentError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await ref.read(sessionProvider.notifier).changePassword(current: _current.text, next: _next.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      setState(() => _currentError = 'Current password is incorrect');
      return;
    }
    // Prototype `ceSaved`: the destination + a toast, never a toast alone.
    showCeToast(context, 'Password updated');
    context.go(Routes.settings);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(currentAccountProvider.select((a) => a?.settings)) ?? const AccountSettings();
    final session = ref.read(sessionProvider.notifier);
    return Scaffold(
      appBar: const CeTopBar(title: 'Password & security', fallbackLocation: Routes.settings),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(bottom: 28 + MediaQuery.viewInsetsOf(context).bottom),
        children: [
          const CeSectionHeader('Password'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const CeFieldLabel('Current password'),
                CeTextField(
                  fieldKey: const Key('security.current'),
                  controller: _current,
                  hint: 'Enter current password',
                  icon: 'lock',
                  obscure: true,
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password' : null,
                  onChanged: (_) {
                    if (_currentError != null) setState(() => _currentError = null);
                  },
                ),
                if (_currentError != null)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: CeInlineError(_currentError)),
                const CeFieldLabel('New password'),
                CeTextField(
                  fieldKey: const Key('security.new'),
                  controller: _next,
                  hint: 'At least $kNewPasswordMinLength characters',
                  icon: 'key',
                  obscure: true,
                  textInputAction: TextInputAction.done,
                  validator: (v) => validateNewPassword(v, _current.text),
                  onFieldSubmitted: (_) => _update(),
                ),
                if (s.passwordChangedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('Last changed ${CeFormat.date(s.passwordChangedAt!)}',
                        style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                  ),
                CeButton(label: 'Update Password', loading: _saving, onPressed: _saving ? null : _update),
              ]),
            ),
          ),
          const CeSectionHeader('Sign-in'),
          CeGroupCard(children: [
            CeToggleRow(
              icon: 'shield',
              title: 'Two-step verification',
              subtitle: 'SMS code on new devices',
              value: s.twoStep,
              onChanged: (v) => session.updateSettings((x) => x.copyWith(twoStep: v)),
            ),
            CeToggleRow(
              icon: 'bell',
              title: 'Login alerts',
              subtitle: 'Notify me of new sign-ins',
              value: s.loginAlerts,
              showDivider: false,
              onChanged: (v) => session.updateSettings((x) => x.copyWith(loginAlerts: v)),
            ),
          ]),
        ],
      ),
    );
  }
}
