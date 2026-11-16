import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// The email-codes switch as built: `--dart-define=CRICECO_EMAIL_CODES=true`
/// turns it on; without it (every normal build) it is OFF.
const bool kEmailCodesBuild = bool.fromEnvironment('CRICECO_EMAIL_CODES');

/// The Google switch (AUTH-05) as built: `--dart-define=CRICECO_GOOGLE_SIGN_IN=true`
/// once the Supabase Google provider is configured; OFF otherwise.
const bool kGoogleSignInBuild = bool.fromEnvironment('CRICECO_GOOGLE_SIGN_IN');

/// Which sign-in and password features this build offers. Screens ask this
/// instead of the backend mode.
///
/// Memory mode (the demo) keeps everything it has today. Supabase mode signs
/// in with email and password; phone sign-in and password change are not
/// configured there (D13), so they are hidden rather than shown and failing.
/// Its password reset (AUTH-04) needs the recovery email, so it follows the
/// email-codes switch; Google (AUTH-05) has its own switch, for a project
/// whose Google provider is set up.
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

  /// Supabase mode: email and password; reset with the email-codes switch,
  /// Google with its own.
  const AuthFeatures.emailOnly({
    this.emailCodes = false,
    this.googleSignIn = false,
  }) : phoneSignIn = false,
       passwordReset = emailCodes,
       passwordChange = false;

  factory AuthFeatures.of(
    BackendConfig config, {
    bool emailCodes = kEmailCodesBuild,
    bool google = kGoogleSignInBuild,
  }) => config.isSupabase
      ? AuthFeatures.emailOnly(emailCodes: emailCodes, googleSignIn: google)
      : AuthFeatures.all(emailCodes: emailCodes);

  /// Log in / sign up with a phone number. Off: email only.
  final bool phoneSignIn;

  /// "Continue with Google".
  final bool googleSignIn;

  /// "Forgot password?" (the reset-code sheet; Supabase: code or link, then
  /// Reset Password).
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

/// The Google switch: [kGoogleSignInBuild], overridden in tests.
final googleSignInEnabledProvider = Provider<bool>((ref) => kGoogleSignInBuild);

/// The build's auth features, derived from [backendConfigProvider],
/// [emailCodesEnabledProvider] and [googleSignInEnabledProvider].
final authFeaturesProvider = Provider<AuthFeatures>(
  (ref) => AuthFeatures.of(
    ref.watch(backendConfigProvider),
    emailCodes: ref.watch(emailCodesEnabledProvider),
    google: ref.watch(googleSignInEnabledProvider),
  ),
);
