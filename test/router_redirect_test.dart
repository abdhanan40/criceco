import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _account = UserAccount(id: 'a', fullName: 'Aman Ali', contactMethod: ContactMethod.phone, onboardingComplete: true);

SessionState _signedIn({bool clubProfile = false}) => SessionState(
      status: SessionStatus.signedIn,
      account: _account.copyWith(hasClubOwnerProfile: clubProfile),
    );

String? _r(String loc, SessionState s, UserRole? role) => resolveRedirect(location: loc, session: s, activeRole: role);

void main() {
  group('signed out', () {
    const out = SessionState();
    test('protected routes go to login', () {
      expect(_r(Routes.playerHome, out, null), Routes.login);
      expect(_r(Routes.clubHome, out, null), Routes.login);
      expect(_r(Routes.settings, out, null), Routes.login);
      expect(_r(Routes.continueAs, out, null), Routes.login);
    });
    test('public routes allowed', () {
      expect(_r(Routes.login, out, null), isNull);
      expect(_r(Routes.signup, out, null), isNull);
      expect(_r(Routes.createAccount, out, null), isNull);
    });
  });

  test('onboarding status forces Complete Profile', () {
    const s = SessionState(status: SessionStatus.onboarding, account: _account);
    expect(_r(Routes.playerHome, s, null), Routes.completeProfile);
    expect(_r(Routes.roleDetails, s, null), isNull);
    expect(_r(Routes.continueAs, s, null), Routes.completeProfile);
    // Back from Complete Profile may return to the auth screens.
    expect(_r(Routes.createAccount, s, null), isNull);
    expect(_r(Routes.signup, s, null), isNull);
  });

  test('signed in: auth screens redirect to Continue As or role home', () {
    expect(_r(Routes.login, _signedIn(), null), Routes.continueAs);
    expect(_r(Routes.login, _signedIn(), UserRole.player), Routes.playerHome);
  });

  test('role routes need an active role', () {
    expect(_r(Routes.playerHome, _signedIn(), null), Routes.continueAs);
    expect(_r(Routes.continueAs, _signedIn(), null), isNull);
  });

  group('navigation never changes the role (role-leak guard)', () {
    test('player cannot enter club routes (Availability→Squad, View Match Details leaks)', () {
      expect(_r(Routes.teams, _signedIn(clubProfile: true), UserRole.player), Routes.playerHome);
      expect(_r(Routes.matchManagement(MatchTab.scheduled), _signedIn(clubProfile: true), UserRole.player),
          Routes.playerHome);
    });
    test('club owner cannot enter player routes', () {
      expect(_r(Routes.myMatches, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
    });
    test('club routes without a Club Owner profile go to club setup', () {
      expect(_r(Routes.clubHome, _signedIn(), UserRole.clubOwner), Routes.chooseOption);
    });
    test('correct role passes; shared routes pass for any role', () {
      expect(_r(Routes.playerMatchDetails('pm_1'), _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.tournamentHub, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
      expect(_r(Routes.notifications, _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.settings, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
    });
  });
}
