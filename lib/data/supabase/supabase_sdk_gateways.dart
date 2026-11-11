import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

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
  Future<void> signOut() => _guardAuth(() => _auth.signOut());

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
      switch (e.code) {
        case 'email_not_confirmed':
          return const GatewayEmailNotConfirmedException();
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

  /// The only tables [updateAddress] may write.
  static const addressTables = {'current_addresses', 'permanent_addresses'};

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
  Future<void> upsertPlayerProfile(Map<String, Object?> row) => _guard(
    () => _client.from('player_profiles').upsert(row, onConflict: 'user_id'),
  );

  @override
  Future<void> updateProfileColumns(
    String userId,
    Map<String, Object?> columns,
  ) => _guard(() => _client.from('profiles').update(columns).eq('id', userId));

  @override
  Future<void> updateAddress(
    String table,
    String userId,
    Map<String, Object?> columns,
  ) {
    if (!addressTables.contains(table)) {
      throw ArgumentError.value(table, 'table', 'not an address table');
    }
    return _guard(
      () => _client.from(table).update(columns).eq('user_id', userId),
    );
  }

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
