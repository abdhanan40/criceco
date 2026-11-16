import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'auth_url_params.dart';

/// Replaces the address (no reload, no new history entry) with one without
/// the auth callback's parameters. The entry's state — Flutter's own
/// navigation state — is kept.
void clearAuthResultFromUrl() {
  try {
    final location = globalContext.getProperty<JSObject>('location'.toJS);
    final href = location.getProperty<JSString>('href'.toJS).toDart;
    final cleaned = withoutAuthResult(href);
    if (cleaned == null) return;
    final history = globalContext.getProperty<JSObject>('history'.toJS);
    history.callMethodVarArgs<JSAny?>('replaceState'.toJS, [
      history.getProperty<JSAny?>('state'.toJS),
      ''.toJS,
      cleaned.toJS,
    ]);
  } catch (_) {
    // Only cosmetic: a reload would show the message once more.
  }
}
