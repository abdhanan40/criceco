import '../../core/models/models.dart';
import '../../core/utils/validators.dart';

/// Pure conversions between the Supabase rows of the four ERD v8 tables
/// (`profiles`, `current_addresses`, `permanent_addresses`,
/// `player_profiles`) and the app's [UserAccount]. Rows are the JSON maps the
/// REST API returns; nothing here talks to Supabase.
///
/// Approved decisions: the profile photo is device-only and never comes from
/// the database (D3); the profile City is the current address's city (D4);
/// a profile counts as complete only when `profile_completed` is set *and* a
/// date of birth and both addresses exist (D7), so legacy rows go through
/// Profile Setup once.
abstract final class ProfileRowMapper {
  // ---------------------------------------------------------------------------
  // Database codes — identical to the CHECK constraints in the migrations.
  // ---------------------------------------------------------------------------

  static String playerRoleCode(PlayerRole r) => switch (r) {
    PlayerRole.batsman => 'batsman',
    PlayerRole.bowler => 'bowler',
    PlayerRole.allRounder => 'all_rounder',
  };

  static String battingStyleCode(BattingStyle s) => switch (s) {
    BattingStyle.rightHanded => 'right_handed',
    BattingStyle.leftHanded => 'left_handed',
  };

  static String bowlingStyleCode(BowlingStyle s) => switch (s) {
    BowlingStyle.rightArmFast => 'right_arm_fast',
    BowlingStyle.rightArmMedium => 'right_arm_medium',
    BowlingStyle.rightArmOffSpin => 'right_arm_off_spin',
    BowlingStyle.rightArmLegSpin => 'right_arm_leg_spin',
    BowlingStyle.leftArmFast => 'left_arm_fast',
    BowlingStyle.leftArmMedium => 'left_arm_medium',
    BowlingStyle.leftArmOrthodox => 'left_arm_orthodox',
    BowlingStyle.leftArmChinaman => 'left_arm_chinaman',
  };

  /// `profiles.role`: the Role Selection choice (NULL until chosen).
  static String userRoleCode(UserRole r) => switch (r) {
    UserRole.player => 'player',
    UserRole.clubOwner => 'club_owner',
  };

  static PlayerRole playerRoleFromCode(String code) =>
      _decode(PlayerRole.values, playerRoleCode, code, 'player_role');

  static BattingStyle battingStyleFromCode(String code) =>
      _decode(BattingStyle.values, battingStyleCode, code, 'batting_style');

  static BowlingStyle bowlingStyleFromCode(String code) =>
      _decode(BowlingStyle.values, bowlingStyleCode, code, 'bowling_style');

  static UserRole? userRoleFromCode(String? code) => code == null
      ? null
      : _decode<UserRole>(UserRole.values, userRoleCode, code, 'role');

  /// An unknown code means the app and the schema disagree — fail loudly.
  static T _decode<T>(
    List<T> values,
    String Function(T) codeOf,
    String code,
    String column,
  ) {
    for (final v in values) {
      if (codeOf(v) == code) return v;
    }
    throw FormatException('Unknown $column value', code);
  }

  // ---------------------------------------------------------------------------
  // Rows → app
  // ---------------------------------------------------------------------------

  /// The account for one `profiles` row plus its (optional) address and
  /// player rows. [email] is the Supabase Auth user's email, if any.
  ///
  /// `profiles.role` (the Role Selection choice) is deliberately not mapped
  /// onto the account yet: how it relates to the Club Owner profile is
  /// pending decision D6. [userRoleFromCode] already decodes it.
  static UserAccount accountFromRows({
    required Map<String, dynamic> profile,
    Map<String, dynamic>? currentAddress,
    Map<String, dynamic>? permanentAddress,
    Map<String, dynamic>? playerProfile,
    String? email,
  }) {
    final dateOfBirth = parseDate(profile['date_of_birth'] as String?);
    final phone = profile['phone'] as String?;
    final currentCity = currentAddress?['city'] as String?;
    final hasEmail = email != null && email.trim().isNotEmpty;
    return UserAccount(
      id: profile['id'] as String,
      fullName: (profile['full_name'] as String?) ?? '',
      contactMethod: hasEmail ? ContactMethod.email : ContactMethod.phone,
      email: hasEmail ? email : null,
      // Legacy rows hold 03XXXXXXXXX (spaced / dashed), saves hold +923…;
      // the app works with 03XXXXXXXXX. Anything else is kept as stored.
      phone: phone == null
          ? null
          : (CeValidators.normalizePkPhone(phone) ?? phone),
      city: currentCity,
      dateOfBirth: dateOfBirth,
      currentCity: currentCity,
      currentArea: currentAddress?['area'] as String?,
      currentAddress: currentAddress?['address'] as String?,
      permanentCity: permanentAddress?['city'] as String?,
      permanentArea: permanentAddress?['area'] as String?,
      permanentAddress: permanentAddress?['address'] as String?,
      isPermanentSameAsCurrent:
          (profile['permanent_same_as_current'] as bool?) ?? true,
      playerProfile: playerProfile == null
          ? const PlayerProfile()
          : playerProfileFromRow(playerProfile),
      profileComplete:
          profile['profile_completed'] == true &&
          dateOfBirth != null &&
          currentAddress != null &&
          permanentAddress != null,
    );
  }

  static PlayerProfile playerProfileFromRow(Map<String, dynamic> row) {
    final batting = row['batting_style'] as String?;
    final bowling = row['bowling_style'] as String?;
    return PlayerProfile(
      role: playerRoleFromCode(row['player_role'] as String),
      battingStyle: batting == null ? null : battingStyleFromCode(batting),
      bowlingStyle: bowling == null ? null : bowlingStyleFromCode(bowling),
      isWicketkeeper: (row['is_wicketkeeper'] as bool?) ?? false,
    );
  }

  // ---------------------------------------------------------------------------
  // App → database
  // ---------------------------------------------------------------------------

  /// Named arguments for `public.save_profile_setup(...)`. Under "same as
  /// current" the permanent fields are left out: the function copies the
  /// current address itself. Throws [StateError] when a field the function
  /// needs is missing (value rules are checked by the app and the database).
  static Map<String, Object?> saveProfileSetupParams(UserAccount account) {
    final same = account.isPermanentSameAsCurrent;
    final missing = [
      if (account.fullName.trim().isEmpty) 'fullName',
      if (account.phone == null) 'phone',
      if (account.dateOfBirth == null) 'dateOfBirth',
      if (account.currentCity == null) 'currentCity',
      if (account.currentArea == null) 'currentArea',
      if (account.currentAddress == null) 'currentAddress',
      if (!same && account.permanentCity == null) 'permanentCity',
      if (!same && account.permanentArea == null) 'permanentArea',
      if (!same && account.permanentAddress == null) 'permanentAddress',
    ];
    if (missing.isNotEmpty) {
      throw StateError('Profile Setup is missing: ${missing.join(', ')}');
    }
    return {
      'p_full_name': account.fullName,
      'p_phone': account.phone,
      'p_date_of_birth': formatDate(account.dateOfBirth!),
      'p_current_city': account.currentCity,
      'p_current_area': account.currentArea,
      'p_current_address': account.currentAddress,
      'p_permanent_same_as_current': same,
      'p_permanent_city': same ? null : account.permanentCity,
      'p_permanent_area': same ? null : account.permanentArea,
      'p_permanent_address': same ? null : account.permanentAddress,
    };
  }

  /// A `player_profiles` row for [userId]. The database enforces the role
  /// rules (styles per role, wicket keeping for Batsmen only).
  static Map<String, Object?> playerProfileRow(
    String userId,
    PlayerProfile profile,
  ) {
    final role = profile.role;
    if (role == null) throw StateError('A player profile needs a playing role');
    return {
      'user_id': userId,
      'player_role': playerRoleCode(role),
      'batting_style': profile.battingStyle == null
          ? null
          : battingStyleCode(profile.battingStyle!),
      'bowling_style': profile.bowlingStyle == null
          ? null
          : bowlingStyleCode(profile.bowlingStyle!),
      'is_wicketkeeper': profile.isWicketkeeper,
    };
  }

  // ---------------------------------------------------------------------------
  // `date` columns travel as YYYY-MM-DD.
  // ---------------------------------------------------------------------------

  static DateTime? parseDate(String? value) {
    if (value == null) return null;
    final d = DateTime.parse(value);
    return DateTime(d.year, d.month, d.day);
  }

  static String formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
