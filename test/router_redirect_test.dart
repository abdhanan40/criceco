import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/role_controller.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _account = UserAccount(id: 'a', fullName: 'Aman Ali', contactMethod: ContactMethod.phone, profileComplete: true);
const _player = PlayerProfile(
    role: PlayerRole.batsman, battingStyle: BattingStyle.rightHanded, bowlingStyle: BowlingStyle.rightArmOffSpin);

SessionState _signedIn({bool clubProfile = false, bool player = false}) => SessionState(
      status: SessionStatus.signedIn,
      account: _account.copyWith(hasClubOwnerProfile: clubProfile, playerProfile: player ? _player : null),
    );

String? _r(String loc, SessionState s, UserRole? role) => resolveRedirect(location: loc, session: s, activeRole: role);

void main() {
  group('signed out', () {
    const out = SessionState();
    test('protected routes go to the Auth page (Login)', () {
      expect(_r(Routes.playerHome, out, null), Routes.login);
      expect(_r(Routes.clubHome, out, null), Routes.login);
      expect(_r(Routes.settings, out, null), Routes.login);
      expect(_r(Routes.roleSelection, out, null), Routes.login);
      expect(_r(Routes.profileSetup, out, null), Routes.login);
    });
    test('Login / Sign Up / Create Account allowed', () {
      expect(_r(Routes.login, out, null), isNull);
      expect(_r(Routes.signup, out, null), isNull);
      expect(_r(Routes.createAccount, out, null), isNull);
    });
  });

  test('incomplete common profile forces User Profile Setup (auth screens stay reachable for Back)', () {
    const s = SessionState(status: SessionStatus.onboarding, account: _account);
    expect(_r(Routes.playerHome, s, null), Routes.profileSetup);
    expect(_r(Routes.roleSelection, s, null), Routes.profileSetup);
    expect(_r(Routes.clubSetup, s, null), Routes.profileSetup);
    expect(_r(Routes.roleDetails, s, null), Routes.profileSetup);
    expect(_r(Routes.profileSetup, s, null), isNull);
    expect(_r(Routes.createAccount, s, null), isNull);
    expect(_r(Routes.signup, s, null), isNull);
  });

  test('profile complete: auth/profile screens go to the role home, else Role Selection', () {
    expect(_r(Routes.login, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.profileSetup, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.login, _signedIn(), UserRole.player), Routes.playerHome);
    expect(_r(Routes.login, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
  });

  test('role routes need a role; Role Selection and Club Setup are open to a signed-in user', () {
    expect(_r(Routes.playerHome, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.clubHome, _signedIn(), null), Routes.roleSelection);
    expect(_r(Routes.roleSelection, _signedIn(), null), isNull);
    expect(_r(Routes.clubSetup, _signedIn(), null), isNull);
  });

  group('returning users: the single completed role is entered directly', () {
    test('Player set up only → Player', () => expect(inferEntryRole(_signedIn(player: true)), UserRole.player));
    test('Club Owner set up only → Club Owner',
        () => expect(inferEntryRole(_signedIn(clubProfile: true)), UserRole.clubOwner));
    test('both or neither → the user chooses on Role Selection', () {
      expect(inferEntryRole(_signedIn(player: true, clubProfile: true)), isNull);
      expect(inferEntryRole(_signedIn()), isNull);
    });
    test('never before the common profile is complete', () {
      final s = SessionState(status: SessionStatus.onboarding, account: _account.copyWith(playerProfile: _player));
      expect(inferEntryRole(s), isNull);
    });
    test('a Player profile needs role + both styles', () {
      expect(const PlayerProfile(role: PlayerRole.bowler).isComplete, isFalse);
      expect(_player.isComplete, isTrue);
    });
  });

  group('navigation never changes the role (role-leak guard)', () {
    test('player cannot enter club routes', () {
      expect(_r(Routes.teams, _signedIn(clubProfile: true), UserRole.player), Routes.playerHome);
      expect(_r(Routes.matchManagement(MatchTab.scheduled), _signedIn(clubProfile: true), UserRole.player),
          Routes.playerHome);
    });
    test('club owner cannot enter player routes', () {
      expect(_r(Routes.myMatches, _signedIn(clubProfile: true), UserRole.clubOwner), Routes.clubHome);
    });
    test('club routes without a Club Owner profile go to Club Setup Details', () {
      expect(_r(Routes.clubHome, _signedIn(), UserRole.clubOwner), Routes.clubSetup);
    });
    test('correct role passes; shared routes pass for any role', () {
      expect(_r(Routes.playerMatchDetails('pm_1'), _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.tournamentHub, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
      expect(_r(Routes.notifications, _signedIn(), UserRole.player), isNull);
      expect(_r(Routes.settings, _signedIn(clubProfile: true), UserRole.clubOwner), isNull);
    });
  });
}
