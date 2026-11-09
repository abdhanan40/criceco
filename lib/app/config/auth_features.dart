import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// Which sign-in and password features this build offers. Screens ask this
/// instead of the backend mode.
///
/// Memory mode (the demo) keeps everything it has today. Supabase mode signs
/// in with email and password only: phone sign-in, Google sign-in and the
/// password reset / change flows are not configured there (D13), so they are
/// hidden rather than shown and failing.
class AuthFeatures {
  const AuthFeatures({
    required this.phoneSignIn,
    required this.googleSignIn,
    required this.passwordReset,
    required this.passwordChange,
  });

  /// Memory mode: phone (or email) sign-in, Google, reset and change.
  const AuthFeatures.all()
    : phoneSignIn = true,
      googleSignIn = true,
      passwordReset = true,
      passwordChange = true;

  /// Supabase mode: email and password only.
  const AuthFeatures.emailOnly()
    : phoneSignIn = false,
      googleSignIn = false,
      passwordReset = false,
      passwordChange = false;

  factory AuthFeatures.of(BackendConfig config) => config.isSupabase
      ? const AuthFeatures.emailOnly()
      : const AuthFeatures.all();

  /// Log in / sign up with a phone number. Off: email only.
  final bool phoneSignIn;

  /// "Continue with Google".
  final bool googleSignIn;

  /// "Forgot password?" (the reset-code sheet).
  final bool passwordReset;

  /// Settings → Password & security → Update Password.
  final bool passwordChange;
}

/// The build's auth features, derived from [backendConfigProvider].
final authFeaturesProvider = Provider<AuthFeatures>(
  (ref) => AuthFeatures.of(ref.watch(backendConfigProvider)),
);
