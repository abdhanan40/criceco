import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/repositories.dart';

/// A message for Login about something that happened outside a screen's own
/// call (AUTH-04/05): a failed recovery or Google link, a session the
/// backend ended, a password that was just reset. Login shows it once.
class AuthNotice {
  const AuthNotice(this.message, {this.isError = true});
  final String message;

  /// `false`: good news (shown as a toast), not an error banner.
  final bool isError;

  static AuthNotice forLink(AuthLinkFailure reason) =>
      AuthNotice(switch (reason) {
        AuthLinkFailure.expired =>
          'That link has expired or was already used — request a new one.',
        AuthLinkFailure.cancelled => 'Google sign-in was cancelled.',
        AuthLinkFailure.invalid => 'That link can’t be used here — open it on the device where you asked for it, or request a new one.',
        AuthLinkFailure.failed =>
          'Couldn’t finish signing in — please try again.',
      });

  static const sessionEnded = AuthNotice(
    'Your session has ended — please log in again.',
  );
  static const passwordUpdated = AuthNotice(
    'Password updated. Log in with your new password.',
    isError: false,
  );
}

class AuthNoticeController extends Notifier<AuthNotice?> {
  @override
  AuthNotice? build() => null;

  void show(AuthNotice notice) => state = notice;

  /// The notice, once: it is cleared as it is read.
  AuthNotice? take() {
    final n = state;
    if (n != null) state = null;
    return n;
  }
}

final authNoticeProvider = NotifierProvider<AuthNoticeController, AuthNotice?>(
  AuthNoticeController.new,
);
