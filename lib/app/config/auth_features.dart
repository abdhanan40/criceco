import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// The email-codes switch as built: `--dart-define=CRICECO_EMAIL_CODES=true`
/// turns it on; without it (every normal build) it is OFF.
const bool kEmailCodesBuild = bool.fromEnvironment('CRICECO_EMAIL_CODES');

/// Which sign-in and password features this build offers. Screens ask this
/// instead of the backend mode.
///
/// Memory mode (the demo) keeps everything it has today. Supabase mode signs
/// in with email and password only: phone sign-in, Google sign-in and the
/// password reset / change flows are not configured there (D13), so they are
/// hidden rather than shown and failing.
///
/// [emailCodes] (AUTH-02, both modes, OFF by default): an email sign-up that
/// needs its address confirmed is verified with a 6-digit code in the app.
class AuthFeatures {
  const AuthFeatures({
    required this.phoneSignIn,
    required this.googleSignIn,
    required this.passwordReset,
    required this.passwordChange,
    this.emailCodes = false,
  });

  /// Memory mode: phone (or email) sign-in, Google, reset and change.
  const AuthFeatures.all({this.emailCodes = false})
    : phoneSignIn = true,
      googleSignIn = true,
      passwordReset = true,
      passwordChange = true;

  /// Supabase mode: email and password only.
  const AuthFeatures.emailOnly({this.emailCodes = false})
    : phoneSignIn = false,
      googleSignIn = false,
      passwordReset = false,
      passwordChange = false;

  factory AuthFeatures.of(
    BackendConfig config, {
    bool emailCodes = kEmailCodesBuild,
  }) => config.isSupabase
      ? AuthFeatures.emailOnly(emailCodes: emailCodes)
      : AuthFeatures.all(emailCodes: emailCodes);

  /// Log in / sign up with a phone number. Off: email only.
  final bool phoneSignIn;

  /// "Continue with Google".
  final bool googleSignIn;

  /// "Forgot password?" (the reset-code sheet).
  final bool passwordReset;

  /// Settings → Password & security → Update Password.
  final bool passwordChange;

  /// Sign-up email verification with a 6-digit code (AUTH-02). The backend
  /// still decides whether a code is needed: with email confirmation off it
  /// signs the user in at once and no code is asked for.
  final bool emailCodes;
}

/// The email-codes switch: [kEmailCodesBuild], overridden in tests.
final emailCodesEnabledProvider = Provider<bool>((ref) => kEmailCodesBuild);

/// The build's auth features, derived from [backendConfigProvider] and
/// [emailCodesEnabledProvider].
final authFeaturesProvider = Provider<AuthFeatures>(
  (ref) => AuthFeatures.of(
    ref.watch(backendConfigProvider),
    emailCodes: ref.watch(emailCodesEnabledProvider),
  ),
);
