import '../../core/models/models.dart';
import '../../core/utils/validators.dart';

/// A save a repository refused because the data breaks a profile rule — the
/// same rules the forms check, so normally the screens catch it first.
/// [message] is short and user-facing.
class ProfileValidationException implements Exception {
  const ProfileValidationException(this.message);
  final String message;

  @override
  String toString() => 'ProfileValidationException: $message';
}

/// The profile rules every [AccountRepository] enforces on
/// `saveProfileSetup` / `savePlayerProfile`, built on [CeValidators] (the
/// rules User Profile Setup and Role Selection already apply).
abstract final class ProfileRules {
  /// Hard limits, as the database checks them (`char_length(btrim(...))`).
  /// The form fields are stricter ([CeValidators.nameMaxLength] etc.).
  static const nameMaxLength = 100;
  static const areaMaxLength = 150;
  static const addressMaxLength = 500;

  /// The earliest date of birth the database accepts.
  static final earliestDateOfBirth = DateTime(1900);

  /// User Profile Setup: name, phone, date of birth (1900-01-01 up to [now],
  /// never in the future), the current address and — unless "same as
  /// current" — the permanent address, each within the database limits.
  /// Throws [ProfileValidationException] on the first broken rule.
  static void checkProfileSetup(UserAccount account, DateTime now) {
    check([
      nameError(account.fullName),
      CeValidators.pkPhone(account.phone),
      dateOfBirthError(account.dateOfBirth, now),
      ...addressErrors(
        account.currentCity,
        account.currentArea,
        account.currentAddress,
      ),
      if (!account.isPermanentSameAsCurrent)
        ...addressErrors(
          account.permanentCity,
          account.permanentArea,
          account.permanentAddress,
        ),
    ]);
  }

  /// Full name: the form rule plus the database length limit.
  static String? nameError(String? v) =>
      CeValidators.personName(v) ?? _maxLength(v, nameMaxLength, 'Full name');

  /// Date of birth: required, 1900-01-01 up to [now], never in the future.
  static String? dateOfBirthError(DateTime? dob, DateTime now) =>
      CeValidators.dateOfBirth(dob, now) ?? _notBefore1900(dob);

  /// One address (current or permanent): city, area and address.
  static List<String?> addressErrors(
    String? city,
    String? area,
    String? address,
  ) => [
    CeValidators.city(city),
    CeValidators.addressPart(area, 'Area'),
    _maxLength(area, areaMaxLength, 'Area'),
    CeValidators.addressPart(address, 'Address'),
    _maxLength(address, addressMaxLength, 'Address'),
  ];

  /// Counted like the database: Unicode characters, surrounding spaces
  /// trimmed.
  static String? _maxLength(String? v, int max, String field) =>
      v != null && v.trim().runes.length > max
      ? '$field must be at most $max characters'
      : null;

  static String? _notBefore1900(DateTime? dob) {
    if (dob == null) return null;
    return DateTime(dob.year, dob.month, dob.day).isBefore(earliestDateOfBirth)
        ? 'Date of birth must be in 1900 or later'
        : null;
  }

  /// Role Selection → Player: a playing role, exactly the styles that role
  /// uses (Batsman: batting · Bowler: bowling · All-Rounder: both), and
  /// wicket keeping for a Batsman only.
  static void checkPlayerProfile(PlayerProfile profile) {
    final role = profile.role;
    if (role == null) {
      throw const ProfileValidationException('Choose your playing role');
    }
    check([
      if (role.bats && profile.battingStyle == null) 'Choose a batting style',
      if (!role.bats && profile.battingStyle != null)
        "A ${role.label} doesn't have a batting style",
      if (role.bowls && profile.bowlingStyle == null) 'Choose a bowling style',
      if (!role.bowls && profile.bowlingStyle != null)
        "A ${role.label} doesn't have a bowling style",
      if (profile.isWicketkeeper && !role.canKeepWicket)
        'Only a Batsman can be the wicket keeper',
    ]);
  }

  /// Throws [ProfileValidationException] for the first non-null message.
  static void check(List<String?> errors) {
    for (final e in errors) {
      if (e != null) throw ProfileValidationException(e);
    }
  }
}
