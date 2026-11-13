import '../../core/models/models.dart';

/// Pure conversions between `public.clubs` rows (migration 5) and the app's
/// [Club]. Rows are the JSON maps the REST API returns; nothing here talks to
/// Supabase.
///
/// The club picture is device-only and never comes from the database
/// (approved D-S2-2); `id`, `owner_id` and the join `code` are set by the
/// database and never written by the app.
abstract final class ClubRowMapper {
  /// `clubs.club_type` — identical to `clubs_club_type_check`.
  static String clubTypeCode(ClubType t) => switch (t) {
    ClubType.professional => 'professional',
    ClubType.collegeUniversity => 'college_university',
    ClubType.corporate => 'corporate',
  };

  /// An unknown code means the app and the schema disagree — fail loudly.
  static ClubType clubTypeFromCode(String code) {
    for (final t in ClubType.values) {
      if (clubTypeCode(t) == code) return t;
    }
    throw FormatException('Unknown club_type value', code);
  }

  /// A `clubs` row → [Club], with this device's picture ([logoPath]).
  static Club clubFromRow(Map<String, dynamic> row, {String? logoPath}) => Club(
    id: row['id'] as String,
    name: row['name'] as String,
    shortName: row['short_name'] as String?,
    city: row['city'] as String,
    type: clubTypeFromCode(row['club_type'] as String),
    code: row['code'] as String,
    hasLogo: logoPath != null,
    logoPath: logoPath,
    ownerName: row['owner_name'] as String?,
    address: row['address'] as String?,
    email: row['email'] as String?,
    homeGroundId: row['home_ground_id'] as String?,
    establishedYear: (row['established_year'] as num?)?.toInt(),
  );

  /// The parameters of `create_club(...)` — the database trims them, stores
  /// blanks as NULL and sets the code, owner and established year.
  static Map<String, Object?> createParams({
    required String name,
    required String city,
    required ClubType type,
    String? ownerName,
    String? address,
    String? email,
    String? homeGroundId,
  }) => {
    'p_name': name,
    'p_city': city,
    'p_club_type': clubTypeCode(type),
    'p_owner_name': ownerName,
    'p_address': address,
    'p_email': email,
    'p_home_ground_id': homeGroundId,
  };

  /// The editable columns that differ between [before] and [after] — what an
  /// update writes (`clubs` grants UPDATE on exactly these). Empty when
  /// nothing the database stores changed (e.g. only the picture).
  static Map<String, Object?> updateColumns(Club before, Club after) {
    final columns = <String, Object?>{};
    void put(String column, Object? was, Object? now) {
      if (was != now) columns[column] = now;
    }

    put('name', before.name, after.name);
    put('short_name', before.shortName, after.shortName);
    put('city', before.city, after.city);
    put('club_type', clubTypeCode(before.type), clubTypeCode(after.type));
    put('owner_name', before.ownerName, after.ownerName);
    put('address', before.address, after.address);
    put('email', before.email, after.email);
    put('home_ground_id', before.homeGroundId, after.homeGroundId);
    put('established_year', before.establishedYear, after.establishedYear);
    return columns;
  }
}
