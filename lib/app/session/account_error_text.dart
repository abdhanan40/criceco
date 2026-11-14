import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../router/routes.dart';
import 'session_controller.dart';

/// The text a screen shows for a failed account operation.
///
/// Only messages the app wrote itself are shown: [AccountException]s and
/// [ProfileValidationException]s (thrown by the repositories, with backend
/// details already mapped to plain language) and [WeakPasswordException].
/// Anything else — an SDK, HTTP or database error, a `StateError` — gets the
/// screen's own [fallback], so raw backend text never reaches the user.
String accountErrorText(Object error, {required String fallback}) =>
    switch (error) {
      AccountException(:final message) => message,
      ProfileValidationException(:final message) => message,
      WeakPasswordException(:final message) => message,
      _ => fallback,
    };

/// The operation was refused because the user is no longer signed in to the
/// backend (or as someone else): the screen signs out locally and returns to
/// Login (D-S3).
bool needsSignIn(Object error) =>
    error is NotSignedInException || error is AccountMismatchException;

/// For a protected operation's `catch`: when [error] [needsSignIn], shows its
/// message, signs out locally and goes to Login, and returns `true` (the
/// caller stops). Otherwise does nothing and returns `false`.
bool signOutIfNeeded(BuildContext context, WidgetRef ref, Object error) {
  if (!needsSignIn(error)) return false;
  showCeToast(context, accountErrorText(error, fallback: ''));
  ref.read(sessionProvider.notifier).logout();
  context.go(Routes.login);
  return true;
}
