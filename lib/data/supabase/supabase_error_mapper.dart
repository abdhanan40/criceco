import '../../core/models/announcement.dart' show ClubAnnouncement;
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
    GatewayEmailNotConfirmedException() =>
      const EmailConfirmationRequiredException(),
    GatewayInvalidCodeException() => const InvalidVerificationCodeException(),
    GatewayRateLimitedException() => const TooManyRequestsException(),
    GatewaySamePasswordException() => const SamePasswordException(),
    GatewayWrongPasswordException() => const WrongPasswordException(),
    GatewayOwnershipTransferRequiredException() => const ClubOwnershipTransferRequiredException(),
    GatewayDeletionIncompleteException() => const AccountDeletionIncompleteException(),
    GatewayConstraintException() => _constraint(e),
  };

  static const generic =
      "Some details aren't valid — please check and try again";

  /// Messages raised by `save_profile_setup` / `profiles_validate` (and by
  /// `update_profile_details`, migration 9, which uses the same texts).
  static const _byMessage = {
    'not authenticated': null, // → NotSignedInException
    'full_name must be 2': 'Enter your full name (2–100 characters)',
    'phone must be a Pakistani mobile number':
        'Enter a valid mobile number (03XX-XXXXXXX)',
    'date_of_birth is required': 'Date of birth must be in 1900 or later',
    'date_of_birth cannot be in the future':
        "Date of birth can't be in the future",
    'profile_completed requires': 'Please complete all profile details',
    // save_profile_setup_v2 (migration 8): a city id that isn't an active city.
    'current_city_id must be an active city': 'Please choose your city again',
    'permanent_city_id must be an active city':
        'Please choose your permanent city again',
    // Supabase Auth refusals (translated by the SDK gateway).
    'user already exists':
        'An account with this email already exists — please log in',
    'weak password': 'Choose a stronger password',
    // Raised by create_club() (migration 5).
    'club name is required': 'Club name is required',
    'club city is required': 'Please select a city',
    'club type is required': 'Please select a club type',
  };

  /// CHECK / UNIQUE / FOREIGN KEY constraints (migrations 1–3, 5 and 8),
  /// matched by name.
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
    // city_id → public.cities (migration 8, 23503): an unknown city id.
    'current_addresses_city_id_fkey': 'Please choose your city again',
    'permanent_addresses_city_id_fkey':
        'Please choose your permanent city again',
    'player_profiles_player_role_check': 'Choose your playing role',
    'player_profiles_batting_style_check': 'Choose a valid batting style',
    'player_profiles_bowling_style_check': 'Choose a valid bowling style',
    'player_profiles_batting_follows_role':
        "The batting style doesn't match the playing role",
    'player_profiles_bowling_follows_role':
        "The bowling style doesn't match the playing role",
    'player_profiles_wicketkeeper_batsman_only':
        'Only a Batsman can be the wicket keeper',
    // clubs (migration 5).
    'clubs_name_check': 'Enter a club name (up to 100 characters)',
    'clubs_short_name_check': 'Short name must be up to 40 characters',
    'clubs_city_check': 'City is required (up to 100 characters)',
    'clubs_club_type_check': 'Choose a valid club type',
    'clubs_owner_name_check': 'Owner name must be 2–100 characters',
    'clubs_address_check': 'Address must be up to 500 characters',
    'clubs_email_check': 'Enter a valid email address',
    'clubs_home_ground_id_check': 'Choose a valid home ground',
    'clubs_established_year_check':
        'Established year must be between 1800 and 2100',
    // A join-code collision (≈1 in 10⁹): no automatic retry (D-S3-3).
    'clubs_code_key': "Couldn't create the club — please try again",
    'clubs_owner_id_key': 'You already have a club',
    // join_requests / teams (migrations 11–12).
    'join_requests_decline_reason_check': 'Keep the reason to 120 characters',
    'join_requests_message_check': 'Keep the message to 300 characters',
    'teams_name_check': 'Enter a team name (up to 40 characters)',
    'teams_custom_overs_check': 'Enter between 1 and 50 overs',
  };

  static Exception _constraint(GatewayConstraintException e) {
    // 42501 is a privilege / row-level security refusal: the session is
    // fine, so it never means "sign in again" — except the database
    // functions' own `not authenticated` (no auth.uid()).
    if (e.sqlState == '42501') {
      return e.message.contains('not authenticated')
          ? const NotSignedInException()
          : const PermissionDeniedException();
    }
    // Club memberships (migration 11) and teams (migration 12): their
    // functions prefix every refusal ("club_join: …", "team: …").
    if (_membership(e.message) case final mapped?) return mapped;
    if (_team(e.message) case final mapped?) return mapped;
    if (_ownership(e.message) case final mapped?) return mapped;
    // Challenges, matches, lineups, availability (migrations 17–19);
    // results, scorecards and statistics (migrations 20–23).
    if (_matches(e.message) case final mapped?) return mapped;
    // The server inbox and club announcements (migration 25).
    if (_notifications(e.message) case final mapped?) return mapped;
    // update_profile_details() (migration 9): no profile row for the
    // signed-in user — nothing was written.
    if (e.sqlState == 'P0002' && e.message.contains('profile not found')) {
      return const ProfileNotFoundException();
    }
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

  /// `club_join: …` refusals (migration 11) → what the person can do next.
  static Exception? _membership(String message) {
    if (!message.contains('club_join:')) return null;
    bool has(String s) => message.contains('club_join: $s');
    if (has('unknown code')) return const ClubCodeNotFoundException();
    // The brute-force throttle (10 failed codes in 15 minutes).
    if (has('too many attempts')) return const TooManyRequestsException();
    if (has('own club')) return const ClubMembershipException('This is your own club — no request needed.');
    if (has('already member')) return const ClubMembershipException('You’re already a member of this club.');
    if (has('already pending')) {
      return const ClubMembershipException('You already have a pending request to this club.');
    }
    if (has('profile incomplete')) {
      return const ClubMembershipException('Complete your profile before joining a club.');
    }
    if (has('not pending')) return const ClubMembershipException('This request has already been decided.');
    if (has('not found')) return const ClubMembershipException('This request or member no longer exists.');
    if (has('invalid role')) return const ClubMembershipException('Choose a valid club role.');
    return const BackendOperationException();
  }

  /// `team: …` refusals (migration 12).
  /// `ownership: …` refusals (migration 16) → what the person can do next.
  /// ("not allowed" / "not authenticated" are 42501: handled above.)
  static Exception? _ownership(String message) {
    if (!message.contains('ownership:')) return null;
    bool has(String s) => message.contains('ownership: $s');
    String text;
    if (has('already pending')) {
      text = 'This club already has an open ownership offer. Cancel it first to offer the club to someone else.';
    } else if (has('self transfer')) {
      text = 'You already own this club.';
    } else if (has('recipient owns a club')) {
      text = 'This member already owns a club — a person can own only one.';
    } else if (has('recipient profile incomplete')) {
      text = 'This member hasn’t completed their profile yet, so they can’t own a club.';
    } else if (has('not a member')) {
      text = 'This person isn’t an active member of the club any more.';
    } else if (has('not pending')) {
      text = 'This offer has already been answered or cancelled.';
    } else if (has('no longer valid')) {
      text = 'This offer is no longer valid.';
    } else if (has('invalid')) {
      text = 'Choose Player, Coach or Manager as your new role.';
    } else {
      text = 'This offer no longer exists.';
    }
    return OwnershipTransferException(text);
  }

  static Exception? _team(String message) {
    if (!message.contains('team:')) return null;
    bool has(String s) => message.contains('team: $s');
    if (has('duplicate name')) return const TeamRuleException('A team with this name already exists');
    if (has('squad full')) {
      return const TeamRuleException('A squad can have at most 11 players and 4 substitutes');
    }
    if (has('player not in club')) {
      return const TeamRuleException('Only active club members can be added to a team');
    }
    if (has('archived')) return const TeamRuleException('This team has been deleted');
    if (has('not found')) return const TeamRuleException('This team no longer exists');
    if (has('invalid')) return const TeamRuleException("Some team details aren't valid — please check and try again");
    return const BackendOperationException();
  }

  /// The refusal reason after a `challenge:` / `match:` / `lineup:` /
  /// `availability:` prefix (migrations 17–19), e.g. "already pending".
  static String? _reason(String message, String prefix) =>
      RegExp('(?:^|[^a-z_])$prefix: ([a-z -]+)').firstMatch(message)?.group(1)?.trim();

  /// Text per refusal, checked most specific first.
  static const _challengeTexts = {
    'own club': 'You can’t challenge your own club.',
    'club not found': 'This club no longer exists.',
    'invalid date': 'Choose a match date from tomorrow, up to a year ahead.',
    'invalid venue': 'Enter a venue (up to 100 characters).',
    'invalid message': 'Keep the message to 280 characters.',
    'already pending': 'There’s already an open challenge between your clubs.',
    'too many pending': 'You have 20 open challenges — wait for replies before sending more.',
    'not pending': 'This challenge has already been answered.',
    'not found': 'This challenge no longer exists.',
    'invalid': 'Check the match format (Custom needs 1–50 overs).',
  };
  static const _matchTexts = {
    'not open': 'This match is closed — it was cancelled or played.',
    'already started': 'This match has already started.',
    'no proposal': 'There’s no open proposal to answer.',
    'proposal changed': 'The other club changed the proposal — check the new time and try again.',
    'schedule clash': 'One of the clubs already has a confirmed match at that time.',
    'invalid time': 'Choose a start time in the future, up to a year ahead.',
    'invalid venue': 'Enter a venue (up to 100 characters).',
    'invalid city': 'Keep the city to 60 characters.',
    'invalid reason': 'Give a reason (up to 200 characters).',
    'not found': 'This match no longer exists.',
  };
  static const _lineupTexts = {
    'match not confirmed': 'Lineups can be saved only for confirmed matches.',
    'match started': 'This match has already started — the lineup is locked.',
    'invalid squad': 'A lineup needs exactly 11 players and 4 substitutes.',
    'invalid captain': 'Pick the captain from the Playing XI (not the vice-captain).',
    'invalid vice-captain': 'Pick the vice-captain from the Playing XI.',
    'invalid team': 'Choose one of your club’s teams.',
    'invalid name': 'Enter a lineup name (up to 40 characters).',
    'team archived': 'This team has been deleted.',
    'player not in club': 'Only active members of your club can be in the lineup.',
    'player unavailable': 'A selected player is injured or unavailable on the match day.',
    'not found': 'This match no longer exists.',
  };
  static const _availabilityTexts = {
    'invalid status': 'Choose a valid availability status.',
    'invalid reason': 'Choose a valid reason.',
    'invalid date': 'Choose an end date from today, up to a year ahead.',
    'invalid notes': 'Keep the notes to 200 characters.',
    'not found': 'Complete your profile first.',
  };

  /// Official results, scorecards and statistics (migrations 20–24).
  /// The app only READS official results (migration 24): the read functions
  /// refuse with "not authenticated" / "not allowed" (42501, above) or
  /// "not found".
  static const _resultTexts = {
    'not found': 'This match no longer exists.',
  };

  /// Refusals of migrations 17–23 → [MatchRuleException] with what to do
  /// next ("not authenticated" / "not allowed" are 42501: handled above).
  /// An unknown reason gets a generic text — never the raw database message.
  static Exception? _matches(String message) {
    for (final (prefix, texts, fallback) in [
      ('challenge', _challengeTexts, "Some challenge details aren't valid — please check and try again"),
      ('match', _matchTexts, "Some match details aren't valid — please check and try again"),
      ('lineup', _lineupTexts, "Some lineup details aren't valid — please check and try again"),
      ('availability', _availabilityTexts, "Some availability details aren't valid — please check and try again"),
      ('result', _resultTexts, 'This result isn’t available.'),
      ('stats', const <String, String>{}, 'These statistics aren’t available.'),
    ]) {
      final reason = _reason(message, prefix);
      if (reason == null) continue;
      return MatchRuleException(texts[reason] ?? fallback);
    }
    return null;
  }

  /// The server inbox and club announcements (migration 25). "not
  /// authenticated" / "not allowed" are 42501 (above).
  static const _notificationTexts = {
    'invalid': 'Couldn’t load your notifications — please try again.',
    'not found': 'Complete your profile first.',
  };
  static const _announcementTexts = {
    'invalid title': 'Enter a title (up to ${ClubAnnouncement.titleMaxLength} characters).',
    'invalid message': 'Enter a message (up to ${ClubAnnouncement.messageMaxLength} characters).',
    'invalid audience': 'Choose who gets the announcement.',
    'too many': 'Your club has sent 20 announcements in the last 24 hours — please try again later.',
    'not found': 'This announcement is no longer available.',
  };

  /// Refusals of migration 25 → [NotificationRuleException]; an unknown
  /// reason gets a generic text — never the raw database message.
  static Exception? _notifications(String message) {
    for (final (prefix, texts, fallback) in [
      ('notification', _notificationTexts, 'Couldn’t update your notifications — please try again.'),
      ('announcement', _announcementTexts, "Some announcement details aren't valid — please check and try again"),
    ]) {
      final reason = _reason(message, prefix);
      if (reason == null) continue;
      return NotificationRuleException(texts[reason] ?? fallback);
    }
    return null;
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
