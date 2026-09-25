import '../../core/enums/enums.dart';
import 'routes.dart';

/// A drawer destination. Also defines which locations are "top-level" and may
/// be remembered as the role's last route (prototype `ceLastScreen` rule).
class RoleDestination {
  const RoleDestination(this.icon, this.label, this.location);
  final String icon; // icon key → CeIcons
  final String label;
  final String location;
}

class DestinationGroup {
  const DestinationGroup(this.label, this.items);
  final String label;
  final List<RoleDestination> items;
}

/// Prototype `CE_ROLES` (criceco-app.js :7809) with the approved fix:
/// Club Owner "Tournaments" opens the Tournament hub.
abstract final class RoleDestinations {
  static const player = [
    DestinationGroup('Navigate', [
      RoleDestination('home', 'Dashboard', Routes.playerHome),
      RoleDestination('user', 'My Profile', Routes.playerProfile),
      RoleDestination('bar-chart', 'My Performance', Routes.myPerformance),
    ]),
    DestinationGroup('Cricket', [
      RoleDestination('calendar', 'My Matches', Routes.myMatches),
      RoleDestination('circle-dot', 'Open Matches', Routes.openMatches),
      RoleDestination('check-circle', 'Availability', Routes.availability),
      RoleDestination('bell', 'Notifications', Routes.notifications),
    ]),
  ];

  static const club = [
    DestinationGroup('Navigate', [
      RoleDestination('home', 'Dashboard', Routes.clubHome),
      RoleDestination('shield', 'My Club', Routes.myClub),
      RoleDestination('users', 'My Teams', Routes.teams),
    ]),
    DestinationGroup('Manage', [
      RoleDestination('clipboard-list', 'Members', Routes.members),
      RoleDestination('search', 'Player Hunt', Routes.playerHunt),
      RoleDestination('swords', 'Challenges', Routes.challenges),
      RoleDestination('calendar', 'Match Management', '/club/matches'),
      RoleDestination('trophy', 'Tournaments', Routes.tournamentHub),
      RoleDestination('user', 'Requests', Routes.joinRequests),
      RoleDestination('bell', 'Notifications', Routes.notifications),
    ]),
  ];

  static List<DestinationGroup> forRole(UserRole role) => role == UserRole.player ? player : club;

  /// Role-owned top-level locations (excludes shared ones like Notifications).
  static Set<String> topLevel(UserRole role) => {
        for (final g in forRole(role))
          for (final d in g.items)
            if (role == UserRole.player ? Routes.isPlayerLocation(d.location) : Routes.isClubLocation(d.location))
              d.location,
      };
}
