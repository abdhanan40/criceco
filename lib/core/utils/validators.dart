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

  /// Prototype: "Min 6 characters".
  static const passwordMinLength = 6;

  static String? password(String? v) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < passwordMinLength) return 'Password must be at least $passwordMinLength characters';
    return null;
  }

  static String? confirmPassword(String? v, String original) {
    if (v == null || v.isEmpty) return 'Please re-enter your password';
    return v == original ? null : 'Passwords do not match';
  }

  static String? personName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Full name is required';
    if (v.trim().length < 2) return 'Enter your full name';
    return null;
  }

  /// Club codes: letters and digits, 4–10 characters (e.g. KRC001, 35HLWZ).
  static String? clubCode(String? v) {
    if (v == null || v.trim().isEmpty) return 'Please enter a club code';
    return RegExp(r'^[A-Za-z0-9]{4,10}$').hasMatch(v.trim()) ? null : 'Club codes are 4–10 letters or digits';
  }
}
