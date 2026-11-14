// Stage 3B: the owner's club in Supabase mode, end to end through the app —
// created on Club Setup, kept across restarts and logout / login, the club
// row as the only source of the Club Owner profile; Join a Club shows
// "Coming soon" (Phase 3E). On the in-memory gateway fakes: no live project.
import 'package:criceco/app/app.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/club_features.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/app/router/app_router.dart';
import 'package:criceco/app/router/routes.dart';
import 'package:criceco/app/session/session_controller.dart';
import 'package:criceco/core/constants/city_areas.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/navigation/role_shells.dart';
import 'package:criceco/shared/widgets/ce_buttons.dart';
import 'package:criceco/shared/widgets/ce_inputs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_fakes.dart';

class _Picker implements PhotoPicker {
  @override
  Future<String?> pick(PhotoSource source) async => '/photos/gallery.jpg';
}

final _supabase = BackendConfig.parse(
  backend: 'supabase',
  supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
  supabasePublishableKey: 'sb_publishable_test_0000000000000000',
);

const _email = 'owner@example.com';
const _password = 'Cricket@123';

// The "server" and the SDK's stored session: they outlive an app restart.
late FakeDb db;
late FakeAuth auth;
late FakeClubDb clubDb;

/// A (re)started app. [restore] runs what main() does before the first
/// frame. [supabase] false: the in-memory demo (memory mode).
Future<ProviderContainer> _start(
  WidgetTester tester, {
  bool supabase = true,
  Map<String, Object> saved = const {},
  bool restore = false,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(375 * 3, 812 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      nowProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      photoPickerProvider.overrideWithValue(_Picker()),
      cityAreasProvider.overrideWith((ref) async => CityAreas.empty),
      if (supabase) ...[
        backendConfigProvider.overrideWithValue(_supabase),
        authGatewayProvider.overrideWithValue(auth),
        profileGatewayProvider.overrideWithValue(db),
        clubGatewayProvider.overrideWithValue(clubDb),
      ],
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  if (restore) await c.read(sessionProvider.notifier).restore();
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const CricEcoApp()),
  );
  await tester.pumpAndSettle();
  return c;
}

/// What the next start would read from SharedPreferences.
Map<String, Object> _kept(ProviderContainer c) {
  final prefs = c.read(sharedPreferencesProvider);
  return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
}

String _loc(ProviderContainer c) => c.read(routerProvider).state.uri.toString();

Future<void> _go(WidgetTester tester, ProviderContainer c, String route) async {
  c.read(routerProvider).go(route);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

Finder _button(String label) => find.widgetWithText(CeButton, label);

Future<void> _login(WidgetTester tester) async {
  await _enter(tester, 'login.email', _email);
  await _enter(tester, 'login.password', _password);
  await _tap(tester, _button('Login'));
}

/// A user with User Profile Setup done (and optionally a Player profile and
/// a stored role), not signed in on this device yet.
AuthUser _user({String? role, bool player = false}) {
  final u = auth.addUser(_email, _password);
  db.completeProfile(u.id);
  db.profiles[u.id] = {...db.profiles[u.id]!, 'role': role};
  if (player) {
    db.players[u.id] = {
      'user_id': u.id,
      'player_role': 'bowler',
      'batting_style': null,
      'bowling_style': 'right_arm_fast',
      'is_wicketkeeper': false,
    };
  }
  return u;
}

/// A club already stored for [u] (as create_club() leaves it).
Future<Map<String, dynamic>> _storedClub(AuthUser u) async {
  final before = auth.current;
  auth.current = u;
  final row = await clubDb.createClub({
    'p_name': 'Lahore Lions CC',
    'p_city': 'Lahore',
    'p_club_type': 'corporate',
  });
  auth.current = before;
  return row;
}

/// Club Setup Details with valid answers (Home Ground: No).
Future<void> _fillClub(WidgetTester tester) async {
  await _enter(tester, 'club.name', 'Karachi Kites');
  await _enter(tester, 'club.owner', 'Hamza Sheikh');
  await _enter(tester, 'club.address', 'Clifton');
  await _tap(tester, find.byKey(const Key('club.city')));
  await _tap(tester, find.text('Karachi').last);
  await _tap(tester, find.text('Professional'));
  await _tap(tester, find.text('No'));
}

Finder get _clubCard => find.bySemanticsLabel(RegExp(r'^Club Owner\. '));

Finder _navTab(String label) => find.descendant(
  of: find.byType(CeBottomNav),
  matching: find.bySemanticsLabel(label),
);

void main() {
  setUp(() {
    db = FakeDb();
    auth = FakeAuth(db);
    clubDb = FakeClubDb(db);
  });

  group('the club in Supabase', () {
    testWidgets(
      'Create Club → Club Dashboard with its real code; kept across a restart and logout / login',
      (tester) async {
        final u = _user();
        var c = await _start(tester);
        await _login(tester);
        expect(_loc(c), Routes.roleSelection);
        await _tap(tester, _clubCard);
        expect(_loc(c), Routes.clubSetup);
        await _fillClub(tester);
        await _tap(tester, _button('Create Club'));

        expect(_loc(c), Routes.clubHome);
        final row = clubDb.clubs[u.id]!;
        final code = row['code'] as String;
        expect(row['name'], 'Karachi Kites');
        expect(
          db.profiles[u.id]!['role'],
          'club_owner',
          reason: 'set by create_club',
        );
        expect(find.byKey(const Key('club.code')), findsOneWidget);
        expect(
          find.text('Code $code'),
          findsOneWidget,
          reason: 'the real join code',
        );
        final s = c.read(sessionProvider);
        expect(
          (s.hasClubOwnerProfile, s.account!.ownedClubId),
          (true, row['id']),
        );

        // Restart: main() restores the session first, then the app opens.
        c = await _start(tester, saved: _kept(c), restore: true);
        expect(_loc(c), Routes.clubHome);
        expect(c.read(currentClubProvider)!.name, 'Karachi Kites');
        expect(find.text('Code $code'), findsOneWidget);

        // Logout, then login: the club comes back from the database.
        c.read(sessionProvider.notifier).logout();
        await tester.pumpAndSettle();
        expect(_loc(c), Routes.login);
        await _login(tester);
        expect(_loc(c), Routes.clubHome);
        expect(c.read(currentClubProvider)!.code, code);
        expect(clubDb.clubs, hasLength(1), reason: 'never a second club');
      },
    );

    testWidgets('club profile edits and the club picture survive a restart', (
      tester,
    ) async {
      final u = _user();
      final row = await _storedClub(u);
      var c = await _start(tester);
      await _login(tester);
      expect(_loc(c), Routes.clubHome, reason: 'its only role, inferred');
      final session = c.read(sessionProvider.notifier);
      await session.updateClub(
        (club) => club.copyWith(city: 'Multan', establishedYear: 2001),
      );
      await session.updateClub((club) => club.withLogo('/photos/club.jpg'));
      expect(clubDb.clubs[u.id]!['city'], 'Multan');
      expect(clubDb.lastUpdateColumns, {
        'city': 'Multan',
        'established_year': 2001,
      }, reason: 'the picture never goes to the database');

      c = await _start(tester, saved: _kept(c), restore: true);
      final club = c.read(currentClubProvider)!;
      expect(
        (club.id, club.city, club.establishedYear),
        (row['id'], 'Multan', 2001),
      );
      expect((club.hasLogo, club.logoPath), (true, '/photos/club.jpg'));
    });
  });

  group('who owns a club', () {
    testWidgets(
      'a legacy club_owner without a club → Role Selection → Club Setup',
      (tester) async {
        _user(role: 'club_owner');
        final c = await _start(tester);
        await _login(tester);
        expect(
          _loc(c),
          Routes.roleSelection,
          reason: 'no club row → no Club Owner profile',
        );
        expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
        await _tap(tester, _clubCard);
        expect(_loc(c), Routes.clubSetup);
      },
    );

    testWidgets(
      'a Player-only account: the Player Dashboard, no club request',
      (tester) async {
        final u = _user(role: 'player', player: true);
        final c = await _start(tester);
        await _login(tester);
        expect(_loc(c), Routes.playerHome);
        expect(c.read(sessionProvider).hasClubOwnerProfile, isFalse);
        expect(clubDb.calls, isNot(contains('fetchOwnClub')));
        expect(db.profiles[u.id]!['role'], 'player', reason: 'untouched');
      },
    );

    testWidgets(
      'both roles set up → Role Selection; Club Owner enters the club directly',
      (tester) async {
        final u = _user(role: 'player', player: true);
        await _storedClub(u);
        final c = await _start(tester);
        await _login(tester);
        expect(_loc(c), Routes.roleSelection);
        expect(c.read(currentClubProvider)!.name, 'Lahore Lions CC');
        await _tap(tester, _clubCard);
        expect(
          _loc(c),
          Routes.clubHome,
          reason: 'already set up: no Club Setup',
        );
        expect(db.profiles[u.id]!['role'], 'club_owner');
      },
    );
  });

  group('Join a Club (Phase 3E): Coming soon in Supabase mode', () {
    testWidgets(
      'the Player Club sheet and /join show Coming soon; no code entry',
      (tester) async {
        _user(role: 'player', player: true);
        final c = await _start(tester);
        await _login(tester);
        await _tap(tester, _navTab('Club'));
        expect(find.byKey(const Key('joinClub.comingSoon')), findsOneWidget);
        expect(find.text(ClubFeatures.joinComingSoon), findsOneWidget);
        expect(find.byKey(const Key('joinClub.code')), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await _tap(tester, _button('Close'));

        await _go(tester, c, Routes.enterClubCode);
        expect(find.byKey(const Key('join.comingSoon')), findsOneWidget);
        expect(find.text(ClubFeatures.joinComingSoon), findsOneWidget);
        expect(find.byKey(const Key('join.code')), findsNothing);
        expect(clubDb.calls, isEmpty, reason: 'no club lookup at all');
      },
    );

    testWidgets(
      'gate forced open: the refusal is shown, nothing stays loading',
      (tester) async {
        _user(role: 'player', player: true);
        final c = await _start(
          tester,
          extra: [
            clubFeaturesProvider.overrideWithValue(const ClubFeatures.all()),
          ],
        );
        await _login(tester);

        // Sheet: the lookup is refused → the note, and the spinner stops.
        await _tap(tester, _navTab('Club'));
        await _enter(tester, 'joinClub.code', 'KRC001');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('joinClub.problem')), findsOneWidget);
        expect(find.text(ClubFeatures.joinComingSoon), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tapAt(const Offset(10, 10)); // close the sheet
        await tester.pumpAndSettle();

        // /join: the send is refused → the inline message, the button usable.
        await _go(tester, c, Routes.enterClubCode);
        await _enter(tester, 'join.code', 'KRC001');
        await _tap(tester, _button('Send Join Request'));
        expect(find.text(ClubFeatures.joinComingSoon), findsOneWidget);
        expect(
          tester.widget<CeButton>(_button('Send Join Request')).loading,
          isFalse,
        );
        expect(_loc(c), Routes.enterClubCode);
      },
    );

    testWidgets('memory mode is unchanged: the code entry is there', (
      tester,
    ) async {
      final c = await _start(tester, supabase: false);
      await _enter(tester, 'login.phone', '0312-9020000');
      await _enter(tester, 'login.password', 'secret1');
      await _tap(tester, _button('Login'));
      expect(_loc(c), Routes.playerHome);
      await _tap(tester, _navTab('Club'));
      expect(find.byKey(const Key('joinClub.code')), findsOneWidget);
      expect(find.byKey(const Key('joinClub.comingSoon')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _go(tester, c, Routes.enterClubCode);
      expect(find.byKey(const Key('join.code')), findsOneWidget);
      expect(find.byType(CeTextField), findsWidgets);
    });
  });
}
