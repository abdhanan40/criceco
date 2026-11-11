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

  /// The clubs table, when a [FakeClubDb] is attached: the account read
  /// embeds the user's own club (`clubs(id)`), as the real select does.
  FakeClubDb? clubDb;
  final profiles = <String, Map<String, dynamic>>{};
  final currentAddresses = <String, Map<String, dynamic>>{};
  final permanentAddresses = <String, Map<String, dynamic>>{};
  final players = <String, Map<String, dynamic>>{};
  GatewayException? failNext;
  final calls = <String>[];
  Map<String, Object?>? lastSetupParams;

  /// The parameters of the last save_profile_setup_v2 call.
  Map<String, Object?>? lastSetupV2Params;

  /// `public.cities` as save_profile_setup_v2 sees it: id → name (active).
  /// An id not listed here is refused like an inactive / unknown city.
  Map<int, String> cities = const {
    1: 'Karachi',
    2: 'Lahore',
    6: 'Multan',
    101: 'Kamra',
    102: 'Kamra',
  };

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
    final club = clubDb?.clubs[userId];
    return AccountRows(
      profile: Map.of(p),
      currentAddress: currentAddresses[userId],
      permanentAddress: permanentAddresses[userId],
      playerProfile: players[userId],
      club: club == null ? null : {'id': club['id']},
      // As migration 7's triggers: the rows grant the roles.
      roles: [
        if (players[userId] != null) {'role': 'player'},
        if (club != null) {'role': 'club_owner'},
      ],
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

  /// As migration 8: the city ids must be active cities (else a 23514 with
  /// the function's message); the city text is stored from the id.
  @override
  Future<void> saveProfileSetupV2(Map<String, Object?> params) async {
    _maybeFail('saveProfileSetupV2');
    final uid = _uid();
    lastSetupV2Params = params;
    final same = params['p_permanent_same_as_current'] as bool;
    final currentId = params['p_current_city_id'] as int?;
    final permanentId = same
        ? currentId
        : params['p_permanent_city_id'] as int?;
    for (final (id, which) in [
      (currentId, 'current'),
      (permanentId, 'permanent'),
    ]) {
      if (id == null || !cities.containsKey(id)) {
        throw GatewayConstraintException(
          sqlState: '23514',
          message: '${which}_city_id must be an active city',
        );
      }
    }
    profiles[uid] = {
      ...profiles[uid]!,
      'full_name': params['p_full_name'],
      'phone': params['p_phone'],
      'date_of_birth': params['p_date_of_birth'],
      'permanent_same_as_current': same,
      'profile_completed': true,
    };
    Map<String, dynamic> address(String prefix, int id) => {
      'user_id': uid,
      'city_id': id,
      'city': cities[id],
      'area': params['p_${prefix}_area'],
      'address': params['p_${prefix}_address'],
    };
    currentAddresses[uid] = address('current', currentId!);
    permanentAddresses[uid] = same
        ? Map.of(currentAddresses[uid]!)
        : address('permanent', permanentId!);
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

  /// Marks [userId]'s User Profile Setup as done (the rows
  /// save_profile_setup() would write).
  void completeProfile(String userId) {
    profiles[userId] = {
      ...profiles[userId]!,
      'full_name': 'Test Owner',
      'phone': '+923001234567',
      'date_of_birth': '2000-05-01',
      'profile_completed': true,
    };
    final address = {
      'user_id': userId,
      'city': 'Lahore',
      'area': 'Gulberg',
      'address': 'Street 1',
    };
    currentAddresses[userId] = address;
    permanentAddresses[userId] = Map.of(address);
  }
}

/// Stand-in for `public.clubs` + `create_club()` (migration 5): RLS keeps
/// every call to the signed-in owner's club; create_club() refuses a missing
/// name / city / type and an unfinished Profile Setup, keeps one club per
/// owner (a retry returns it), generates the join code and makes the owner's
/// role club_owner (over player, never downgraded). Uses [FakeDb]'s profiles,
/// addresses and signed-in user. [failNext] / [calls] as in [FakeDb].
class FakeClubDb implements ClubGateway {
  FakeClubDb(this.db) {
    db.clubDb = this;
  }
  final FakeDb db;

  /// Club rows by owner id.
  final clubs = <String, Map<String, dynamic>>{};
  GatewayException? failNext;
  final calls = <String>[];
  Map<String, Object?>? lastCreateParams;
  Map<String, Object?>? lastUpdateColumns;

  /// The join code the next new club gets (then a generated one).
  String? nextCode;
  var _next = 0;

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  static GatewayConstraintException _check(String constraint) =>
      GatewayConstraintException(
        sqlState: '23514',
        message:
            'new row for relation "clubs" violates check constraint '
            '"$constraint"',
      );

  @override
  Future<Map<String, dynamic>?> fetchOwnClub(String userId) async {
    _maybeFail('fetchOwnClub');
    final uid = db.auth.current?.id;
    if (uid == null) throw const GatewayPermissionException();
    final row = clubs[userId];
    return userId == uid && row != null ? Map.of(row) : null; // RLS
  }

  @override
  Future<Map<String, dynamic>> createClub(Map<String, Object?> params) async {
    _maybeFail('createClub');
    lastCreateParams = params;
    final uid = db.auth.current?.id;
    if (uid == null) {
      throw const GatewayConstraintException(
        sqlState: '42501',
        message: 'not authenticated',
      );
    }
    String? text(String key) {
      final v = (params[key] as String?)?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    for (final (key, message) in [
      ('p_name', 'club name is required'),
      ('p_city', 'club city is required'),
      ('p_club_type', 'club type is required'),
    ]) {
      if (text(key) == null) {
        throw GatewayConstraintException(sqlState: '23514', message: message);
      }
    }
    if (!const {
      'professional',
      'college_university',
      'corporate',
    }.contains(text('p_club_type'))) {
      throw _check('clubs_club_type_check');
    }
    final p = db.profiles[uid];
    if (p == null ||
        p['profile_completed'] != true ||
        p['date_of_birth'] == null ||
        !db.currentAddresses.containsKey(uid) ||
        !db.permanentAddresses.containsKey(uid)) {
      throw const GatewayConstraintException(
        sqlState: '23514',
        message:
            'profile_completed requires a completed User Profile Setup '
            'before creating a club',
      );
    }
    final existing = clubs[uid];
    if (existing != null) return Map.of(existing); // on conflict do nothing

    final n = ++_next;
    final code = nextCode ?? 'CL${2222 + n}';
    nextCode = null;
    if (clubs.values.any((c) => c['code'] == code)) {
      throw const GatewayConstraintException(
        sqlState: '23505',
        message:
            'duplicate key value violates unique constraint "clubs_code_key"',
      );
    }
    final row = <String, dynamic>{
      'id': 'club-$n',
      'owner_id': uid,
      'name': text('p_name'),
      'short_name': null,
      'city': text('p_city'),
      'club_type': text('p_club_type'),
      'code': code,
      'owner_name': text('p_owner_name'),
      'address': text('p_address'),
      'email': text('p_email'),
      'home_ground_id': text('p_home_ground_id'),
      'established_year': DateTime.now().year,
      'created_at': '2026-11-09T10:00:00+00:00',
      'last_updated_at': '2026-11-09T10:00:00+00:00',
    };
    clubs[uid] = row;
    // clubs_set_owner_role: club_owner over player, never downgraded.
    if (p['role'] == null || p['role'] == 'player') {
      db.profiles[uid] = {...p, 'role': 'club_owner'};
    }
    return Map.of(row);
  }

  @override
  Future<Map<String, dynamic>?> updateClub(
    String clubId,
    String userId,
    Map<String, Object?> columns,
  ) async {
    _maybeFail('updateClub');
    lastUpdateColumns = columns;
    final uid = db.auth.current?.id;
    if (uid == null) throw const GatewayPermissionException();
    final row = clubs[userId];
    if (userId != uid || row == null || row['id'] != clubId) return null;
    final name = columns['name'];
    if (name is String && name.trim().isEmpty) {
      throw _check('clubs_name_check');
    }
    final email = columns['email'];
    if (email is String && !email.contains('@')) {
      throw _check('clubs_email_check');
    }
    final updated = {...row, ...columns};
    clubs[userId] = updated;
    return Map.of(updated);
  }
}

/// The location lookup (migration 6) for Supabase-mode widget tests: three
/// featured cities and the two Kamra towns, with the ids [FakeDb.cities]
/// knows, as `v_city_options` rows. No provinces (the filters stay hidden).
class FakeLocationGateway implements LocationGateway {
  final searches = <Map<String, Object?>>[];

  static Map<String, dynamic> row(
    int id,
    String name, {
    int? rank,
    String? qualifier,
    String province = 'Punjab',
  }) => {
    'id': id,
    'name': name,
    'qualifier': qualifier,
    'kind': 'city',
    'featured_rank': rank,
    'province_id': 1,
    'province_name': province,
    'primary_district_id': null,
    'primary_district_name': null,
    'district_count': 0,
  };

  static final featured = [
    row(1, 'Karachi', rank: 1, province: 'Sindh'),
    row(2, 'Lahore', rank: 2),
    row(6, 'Multan', rank: 3),
  ];
  static final others = [
    row(101, 'Kamra', qualifier: 'Attock'),
    row(102, 'Kamra', qualifier: 'Rawalpindi'),
  ];

  @override
  Future<List<Map<String, dynamic>>> fetchProvinces() async => const [];

  @override
  Future<List<Map<String, dynamic>>> fetchDistricts(int provinceId) async =>
      const [];

  @override
  Future<List<Map<String, dynamic>>> searchCities(
    Map<String, Object?> params,
  ) async {
    searches.add(params);
    final q = (params['p_query'] as String?)?.trim().toLowerCase();
    if (q == null || q.length < 2) return featured;
    return [
      for (final r in [...featured, ...others])
        if ((r['name'] as String).toLowerCase().startsWith(q)) r,
    ];
  }

  @override
  Future<Map<String, dynamic>?> fetchCity(int id) async {
    for (final r in [...featured, ...others]) {
      if (r['id'] == id) return r;
    }
    return null;
  }
}
