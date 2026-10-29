import '../../core/utils/validators.dart';
import '../repositories/repositories.dart';
import 'supabase_gateways.dart';

/// Turns a [GatewayException] into what screens can handle: an
/// [AccountException] or a [ProfileValidationException] with user-facing
/// text. The raw database text is never passed on.
abstract final class SupabaseErrorMapper {
  static Exception map(GatewayException e) => switch (e) {
    GatewayNetworkException() => const BackendUnavailableException(),
    GatewayPermissionException() => const NotSignedInException(),
    GatewayUnexpectedException() => const BackendOperationException(),
    GatewayConstraintException() => _constraint(e),
  };

  static const generic =
      "Some details aren't valid — please check and try again";

  /// Messages raised by `save_profile_setup` / `profiles_validate`.
  static const _byMessage = {
    'not authenticated': null, // → NotSignedInException
    'full_name must be 2': 'Enter your full name (2–100 characters)',
    'phone must be a Pakistani mobile number':
        'Enter a valid mobile number (03XX-XXXXXXX)',
    'date_of_birth is required': 'Date of birth must be in 1900 or later',
    'date_of_birth cannot be in the future':
        "Date of birth can't be in the future",
    'profile_completed requires': 'Please complete all profile details',
  };

  /// CHECK constraints (migrations 1–3), matched by name.
  static const _byConstraint = {
    'profiles_date_of_birth_check': 'Date of birth must be in 1900 or later',
    'current_addresses_city_check': 'City is required (up to 100 characters)',
    'permanent_addresses_city_check': 'City is required (up to 100 characters)',
    'current_addresses_area_check': 'Area is required (up to 150 characters)',
    'permanent_addresses_area_check': 'Area is required (up to 150 characters)',
    'current_addresses_address_check':
        'Address is required (up to 500 characters)',
    'permanent_addresses_address_check':
        'Address is required (up to 500 characters)',
    'player_profiles_player_role_check': 'Choose your playing role',
    'player_profiles_batting_style_check': 'Choose a valid batting style',
    'player_profiles_bowling_style_check': 'Choose a valid bowling style',
    'player_profiles_batting_follows_role':
        "The batting style doesn't match the playing role",
    'player_profiles_bowling_follows_role':
        "The bowling style doesn't match the playing role",
    'player_profiles_wicketkeeper_batsman_only':
        'Only a Batsman can be the wicket keeper',
  };

  static Exception _constraint(GatewayConstraintException e) {
    if (e.sqlState == '42501') return const NotSignedInException();
    if (e.sqlState == '23502') {
      return const ProfileValidationException(
        'Please complete all address fields',
      );
    }
    final name = e.constraint ?? _constraintIn(e.message);
    final byName = name == null ? null : _byConstraint[name];
    if (byName != null) return ProfileValidationException(byName);
    for (final MapEntry(key: fragment, value: text) in _byMessage.entries) {
      if (e.message.contains(fragment)) {
        return text == null
            ? const NotSignedInException()
            : ProfileValidationException(text);
      }
    }
    return e.sqlState.startsWith('23')
        ? const ProfileValidationException(generic)
        : const BackendOperationException();
  }

  /// `… violates check constraint "<name>"` → `<name>`.
  static String? _constraintIn(String message) =>
      RegExp(r'constraint "([^"]+)"').firstMatch(message)?.group(1);

  /// The canonical stored phone: `+923XXXXXXXXX`. Throws
  /// [ProfileValidationException] for anything that isn't a Pakistani mobile.
  static String storedPhone(String phone) {
    final local = CeValidators.normalizePkPhone(phone);
    if (local == null) {
      throw ProfileValidationException(CeValidators.pkPhone(phone) ?? generic);
    }
    return '+92${local.substring(1)}';
  }
}
