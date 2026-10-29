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

/// The backend could not be reached (offline, timeout, server down).
class BackendUnavailableException extends AccountException {
  const BackendUnavailableException()
    : super("Couldn't reach the server — check your connection and try again");
}

/// Sign-up succeeded, but the email address must be confirmed before the
/// user can sign in.
class EmailConfirmationRequiredException extends AccountException {
  const EmailConfirmationRequiredException()
    : super('Check your email to confirm your account, then sign in');
}

/// The backend does not support this way of signing in or up (e.g. phone
/// numbers while only email is enabled).
class UnsupportedSignInMethodException extends AccountException {
  const UnsupportedSignInMethodException()
    : super('Please use your email address');
}

/// Anything else the backend reported. The raw backend text is never shown.
class BackendOperationException extends AccountException {
  const BackendOperationException()
    : super('Something went wrong — please try again');
}
