import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The two narrow seams between [SupabaseAccountRepository] and Supabase.
/// They use the app's own types only, so the repository is tested with
/// fakes; the real implementations (on `supabase_flutter`) arrive in
/// Phase 2 Step 4. Every method throws a [GatewayException] on failure.

/// The signed-in Supabase Auth user, as the app needs it.
class AuthUser {
  const AuthUser({required this.id, this.email, this.metadata = const {}});
  final String id;
  final String? email;

  /// Auth user metadata (`raw_user_meta_data`), e.g. `full_name` (D5).
  final Map<String, Object?> metadata;

  String? get fullName {
    final v = metadata['full_name'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }
}

class SignUpResult {
  const SignUpResult({required this.user, required this.hasSession});
  final AuthUser user;

  /// `false` when the email address must be confirmed first.
  final bool hasSession;
}

abstract interface class AuthGateway {
  /// The user of the persisted session, or `null` when signed out.
  AuthUser? get currentUser;

  /// `null` for wrong credentials.
  Future<AuthUser?> signInWithPassword({
    required String email,
    required String password,
  });

  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required Map<String, Object?> metadata,
  });

  Future<void> signOut();
}

/// One account's rows: `profiles` plus its (optional) address and player
/// rows, as JSON maps.
class AccountRows {
  const AccountRows({
    required this.profile,
    this.currentAddress,
    this.permanentAddress,
    this.playerProfile,
  });
  final Map<String, dynamic> profile;
  final Map<String, dynamic>? currentAddress;
  final Map<String, dynamic>? permanentAddress;
  final Map<String, dynamic>? playerProfile;
}

abstract interface class ProfileGateway {
  /// `null` when the user has no `profiles` row (RLS: own row only).
  Future<AccountRows?> fetchAccountRows(String userId);

  /// `rpc('save_profile_setup', params)` — one transaction.
  Future<void> saveProfileSetup(Map<String, Object?> params);

  /// Upsert into `player_profiles` on `user_id`.
  Future<void> upsertPlayerProfile(Map<String, Object?> row);

  /// `update profiles set <columns> where id = userId`.
  Future<void> updateProfileColumns(
    String userId,
    Map<String, Object?> columns,
  );

  /// `update <table> set <columns> where user_id = userId` — updates an
  /// existing address row only ([table] is `current_addresses` or
  /// `permanent_addresses`).
  Future<void> updateAddress(
    String table,
    String userId,
    Map<String, Object?> columns,
  );

  /// `update profiles set role = role where id = userId and role is null`:
  /// never overwrites a role that is already set.
  Future<void> setRoleIfUnset(String userId, String role);
}

/// What a gateway reports when a call fails.
sealed class GatewayException implements Exception {
  const GatewayException();
}

/// Offline, timeout, DNS, 5xx — the call may not have reached the server.
class GatewayNetworkException extends GatewayException {
  const GatewayNetworkException();
}

/// The database refused the data (`23514` check, `23502` not-null, …).
/// [constraint] is the constraint name when the backend reports one.
class GatewayConstraintException extends GatewayException {
  const GatewayConstraintException({
    required this.sqlState,
    required this.message,
    this.constraint,
  });
  final String sqlState;
  final String message;
  final String? constraint;
}

/// `42501` / RLS refusal / no valid session.
class GatewayPermissionException extends GatewayException {
  const GatewayPermissionException();
}

/// Anything else (bad response, unexpected error).
class GatewayUnexpectedException extends GatewayException {
  const GatewayUnexpectedException(this.detail);
  final String detail;
}

const _notYet =
    'CRICECO_BACKEND=supabase is not available yet: the Supabase '
    'gateways arrive with the supabase_flutter package (Phase 2 Step 4)';

/// Overridden with real implementations in Step 4 (and with fakes in tests).
final authGatewayProvider = Provider<AuthGateway>(
  (ref) => throw UnsupportedError(_notYet),
);
final profileGatewayProvider = Provider<ProfileGateway>(
  (ref) => throw UnsupportedError(_notYet),
);
