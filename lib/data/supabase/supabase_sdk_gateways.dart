import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth_url_cleanup.dart';
import 'supabase_gateways.dart';

/// [AuthGateway] / [ProfileGateway] on `supabase_flutter`. The SDK's types
/// stay inside this file: callers only see [AuthUser], [AccountRows] and
/// [GatewayException]s.

/// How long one gateway call may take before it counts as unreachable
/// ([GatewayNetworkException]). The SDK sets no timeout of its own, so a
/// stalled connection would otherwise keep a screen's spinner going for as
/// long as the operating system waits.
const kGatewayTimeout = Duration(seconds: 20);

class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(this._auth, {this.timeout = kGatewayTimeout});
  final sb.GoTrueClient _auth;
  final Duration timeout;

  @override
  AuthUser? get currentUser => _toUser(_auth.currentUser);

  @override
  Future<AuthUser?> signInWithPassword({
    required String email,
    required String password,
  }) => _guardAuth(() async {
    try {
      final r = await _auth.signInWithPassword(
        email: email,
        password: password,
      );
      _recovering = false;
      return _toUser(r.user);
    } on sb.AuthException catch (e) {
      if (isInvalidCredentials(e)) return null;
      rethrow;
    }
  });

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required Map<String, Object?> metadata,
  }) => _guardAuth(() async {
    final r = await _auth.signUp(
      email: email,
      password: password,
      data: metadata,
    );
    final user = _toUser(r.user);
    if (user == null) throw const GatewayUnexpectedException('signup-no-user');
    return SignUpResult(user: user, hasSession: r.session != null);
  });

  @override
  Future<AuthUser> verifySignUpCode({
    required String email,
    required String code,
  }) => _guardAuth(() async {
    final r = await _auth.verifyOTP(
      type: sb.OtpType.signup,
      email: email,
      token: code,
    );
    final user = _toUser(r.user);
    if (user == null || r.session == null) {
      throw const GatewayUnexpectedException('verify-no-session');
    }
    _recovering = false;
    return user;
  });

  @override
  Future<void> resendSignUpCode({required String email}) =>
      _guardAuth(() => _auth.resend(type: sb.OtpType.signup, email: email));

  @override
  Future<void> signOut() => _guardAuth(() async {
    _recovering = false;
    await _auth.signOut();
  });

  // ---- AUTH-04: password recovery ----

  @override
  Future<void> sendPasswordReset({required String email, String? redirectTo}) =>
      _guardAuth(
        () => _auth.resetPasswordForEmail(email, redirectTo: redirectTo),
      );

  @override
  Future<AuthUser> verifyRecoveryCode({
    required String email,
    required String code,
  }) => _guardAuth(() async {
    final r = await _auth.verifyOTP(
      type: sb.OtpType.recovery,
      email: email,
      token: code,
    );
    final user = _toUser(r.user);
    if (user == null || r.session == null) {
      throw const GatewayUnexpectedException('recovery-no-session');
    }
    _recovering = true;
    return user;
  });

  @override
  Future<void> updatePassword(String password) =>
      _guardAuth(() => _auth.updateUser(sb.UserAttributes(password: password)));

  @override
  Future<void> signOutEverywhere() => _guardAuth(() async {
    await _auth.signOut(scope: sb.SignOutScope.global);
    _recovering = false;
  });

  // ---- AUTH-05: Google ----

  @override
  Future<bool> startGoogleSignIn({String? redirectTo}) => _guardAuth(
    () =>
        _auth.signInWithOAuth(sb.OAuthProvider.google, redirectTo: redirectTo),
  );

  // ---- Auth events ----

  /// A recovery code or link started the current session. The token alone
  /// can't say: Supabase labels a code-started recovery `otp` (checked on a
  /// local stack), a link-started one `recovery`. Cleared by any other
  /// sign-in or sign-out; an app restart forgets it, and a recovery session
  /// left from before is then ended at start (nothing is remembered for it).
  bool _recovering = false;

  @override
  AuthSessionKind get sessionKind {
    final session = _auth.currentSession;
    if (session == null) return AuthSessionKind.none;
    if (_recovering) return AuthSessionKind.recovery;
    return kindOf(session);
  }

  StreamSubscription<sb.AuthState>? _subscription;
  final _events = StreamController<AuthGatewayEvent>.broadcast();
  var _started = false;
  AuthGatewayEvent? _startEvent;

  @override
  Stream<AuthGatewayEvent> get events => _events.stream;

  /// The SDK's auth stream replays its latest event to a new listener: at
  /// app start that is what `Supabase.initialize` did with the page's URL
  /// (web) — a recovery link, a Google return, or the error of a failed
  /// one. Events delivered before this returns are the start event; later
  /// ones go to [events].
  @override
  Future<AuthGatewayEvent?> takeStartEvent() async {
    _listen();
    // The replayed event is delivered in a microtask; a zero timer runs
    // after all of them.
    await Future<void>.delayed(Duration.zero);
    _started = true;
    final e = _startEvent;
    _startEvent = null;
    return e;
  }

  void _listen() => _subscription ??= _auth.onAuthStateChange.listen(
    (s) {
      if (s.event == sb.AuthChangeEvent.passwordRecovery) {
        _recovering = true;
      } else if (s.event == sb.AuthChangeEvent.signedIn ||
          s.event == sb.AuthChangeEvent.signedOut) {
        _recovering = false;
      }
      _emit(eventOf(s, kindOf(s.session)));
    },
    onError: (Object e, StackTrace _) {
      final reason = linkError(e);
      if (reason == null) return;
      clearAuthResultFromUrl(); // web: a reload must not report it again
      _emit(GatewayLinkFailed(reason));
    },
  );

  void _emit(AuthGatewayEvent? e) {
    if (e == null) return;
    if (_started) {
      _events.add(e);
    } else {
      _startEvent = e;
    }
  }

  /// SDK auth state → the app's event, or `null` for the app's own calls
  /// (password sign-in, sign-up codes, its own sign-out, token refreshes).
  static AuthGatewayEvent? eventOf(sb.AuthState s, AuthSessionKind kind) {
    switch (s.event) {
      case sb.AuthChangeEvent.passwordRecovery:
        return const GatewayRecoveryStarted();
      case sb.AuthChangeEvent.signedIn:
        final user = _toUser(s.session?.user);
        return kind == AuthSessionKind.oauth && user != null
            ? GatewayOAuthSignedIn(user)
            : null;
      case sb.AuthChangeEvent.signedOut:
        final reason = s.signOutReason;
        return reason != null && reason != sb.SignOutReason.userInitiated
            ? const GatewaySessionExpired()
            : null;
      default:
        return null;
    }
  }

  /// The error of a failed auth link (`?error=…&error_code=…` on the
  /// callback, or a code that can't be exchanged), or `null` for errors
  /// that aren't about a link (offline token refresh, expired refresh
  /// token — the latter ends the session as [GatewaySessionExpired]).
  static GatewayLinkError? linkError(Object e) {
    if (e is! sb.AuthException || e is sb.AuthRetryableFetchException) {
      return null;
    }
    // On a callback URL the SDK puts `error` in code and `error_code` (when
    // the backend sends one — provider errors often come without it) in
    // statusCode; on an API error they are the error code and HTTP status.
    final error = e.code;
    final errorCode = e.statusCode;
    bool has(Set<String> codes) =>
        codes.contains(error) || codes.contains(errorCode);
    if (has(_sessionErrors)) return null; // ends as GatewaySessionExpired
    if (has(const {'otp_expired', 'flow_state_expired'})) {
      return GatewayLinkError.expired;
    }
    if (e is sb.AuthPKCEGrantCodeExchangeError ||
        e.message.contains('Code verifier') ||
        has(_invalidLinkErrors)) {
      return GatewayLinkError.invalid;
    }
    if (error == 'access_denied') return GatewayLinkError.cancelled;
    // A plain AuthException (not an API one) is what the SDK raises for a
    // callback address's own error parameters: `server_error` and any other
    // provider or backend error — or, with no `error` at all, a malformed
    // callback.
    if (e.runtimeType == sb.AuthException) {
      return error == null ? GatewayLinkError.invalid : GatewayLinkError.failed;
    }
    if (errorCode != null && int.tryParse(errorCode) == null) {
      return GatewayLinkError.failed; // another error_code from a callback
    }
    return null;
  }

  /// Session problems the SDK also reports on the auth stream — not links.
  static const _sessionErrors = {
    'session_missing',
    'session_expired',
    'session_not_found',
    'refresh_token_not_found',
    'refresh_token_already_used',
  };

  /// A callback that can't be used here: a stale or foreign OAuth state, a
  /// code without its PKCE verifier (another browser or device), a
  /// malformed request.
  static const _invalidLinkErrors = {
    'flow_state_not_found',
    'bad_code_verifier',
    'bad_oauth_state',
    'bad_oauth_callback',
    'validation_failed',
    'invalid_request',
  };

  /// How [session] was started, from its access token's `amr` claim.
  static AuthSessionKind kindOf(sb.Session? session) {
    if (session == null) return AuthSessionKind.none;
    final methods = amrMethods(session.accessToken);
    if (methods.contains('recovery')) return AuthSessionKind.recovery;
    if (methods.contains('oauth')) return AuthSessionKind.oauth;
    return AuthSessionKind.other;
  }

  /// The `amr` methods of a JWT (no signature check: only used to tell
  /// sessions apart, never to grant anything). Unreadable → empty.
  static Set<String> amrMethods(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return const {};
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final amr = payload is Map ? payload['amr'] : null;
      return {
        if (amr is List)
          for (final m in amr)
            if (m is Map && m['method'] is String) m['method'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  static AuthUser? _toUser(sb.User? u) => u == null
      ? null
      : AuthUser(
          id: u.id,
          email: u.email,
          metadata: Map<String, Object?>.from(u.userMetadata ?? const {}),
        );

  /// Wrong email or password (Supabase answers 400 `invalid_credentials`).
  static bool isInvalidCredentials(sb.AuthException e) =>
      e.code == 'invalid_credentials' ||
      (e.statusCode == '400' &&
          e.message.toLowerCase().contains('invalid login credentials'));

  /// Supabase Auth errors → [GatewayException].
  static GatewayException translate(Object e) {
    if (e is GatewayException) return e;
    if (e is sb.AuthRetryableFetchException) {
      return const GatewayNetworkException();
    }
    if (e is sb.AuthWeakPasswordException) {
      return const GatewayConstraintException(
        sqlState: '23514',
        message: 'weak password',
      );
    }
    if (e is sb.AuthException) {
      final status = int.tryParse(e.statusCode ?? '');
      // By error code first: a wrong code comes back as 403, which must not
      // read as a missing session below.
      switch (e.code) {
        case 'email_not_confirmed':
          return const GatewayEmailNotConfirmedException();
        case 'otp_expired':
          return const GatewayInvalidCodeException();
        case 'over_email_send_rate_limit' || 'over_request_rate_limit':
          return const GatewayRateLimitedException();
        case 'same_password':
          return const GatewaySamePasswordException();
        case 'user_already_exists' || 'email_exists':
          return const GatewayConstraintException(
            sqlState: '23505',
            message: 'user already exists',
          );
        case 'weak_password':
          return const GatewayConstraintException(
            sqlState: '23514',
            message: 'weak password',
          );
      }
      if (status == 429) return const GatewayRateLimitedException();
      if (e is sb.AuthSessionMissingException ||
          status == 401 ||
          status == 403) {
        return const GatewayPermissionException();
      }
      if (status != null && status >= 500) {
        return const GatewayNetworkException();
      }
      return GatewayUnexpectedException(
        'auth:${e.code ?? e.statusCode ?? 'unknown'}',
      );
    }
    if (_isNetwork(e)) return const GatewayNetworkException();
    return const GatewayUnexpectedException('auth');
  }

  Future<T> _guardAuth<T>(Future<T> Function() run) =>
      _guarded(run, timeout, translate);
}

class SupabaseProfileGateway implements ProfileGateway {
  SupabaseProfileGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<AccountRows?> fetchAccountRows(String userId) => _guard(() async {
    final row = await _client
        .from('profiles')
        .select(
          '*, current_addresses(*), permanent_addresses(*), player_profiles(*), '
          'clubs(id), $userRolesEmbed',
        )
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    final profile = Map<String, dynamic>.of(row)
      ..remove('current_addresses')
      ..remove('permanent_addresses')
      ..remove('player_profiles')
      ..remove('clubs')
      ..remove('user_roles');
    return AccountRows(
      profile: profile,
      currentAddress: _one(row['current_addresses']),
      permanentAddress: _one(row['permanent_addresses']),
      playerProfile: _one(row['player_profiles']),
      // The own club (one per owner, migration 5): its id only.
      club: _one(row['clubs']),
      roles: _many(row['user_roles']),
    );
  });

  /// `user_roles` has two foreign keys to `profiles` (`user_id`,
  /// `granted_by`), so the embed must name the one it follows — otherwise
  /// PostgREST refuses the request as ambiguous (PGRST201).
  static const userRolesEmbed = 'user_roles!user_roles_user_id_fkey(role)';

  /// A one-to-many embed: a list of objects (tolerates `null`).
  static List<Map<String, dynamic>> _many(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  @override
  Future<void> saveProfileSetup(Map<String, Object?> params) =>
      _guard(() => _client.rpc<void>('save_profile_setup', params: params));

  @override
  Future<void> saveProfileSetupV2(Map<String, Object?> params) =>
      _guard(() => _client.rpc<void>('save_profile_setup_v2', params: params));

  @override
  Future<void> updateProfileDetails(Map<String, Object?> params) =>
      _guard(() => _client.rpc<void>('update_profile_details', params: params));

  @override
  Future<void> upsertPlayerProfile(Map<String, Object?> row) => _guard(
    () => _client.from('player_profiles').upsert(row, onConflict: 'user_id'),
  );

  @override
  Future<void> setRoleIfUnset(String userId, String role) => _guard(
    () => _client
        .from('profiles')
        .update({'role': role})
        .eq('id', userId)
        .isFilter('role', null),
  );

  /// An embedded one-to-one relation comes back as an object (or `null`);
  /// tolerate a one-element list too.
  static Map<String, dynamic>? _one(Object? v) => switch (v) {
    final Map<dynamic, dynamic> m => Map<String, dynamic>.from(m),
    final List<dynamic> l when l.isNotEmpty && l.first is Map =>
      Map<String, dynamic>.from(l.first as Map),
    _ => null,
  };

  /// PostgREST / network errors → [GatewayException].
  static GatewayException translate(Object e) {
    if (e is GatewayException) return e;
    if (e is sb.PostgrestException) {
      final code = e.code ?? '';
      // No valid session: the JWT is invalid (PGRST301), missing where
      // required (PGRST302) or expired / failing its claims (PGRST303).
      if (const {
        'PGRST301',
        'PGRST302',
        'PGRST303',
        '401',
        '403',
      }.contains(code)) {
        return const GatewayPermissionException();
      }
      if (RegExp(r'^5\d\d$').hasMatch(code)) {
        return const GatewayNetworkException();
      }
      // A Postgres SQLSTATE (23514 check, 23502 not-null, P0001 raise, …).
      // 42501 (a privilege / RLS refusal) is one too: the mapper tells it
      // apart from a lost session by its message.
      if (RegExp(r'^[0-9A-Z]{5}$').hasMatch(code)) {
        return GatewayConstraintException(sqlState: code, message: e.message);
      }
      return GatewayUnexpectedException(
        'postgrest:${code.isEmpty ? 'unknown' : code}',
      );
    }
    if (e is sb.AuthException) {
      return SupabaseAuthGateway.translate(e); // e.g. expired session
    }
    if (_isNetwork(e)) return const GatewayNetworkException();
    return const GatewayUnexpectedException('postgrest');
  }

  Future<T> _guard<T>(Future<T> Function() run) =>
      _guarded(run, timeout, translate);
}

class SupabaseClubGateway implements ClubGateway {
  SupabaseClubGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<Map<String, dynamic>?> fetchOwnClub(String userId) => _guard(
    () async => _row(
      await _client.from('clubs').select().eq('owner_id', userId).maybeSingle(),
    ),
  );

  @override
  Future<Map<String, dynamic>> createClub(Map<String, Object?> params) =>
      _guard(() async {
        final row = _row(
          await _client.rpc<dynamic>('create_club', params: params),
        );
        if (row == null) {
          throw const GatewayUnexpectedException('create_club-no-row');
        }
        return row;
      });

  // The updated rows come back as a list (not `.maybeSingle()`): an empty
  // list is "no row updated" whatever the PostgREST version, while a
  // single-object request would turn that into an HTTP 406 error.
  @override
  Future<Map<String, dynamic>?> updateClub(
    String clubId,
    String userId,
    Map<String, Object?> columns,
  ) => _guard(
    () async => _row(
      await _client
          .from('clubs')
          .update(columns)
          .eq('id', clubId)
          .eq('owner_id', userId)
          .select(),
    ),
  );

  /// A function returning one row comes back as an object; tolerate a
  /// one-element list too.
  static Map<String, dynamic>? _row(Object? v) => switch (v) {
    final Map<dynamic, dynamic> m => Map<String, dynamic>.from(m),
    final List<dynamic> l when l.isNotEmpty && l.first is Map =>
      Map<String, dynamic>.from(l.first as Map),
    _ => null,
  };

  // Same PostgREST / network translation as the profile tables.
  Future<T> _guard<T>(Future<T> Function() run) =>
      _guarded(run, timeout, SupabaseProfileGateway.translate);
}

/// Club memberships (migration 11): database functions only.
class SupabaseMembershipGateway implements MembershipGateway {
  SupabaseMembershipGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<Map<String, dynamic>?> lookupClubByCode(String code) => _guard(
    () async => SupabaseClubGateway._row(
      await _client.rpc<dynamic>('lookup_club_by_code', params: {'p_code': code}),
    ),
  );

  /// `null` for an unknown code: the function returns NULL (PostgREST: `null`,
  /// or a row whose fields are all `null`).
  @override
  Future<Map<String, dynamic>?> requestToJoin(String code) => _guard(() async {
    final row = SupabaseClubGateway._row(
      await _client.rpc<dynamic>('request_to_join_club', params: {'p_code': code}),
    );
    return row == null || row['id'] == null ? null : row;
  });

  @override
  Future<Map<String, dynamic>> cancelJoinRequest(String requestId) =>
      _one('cancel_join_request', {'p_request_id': requestId});

  @override
  Future<List<Map<String, dynamic>>> myJoinRequests() => _list('my_join_requests', const {});

  @override
  Future<List<Map<String, dynamic>>> myMemberships() => _list('my_club_memberships', const {});

  @override
  Future<List<Map<String, dynamic>>> clubJoinRequests(String clubId) =>
      _list('club_join_requests', {'p_club_id': clubId});

  @override
  Future<Map<String, dynamic>> decideJoinRequest({
    required String requestId,
    required bool approve,
    required String role,
    String? reason,
  }) => _one('decide_join_request', {
    'p_request_id': requestId,
    'p_approve': approve,
    'p_role': role,
    'p_reason': reason,
  });

  @override
  Future<List<Map<String, dynamic>>> clubMembers(String clubId) =>
      _list('club_member_list', {'p_club_id': clubId});

  @override
  Future<Map<String, dynamic>> removeMember(String memberId) =>
      _one('remove_club_member', {'p_member_id': memberId});

  Future<Map<String, dynamic>> _one(String fn, Map<String, Object?> params) => _guard(() async {
    final row = SupabaseClubGateway._row(await _client.rpc<dynamic>(fn, params: params));
    if (row == null) throw GatewayUnexpectedException('$fn-no-row');
    return row;
  });

  Future<List<Map<String, dynamic>>> _list(String fn, Map<String, Object?> params) =>
      _guard(() async => _rowsOf(await _client.rpc<dynamic>(fn, params: params)));

  Future<T> _guard<T>(Future<T> Function() run) =>
      _guarded(run, timeout, SupabaseProfileGateway.translate);
}

/// Teams and squads (migration 12): reads through RLS, writes through
/// database functions.
class SupabaseTeamGateway implements TeamGateway {
  SupabaseTeamGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<List<Map<String, dynamic>>> fetchTeams(String clubId) => _guard(
    () async => _rowsOf(
      await _client
          .from('teams')
          .select('*, team_players(*)')
          .eq('club_id', clubId)
          .eq('status', 'active')
          .order('created_at'),
    ),
  );

  @override
  Future<Map<String, dynamic>> createTeam(Map<String, Object?> params) => _one('create_team', params);

  @override
  Future<Map<String, dynamic>> saveTeam(Map<String, Object?> params) => _one('save_team', params);

  @override
  Future<Map<String, dynamic>> archiveTeam(String teamId) => _one('archive_team', {'p_team_id': teamId});

  Future<Map<String, dynamic>> _one(String fn, Map<String, Object?> params) => _guard(() async {
    final row = SupabaseClubGateway._row(await _client.rpc<dynamic>(fn, params: params));
    if (row == null) throw GatewayUnexpectedException('$fn-no-row');
    return row;
  });

  Future<T> _guard<T>(Future<T> Function() run) =>
      _guarded(run, timeout, SupabaseProfileGateway.translate);
}

/// A list of JSON objects from a REST / function response (tolerates `null`).
List<Map<String, dynamic>> _rowsOf(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is Map) Map<String, dynamic>.from(e),
];

class SupabaseLocationGateway implements LocationGateway {
  SupabaseLocationGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<List<Map<String, dynamic>>> fetchProvinces() => _guard(
    () async => _rows(
      await _client
          .from('provinces')
          .select('id, name, display_name, kind, sort_order')
          .eq('is_active', true)
          // postgrest's order() is descending unless told otherwise.
          .order('sort_order', ascending: true),
    ),
  );

  @override
  Future<List<Map<String, dynamic>>> fetchDistricts(int provinceId) => _guard(
    () async => _rows(
      await _client
          .from('districts')
          .select('id, province_id, name')
          .eq('province_id', provinceId)
          .eq('is_active', true)
          .order('name', ascending: true),
    ),
  );

  @override
  Future<List<Map<String, dynamic>>> searchCities(
    Map<String, Object?> params,
  ) => _guard(
    () async =>
        _rows(await _client.rpc<dynamic>('search_cities', params: params)),
  );

  @override
  Future<Map<String, dynamic>?> fetchCity(int id) => _guard(() async {
    final rows = _rows(
      await _client.from('v_city_options').select().eq('id', id).limit(1),
    );
    return rows.isEmpty ? null : rows.first;
  });

  static List<Map<String, dynamic>> _rows(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
  ];

  Future<T> _guard<T>(Future<T> Function() run) =>
      _guarded(run, timeout, SupabaseProfileGateway.translate);
}

/// Runs one gateway call with [timeout]; any failure, a timeout included,
/// becomes a [GatewayException] through [translate].
/// [AccountPrivacyGateway] on `supabase_flutter`: two RPCs (migration 13) and
/// the `delete-account` Edge Function. The function runs with the service
/// role on the server; the app only sends the user's own session and the
/// password typed to confirm.
class SupabaseAccountPrivacyGateway implements AccountPrivacyGateway {
  SupabaseAccountPrivacyGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<bool> fetchPhoneSharing() => _guarded(
        () async => await _client.rpc('my_privacy_settings') == true,
        timeout,
        SupabaseProfileGateway.translate,
      );

  @override
  Future<void> setPhoneSharing(bool share) => _guarded(
        () => _client.rpc('set_phone_sharing', params: {'p_share': share}),
        timeout,
        SupabaseProfileGateway.translate,
      );

  @override
  Future<void> deleteAccount({required String password}) => _guarded(
        () async {
          try {
            final res = await _client.functions.invoke(
              'delete-account',
              body: {'password': password, 'confirm': 'DELETE'},
            );
            final data = res.data;
            if (data is Map && data['deleted'] == true) return;
            throw const GatewayUnexpectedException('delete-account:response');
          } on sb.FunctionException catch (e) {
            throw functionError(e.status, e.details);
          }
        },
        timeout,
        SupabaseProfileGateway.translate,
      );

  /// The Edge Function's error answers → [GatewayException].
  static GatewayException functionError(int status, Object? details) {
    final code = details is Map ? details['error'] : null;
    if (status == 403 && code == 'invalid_password') return const GatewayWrongPasswordException();
    if (status == 409 && code == 'CLUB_OWNERSHIP_TRANSFER_REQUIRED') {
      return const GatewayOwnershipTransferRequiredException();
    }
    if (status == 500 && code == 'auth_delete_failed') return const GatewayDeletionIncompleteException();
    if (status == 401) return const GatewayPermissionException();
    if (status == 429) return const GatewayRateLimitedException();
    if (status >= 500 && status != 501) return const GatewayNetworkException();
    return GatewayUnexpectedException('delete-account:$status');
  }
}

/// [OwnershipGateway] on `supabase_flutter` (migration 16): database
/// functions only — the caller is always the session's user.
class SupabaseOwnershipGateway implements OwnershipGateway {
  SupabaseOwnershipGateway(this._client, {this.timeout = kGatewayTimeout});
  final sb.SupabaseClient _client;
  final Duration timeout;

  @override
  Future<Map<String, dynamic>> offer(Map<String, Object?> params) => _one('offer_club_ownership', params);

  @override
  Future<Map<String, dynamic>> cancel(String transferId) =>
      _one('cancel_ownership_transfer', {'p_transfer_id': transferId});

  @override
  Future<Map<String, dynamic>> reject(String transferId) =>
      _one('reject_ownership_transfer', {'p_transfer_id': transferId});

  @override
  Future<Map<String, dynamic>> accept(String transferId) =>
      _one('accept_ownership_transfer', {'p_transfer_id': transferId});

  @override
  Future<List<Map<String, dynamic>>> clubTransfers(String clubId) =>
      _list('club_ownership_transfers', {'p_club_id': clubId});

  @override
  Future<List<Map<String, dynamic>>> myOffers() => _list('my_ownership_offers', const {});

  Future<Map<String, dynamic>> _one(String fn, Map<String, Object?> params) => _guarded(() async {
        final row = SupabaseClubGateway._row(await _client.rpc<dynamic>(fn, params: params));
        if (row == null) throw GatewayUnexpectedException('$fn-no-row');
        return row;
      }, timeout, SupabaseProfileGateway.translate);

  Future<List<Map<String, dynamic>>> _list(String fn, Map<String, Object?> params) => _guarded(
        () async => _rowsOf(await _client.rpc<dynamic>(fn, params: params)),
        timeout,
        SupabaseProfileGateway.translate,
      );
}

Future<T> _guarded<T>(
  Future<T> Function() run,
  Duration timeout,
  GatewayException Function(Object e) translate,
) async {
  try {
    return await run().timeout(timeout);
  } on Exception catch (e) {
    throw translate(e);
  }
}

/// No connection, DNS failure, dropped socket (wrapped by `package:http`),
/// or a timeout.
bool _isNetwork(Object e) => e is http.ClientException || e is TimeoutException;
