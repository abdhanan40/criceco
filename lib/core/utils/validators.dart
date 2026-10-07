/// Shared form validators. Each returns `null` when valid or a short,
/// user-facing message (never a raw exception).
abstract final class CeValidators {
  static String? required(String? v, [String field = 'This field']) =>
      (v == null || v.trim().isEmpty) ? '$field is required' : null;

  /// Pakistani mobile numbers: 03XXXXXXXXX, 03XX-XXXXXXX, +92 3XX XXXXXXX.
  static String? pkPhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Phone number is required';
    if (normalizePkPhone(v) == null) return 'Enter a valid mobile number (03XX-XXXXXXX)';
    return null;
  }

  /// Returns the canonical `03XXXXXXXXX` form, or `null` if invalid.
  static String? normalizePkPhone(String v) {
    var digits = v.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.startsWith('+92')) digits = '0${digits.substring(3)}';
    if (digits.startsWith('92') && digits.length == 12) digits = '0${digits.substring(2)}';
    return RegExp(r'^03\d{9}$').hasMatch(digits) ? digits : null;
  }

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? email(String? v, {bool optional = false}) {
    if (v == null || v.trim().isEmpty) return optional ? null : 'Email is required';
    return _email.hasMatch(v.trim()) ? null : 'Enter a valid email address';
  }

  /// Strong mixed password for new passwords (Sign Up, reset, change):
  /// 8+ characters with an uppercase and a lowercase letter, a number and a
  /// special character (e.g. "Cricket@123"). Login only checks it isn't empty,
  /// so existing accounts can still sign in.
  static const passwordMinLength = 8;

  /// The rules in display order — the live checklist and [password] share them.
  static final List<(String label, String message, bool Function(String))> passwordRules = [
    ('8+ characters', 'Password must be at least $passwordMinLength characters', (v) => v.length >= passwordMinLength),
    // Unicode-aware, so accented letters (e.g. "Ü") count as letters.
    ('Uppercase letter', 'Add an uppercase letter (A–Z)', (v) => RegExp(r'\p{Lu}', unicode: true).hasMatch(v)),
    ('Lowercase letter', 'Add a lowercase letter (a–z)', (v) => RegExp(r'\p{Ll}', unicode: true).hasMatch(v)),
    ('Number', 'Add a number (0–9)', (v) => RegExp(r'\p{Nd}', unicode: true).hasMatch(v)),
    (
      'Special character',
      r'Add a special character (e.g. @ # ! $)',
      (v) => RegExp(r'[^\p{L}\p{Nd}\s]', unicode: true).hasMatch(v),
    ),
  ];

  static String? password(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    for (final (_, message, ok) in passwordRules) {
      if (!ok(v)) return message;
    }
    return null;
  }

  static bool isStrongPassword(String v) => password(v) == null;

  static String? confirmPassword(String? v, String original) {
    if (v == null || v.isEmpty) return 'Please re-enter your password';
    return v == original ? null : 'Passwords do not match';
  }

  /// A person's name ([field] names it in the message, e.g. "Owner name").
  static String? personName(String? v, [String field = 'Full name']) {
    if (v == null || v.trim().isEmpty) return '$field is required';
    if (v.trim().length < 2) return field == 'Full name' ? 'Enter your full name' : 'Enter a valid name';
    if (!_hasLetter(v)) return 'Enter a valid name';
    return null;
  }

  /// A club / team / tournament name: required, and must contain a letter
  /// ("Lahore Lions", "1st XI" pass; "123" or "--" don't).
  static String? entityName(String? v, String field) {
    final empty = required(v, field);
    if (empty != null) return empty;
    return _hasLetter(v!) ? null : 'Enter a valid ${field.toLowerCase()}';
  }

  // Any script's letters (Urdu, Latin, …).
  static bool _hasLetter(String v) => RegExp(r'\p{L}', unicode: true).hasMatch(v);

  /// Shared text limits (one place for every form that uses them).
  static const nameMaxLength = 40;

  /// Custom-overs matches: 1–50 overs (Match Setup, teams, slots, tournaments).
  static const maxCustomOvers = 50;

  static String? customOvers(int? overs) {
    if (overs == null) return 'Please enter the number of overs';
    if (overs < 1 || overs > maxCustomOvers) return 'Enter between 1 and $maxCustomOvers overs';
    return null;
  }

  /// Date of birth: required and not in the future.
  static String? dateOfBirth(DateTime? dob, DateTime now) {
    if (dob == null) return 'Date of birth is required';
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(dob.year, dob.month, dob.day).isAfter(today) ? "Date of birth can't be in the future" : null;
  }

  /// Match Setup: a match can be scheduled from tomorrow (local date) on —
  /// never today or a past day. Existing matches are never re-checked.
  static const matchDateMessage = 'Please select a match date from tomorrow onwards.';

  /// The first day a new match may be played on, from the device's local date.
  static DateTime firstMatchDate(DateTime now) => DateTime(now.year, now.month, now.day + 1);

  static String? matchDate(DateTime? date, DateTime now) {
    if (date == null) return 'Please pick a date';
    final day = DateTime(date.year, date.month, date.day);
    return day.isBefore(firstMatchDate(now)) ? matchDateMessage : null;
  }

  /// Club codes: letters and digits, 4–10 characters (e.g. KRC001, 35HLWZ).
  static String? clubCode(String? v) {
    if (v == null || v.trim().isEmpty) return 'Please enter a club code';
    return RegExp(r'^[A-Za-z0-9]{4,10}$').hasMatch(v.trim()) ? null : 'Club codes are 4–10 letters or digits';
  }
}
