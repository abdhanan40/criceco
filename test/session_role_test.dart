import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

void main() {
  test('login of a set-up Player infers the role; choosing it explicitly persists it', () async {
    final c = await makeContainer();
    await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
    expect(c.read(sessionProvider).status, SessionStatus.signedIn);
    // The seed account is a completed Player with no club: entered directly.
    expect(c.read(activeRoleProvider), UserRole.player);
    expect(c.read(roleControllerProvider).active, isNull, reason: 'inferred, not stored');

    final nav = c.read(roleControllerProvider.notifier).continueAs(UserRole.player);
    expect(nav, isA<GoToLocation>().having((n) => n.location, 'location', Routes.playerHome));
    expect(c.read(activeRoleProvider), UserRole.player);
    expect((await SharedPreferences.getInstance()).getString('criceco.activeRole'), 'player');
  });

  test('Club Owner without profile goes to setup and does not change role', () async {
    final c = await makeContainer();
    await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
    final roles = c.read(roleControllerProvider.notifier);
    roles.continueAs(UserRole.player);

    expect(roles.continueAs(UserRole.clubOwner), isA<NeedsClubSetup>());
    expect(roles.switchTo(UserRole.clubOwner),
        isA<NeedsClubSetup>().having((n) => n.location, 'location', Routes.roleSetup));
    expect(c.read(activeRoleProvider), UserRole.player);
  });

  test('creating a club grants the profile; switching restores the last top-level route', () async {
    final c = await makeContainer();
    final session = c.read(sessionProvider.notifier);
    final roles = c.read(roleControllerProvider.notifier);
    await session.signIn(identifier: 'x', password: 'y');
    roles.continueAs(UserRole.player);
    roles.recordLocation(Routes.myPerformance);

    await session.createClub(name: 'Lahore Lions CC', city: 'Lahore', type: ClubType.corporate);
    roles.becomeClubOwner();
    expect(c.read(sessionProvider).hasClubOwnerProfile, isTrue);
    expect(c.read(currentClubProvider)!.name, 'Lahore Lions CC');
    roles.recordLocation(Routes.challenges);
    roles.recordLocation('/club/matches/m_3/setup'); // flow step — never remembered

    final back = roles.switchTo(UserRole.player);
    expect(back, isA<GoToLocation>().having((n) => n.location, 'location', Routes.myPerformance));
    final again = roles.switchTo(UserRole.clubOwner);
    expect(again, isA<GoToLocation>().having((n) => n.location, 'location', Routes.challenges));
  });

  test('Coach/Manager membership never grants the Club Owner role (fix C)', () async {
    final c = await makeContainer();
    await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
    await c.read(sessionProvider.notifier).addMembership(
        const ClubMembership(clubId: 'k', clubName: 'Karachi Ravians CC', clubCode: 'KRC001', role: MemberRole.coach));
    c.read(roleControllerProvider.notifier).enterPlayerContext();

    expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
    expect(c.read(activeRoleProvider), UserRole.player);
    expect(c.read(currentAccountProvider)!.memberships.single.role, MemberRole.coach);
  });

  test('logout clears session, active role and persisted keys', () async {
    final c = await makeContainer();
    await c.read(sessionProvider.notifier).signIn(identifier: 'x', password: 'y');
    c.read(roleControllerProvider.notifier)
      ..continueAs(UserRole.player)
      ..recordLocation(Routes.myMatches);

    c.read(sessionProvider.notifier).logout();

    expect(c.read(sessionProvider).isAuthenticated, isFalse);
    expect(c.read(activeRoleProvider), isNull);
    expect(c.read(roleControllerProvider).lastRoute, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('criceco.activeRole'), isNull);
    expect(prefs.getString('criceco.lastRoute.player'), isNull);
    expect(prefs.getString('criceco.session.accountId'), isNull);
  });

  test('active role is restored across restarts (P21)', () async {
    final c = await makeContainer(prefs: {
      'criceco.session.accountId': 'acc_aman',
      'criceco.activeRole': 'player',
      'criceco.lastRoute.player': Routes.myMatches,
      'criceco.lastRoute.clubOwner': '/not/a/top/level', // stale value is healed
    });
    await c.read(sessionProvider.notifier).restore();
    expect(c.read(sessionProvider).status, SessionStatus.signedIn);
    expect(c.read(activeRoleProvider), UserRole.player);
    expect(c.read(roleControllerProvider).lastRoute, {UserRole.player: Routes.myMatches});
  });
}
