import 'package:criceco/data/supabase/supabase_gateways.dart';

/// In-memory stand-ins for the Supabase gateways (Phase 2 Step 3). They
/// mimic what the live project does: the sign-up trigger creates an empty
/// `profiles` row, `save_profile_setup` writes the caller's rows in one go,
/// RLS keeps every call to the signed-in user. [failNext] makes the next
/// call fail with the given [GatewayException]; [calls] records each call.

class FakeAuth implements AuthGateway {
  FakeAuth(this.db) {
    db.auth = this;
  }
  final FakeDb db;
  final _users = <String, ({String password, AuthUser user})>{};
  AuthUser? current;
  bool requireConfirmation = false;
  GatewayException? failNext;
  final calls = <String>[];
  var _next = 0;

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  /// An existing user (with the trigger-created profile row).
  AuthUser addUser(
    String email,
    String password, {
    String? id,
    Map<String, Object?> metadata = const {},
  }) {
    final user = AuthUser(
      id: id ?? 'user-${++_next}',
      email: email,
      metadata: metadata,
    );
    _users[email] = (password: password, user: user);
    db.profiles[user.id] ??= FakeDb.freshProfile(user.id);
    return user;
  }

  @override
  AuthUser? get currentUser => current;

  @override
  Future<AuthUser?> signInWithPassword({
    required String email,
    required String password,
  }) async {
    _maybeFail('signInWithPassword');
    final u = _users[email];
    if (u == null || u.password != password) return null;
    return current = u.user;
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required Map<String, Object?> metadata,
  }) async {
    _maybeFail('signUp');
    final user = addUser(email, password, metadata: metadata);
    if (requireConfirmation) return SignUpResult(user: user, hasSession: false);
    current = user;
    return SignUpResult(user: user, hasSession: true);
  }

  @override
  Future<void> signOut() async {
    _maybeFail('signOut');
    current = null;
  }
}

class FakeDb implements ProfileGateway {
  late FakeAuth auth;
  final profiles = <String, Map<String, dynamic>>{};
  final currentAddresses = <String, Map<String, dynamic>>{};
  final permanentAddresses = <String, Map<String, dynamic>>{};
  final players = <String, Map<String, dynamic>>{};
  GatewayException? failNext;
  final calls = <String>[];
  Map<String, Object?>? lastSetupParams;

  static Map<String, dynamic> freshProfile(String id) => {
    'id': id,
    'created_at': '2026-10-29T10:00:00+00:00',
    'full_name': null,
    'phone': null,
    'role': null,
    'profile_completed': false,
    'date_of_birth': null,
    'permanent_same_as_current': true,
    'last_updated_at': '2026-10-29T10:00:00+00:00',
  };

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  /// RLS: only the signed-in user's own rows.
  String _uid() {
    final u = auth.current;
    if (u == null) throw const GatewayPermissionException();
    return u.id;
  }

  void _own(String userId) {
    if (_uid() != userId) throw const GatewayPermissionException();
  }

  @override
  Future<AccountRows?> fetchAccountRows(String userId) async {
    _maybeFail('fetchAccountRows');
    _own(userId);
    final p = profiles[userId];
    if (p == null) return null;
    return AccountRows(
      profile: Map.of(p),
      currentAddress: currentAddresses[userId],
      permanentAddress: permanentAddresses[userId],
      playerProfile: players[userId],
    );
  }

  @override
  Future<void> saveProfileSetup(Map<String, Object?> params) async {
    _maybeFail('saveProfileSetup');
    final uid = _uid();
    lastSetupParams = params;
    final same = params['p_permanent_same_as_current'] as bool;
    profiles[uid] = {
      ...profiles[uid]!,
      'full_name': params['p_full_name'],
      'phone': params['p_phone'],
      'date_of_birth': params['p_date_of_birth'],
      'permanent_same_as_current': same,
      'profile_completed': true,
    };
    Map<String, dynamic> address(String prefix) => {
      'user_id': uid,
      'city': params['p_${prefix}_city'],
      'area': params['p_${prefix}_area'],
      'address': params['p_${prefix}_address'],
    };
    currentAddresses[uid] = address('current');
    permanentAddresses[uid] = same
        ? Map.of(currentAddresses[uid]!)
        : address('permanent');
  }

  @override
  Future<void> upsertPlayerProfile(Map<String, Object?> row) async {
    _maybeFail('upsertPlayerProfile');
    _own(row['user_id'] as String);
    players[row['user_id'] as String] = Map.of(row);
  }

  @override
  Future<void> updateProfileColumns(
    String userId,
    Map<String, Object?> columns,
  ) async {
    _maybeFail('updateProfileColumns');
    _own(userId);
    profiles[userId] = {...profiles[userId]!, ...columns};
  }

  @override
  Future<void> updateAddress(
    String table,
    String userId,
    Map<String, Object?> columns,
  ) async {
    _maybeFail('updateAddress:$table');
    _own(userId);
    final rows = table == 'current_addresses'
        ? currentAddresses
        : permanentAddresses;
    final row = rows[userId];
    if (row != null) rows[userId] = {...row, ...columns};
  }

  @override
  Future<void> setRoleIfUnset(String userId, String role) async {
    _maybeFail('setRoleIfUnset');
    _own(userId);
    final p = profiles[userId]!;
    if (p['role'] == null) profiles[userId] = {...p, 'role': role};
  }
}
