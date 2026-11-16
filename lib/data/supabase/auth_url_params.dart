/// The parameters an auth callback leaves on the web app's address
/// (AUTH-04/05): `?code=` of a recovery link or Google return, or the
/// `error…` of a failed one.
const kAuthResultParameters = {
  'code',
  'error',
  'error_code',
  'error_description',
};

/// Ready-made session values. The app only uses PKCE (the callback carries a
/// one-time `code` that only this app's stored verifier can exchange), so a
/// callback with any of these is never one it started.
const kSessionTokenParameters = {
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
};

/// Security S1: whether `Supabase.initialize` may treat [uri] — the web
/// app's address at start, or a `com.criceco.criceco://login-callback` link
/// on Android — as an auth callback.
///
/// Accepted: a PKCE authorization `code` (in the query, where Supabase puts
/// it) or an `error` / `error_code` / `error_description` from a failed
/// callback (message only, never a session). Refused: anything carrying
/// [kSessionTokenParameters] (in the query or the fragment) — otherwise a
/// crafted link with someone else's tokens would replace the user's session
/// — and anything else, including a malformed address.
bool isAcceptedAuthCallback(Uri uri) {
  try {
    final query = uri.queryParametersAll;
    final fragment = uri.hasFragment
        ? Uri.splitQueryString(uri.fragment)
        : const <String, String>{};
    bool has(String key) => query.containsKey(key) || fragment.containsKey(key);
    if (kSessionTokenParameters.any(has)) return false;
    return query.containsKey('code') ||
        const {'error', 'error_code', 'error_description'}.any(has);
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// [href] without [kAuthResultParameters] in its query, or `null` when it
/// has none (nothing to change). The fragment (the app's route) is kept.
String? withoutAuthResult(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null ||
      !uri.queryParameters.keys.any(kAuthResultParameters.contains)) {
    return null;
  }
  final kept = [
    for (final e in uri.queryParametersAll.entries)
      if (!kAuthResultParameters.contains(e.key))
        for (final v in e.value)
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(v)}',
  ];
  final base = uri
      .replace(query: '', fragment: '')
      .toString()
      .replaceAll(RegExp(r'[?#]+$'), '');
  return '$base${kept.isEmpty ? '' : '?${kept.join('&')}'}${uri.hasFragment ? '#${uri.fragment}' : ''}';
}
