import '../../app/router/routes.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import 'notifications_controller.dart' show notificationLocation;

/// Server notifications (migration 25) → the inbox's rows. The server sends a
/// type and its parameters; the wording is written here (decision D3).
///
/// Never throws: a missing parameter gets a neutral word ("your club", "a
/// player") rather than an error, and a person who deleted their account is
/// "Deleted player" (D11). A target is given only where its id is known, and
/// always inside the notification's own inbox (a Player row never opens a
/// Club Owner screen).
abstract final class ServerNotificationAdapter {
  static const deletedPerson = 'Deleted player';

  static NotificationItem item(ServerNotification n) {
    final (icon, tone, title, subtitle, target) = _parts(n);
    return NotificationItem(
      id: n.id,
      role: n.role,
      icon: icon,
      title: title,
      subtitle: subtitle,
      createdAt: n.createdAt,
      tone: tone,
      target: _ownInbox(n.role, target) ? target : null,
    );
  }

  /// A target never leaves the notification's inbox (defence in depth: the
  /// server sends each type to one inbox only).
  static bool _ownInbox(UserRole role, NotificationTarget? target) {
    final location = notificationLocation(target);
    if (location == null) return true;
    return role == UserRole.player
        ? Routes.isPlayerLocation(location)
        : Routes.isClubLocation(location);
  }

  static (String, NotificationTone, String, String, NotificationTarget?) _parts(
    ServerNotification n,
  ) {
    final club = n.text('club_name') ?? 'your club';
    final opponent = n.text('opponent_name') ?? 'the other club';
    final person = n.personDeleted
        ? deletedPerson
        : (n.text('person_name') ?? 'A club member');
    final owner = n.role == UserRole.clubOwner;
    final matchId = n.matchId;
    final subjectId = n.subjectId;
    // Match notices open the match in the notification's own inbox.
    final NotificationTarget? matchTarget = matchId == null
        ? null
        : owner
        ? const ClubMatchesTarget(MatchTab.scheduled)
        : PlayerMatchTarget(matchId);
    final NotificationTarget? resultTarget = matchId == null
        ? null
        : owner
        ? ClubMatchResultTarget(matchId)
        : PlayerScorecardTarget(matchId);
    final fixture = _join([
      '$club vs $opponent',
      _when(n.instant('starts_at')),
    ]);

    return switch (n.type) {
      ServerNotificationType.joinRequestReceived => (
        'user-plus',
        NotificationTone.amber,
        'Join request from $person',
        club,
        subjectId == null ? null : JoinRequestTarget(subjectId),
      ),
      ServerNotificationType.joinRequestApproved => (
        'check-circle',
        NotificationTone.green,
        'Join request approved',
        'You are now ${_article(_role(n.text('role')))} at $club',
        const PlayerProfileTarget(),
      ),
      ServerNotificationType.joinRequestDeclined => (
        'x-circle',
        NotificationTone.amber,
        'Join request not accepted',
        '$club didn’t accept your request',
        null,
      ),
      ServerNotificationType.removedFromClub => (
        'users',
        NotificationTone.amber,
        'Club membership ended',
        'You are no longer a member of $club',
        null,
      ),
      ServerNotificationType.ownershipOffered => (
        'shield',
        NotificationTone.green,
        'Club ownership offer',
        '$person offered you ownership of $club',
        const OwnershipOffersTarget(),
      ),
      ServerNotificationType.ownershipWithdrawn => (
        'shield',
        NotificationTone.amber,
        'Ownership offer withdrawn',
        '$person withdrew the offer for $club',
        null,
      ),
      ServerNotificationType.ownershipRejected => (
        'shield',
        NotificationTone.amber,
        'Ownership offer declined',
        '$person declined ownership of $club',
        const ClubOwnershipTarget(),
      ),
      ServerNotificationType.ownershipAccepted => (
        'shield',
        NotificationTone.blue,
        'Club ownership transferred',
        '$person is now the owner of $club',
        null,
      ),
      ServerNotificationType.challengeReceived => (
        'swords',
        NotificationTone.green,
        'Challenge from $opponent',
        _terms(n),
        const MyChallengesTarget(),
      ),
      ServerNotificationType.challengeAccepted => (
        'swords',
        NotificationTone.green,
        '$opponent accepted your challenge',
        _join([_terms(n), 'Agree the schedule next']),
        const ClubMatchesTarget(MatchTab.waiting),
      ),
      ServerNotificationType.challengeDeclined => (
        'swords',
        NotificationTone.amber,
        '$opponent declined your challenge',
        _terms(n),
        const MyChallengesTarget(),
      ),
      ServerNotificationType.scheduleProposed => (
        'calendar',
        NotificationTone.amber,
        n.flag('reschedule')
            ? '$opponent proposed a new match time'
            : '$opponent proposed a match time',
        _schedule(n),
        ClubMatchesTarget(
          n.flag('reschedule') ? MatchTab.scheduled : MatchTab.waiting,
        ),
      ),
      ServerNotificationType.scheduleAccepted => (
        'calendar-check',
        NotificationTone.green,
        n.flag('reschedule')
            ? '$opponent accepted the new match time'
            : '$opponent confirmed the match',
        _schedule(n),
        const ClubMatchesTarget(MatchTab.scheduled),
      ),
      ServerNotificationType.scheduleDeclined => (
        'calendar',
        NotificationTone.amber,
        '$opponent declined your proposed time',
        _schedule(n),
        ClubMatchesTarget(
          n.flag('reschedule') ? MatchTab.scheduled : MatchTab.waiting,
        ),
      ),
      ServerNotificationType.matchRescheduled => (
        'calendar',
        NotificationTone.blue,
        'Match rescheduled',
        _join([fixture, n.text('venue_name')]),
        matchTarget,
      ),
      ServerNotificationType.matchCancelled => (
        'x-circle',
        NotificationTone.amber,
        'Match cancelled',
        // An owner hears it from the other club; a player sees the fixture.
        n.params.containsKey('selection') || !owner
            ? fixture
            : _join(['vs $opponent', _when(n.instant('starts_at'))]),
        owner ? const ClubMatchesTarget(MatchTab.history) : matchTarget,
      ),
      ServerNotificationType.lineupSelected => (
        'check-circle',
        NotificationTone.green,
        _selected(n),
        fixture,
        matchTarget,
      ),
      ServerNotificationType.lineupChanged => (
        'users',
        NotificationTone.blue,
        n.text('selection') == 'playing'
            ? 'You’re now in the Playing XI'
            : 'You’re now a substitute',
        fixture,
        matchTarget,
      ),
      ServerNotificationType.lineupDropped => (
        'users',
        NotificationTone.amber,
        'You’re no longer in the line-up',
        fixture,
        matchTarget,
      ),
      ServerNotificationType.resultPublished => (
        'trophy',
        _resultTone(n.text('result')),
        _result(n.text('result'), club, opponent),
        'Official result',
        resultTarget,
      ),
      ServerNotificationType.resultCorrected => (
        'trophy',
        NotificationTone.blue,
        _result(n.text('result'), club, opponent),
        'The official result was corrected',
        resultTarget,
      ),
      ServerNotificationType.playerOfMatch => (
        'trophy',
        NotificationTone.green,
        'You’re the Player of the Match',
        '$club vs $opponent',
        resultTarget,
      ),
      ServerNotificationType.announcement => (
        'megaphone',
        NotificationTone.green,
        'Club Announcement',
        _join([club, n.text('title')]),
        subjectId == null ? null : AnnouncementTarget(subjectId),
      ),
      // Reminders (migration 28, M3 P6).
      ServerNotificationType.matchReminder => (
        'clock',
        NotificationTone.blue,
        'Your match is coming up',
        _join([fixture, n.text('venue_name')]),
        matchTarget,
      ),
      ServerNotificationType.challengeExpiring => (
        'hourglass',
        NotificationTone.amber,
        'Challenge from $opponent expires soon',
        _join([_answerBy(n), _terms(n)]),
        const MyChallengesTarget(),
      ),
      ServerNotificationType.ownershipExpiring => (
        'hourglass',
        NotificationTone.amber,
        'Ownership offer expires soon',
        _join(['$person offered you $club', _answerBy(n)]),
        const OwnershipOffersTarget(),
      ),
    };
  }

  // ---- Pieces ----

  static String? _answerBy(ServerNotification n) =>
      switch (_when(n.instant('expires_at'))) {
        final String w => 'Answer by $w',
        null => null,
      };

  static String _join(List<String?> parts) =>
      parts.whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  static String? _when(DateTime? at) => at == null
      ? null
      : '${CeFormat.weekdayTime(at)}, ${CeFormat.dayMonth(at)}';

  static String _terms(ServerNotification n) {
    final format = MatchFormat.values
        .where((f) => f.name == n.text('format'))
        .firstOrNull;
    final date = n.date('proposed_date');
    return _join([
      format?.display(n.integer('custom_overs')),
      date == null ? null : CeFormat.dayMonth(date),
      n.text('venue_name'),
    ]);
  }

  static String _schedule(ServerNotification n) => _join([
    _when(n.instant('starts_at')),
    n.text('venue_name'),
    n.text('city'),
  ]);

  static String _selected(ServerNotification n) =>
      switch ((n.text('selection'), n.text('leader'))) {
        ('playing', 'captain') => 'You’re captain of the Playing XI',
        ('playing', 'vice_captain') => 'You’re vice-captain of the Playing XI',
        ('playing', _) => 'You’re in the Playing XI',
        _ => 'You’re a substitute',
      };

  static String _role(String? code) =>
      (MemberRole.values
                  .where((r) => r.name == code && r != MemberRole.owner)
                  .firstOrNull
                  ?.label ??
              'Member')
          .toLowerCase();

  static String _article(String role) =>
      '${'aeiou'.contains(role[0]) ? 'an' : 'a'} $role';

  static String _result(String? result, String club, String opponent) =>
      switch (result) {
        'won' => '$club won against $opponent',
        'lost' => '$club lost to $opponent',
        'tied' => '$club tied with $opponent',
        'abandoned' => 'Abandoned: $club vs $opponent',
        _ => 'No result: $club vs $opponent',
      };

  static NotificationTone _resultTone(String? result) => switch (result) {
    'won' => NotificationTone.green,
    'lost' => NotificationTone.amber,
    _ => NotificationTone.blue,
  };
}
