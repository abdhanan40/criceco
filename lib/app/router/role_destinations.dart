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
      // My Matches, Playing Opportunities and Availability are reached from
      // the dashboard Quick Actions, the bottom nav (Matches) and My Profile
      // ("Update Availability") — not repeated here.
      RoleDestination('bell', 'Notifications', Routes.notifications),
    ]),
  ];

  static const club = [
    DestinationGroup('Navigate', [
      RoleDestination('home', 'Dashboard', Routes.clubHome),
      RoleDestination('shield', 'My Club', Routes.myClub),
      RoleDestination('users', 'My Teams', Routes.teams),
    ]),
    // Members, Find Player, Challenges, Match Management, Tournaments and
    // Requests are reached from the dashboard (sheets / quick actions) and
    // the bottom nav; Edit Club is a drawer action (sheet), not a route.
    DestinationGroup('Manage', [
      RoleDestination('bell', 'Notifications', Routes.notifications),
    ]),
  ];

  static List<DestinationGroup> forRole(UserRole role) => role == UserRole.player ? player : club;

  /// Club areas no longer in the sidebar that are still top-level screens
  /// (remembered as the role's last location, as before).
  static const _clubTopLevelOffMenu = [
    Routes.members,
    Routes.playerHunt,
    Routes.challenges,
    Routes.matchManagementPath,
    Routes.tournamentHub,
    Routes.joinRequests,
  ];

  /// Player areas no longer in the sidebar that are still top-level screens
  /// (remembered as the role's last location, as before).
  static const _playerTopLevelOffMenu = [
    Routes.myMatches,
    Routes.openMatches,
    Routes.availability,
  ];

  /// Role-owned top-level locations (excludes shared ones like Notifications).
  static Set<String> topLevel(UserRole role) => {
        for (final g in forRole(role))
          for (final d in g.items)
            if (role == UserRole.player ? Routes.isPlayerLocation(d.location) : Routes.isClubLocation(d.location))
              d.location,
        if (role == UserRole.player) ..._playerTopLevelOffMenu,
        if (role == UserRole.clubOwner) ..._clubTopLevelOffMenu,
      };
}
