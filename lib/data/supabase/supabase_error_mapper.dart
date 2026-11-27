import '../../core/models/announcement.dart' show ClubAnnouncement;
import '../../core/models/fitness.dart' show WorkoutEntry;
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
    // update_profile_details (migration 30): a completed profile keeps its phone.
    'profile_completed requires phone': 'A phone number is required for a completed profile',
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
    // profiles (migration 30): the same texts as the app's own checks.
    'profiles_full_name_check': 'Enter your full name (2–100 characters)',
    'profiles_phone_check': 'Enter a valid mobile number (03XX-XXXXXXX)',
    'profiles_role_check': 'Choose a valid role (Player or Club Owner)',
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
    // Profile and club pictures (migration 31): `media: …` refusals, 42501
    // or 22023, and the Storage API's own (translated by the gateway).
    if (_media(e.message) case final mapped?) return mapped;
    // 42501 is a privilege / row-level security refusal: the session is
    // fine, so it never means "sign in again" — except the database
    // functions' own `not authenticated` (no auth.uid()).
    if (e.sqlState == '42501') {
      return e.message.contains('not authenticated')
          ? const NotSignedInException()
          : const PermissionDeniedException();
    }
    // A team saved from a stale copy (M4 optimistic concurrency): 40001.
    if (e.sqlState == '40001' && e.message.contains('team:')) {
      return const TeamChangedElsewhereException();
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
    // Logged workouts and the owner's squad fitness (migration 34).
    if (_fitness(e.message) case final mapped?) return mapped;
    // Player Hunt (migration 33).
    if (_hunt(e.message) case final mapped?) return mapped;
    // Tournaments (migration 35).
    if (_tournament(e.message) case final mapped?) return mapped;
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

  /// `media: …` refusals (migration 31 and Storage) → [MediaException].
  static Exception? _media(String message) {
    if (!message.contains('media:')) return null;
    bool has(String s) => message.contains('media: $s');
    if (has('not authenticated')) return const NotSignedInException();
    if (has('profile not found')) return const ProfileNotFoundException();
    if (has('too large')) return const MediaException.tooLarge();
    if (has('unsupported type') || has('invalid type')) return const MediaException.unsupported();
    if (has('not owner') || has('not allowed')) return const MediaException.notAllowed();
    return const MediaException.failed();
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
    if (has('changed elsewhere')) return const TeamChangedElsewhereException();
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

  /// Availability slots (migration 32). "not authenticated" / "not allowed"
  /// are 42501 (above).
  static const _slotTexts = {
    'club not found': 'Your club no longer exists.',
    'not found': 'This slot no longer exists.',
    'invalid date': 'Choose a date from tomorrow (Pakistan time), up to a year ahead.',
    'invalid time': 'Choose a time slot that ends after it starts, by 11:59 pm.',
    'invalid city': 'Choose a city (up to 60 characters).',
    'invalid ground': 'Choose a listed ground, or any ground in the city.',
    'invalid venue': 'Keep the venue to 100 characters.',
    'invalid notes': 'Keep the notes to 200 characters.',
    'invalid': 'Check the format (Custom needs 1–50 overs).',
    'overlaps': 'You already have an open slot at that time — pick another time.',
    'too many open': 'You already have 10 open slots — remove one before posting another.',
    'not open': 'This slot has already started or been taken.',
  };
  static const _clubTexts = {
    'not found': 'This club is no longer available.',
    'invalid': 'Keep the search to 100 characters and the city to 60.',
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
      // Club discovery, slots and rankings (migration 32).
      ('slot', _slotTexts, "Some slot details aren't valid — please check and try again"),
      ('club', _clubTexts, 'This club isn’t available.'),
      ('ranking', const {'invalid': 'Couldn’t load the rankings — please try again.'}, 'Couldn’t load the rankings — please try again.'),
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
      ('push', const {'too many device moves': 'This phone was moved between accounts too often — please try again later.'}, 'Couldn’t set up notifications on this phone — please try again.'),
    ]) {
      final reason = _reason(message, prefix);
      if (reason == null) continue;
      return NotificationRuleException(texts[reason] ?? fallback);
    }
    return null;
  }

  /// `fitness: …` refusals (migration 34) → [FitnessRuleException], checked
  /// most specific first. "not authenticated" / "not allowed" are 42501
  /// (above); an unknown reason gets a generic text — never the raw message.
  static const _fitnessTexts = [
    ('too many workouts on that day', FitnessTexts.perDay),
    ('too many workouts logged', FitnessTexts.perWindow),
    ('workout not found', FitnessTexts.notFound),
    ('future date', FitnessTexts.futureDate),
    ('date too old', FitnessTexts.tooOld),
    ('invalid date', FitnessTexts.date),
    ('invalid type', FitnessTexts.type),
    ('invalid minutes', FitnessTexts.minutes),
    ('invalid intensity', FitnessTexts.intensity),
    ('notes too long', FitnessTexts.notes),
    ('invalid range', FitnessTexts.range),
  ];

  static Exception? _fitness(String message) {
    if (!message.contains('fitness:')) return null;
    if (message.contains('fitness: not authenticated')) return const NotSignedInException();
    if (message.contains('fitness: not allowed')) return const PermissionDeniedException();
    if (message.contains('fitness: profile not found')) return const ProfileNotFoundException();
    for (final (reason, text) in _fitnessTexts) {
      if (message.contains('fitness: $reason')) return FitnessRuleException(text);
    }
    return const FitnessRuleException(FitnessTexts.generic);
  }

  /// `hunt: …` refusals (migration 33) → [HuntRuleException], checked most
  /// specific first. The daily limits say when to try again; "not
  /// authenticated" / "not allowed" are 42501 (above).
  static const _huntTexts = [
    ('profile not found', null),
    ('player profile required', HuntTexts.profileRequired),
    ('city required', HuntTexts.cityRequired),
    ('invalid listing', HuntTexts.generic),
    ('invalid role', HuntTexts.role),
    ('invalid format', HuntTexts.format),
    ('invalid players needed', HuntTexts.players),
    ('invalid city', HuntTexts.city),
    ('invalid date', HuntTexts.date),
    ('invalid time', HuntTexts.time),
    ('invalid budget', HuntTexts.budget),
    ('invalid notes', HuntTexts.notes),
    ('duplicate post', HuntTexts.duplicate),
    ('too many open posts', HuntTexts.tooManyOpen),
    ('too many posts', HuntTexts.tooManyPosts),
    ('too many interests', HuntTexts.tooManyInterests),
    ('too many invites', HuntTexts.tooManyInvites),
    ('post not found', HuntTexts.postGone),
    ('post closed', HuntTexts.postClosed),
    ('own club', HuntTexts.ownClub),
    ('invalid player', HuntTexts.playerUnavailable),
    ('cannot invite yourself', HuntTexts.self),
    ('invalid post', HuntTexts.postGone),
    ('already a member', HuntTexts.alreadyMember),
    ('player not available', HuntTexts.playerUnavailable),
    ('already invited', HuntTexts.alreadyInvited),
    ('invite declined recently', HuntTexts.declinedRecently),
    ('invalid answer', HuntTexts.generic),
    ('invite not found', HuntTexts.inviteGone),
    ('invite not pending', HuntTexts.inviteAnswered),
  ];

  static Exception? _hunt(String message) {
    if (!message.contains('hunt:')) return null;
    for (final (reason, text) in _huntTexts) {
      if (!message.contains('hunt: $reason')) continue;
      return text == null ? const ProfileNotFoundException() : HuntRuleException(text);
    }
    return const HuntRuleException(HuntTexts.generic);
  }

  /// `tournament: …` refusals (migration 35) → [TournamentRuleException]
  /// with its reason, checked longest first where one reason starts another
  /// ("too many tournaments, try later"). "not authenticated" / "not
  /// allowed" are 42501 (above).
  static const _tournamentTexts = [
    ('invalid name', TournamentTexts.name),
    ('invalid city', TournamentTexts.city),
    ('invalid ground', TournamentTexts.ground),
    ('invalid format', TournamentTexts.format),
    ('invalid overs', TournamentTexts.overs),
    ('invalid type', TournamentTexts.type),
    ('invalid start date', TournamentTexts.startDate),
    ('start date in the past', TournamentTexts.startPast),
    ('start date too far ahead', TournamentTexts.startTooFar),
    ('invalid end date', TournamentTexts.endDate),
    ('end date before start date', TournamentTexts.endBeforeStart),
    ('tournament too long', TournamentTexts.tooLong),
    ('invalid deadline', TournamentTexts.deadline),
    ('deadline in the past', TournamentTexts.deadlinePast),
    ('deadline after start date', TournamentTexts.deadlineAfterStart),
    ('invalid max teams', TournamentTexts.maxTeams),
    ('invalid entry fee', TournamentTexts.entryFee),
    ('invalid prize', TournamentTexts.prize),
    ('invalid description', TournamentTexts.description),
    ('invalid rules', TournamentTexts.rules),
    ('too many tournaments, try later', TournamentTexts.tooManyToday),
    ('too many tournaments', TournamentTexts.tooManyOpen),
    ('rules not agreed', TournamentTexts.rulesNotAgreed),
    ('invalid squad', TournamentTexts.squad),
    ('squad must be 11 + 4', TournamentTexts.squadSize),
    ('invalid captain', TournamentTexts.captain),
    ('invalid vice-captain', TournamentTexts.viceCaptain),
    ('invalid wicket-keeper', TournamentTexts.keeper),
    ('invalid team name', TournamentTexts.teamName),
    ('invalid team', TournamentTexts.team),
    ('player not in club', TournamentTexts.playerNotInClub),
    ('own tournament', TournamentTexts.ownTournament),
    ('team archived', TournamentTexts.teamArchived),
    ('registration closed', TournamentTexts.closed),
    ('registration full', TournamentTexts.full),
    ('already registered', TournamentTexts.alreadyRegistered),
    ('player unavailable', TournamentTexts.playerUnavailable),
    ('player already registered', TournamentTexts.playerElsewhere),
    ('too many requests', TournamentTexts.tooManyRequests),
    ('too many registrations, try later', TournamentTexts.tooManyRegistrations),
    ('not pending', TournamentTexts.notPending),
    ('not approved', TournamentTexts.notApproved),
    ('fixtures generated', TournamentTexts.fixturesGenerated),
    ('not enough teams', TournamentTexts.notEnoughTeams),
    ('registration not found', TournamentTexts.registrationGone),
    ('fixture not found', TournamentTexts.generic),
    ('not found', TournamentTexts.tournamentGone),
  ];

  static Exception? _tournament(String message) {
    if (!message.contains('tournament:')) return null;
    for (final (reason, text) in _tournamentTexts) {
      if (message.contains('tournament: $reason')) return TournamentRuleException(text, reason: reason);
    }
    return const TournamentRuleException(TournamentTexts.generic);
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

/// What a refused Player Hunt change tells the person (migration 33).
abstract final class HuntTexts {
  static const profileRequired = 'Set up your cricket profile first (Role Selection → Player).';
  static const cityRequired = 'Add your city to your profile before listing yourself.';
  static const role = 'Choose the role.';
  static const format = 'Choose the match format.';
  static const players = 'Choose between 1 and 11 players.';
  static const city = 'Keep the city to 100 characters.';
  static const date = 'Choose a date from today, up to 180 days ahead.';
  static const time = 'Choose the match time again.';
  static const budget = 'Choose the budget.';
  static const notes = 'Keep the notes to 280 characters.';
  static const duplicate = 'You already have this requirement posted';
  static const tooManyOpen = 'You already have 10 open requirements — remove one before posting another.';
  static const tooManyPosts = 'You posted 20 requirements in the last 24 hours — please try again later.';
  static const tooManyInterests = 'You showed interest 30 times in the last 24 hours — please try again later.';
  static const tooManyInvites = 'Your club sent 20 invites in the last 24 hours — please try again later.';
  static const postGone = 'This requirement is no longer available.';
  static const postClosed = 'This requirement is closed — the club isn’t looking any more.';
  static const ownClub = 'This is your own club’s requirement.';
  static const self = 'You can’t invite yourself.';
  static const alreadyMember = 'This player is already a member of your club.';
  static const playerUnavailable = 'This player isn’t available any more.';
  static const alreadyInvited = 'You already invited this player.';
  static const declinedRecently = 'This player declined your invite recently — try again after 30 days.';
  static const inviteGone = 'This invite is no longer available.';
  static const inviteAnswered = 'This invite was already answered or has expired.';
  static const generic = "Some details aren't valid — please check and try again";
}

/// What a refused tournament change tells the club owner (migration 35).
/// Where the app checks the same thing first, the texts are the same.
abstract final class TournamentTexts {
  static const name = 'Enter a tournament name (up to 60 characters)';
  static const city = 'Please select a city (up to 60 characters)';
  static const ground = 'Enter a ground (up to 60 characters)';
  static const format = 'Please select a tournament format';
  static const overs = 'Enter between 1 and 50 overs';
  static const type = 'Please select a tournament type';
  static const startDate = 'Please select a start date';
  static const startPast = 'Start date cannot be in the past';
  static const startTooFar = 'The start date must be within a year from today';
  static const endDate = 'Please select an end date';
  static const endBeforeStart = 'End date must be on or after the start date';
  static const tooLong = 'A tournament can last at most 180 days';
  static const deadline = 'Please select a registration deadline';
  static const deadlinePast = 'Registration deadline cannot be in the past';
  static const deadlineAfterStart = 'Registration must close on or before the start date';
  static const maxTeams = 'Enter between 2 and 32 teams';
  static const entryFee = 'Enter an entry fee up to Rs 9,999,999';
  static const prize = 'Enter a prize up to Rs 99,999,999';
  static const description = 'Keep the description to 500 characters';
  static const rules = 'Keep to 20 rules of up to 200 characters each';
  static const tooManyToday = 'Your club created 5 tournaments in the last 24 hours — please try again later.';
  static const tooManyOpen =
      'Your club already has 20 tournaments that are not completed — finish one before hosting another.';
  static const rulesNotAgreed = 'Please agree to the tournament rules';
  static const squad = 'Pick your squad again — a player is listed twice or not at all';
  static const squadSize = 'A tournament squad needs exactly 11 players + 4 substitutes';
  static const captain = 'The captain must be in the Playing XI';
  static const viceCaptain = 'The vice-captain must be in the Playing XI and not the captain';
  static const keeper = 'The wicket-keeper must be in the Playing XI';
  static const team = 'Choose one of your club’s active teams';
  static const teamName = 'Enter a team name (up to 40 characters)';
  static const playerNotInClub = 'A player in this squad is no longer a member of your club';
  static const ownTournament = 'Your club is hosting this tournament';
  static const teamArchived = 'This team is archived — choose another team';
  static const closed = 'Registration for this tournament has closed';
  static const full = 'Registration is full';
  static const alreadyRegistered = 'Your club has already registered for this tournament';
  static const playerUnavailable = 'A player in this squad is injured or unavailable on the start date';
  static const playerElsewhere = 'A player in this squad is already registered for this tournament with another team';
  static const tooManyRequests = 'This tournament has too many requests waiting — please try again later.';
  static const tooManyRegistrations =
      'Your club submitted 20 registrations in the last 24 hours — please try again later.';
  static const notPending = 'This request has already been decided';
  static const notApproved = 'This team is no longer confirmed';
  static const fixturesGenerated = 'Fixtures are already generated';
  static const notEnoughTeams = 'Need at least 2 teams to generate fixtures';
  static const registrationGone = 'This registration is no longer available.';
  static const tournamentGone = 'This tournament is no longer available.';
  static const generic = "Some tournament details aren't valid — please check and try again";
}

/// What a refused workout tells the player (the app's own checks and the
/// server's `fitness: …` refusals say the same).
abstract final class FitnessTexts {
  static const futureDate = "A workout can't be in the future";
  static const tooOld = 'Choose a date within the last year';
  static const minutes =
      'Enter minutes between 1 and ${WorkoutEntry.maxMinutes}';
  static const notes =
      'Keep the notes to ${WorkoutEntry.notesMaxLength} characters';
  static const type = 'Choose a workout type';
  static const intensity = 'Choose an intensity';
  static const date = 'Choose the workout date';
  static const perDay =
      'You already logged 10 workouts on that day — that’s the limit';
  static const perWindow =
      'You logged 30 workouts in the last 24 hours — please try again later';
  static const notFound = 'This workout no longer exists';
  static const range = 'Couldn’t load the workouts — please try again';
  static const generic =
      "Some workout details aren't valid — please check and try again";
}
