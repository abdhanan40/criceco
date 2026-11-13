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

  /// The arguments of the last update_profile_details call.
  Map<String, Object?>? lastDetailsParams;

  /// What the last update_profile_details call wrote, in order: a profile
  /// column (`profiles.full_name` / `profiles.phone` /
  /// `profiles.date_of_birth`) or an address table. Empty: nothing written.
  final detailsWrites = <String>[];

  /// Stand-in for `public.update_profile_details()` (migration 9): the
  /// caller's profile must exist (P0002); only changed values are checked
  /// (23514, with the function's messages) and written; every check runs
  /// before the first write, so a refusal writes nothing. Address arguments
  /// are used only for an existing row and only when one of the four is
  /// given; a supplied id wins (its city's name; a NEW id must be in
  /// [cities]); without one, the text is written and the id kept or
  /// re-resolved as migration 8 does. "Same as current" (the stored flag)
  /// copies the current row as stored after the save.
  @override
  Future<void> updateProfileDetails(Map<String, Object?> params) async {
    _maybeFail('updateProfileDetails');
    final uid = _uid();
    lastDetailsParams = Map.of(params);
    detailsWrites.clear();
    final profile = profiles[uid];
    if (profile == null) {
      throw const GatewayConstraintException(
        sqlState: 'P0002',
        message: 'profile not found',
      );
    }
    Never refuse(String message) =>
        throw GatewayConstraintException(sqlState: '23514', message: message);

    // Profile details.
    final name = (params['p_full_name'] as String?)?.trim();
    final setName = name != (profile['full_name'] as String?)?.trim();
    if (setName && (name == null || name.length < 2 || name.length > 100)) {
      refuse('full_name must be 2–100 characters');
    }
    final sentPhone = params['p_phone'] as String?;
    final storedPhone = profile['phone'] as String?;
    final phone = _canonicalPhone(sentPhone);
    final setPhone =
        phone != _canonicalPhone(storedPhone) ||
        (phone == null && storedPhone != null && sentPhone != storedPhone);
    if (setPhone &&
        phone != null &&
        !RegExp(r'^\+923[0-9]{9}$').hasMatch(phone)) {
      refuse('phone must be a Pakistani mobile number');
    }
    final dob = params['p_date_of_birth'] as String?;
    final setDob = dob != profile['date_of_birth'];
    if (setDob && dob != null) {
      final d = DateTime.parse(dob);
      if (d.isBefore(DateTime(1900))) {
        refuse('date_of_birth is required (1900 or later)');
      }
      if (d.isAfter(DateTime.now())) {
        refuse('date_of_birth cannot be in the future');
      }
    }

    // Addresses.
    String? arg(String which, String field) =>
        params['p_${which}_$field'] as String?;
    int? idArg(String which) => params['p_${which}_city_id'] as int?;
    bool given(String which) =>
        arg(which, 'city') != null ||
        idArg(which) != null ||
        arg(which, 'area') != null ||
        arg(which, 'address') != null;

    final same = (profile['permanent_same_as_current'] as bool?) ?? true;
    final currentRow = currentAddresses[uid];
    final permanentRow = permanentAddresses[uid];
    final current = currentRow != null && given('current')
        ? _plannedAddress(
            'current',
            currentRow,
            city: arg('current', 'city'),
            cityId: idArg('current'),
            area: arg('current', 'area'),
            address: arg('current', 'address'),
            refuse: refuse,
          )
        : null;
    Map<String, dynamic>? permanent;
    if (same && currentRow != null) {
      if (permanentRow != null && given('current')) {
        final c = current ?? currentRow;
        final copy = {
          ...permanentRow,
          'city_id': c['city_id'],
          'city': c['city'],
          'area': c['area'],
          'address': c['address'],
        };
        if (!_sameAddress(copy, permanentRow)) permanent = copy;
      }
    } else {
      final which = same ? 'current' : 'permanent';
      if (permanentRow != null && given(which)) {
        permanent = _plannedAddress(
          'permanent',
          permanentRow,
          city: arg(which, 'city'),
          cityId: idArg(which),
          area: arg(which, 'area'),
          address: arg(which, 'address'),
          refuse: refuse,
        );
      }
    }

    // Writes — all checks have passed.
    final next = {...profile};
    if (setName) {
      next['full_name'] = name;
      detailsWrites.add('profiles.full_name');
    }
    if (setPhone) {
      next['phone'] = phone;
      detailsWrites.add('profiles.phone');
    }
    if (setDob) {
      next['date_of_birth'] = dob;
      detailsWrites.add('profiles.date_of_birth');
    }
    profiles[uid] = next;
    if (current != null) {
      currentAddresses[uid] = current;
      detailsWrites.add('current_addresses');
    }
    if (permanent != null) {
      permanentAddresses[uid] = permanent;
      detailsWrites.add('permanent_addresses');
    }
  }

  /// Migration 9's phone normalisation, for the sent and the stored value.
  static String? _canonicalPhone(String? raw) {
    final r = raw ?? '';
    final digits = r.replaceAll(RegExp(r'[\s-]'), '');
    if (RegExp(r'^03[0-9]{9}$').hasMatch(digits)) {
      return '+92${digits.substring(1)}';
    }
    if (RegExp(r'^923[0-9]{9}$').hasMatch(digits)) return '+$digits';
    final noSpace = r.replaceAll(RegExp(r'\s'), '');
    if (digits.isEmpty && noSpace.isNotEmpty) return noSpace;
    return digits.isEmpty ? null : digits;
  }

  static bool _sameAddress(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['city_id'] == b['city_id'] &&
      a['city'] == b['city'] &&
      a['area'] == b['area'] &&
      a['address'] == b['address'];

  /// One address row after the save, or `null` when nothing changes.
  Map<String, dynamic>? _plannedAddress(
    String which,
    Map<String, dynamic> row, {
    required String? city,
    required int? cityId,
    required String? area,
    required String? address,
    required Never Function(String) refuse,
  }) {
    String? t(Object? v) => (v as String?)?.trim();
    final a = t(area), ad = t(address);
    String? text;
    var isNew = false;
    if (cityId != null) {
      isNew = cityId != row['city_id'];
      final name = cities[cityId];
      if (isNew && name == null) {
        refuse('${which}_city_id must be an active city');
      }
      // A kept id whose city is no longer listed keeps the stored name.
      text = name ?? row['city'] as String?;
    } else {
      text = t(city);
    }
    final write =
        isNew ||
        text != t(row['city']) ||
        a != t(row['area']) ||
        ad != t(row['address']);
    if (!write) return null;
    final table = '${which}_addresses';
    for (final (field, value, max) in [
      ('city', text, 100),
      ('area', a, 150),
      ('address', ad, 500),
    ]) {
      if (value == null || value.isEmpty || value.length > max) {
        refuse(
          '$table.$field must be 1–$max characters '
          '(constraint "${table}_${field}_check")',
        );
      }
    }
    final next = {...row, 'city': text, 'area': a, 'address': ad};
    if (cityId != null) {
      next['city_id'] = cityId;
    } else if (text != row['city'] && cities[row['city_id']] != text) {
      // Migration 8: a changed text keeps the id while it names that city,
      // else re-resolves it (a unique name, or NULL).
      final named = [
        for (final e in cities.entries)
          if (e.value == text) e.key,
      ];
      next['city_id'] = named.length == 1 ? named.single : null;
    }
    return next;
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
