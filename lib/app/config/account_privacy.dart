import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';
import 'backend_modules.dart';

/// The account-privacy switch as built: `--dart-define=CRICECO_ACCOUNT_PRIVACY=true`
/// once migrations 13 (phone sharing consent), 14 (account deletion data),
/// 15 (club-owner protection) and 16 (club ownership transfer) are applied and the `delete-account` Edge Function is deployed
/// (docs/ACCOUNT_PRIVACY_AND_DELETION.md). OFF by default: before that, the
/// functions the app would call don't exist on the server.
const bool kAccountPrivacyBuild = bool.fromEnvironment('CRICECO_ACCOUNT_PRIVACY');

/// The account-privacy switch: [kAccountPrivacyBuild], overridden in tests.
final accountPrivacyEnabledProvider = Provider<bool>((ref) => kAccountPrivacyBuild);

/// Who decides whether club owners see the user's phone number.
enum PhoneSharingMode {
  /// The demo: a setting kept on this device (nothing is sent anywhere).
  device,

  /// Supabase with the switch: the user's consent, stored by the server and
  /// enforced by the club functions. Off until the user turns it on.
  server,

  /// Supabase without the switch (migration 13 not live): the owners of the
  /// clubs the user joins or applies to see the number. The app says so
  /// instead of offering a setting that would change nothing.
  ownersSee,
}

/// What this build can offer for phone privacy and account deletion.
class AccountControls {
  const AccountControls({required this.phoneSharing, required this.canDeleteAccount});

  factory AccountControls.of(BackendConfig config, {bool privacy = kAccountPrivacyBuild}) => !config.isSupabase
      ? const AccountControls(phoneSharing: PhoneSharingMode.device, canDeleteAccount: true)
      : privacy
      ? const AccountControls(phoneSharing: PhoneSharingMode.server, canDeleteAccount: true)
      : const AccountControls(phoneSharing: PhoneSharingMode.ownersSee, canDeleteAccount: false);

  final PhoneSharingMode phoneSharing;

  /// Settings → Delete Account works (demo, or the server side is deployed).
  final bool canDeleteAccount;
}

/// The build's [AccountControls], from [backendConfigProvider] and
/// [accountPrivacyEnabledProvider].
final accountControlsProvider = Provider<AccountControls>(
  (ref) => AccountControls.of(ref.watch(backendConfigProvider), privacy: ref.watch(accountPrivacyEnabledProvider)),
);

/// Club ownership transfer (migration 16) works in this build: Supabase with
/// club memberships and the account-privacy switch (it is deployed with the
/// account controls: an owner must hand the club over before deleting their
/// account). The demo has no other real accounts to accept an offer.
final ownershipTransferAvailableProvider = Provider<bool>(
  (ref) =>
      ref.watch(backendConfigProvider).isSupabase &&
      ref.watch(membershipsEnabledProvider) &&
      ref.watch(accountPrivacyEnabledProvider),
);
