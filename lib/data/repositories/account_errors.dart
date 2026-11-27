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

/// Join a Club (migration 11): no club uses this code.
class ClubCodeNotFoundException extends AccountException {
  const ClubCodeNotFoundException()
    : super('No club found with that code. Check the code and try again.');
}

/// Join a Club / membership: the database refused the step for a reason the
/// person can act on ([message]: own club, already a member, a request
/// already pending, profile incomplete, already decided).
class ClubMembershipException extends AccountException {
  const ClubMembershipException(super.message);
}

/// A club ownership offer the database refused (migration 16): already an
/// open offer, an ineligible member, an answered offer… [message] says what.
class OwnershipTransferException extends AccountException {
  const OwnershipTransferException(super.message);
}

/// A team change the database refused (migration 12): duplicate name, full
/// squad, a player who isn't an active member, a deleted team.
class TeamRuleException extends AccountException {
  const TeamRuleException(super.message);
}

/// The team was saved elsewhere (another device) after this copy was read:
/// `save_team` refused the stale save (SQLSTATE 40001, `team: changed
/// elsewhere`). Nothing was written; the teams are reloaded and the change
/// has to be made again.
class TeamChangedElsewhereException extends TeamRuleException {
  const TeamChangedElsewhereException()
      : super('This team was changed on another device — it has been reloaded. Please make your change again.');
}

/// A challenge, match, lineup or availability change the server refused
/// (migrations 17–19): a duplicate challenge, a replaced proposal, a clash,
/// an incomplete lineup, an invalid date… [message] says what to do next.
class MatchRuleException extends AccountException {
  const MatchRuleException(super.message);
}

/// An inbox or announcement call the server refused (migration 25): an
/// invalid title or message, the daily announcement limit, an announcement
/// that is gone… [message] says what to do next.
class NotificationRuleException extends AccountException {
  const NotificationRuleException(super.message);
}

/// A Player Hunt change the server refused (migration 33): a duplicate or
/// closed post, a player who isn't available any more, an invite already
/// answered, one of the daily limits… [message] says what to do next.
class HuntRuleException extends AccountException {
  const HuntRuleException(super.message);
}

/// A tournament change the server refused or couldn't find (migration 35):
/// an invalid field, the club limits, a closed or full registration, a squad
/// that isn't 11 + 4, a request already decided, a draw already made…
/// [message] says what to do next; [reason] is the server's own reason
/// (`registration full`, `not pending`…), for the screens that react to one.
class TournamentRuleException extends AccountException {
  const TournamentRuleException(super.message, {this.reason});
  final String? reason;
}

/// A workout the server refused or couldn't find (migration 34): a future
/// or too old date, minutes out of range, too long notes, the daily limits,
/// a workout already deleted… [message] says what to do next.
class FitnessRuleException extends AccountException {
  const FitnessRuleException(super.message);
}

/// A profile or club picture that couldn't be saved on the server (M5,
/// migration 31): too large, not a JPG / PNG / WebP, unreadable, or refused
/// by the server. Nothing changed; [message] says what to do next.
class MediaException extends AccountException {
  const MediaException.tooLarge()
    : kind = MediaFailure.tooLarge,
      super('That picture is too large. Choose one under 2 MB.');
  const MediaException.unsupported()
    : kind = MediaFailure.unsupported,
      super('Use a JPG, PNG or WebP picture.');
  const MediaException.unreadable()
    : kind = MediaFailure.unreadable,
      super("That picture couldn't be read. Try another one.");
  const MediaException.notAllowed()
    : kind = MediaFailure.notAllowed,
      super('Only the owner can change this picture.');
  const MediaException.failed()
    : kind = MediaFailure.failed,
      super("Couldn't save the picture — please try again.");

  final MediaFailure kind;

  /// The same picture would be refused again (size, type, unreadable file).
  bool get isPermanent => kind == MediaFailure.tooLarge || kind == MediaFailure.unsupported;
}

enum MediaFailure { tooLarge, unsupported, unreadable, notAllowed, failed }

/// This part of the app has no backend in this build (Supabase mode,
/// docs/PRODUCTION_DEMO_MODE.md): nothing is saved, so nothing is pretended.
/// Delete Account: the password typed to confirm it is wrong.
class WrongPasswordException extends AccountException {
  const WrongPasswordException() : super('That password is incorrect');
}

/// Delete Account refused: the user owns a club. The approved policy is to
/// transfer the club's ownership to another member first.
class ClubOwnershipTransferRequiredException extends AccountException {
  const ClubOwnershipTransferRequiredException()
    : super('You own a club. Transfer its ownership to another member before deleting your account.');
}

/// Delete Account: the data is gone but the sign-in account wasn't deleted
/// yet. Trying again completes it safely.
class AccountDeletionIncompleteException extends AccountException {
  const AccountDeletionIncompleteException()
    : super('Your data was deleted, but closing your sign-in account didn’t finish. Please tap Delete again.');
}

/// Delete Account isn't available in this build (the server side isn't
/// deployed yet).
class AccountDeletionUnavailableException extends AccountException {
  const AccountDeletionUnavailableException()
    : super('Deleting your account isn’t available yet in this version of the app.');
}

class ModuleUnavailableException extends AccountException {
  const ModuleUnavailableException()
    : super('This isn’t available yet — it isn’t connected to the server.');
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
