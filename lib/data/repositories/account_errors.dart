/// Backend-neutral account errors. Repositories throw these (and
/// [ProfileValidationException] from `profile_rules.dart`); screens can show
/// [message], which is short and user-facing.
sealed class AccountException implements Exception {
  const AccountException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The operation needs a signed-in user and there is none.
class NotSignedInException extends AccountException {
  const NotSignedInException() : super('Please sign in again');
}

/// The account being saved is not the signed-in user's account.
class AccountMismatchException extends AccountException {
  const AccountMismatchException()
    : super('This account is not the one signed in — please sign in again');
}

/// The backend refused the operation for the signed-in user (a row-level
/// security or privilege refusal, `42501`). The session is still valid, so
/// this never signs the user out.
class PermissionDeniedException extends AccountException {
  const PermissionDeniedException()
    : super("You don't have permission to do that");
}

/// The backend could not be reached (offline, timeout, server down).
class BackendUnavailableException extends AccountException {
  const BackendUnavailableException()
    : super("Couldn't reach the server — check your connection and try again");
}

/// Sign-up succeeded, but the email address must be confirmed before the
/// user can sign in. [demoCode]: the demo's sign-up code (AUTH-02, nothing
/// is sent there); `null` on a real backend.
class EmailConfirmationRequiredException extends AccountException {
  const EmailConfirmationRequiredException({this.demoCode})
    : super('Check your email to confirm your account, then sign in');

  final String? demoCode;
}

/// A sign-up verification code that is wrong, expired or already used
/// (AUTH-02). One message for all three: the backend doesn't tell them
/// apart.
class InvalidVerificationCodeException extends AccountException {
  const InvalidVerificationCodeException()
    : super(
        'That code is incorrect or has expired — check it or request a new one',
      );
}

/// The sign-up code was accepted — the email address is confirmed — but the
/// account couldn't be read straight after (AUTH-02D: offline, a server
/// hiccup). Nothing is signed in; the user logs in with email and password.
class EmailConfirmedSignInRequiredException extends AccountException {
  const EmailConfirmedSignInRequiredException()
    : super(
        'Your email is confirmed, but we couldn’t sign you in just now — '
        'please log in with your email and password',
      );
}

/// Too many attempts or emails in a short time (rate limited).
class TooManyRequestsException extends AccountException {
  const TooManyRequestsException()
    : super('Too many attempts — please wait a moment and try again');
}

/// Reset password (AUTH-04): the new password is the current one.
class SamePasswordException extends AccountException {
  const SamePasswordException()
    : super('Choose a password you haven’t used for this account');
}

/// Reset password (AUTH-04): the recovery session is gone (it expired, was
/// cancelled or already used), so the password can't be set.
class RecoverySessionMissingException extends AccountException {
  const RecoverySessionMissingException()
    : super('This reset has expired — request a new code and try again');
}

/// Google sign-in (AUTH-05) couldn't be started (no browser to open).
class GoogleSignInUnavailableException extends AccountException {
  const GoogleSignInUnavailableException()
    : super('Couldn’t open Google sign-in — please try again');
}

/// The backend does not support this way of signing in or up (e.g. phone
/// numbers while only email is enabled).
class UnsupportedSignInMethodException extends AccountException {
  const UnsupportedSignInMethodException()
    : super('Please use your email address');
}

/// Joining a club by its code isn't available on this backend yet (Supabase
/// mode, until Phase 3E) — never a simulated request.
class ClubJoinUnavailableException extends AccountException {
  const ClubJoinUnavailableException()
    : super('Joining a club by code is coming soon');
}

/// The signed-in user has no profile row (`P0002 profile not found`, from
/// `update_profile_details()`): nothing was saved. The session itself is
/// valid, so this doesn't sign the user out.
class ProfileNotFoundException extends AccountException {
  const ProfileNotFoundException()
    : super("Your profile couldn't be loaded — please sign in again");
}

/// Anything else the backend reported. The raw backend text is never shown.
class BackendOperationException extends AccountException {
  const BackendOperationException()
    : super('Something went wrong — please try again');
}
