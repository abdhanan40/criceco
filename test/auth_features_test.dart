import 'package:criceco/app/config/auth_features.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/session/account_error_text.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2 Step 5a: auth features by backend mode, and the error text the
/// auth and onboarding screens show.
void main() {
  final supabase = BackendConfig.parse(
    backend: 'supabase',
    supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
    supabasePublishableKey: 'sb_publishable_test_0000000000000000',
  );

  ({bool phone, bool google, bool reset, bool change}) flags(AuthFeatures f) =>
      (
        phone: f.phoneSignIn,
        google: f.googleSignIn,
        reset: f.passwordReset,
        change: f.passwordChange,
      );

  group('AuthFeatures', () {
    test('memory mode keeps every existing feature', () {
      expect(flags(AuthFeatures.of(const BackendConfig.memory())), (
        phone: true,
        google: true,
        reset: true,
        change: true,
      ));
    });

    test('supabase mode: email and password only', () {
      expect(flags(AuthFeatures.of(supabase)), (
        phone: false,
        google: false,
        reset: false,
        change: false,
      ));
    });

    test('the provider follows the backend config (default: memory)', () {
      final memory = ProviderContainer();
      addTearDown(memory.dispose);
      expect(flags(memory.read(authFeaturesProvider)).phone, isTrue);

      final remote = ProviderContainer(
        overrides: [backendConfigProvider.overrideWithValue(supabase)],
      );
      addTearDown(remote.dispose);
      expect(flags(remote.read(authFeaturesProvider)), (
        phone: false,
        google: false,
        reset: false,
        change: false,
      ));
    });
  });

  group('accountErrorText', () {
    const fallback = "Couldn't save — please try again";

    test('every AccountException shows its own message', () {
      final cases = <AccountException, String>{
        const NotSignedInException(): 'Please sign in again',
        const AccountMismatchException():
            'This account is not the one signed in — please sign in again',
        const BackendUnavailableException():
            "Couldn't reach the server — check your connection and try again",
        const EmailConfirmationRequiredException():
            'Check your email to confirm your account, then sign in',
        const UnsupportedSignInMethodException():
            'Please use your email address',
        const BackendOperationException():
            'Something went wrong — please try again',
        const PermissionDeniedException():
            "You don't have permission to do that",
        const ClubJoinUnavailableException():
            'Joining a club by code is coming soon',
      };
      for (final MapEntry(key: e, value: text) in cases.entries) {
        expect(accountErrorText(e, fallback: fallback), text, reason: '$e');
      }
    });

    test('profile rule and weak-password messages are shown', () {
      expect(
        accountErrorText(
          const ProfileValidationException(
            'An account with this email already exists — please log in',
          ),
          fallback: fallback,
        ),
        'An account with this email already exists — please log in',
      );
      expect(
        accountErrorText(
          const WeakPasswordException('Add a number (0–9)'),
          fallback: fallback,
        ),
        'Add a number (0–9)',
      );
    });

    test('anything else gets the fallback — raw text never passes', () {
      for (final e in <Object>[
        StateError('unknown account id 1234'),
        UnsupportedError('password reset is not supported'),
        Exception('PostgrestException(message: relation "profiles" ...)'),
        const FormatException('Unexpected character'),
        'a bare string',
      ]) {
        expect(accountErrorText(e, fallback: fallback), fallback, reason: '$e');
      }
    });
  });

  group('needsSignIn', () {
    test('only for a missing or different signed-in user', () {
      expect(needsSignIn(const NotSignedInException()), isTrue);
      expect(needsSignIn(const AccountMismatchException()), isTrue);
      for (final e in <Object>[
        const BackendUnavailableException(),
        const EmailConfirmationRequiredException(),
        const UnsupportedSignInMethodException(),
        const BackendOperationException(),
        const PermissionDeniedException(), // M1: an RLS refusal keeps the session
        const ClubJoinUnavailableException(),
        const ProfileValidationException('Full name is required'),
        StateError('x'),
      ]) {
        expect(needsSignIn(e), isFalse, reason: '$e');
      }
    });
  });
}
