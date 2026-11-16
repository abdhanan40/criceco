import '../../core/models/models.dart';

/// Auth events the app didn't start a call for (AUTH-04/05): a password
/// recovery link, a return from Google sign-in, a failed link, a session the
/// backend ended. [AccountRepository.sessionAtStart] gives the one of the
/// app start, [AccountRepository.authEvents] the later ones.
sealed class AccountAuthEvent {
  const AccountAuthEvent();
}

/// A recovery code or link started a recovery session: the app may only
/// set a new password now ([AccountRepository.completePasswordRecovery]).
/// [email] is the account's address, when known.
final class PasswordRecoveryStarted extends AccountAuthEvent {
  const PasswordRecoveryStarted({this.email});
  final String? email;
}

/// Google sign-in came back signed in as [account] (new or existing).
final class ExternalSignIn extends AccountAuthEvent {
  const ExternalSignIn(this.account);
  final UserAccount account;
}

/// An auth link or redirect failed; nothing is signed in.
final class AuthLinkFailed extends AccountAuthEvent {
  const AuthLinkFailed(this.reason);
  final AuthLinkFailure reason;
}

/// The backend ended the session (expired or revoked, e.g. by a password
/// reset on another device).
final class SessionExpired extends AccountAuthEvent {
  const SessionExpired();
}

enum AuthLinkFailure {
  /// The link expired or was already used.
  expired,

  /// Google sign-in was cancelled, or permission was refused.
  cancelled,

  /// The link can't be used here (another device or browser, or malformed).
  invalid,

  /// The provider or backend reported an error, or the account couldn't be
  /// read after signing in.
  failed,
}
