// M5 (profile and club pictures in Supabase Storage) and M6 (password change,
// profile visibility on the server) on the Supabase repositories over fakes
// of migration 31 — the upload path / type / size checks, set_my_avatar /
// set_club_logo, the deletion of replaced objects, the one-time move of a
// device photo, the signed-URL display, the members' pictures, the
// visibility load / save / rollback, the password change, the
// CRICECO_PROFILE_MEDIA switch (OFF = today's device-only behaviour) and the
// error mapping. No network, no database.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/profile_media.dart';
import 'package:criceco/app/providers/core_providers.dart';
import 'package:criceco/core/models/models.dart';
import 'package:criceco/core/utils/media_ref.dart';
import 'package:criceco/data/mock/in_memory_repositories.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:criceco/data/supabase/local_account_overlay.dart';
import 'package:criceco/data/supabase/local_club_overlay.dart';
import 'package:criceco/data/supabase/membership_row_mapper.dart';
import 'package:criceco/data/supabase/supabase_account_repository.dart';
import 'package:criceco/data/supabase/supabase_club_repository.dart';
import 'package:criceco/data/supabase/supabase_error_mapper.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';
import 'package:criceco/data/supabase/supabase_sdk_gateways.dart';
import 'package:criceco/demo/seed_data.dart';
import 'package:criceco/shared/media/photo_picker.dart';
import 'package:criceco/shared/widgets/ce_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'media_fakes.dart';
import 'supabase_fakes.dart';

void main() {
  final today = DateTime(2026, 11, 26, 10);
  const email = 'player@example.com';
  const password = 'Cricket@2026';
  const photo = '/device/photos/me.jpg';

  late SharedPreferences prefs;
  late FakeDb db;
  late FakeAuth auth;
  late FakeClubDb clubs;
  late FakeMedia media;
  late FakeFiles files;
  var ids = 0;

  String nextId() => 'obj-${++ids}';

  SupabaseAccountRepository accounts({bool withMedia = true}) =>
      SupabaseAccountRepository(
        auth: auth,
        db: db,
        overlay: LocalAccountOverlay(prefs),
        clock: Clock(() => today),
        media: withMedia ? media : null,
        files: files,
        newObjectId: nextId,
      );

  SupabaseClubRepository clubRepo({bool withMedia = true}) =>
      SupabaseClubRepository(
        auth: auth,
        db: clubs,
        overlay: LocalClubOverlay(prefs),
        local: InMemoryClubRepository(SeedData(today)),
        media: withMedia ? media : null,
        files: files,
        newObjectId: nextId,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = FakeDb();
    auth = FakeAuth(db);
    clubs = FakeClubDb(db);
    media = FakeMedia(db);
    files = FakeFiles();
    ids = 0;
  });

  Future<UserAccount> signedIn(SupabaseAccountRepository repo) async {
    auth.addUser(email, password, id: 'u1');
    return (await repo.signIn(identifier: email, password: password))!;
  }

  /// A device photo saved by an earlier app version (LocalAccountOverlay).
  Future<void> devicePhoto(String userId, String path) => prefs.setString(
    LocalAccountOverlay.keyFor(userId),
    jsonEncode({
      'hasPhoto': true,
      'photoPath': path,
      'settings': <String, Object?>{},
    }),
  );

  String? overlayPhoto(String userId) {
    final raw = prefs.getString(LocalAccountOverlay.keyFor(userId));
    return raw == null
        ? null
        : (jsonDecode(raw) as Map)['photoPath'] as String?;
  }

  group('MediaRef', () {
    test('stored references round-trip; device paths are not stored', () {
      final ref = MediaRef.of('avatars', 'u1/abc.jpg')!;
      expect(ref, 'storage://avatars/u1/abc.jpg');
      expect(MediaRef.isStored(ref), isTrue);
      expect(MediaRef.parse(ref), (bucket: 'avatars', path: 'u1/abc.jpg'));
      expect(MediaRef.objectPathIn('avatars', ref), 'u1/abc.jpg');
      expect(MediaRef.objectPathIn('club-logos', ref), isNull);
      expect(MediaRef.isStored(photo), isFalse);
      expect(MediaRef.isStored(r'C:\photos\me.jpg'), isFalse);
      expect(MediaRef.of('avatars', null), isNull);
      expect(MediaRef.of('avatars', '  '), isNull);
    });

    test('the type comes from the content, not the name', () {
      expect(MediaRef.imageTypeOf(jpegBytes()), (
        ext: 'jpg',
        mime: 'image/jpeg',
      ));
      expect(MediaRef.imageTypeOf(pngBytes()), (ext: 'png', mime: 'image/png'));
      expect(MediaRef.imageTypeOf(webpBytes()), (
        ext: 'webp',
        mime: 'image/webp',
      ));
      expect(MediaRef.imageTypeOf(gifBytes()), isNull);
    });

    test('object ids are random version-4 UUIDs', () {
      final a = MediaRef.newObjectId();
      expect(
        a,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(MediaRef.newObjectId(), isNot(a));
    });
  });

  group('M5 profile picture (switch ON)', () {
    test('a new photo is uploaded to avatars/<uid>/<uuid>.<ext>, then set_my_avatar', () async {
      final repo = accounts();
      final a = await signedIn(repo);
      files.files[photo] = pngBytes();
      final saved = await repo.update(
        a.copyWith(hasPhoto: true, photoPath: photo),
      );
      expect(media.uploads, ['avatars/u1/obj-1.png']);
      expect(media.objects['avatars/u1/obj-1.png']!.contentType, 'image/png');
      expect(media.avatarCalls, ['u1/obj-1.png']);
      expect(db.profiles['u1']!['avatar_path'], 'u1/obj-1.png');
      expect(saved.photoPath, 'storage://avatars/u1/obj-1.png');
      expect(saved.hasPhoto, isTrue);
      expect(
        overlayPhoto('u1'),
        isNull,
        reason: 'the server holds it; not kept on the device',
      );
      // Read again (another app run): the server's picture.
      final again = await accounts().byId('u1');
      expect(again!.photoPath, 'storage://avatars/u1/obj-1.png');
    });

    test('unchanged picture: no upload; a details edit keeps it', () async {
      final repo = accounts();
      final a = await signedIn(repo);
      files.files[photo] = jpegBytes();
      final saved = await repo.update(
        a.copyWith(hasPhoto: true, photoPath: photo),
      );
      media.calls.clear();
      await repo.update(
        saved.copyWith(settings: saved.settings.copyWith(twoStep: true)),
      );
      expect(media.calls, isNot(contains('upload')));
      expect(media.calls, isNot(contains('setMyAvatar')));
    });

    test(
      'changing it deletes the replaced object; removing clears and deletes',
      () async {
        final repo = accounts();
        final a = await signedIn(repo);
        files.files[photo] = jpegBytes();
        files.files['/device/photos/new.webp'] = webpBytes();
        final first = await repo.update(
          a.copyWith(hasPhoto: true, photoPath: photo),
        );
        final second = await repo.update(
          first.copyWith(photoPath: '/device/photos/new.webp'),
        );
        expect(second.photoPath, 'storage://avatars/u1/obj-2.webp');
        expect(media.removed, ['avatars/u1/obj-1.jpg']);
        expect(media.objects.keys, ['avatars/u1/obj-2.webp']);

        final none = await repo.update(
          second.copyWith(hasPhoto: false, clearPhoto: true),
        );
        expect(none.photoPath, isNull);
        expect(media.avatarCalls.last, isNull);
        expect(db.profiles['u1']!['avatar_path'], isNull);
        expect(media.removed.last, 'avatars/u1/obj-2.webp');
        expect(media.objects, isEmpty);
      },
    );

    test(
      'too large (> 2 MB) or not JPG / PNG / WebP: refused before any upload',
      () async {
        final repo = accounts();
        final a = await signedIn(repo);
        files.files['/big.jpg'] = jpegBytes(2 * 1024 * 1024 + 1);
        files.files['/anim.gif'] = gifBytes();
        await expectLater(
          repo.update(a.copyWith(hasPhoto: true, photoPath: '/big.jpg')),
          throwsA(
            isA<MediaException>().having(
              (e) => e.message,
              'message',
              contains('under 2 MB'),
            ),
          ),
        );
        await expectLater(
          repo.update(a.copyWith(hasPhoto: true, photoPath: '/anim.gif')),
          throwsA(
            isA<MediaException>().having(
              (e) => e.kind,
              'kind',
              MediaFailure.unsupported,
            ),
          ),
        );
        await expectLater(
          repo.update(a.copyWith(hasPhoto: true, photoPath: '/gone.jpg')),
          throwsA(
            isA<MediaException>().having(
              (e) => e.kind,
              'kind',
              MediaFailure.unreadable,
            ),
          ),
        );
        expect(media.calls, isNot(contains('upload')));
        expect(db.profiles['u1']!['avatar_path'], isNull);
      },
    );

    test(
      'set_my_avatar refused: the uploaded object is deleted, nothing changes',
      () async {
        final repo = accounts();
        final a = await signedIn(repo);
        files.files[photo] = jpegBytes();
        media.addFailure(
          'setMyAvatar',
          const GatewayConstraintException(
            sqlState: '22023',
            message: 'media: file not found',
          ),
        );
        await expectLater(
          repo.update(a.copyWith(hasPhoto: true, photoPath: photo)),
          throwsA(
            isA<MediaException>().having(
              (e) => e.kind,
              'kind',
              MediaFailure.failed,
            ),
          ),
        );
        expect(media.removed, ['avatars/u1/obj-1.jpg']);
        expect(media.objects, isEmpty);
      },
    );

    test('Profile Setup uploads its picture; a failed upload never fails the setup', () async {
      final repo = accounts();
      final a = await signedIn(repo);
      files.files[photo] = jpegBytes();
      final saved = await repo.saveProfileSetup(
        _filledIn(a, photoPath: photo),
        at: today,
      );
      expect(saved.profileComplete, isTrue);
      expect(saved.photoPath, 'storage://avatars/u1/obj-1.jpg');
      expect(media.avatarCalls, ['u1/obj-1.jpg']);

      // Another user whose upload fails (offline): the profile is saved, the
      // photo stays on the device for the later move.
      auth.addUser('b@example.com', password, id: 'u2');
      final repo2 = accounts();
      final b = (await repo2.signIn(
        identifier: 'b@example.com',
        password: password,
      ))!;
      media.addFailure('upload', const GatewayNetworkException());
      final kept = await repo2.saveProfileSetup(
        _filledIn(b, photoPath: photo),
        at: today,
      );
      expect(kept.profileComplete, isTrue);
      expect(kept.photoPath, photo);
      await repo2.pendingPhotoMove; // the read after the setup tries it once
      expect(db.profiles['u2']!['avatar_path'], startsWith('u2/'));
    });
  });

  group('M5 one-time move of a device photo', () {
    test('switch ON, no server picture, device photo exists: uploaded once, then forgotten locally', () async {
      await devicePhoto('u1', photo);
      files.files[photo] = jpegBytes();
      final repo = accounts();
      final a = await signedIn(repo);
      expect(a.photoPath, photo, reason: 'shown at once, never blocking');
      await repo.pendingPhotoMove;
      expect(media.uploads, ['avatars/u1/obj-1.jpg']);
      expect(db.profiles['u1']!['avatar_path'], 'u1/obj-1.jpg');
      expect(overlayPhoto('u1'), isNull);
      final again = (await repo.byId('u1'))!;
      expect(again.photoPath, 'storage://avatars/u1/obj-1.jpg');
      expect(media.uploads, hasLength(1), reason: 'once');
    });

    test('the server already has a picture: nothing is uploaded', () async {
      await devicePhoto('u1', photo);
      files.files[photo] = jpegBytes();
      auth.addUser(email, password, id: 'u1');
      db.profiles['u1'] = {...db.profiles['u1']!, 'avatar_path': 'u1/old.jpg'};
      media.objects['avatars/u1/old.jpg'] = (
        bytes: jpegBytes(),
        contentType: 'image/jpeg',
      );
      final repo = accounts();
      final a = (await repo.signIn(identifier: email, password: password))!;
      expect(repo.pendingPhotoMove, isNull);
      expect(a.photoPath, 'storage://avatars/u1/old.jpg');
      expect(media.uploads, isEmpty);
    });

    test('the file is gone: forgotten, no upload', () async {
      await devicePhoto('u1', photo);
      final repo = accounts();
      await signedIn(repo);
      await repo.pendingPhotoMove;
      expect(media.uploads, isEmpty);
      expect(overlayPhoto('u1'), isNull);
    });

    test(
      'refused for good (too large): kept on the device, never tried again',
      () async {
        await devicePhoto('u1', photo);
        files.files[photo] = jpegBytes(3 * 1024 * 1024);
        final repo = accounts();
        await signedIn(repo);
        await repo.pendingPhotoMove;
        expect(overlayPhoto('u1'), photo);
        expect(
          prefs.getString(LocalAccountOverlay.refusedPhotoKeyFor('u1')),
          photo,
        );
        final next = accounts(); // the next app run
        await next.byId('u1');
        expect(next.pendingPhotoMove, isNull);
      },
    );

    test('offline: kept, tried again on the next app run', () async {
      await devicePhoto('u1', photo);
      files.files[photo] = jpegBytes();
      media.addFailure('upload', const GatewayNetworkException());
      final repo = accounts();
      await signedIn(repo);
      await repo.pendingPhotoMove;
      expect(overlayPhoto('u1'), photo);
      await repo.byId('u1');
      expect(
        media.calls.where((c) => c == 'upload'),
        hasLength(1),
        reason: 'once per run',
      );
      final next = accounts();
      await next.byId('u1');
      await next.pendingPhotoMove;
      expect(db.profiles['u1']!['avatar_path'], isNotNull);
    });

    test(
      'switch OFF: the device photo stays local; no Storage call at all',
      () async {
        await devicePhoto('u1', photo);
        files.files[photo] = jpegBytes();
        final repo = accounts(withMedia: false);
        final a = await signedIn(repo);
        expect(repo.pendingPhotoMove, isNull);
        expect(a.photoPath, photo);
        final changed = await repo.update(
          a.copyWith(photoPath: '/device/other.jpg'),
        );
        expect(changed.photoPath, '/device/other.jpg');
        expect(overlayPhoto('u1'), '/device/other.jpg');
        expect(media.calls, isEmpty);
      },
    );

    test('switch OFF: a server avatar_path column is ignored', () async {
      auth.addUser(email, password, id: 'u1');
      db.profiles['u1'] = {
        ...db.profiles['u1']!,
        'avatar_path': 'u1/x.jpg',
        'public_profile': false,
      };
      final a = (await accounts(withMedia: false)
          .signIn(identifier: email, password: password))!;
      expect(a.photoPath, isNull);
      expect(
        a.settings.publicProfile,
        isTrue,
        reason: 'device settings, as before',
      );
    });
  });

  group('M6 profile visibility', () {
    test(
      'loads from my_profile_visibility and saves only what changed',
      () async {
        auth.addUser(email, password, id: 'u1');
        db.profiles['u1'] = {
          ...db.profiles['u1']!,
          'public_profile': false,
          'show_stats': true,
        };
        final repo = accounts();
        final a = (await repo.signIn(identifier: email, password: password))!;
        expect(media.calls, contains('fetchProfileVisibility'));
        expect((a.settings.publicProfile, a.settings.showStats), (false, true));

        final saved = await repo.update(
          a.copyWith(settings: a.settings.copyWith(showStats: false)),
        );
        expect(media.visibilityCalls, [
          (publicProfile: null, showStats: false),
        ]);
        expect(saved.settings.showStats, isFalse);
        expect(db.profiles['u1']!['show_stats'], isFalse);

        // Nothing changed: no call.
        await repo.update(
          saved.copyWith(settings: saved.settings.copyWith(twoStep: true)),
        );
        expect(media.visibilityCalls, hasLength(1));
      },
    );

    test(
      'refused: the error is thrown and the stored value stays (rollback)',
      () async {
        final repo = accounts();
        final a = await signedIn(repo);
        media.addFailure(
          'setProfileVisibility',
          const GatewayNetworkException(),
        );
        await expectLater(
          repo.update(
            a.copyWith(settings: a.settings.copyWith(publicProfile: false)),
          ),
          throwsA(isA<BackendUnavailableException>()),
        );
        final again = (await repo.byId('u1'))!;
        expect(again.settings.publicProfile, isTrue);
        // Tried again: sent again.
        await repo.update(
          again.copyWith(
            settings: again.settings.copyWith(publicProfile: false),
          ),
        );
        expect(media.visibilityCalls.last, (
          publicProfile: false,
          showStats: null,
        ));
      },
    );

    test(
      'ProfileVisibility.parse: a row or a one-row list; missing parts null',
      () {
        final row = ProfileVisibility.parse({
          'public_profile': false,
          'show_stats': true,
        });
        expect((row.publicProfile, row.showStats), (false, true));
        final list = ProfileVisibility.parse([
          {'public_profile': true},
        ]);
        expect((list.publicProfile, list.showStats), (true, null));
        final none = ProfileVisibility.parse(null);
        expect((none.publicProfile, none.showStats), (null, null));
      },
    );

    test(
      'my_profile_visibility unreadable: still signs in, from the profile row',
      () async {
        auth.addUser(email, password, id: 'u1');
        db.profiles['u1'] = {...db.profiles['u1']!, 'public_profile': false};
        media.addFailure(
          'fetchProfileVisibility',
          const GatewayNetworkException(),
        );
        final a = (await accounts().signIn(
          identifier: email,
          password: password,
        ))!;
        expect((a.settings.publicProfile, a.settings.showStats), (false, true));
      },
    );

    test('the phone consent stays my_privacy_settings (boolean)', () async {
      final privacy = _Privacy()..sharing = true;
      auth.addUser(email, password, id: 'u1');
      final repo = SupabaseAccountRepository(
        auth: auth,
        db: db,
        overlay: LocalAccountOverlay(prefs),
        privacy: privacy,
        media: media,
        files: files,
      );
      final a = (await repo.signIn(identifier: email, password: password))!;
      expect(a.settings.showPhone, isTrue);
      expect(privacy.calls, ['fetchPhoneSharing']);
      expect(media.calls, contains('fetchProfileVisibility'));
    });
  });

  group('M6 password change', () {
    test('success: re-checks the current password, sets the new one, ends the other sessions', () async {
      final repo = accounts(withMedia: false);
      await signedIn(repo);
      expect(
        await repo.changePassword('u1', current: password, next: 'Newpass@456'),
        isTrue,
      );
      expect(auth.passwordOf(email), 'Newpass@456');
      expect(
        auth.calls,
        containsAllInOrder([
          'signInWithPassword',
          'updatePassword',
          'signOutOthers',
        ]),
      );
      expect(auth.otherSignOuts, 1);
      expect(auth.current?.id, 'u1', reason: 'this session stays');
    });

    test('wrong current password: false, nothing changes', () async {
      final repo = accounts(withMedia: false);
      await signedIn(repo);
      expect(
        await repo.changePassword(
          'u1',
          current: 'Wrong@123',
          next: 'Newpass@456',
        ),
        isFalse,
      );
      expect(
        await repo.changePassword('u1', current: '', next: 'Newpass@456'),
        isFalse,
      );
      expect(auth.passwordOf(email), password);
      expect(auth.calls, isNot(contains('updatePassword')));
      expect(auth.otherSignOuts, 0);
      expect(auth.current?.id, 'u1');
    });

    test(
      'the server\'s weak-password rule: the existing password text',
      () async {
        final repo = accounts(withMedia: false);
        await signedIn(repo);
        auth.addFailure(
          'updatePassword',
          const GatewayConstraintException(
            sqlState: '23514',
            message: 'weak password',
          ),
        );
        await expectLater(
          repo.changePassword('u1', current: password, next: 'Newpass@456'),
          throwsA(
            isA<ProfileValidationException>().having(
              (e) => e.message,
              'message',
              'Choose a stronger password',
            ),
          ),
        );
        expect(auth.passwordOf(email), password);
        expect(auth.otherSignOuts, 0);
      },
    );

    test('the same password: SamePasswordException', () async {
      final repo = accounts(withMedia: false);
      await signedIn(repo);
      await expectLater(
        repo.changePassword('u1', current: password, next: password),
        throwsA(isA<SamePasswordException>()),
      );
    });

    test('ending the other sessions fails: the change still counts', () async {
      final repo = accounts(withMedia: false);
      await signedIn(repo);
      auth.addFailure('signOutOthers', const GatewayNetworkException());
      expect(
        await repo.changePassword('u1', current: password, next: 'Newpass@456'),
        isTrue,
      );
      expect(auth.passwordOf(email), 'Newpass@456');
    });

    test('another account id or signed out: refused before any call', () async {
      final repo = accounts(withMedia: false);
      await signedIn(repo);
      auth.calls.clear();
      await expectLater(
        repo.changePassword(
          'someone-else',
          current: password,
          next: 'Newpass@456',
        ),
        throwsA(isA<AccountMismatchException>()),
      );
      auth.current = null;
      await expectLater(
        repo.changePassword('u1', current: password, next: 'Newpass@456'),
        throwsA(isA<NotSignedInException>()),
      );
      expect(auth.calls, isEmpty);
    });
  });

  group('M5 object names and account deletion', () {
    test(
      'real object names: lowercase <uid>/<uuid>.<ext>, one folder level',
      () async {
        media.strictNames = true;
        final repo = SupabaseAccountRepository(
          auth: auth,
          db: db,
          overlay: LocalAccountOverlay(prefs),
          media: media,
          files: files,
        );
        final a = await signedIn(repo);
        files.files[photo] = webpBytes();
        final saved = await repo.update(
          a.copyWith(hasPhoto: true, photoPath: photo),
        );
        final path = MediaRef.objectPathIn('avatars', saved.photoPath)!;
        expect(
          path,
          matches(
            RegExp(
              r'^u1/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.webp$',
            ),
          ),
        );
      },
    );

    SupabaseAccountRepository deleting(
      _Privacy privacy, {
      bool withMedia = true,
    }) => SupabaseAccountRepository(
      auth: auth,
      db: db,
      overlay: LocalAccountOverlay(prefs),
      privacy: privacy,
      media: withMedia ? media : null,
      files: files,
      newObjectId: nextId,
    );

    test('switch ON: the own avatars are deleted (best effort) before delete-account', () async {
      final privacy = _Privacy(password: password)..media = media;
      final repo = deleting(privacy);
      final a = await signedIn(repo);
      files.files[photo] = jpegBytes();
      await repo.update(a.copyWith(hasPhoto: true, photoPath: photo));
      media.objects['avatars/u1/stray.png'] = (
        bytes: pngBytes(),
        contentType: 'image/png',
      );
      media.objects['avatars/u2/other.png'] = (
        bytes: pngBytes(),
        contentType: 'image/png',
      );
      await repo.deleteAccount('u1', password: password);
      expect(privacy.calls.last, 'deleteAccount');
      expect(
        media.removed,
        containsAll(['avatars/u1/obj-1.jpg', 'avatars/u1/stray.png']),
      );
      expect(media.objects.keys, [
        'avatars/u2/other.png',
      ], reason: 'only the own folder');
      expect(privacy.deletedAfterRemoval, isTrue);
    });

    test('a wrong password removes nothing', () async {
      final privacy = _Privacy(password: password);
      final repo = deleting(privacy);
      final a = await signedIn(repo);
      files.files[photo] = jpegBytes();
      await repo.update(a.copyWith(hasPhoto: true, photoPath: photo));
      await expectLater(
        repo.deleteAccount('u1', password: 'Wrong@123'),
        throwsA(isA<WrongPasswordException>()),
      );
      expect(media.removed, isEmpty);
      expect(privacy.calls, isNot(contains('deleteAccount')));
    });

    test('Storage failing never blocks the deletion', () async {
      final privacy = _Privacy(password: password);
      final repo = deleting(privacy);
      await signedIn(repo);
      media.addFailure('list', const GatewayNetworkException());
      media.objects['avatars/u1/x.png'] = (
        bytes: pngBytes(),
        contentType: 'image/png',
      );
      await repo.deleteAccount('u1', password: password);
      expect(privacy.calls.last, 'deleteAccount');
    });

    test('switch OFF: no Storage call before delete-account', () async {
      final privacy = _Privacy(password: password);
      final repo = deleting(privacy, withMedia: false);
      await signedIn(repo);
      await repo.deleteAccount('u1', password: password);
      expect(media.calls, isEmpty);
      expect(privacy.calls.last, 'deleteAccount');
    });
  });

  group('M5 club picture', () {
    Future<Club> ownClub(SupabaseClubRepository repo) async {
      auth.addUser(email, password, id: 'u1');
      await auth.signInWithPassword(email: email, password: password);
      db.profiles['u1'] = {
        ...db.profiles['u1']!,
        'profile_completed': true,
        'date_of_birth': '2000-05-01',
      };
      db.currentAddresses['u1'] = {'city': 'Lahore'};
      db.permanentAddresses['u1'] = {'city': 'Lahore'};
      return repo.createClub(
        accountId: 'u1',
        name: 'Shalimar CC',
        city: 'Lahore',
        type: ClubType.professional,
      );
    }

    test('owner: upload to club-logos/<club id>/…, set_club_logo, replaced object deleted, removal', () async {
      final repo = clubRepo();
      final club = await ownClub(repo);
      files.files['/logo.png'] = pngBytes();
      files.files['/logo2.jpg'] = jpegBytes();
      final saved = await repo.updateClub('u1', club.withLogo('/logo.png'));
      expect(media.uploads, ['club-logos/${club.id}/obj-1.png']);
      expect(media.logoCalls, ['${club.id}/obj-1.png']);
      expect(saved.logoPath, 'storage://club-logos/${club.id}/obj-1.png');
      expect(
        prefs.getString(LocalClubOverlay.keyFor(club.id)),
        isNull,
        reason: 'not kept on the device',
      );
      expect((await clubRepo().ownClub('u1'))!.logoPath, saved.logoPath);

      final changed = await repo.updateClub('u1', saved.withLogo('/logo2.jpg'));
      expect(changed.logoPath, 'storage://club-logos/${club.id}/obj-2.jpg');
      expect(media.removed, ['club-logos/${club.id}/obj-1.png']);

      final none = await repo.updateClub('u1', changed.withLogo(null));
      expect(none.logoPath, isNull);
      expect(media.logoCalls.last, isNull);
      expect(media.objects, isEmpty);
    });

    test(
      'a details edit keeps the stored picture without any upload',
      () async {
        final repo = clubRepo();
        final club = await ownClub(repo);
        files.files['/logo.png'] = pngBytes();
        final saved = await repo.updateClub('u1', club.withLogo('/logo.png'));
        media.calls.clear();
        final renamed = await repo.updateClub(
          'u1',
          saved.copyWith(name: 'Shalimar Cricket Club'),
        );
        expect(renamed.logoPath, saved.logoPath);
        expect(media.calls, isEmpty);
      },
    );

    test(
      'not the owner: set_club_logo refuses; the object is removed again',
      () async {
        final repo = clubRepo();
        final club = await ownClub(repo);
        files.files['/logo.png'] = pngBytes();
        media.addFailure(
          'setClubLogo',
          const GatewayConstraintException(
            sqlState: '42501',
            message: 'media: not allowed',
          ),
        );
        await expectLater(
          repo.updateClub('u1', club.withLogo('/logo.png')),
          throwsA(
            isA<MediaException>().having(
              (e) => e.kind,
              'kind',
              MediaFailure.notAllowed,
            ),
          ),
        );
        expect(media.objects, isEmpty);
      },
    );

    test(
      'a device club picture from before moves to the server once',
      () async {
        final repo = clubRepo();
        final club = await ownClub(repo);
        await LocalClubOverlay(prefs).save(club.withLogo('/old-logo.jpg'));
        files.files['/old-logo.jpg'] = jpegBytes();
        final next = clubRepo(); // the next app run
        final shown = (await next.ownClub('u1'))!;
        expect(shown.logoPath, '/old-logo.jpg');
        await next.pendingLogoMove;
        expect(media.logoCalls, ['${club.id}/obj-1.jpg']);
        expect(prefs.getString(LocalClubOverlay.keyFor(club.id)), isNull);
        expect(
          (await next.ownClub('u1'))!.logoPath,
          'storage://club-logos/${club.id}/obj-1.jpg',
        );
      },
    );

    test(
      'switch OFF: the picture stays on the device, no Storage call',
      () async {
        final repo = clubRepo(withMedia: false);
        final club = await ownClub(repo);
        final saved = await repo.updateClub('u1', club.withLogo('/logo.png'));
        expect(saved.logoPath, '/logo.png');
        expect(media.calls, isEmpty);
      },
    );
  });

  group('M5 members\' and applicants\' pictures', () {
    test('rows map avatar_path / club_logo_path with the switch; ignored without it', () {
      final member = {
        'member_id': 'm1',
        'full_name': 'Ali',
        'member_role': 'player',
        'avatar_path': 'u9/a.jpg',
      };
      expect(
        MembershipRowMapper.memberFromRow(member, media: true).photoPath,
        'storage://avatars/u9/a.jpg',
      );
      expect(MembershipRowMapper.memberFromRow(member).photoPath, isNull);
      expect(
        MembershipRowMapper.memberFromRow({
          ...member,
          'avatar_path': null,
        }, media: true).photoPath,
        isNull,
      );
      expect(
        MembershipRowMapper.memberFromRow(
          {...member}..remove('avatar_path'),
          media: true,
        ).photoPath,
        isNull,
      );

      final request = {
        'request_id': 'r1',
        'full_name': 'Ali',
        'status': 'pending',
        'avatar_path': 'u9/a.jpg',
      };
      final mapped = MembershipRowMapper.joinRequestFromRow(
        request,
        now: today,
        media: true,
      );
      expect(mapped.photoPath, 'storage://avatars/u9/a.jpg');
      expect(
        mapped.decided(JoinRequestReview.approved, at: today).photoPath,
        mapped.photoPath,
      );
      expect(
        MembershipRowMapper.joinRequestFromRow(request, now: today).photoPath,
        isNull,
      );

      final membership = {
        'club_id': 'c1',
        'club_name': 'X',
        'club_code': 'CL1',
        'member_role': 'player',
        'club_logo_path': 'c1/l.png',
      };
      expect(
        MembershipRowMapper.membershipFromRow(
          membership,
          media: true,
        ).clubLogoPath,
        'storage://club-logos/c1/l.png',
      );
      expect(
        MembershipRowMapper.membershipFromRow(membership).clubLogoPath,
        isNull,
      );
    });
  });

  group('M5 display through signed URLs', () {
    final supabase = BackendConfig.parse(
      backend: 'supabase',
      supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
      supabasePublishableKey: 'sb_publishable_test_0000000000000000',
    );

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      bool on = true,
    }) async {
      auth.current = auth.addUser(email, password, id: 'u1');
      media.objects['avatars/u9/a.jpg'] = (
        bytes: jpegBytes(),
        contentType: 'image/jpeg',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backendConfigProvider.overrideWithValue(supabase),
            profileMediaEnabledProvider.overrideWithValue(on),
            mediaGatewayProvider.overrideWithValue(media),
            clockProvider.overrideWithValue(Clock(() => today)),
          ],
          child: MaterialApp(
            home: Scaffold(body: Center(child: child)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Iterable<NetworkImage> networkImages(WidgetTester tester) => tester
        .widgetList<Image>(find.byType(Image))
        .map((i) => i.image)
        .whereType<NetworkImage>();

    testWidgets('a stored picture is shown from its 1-hour signed URL', (
      tester,
    ) async {
      await pump(
        tester,
        const CeAvatar('Ali', photoPath: 'storage://avatars/u9/a.jpg'),
      );
      final urls = networkImages(tester).map((i) => i.url).toList();
      expect(urls, hasLength(1));
      expect(
        urls.single,
        startsWith('https://storage.test/avatars/u9/a.jpg?expires=3600'),
      );
      expect(media.calls.where((c) => c == 'signedUrl'), isNotEmpty);
    });

    testWidgets('switch OFF: no URL is asked for; the initial shows', (
      tester,
    ) async {
      await pump(
        tester,
        const CeAvatar('Ali', photoPath: 'storage://avatars/u9/a.jpg'),
        on: false,
      );
      expect(networkImages(tester), isEmpty);
      expect(find.text('A'), findsOneWidget);
      expect(media.calls, isEmpty);
    });

    testWidgets('no picture: the initial, no request', (tester) async {
      await pump(tester, const CeAvatar('Ali'));
      expect(find.text('A'), findsOneWidget);
      expect(media.calls, isEmpty);
    });

    testWidgets('the URL can\'t be signed (object gone): the fallback', (
      tester,
    ) async {
      await pump(
        tester,
        const CePhotoImage(
          path: 'storage://avatars/u9/missing.jpg',
          size: 40,
          fallback: Text('fallback'),
        ),
      );
      expect(find.text('fallback'), findsOneWidget);
      expect(networkImages(tester), isEmpty);
    });
  });

  group('photo picker limit', () {
    test('2 MB when pictures are uploaded, 10 MB on the device only', () {
      final supabase = BackendConfig.parse(
        backend: 'supabase',
        supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
        supabasePublishableKey: 'sb_publishable_test_0000000000000000',
      );
      final on = ProviderContainer(
        overrides: [
          backendConfigProvider.overrideWithValue(supabase),
          profileMediaEnabledProvider.overrideWithValue(true),
        ],
      );
      addTearDown(on.dispose);
      expect(on.read(photoMaxBytesProvider), 2 * 1024 * 1024);
      expect(
        (on.read(photoPickerProvider) as DevicePhotoPicker).maxBytes,
        2 * 1024 * 1024,
      );
      final off = ProviderContainer();
      addTearDown(off.dispose);
      expect(off.read(profileMediaLiveProvider), isFalse);
      expect(off.read(photoMaxBytesProvider), 10 * 1024 * 1024);
      expect(kProfileMediaBuild, isFalse, reason: 'OFF by default');
    });
  });

  group('error mapping (M4 migration 30, M5 media, push)', () {
    String text(Object e) => switch (e) {
      AccountException(:final message) => message,
      ProfileValidationException(:final message) => message,
      _ => '$e',
    };
    Object map(String sqlState, String message, {String? constraint}) =>
        SupabaseErrorMapper.map(
          GatewayConstraintException(
            sqlState: sqlState,
            message: message,
            constraint: constraint,
          ),
        );

    test('profiles rules of migration 30', () {
      expect(
        text(map('23514', 'profile_completed requires phone')),
        'A phone number is required for a completed profile',
      );
      expect(
        text(
          map(
            '23514',
            'new row for relation "profiles" violates check constraint "profiles_phone_check"',
          ),
        ),
        'Enter a valid mobile number (03XX-XXXXXXX)',
      );
      expect(
        text(
          map(
            '23514',
            'violates check constraint',
            constraint: 'profiles_full_name_check',
          ),
        ),
        'Enter your full name (2–100 characters)',
      );
      expect(
        text(
          map(
            '23514',
            'new row for relation "profiles" violates check constraint "profiles_role_check"',
          ),
        ),
        'Choose a valid role (Player or Club Owner)',
      );
      // The other completed-profile rule keeps its text.
      expect(
        text(
          map(
            '23514',
            'profile_completed requires a completed User Profile Setup before creating a club',
          ),
        ),
        'Please complete all profile details',
      );
    });

    test('media refusals of migration 31 (final texts)', () {
      MediaFailure? kind(Object e) => e is MediaException ? e.kind : null;
      expect(kind(map('42501', 'media: not allowed')), MediaFailure.notAllowed);
      expect(
        kind(map('42501', 'media: avatar_path is set through set_my_avatar')),
        MediaFailure.failed,
      );
      expect(kind(map('22023', 'media: invalid path')), MediaFailure.failed);
      expect(kind(map('22023', 'media: file not found')), MediaFailure.failed);
      expect(
        map('42501', 'media: not authenticated'),
        isA<NotSignedInException>(),
      );
      expect(
        map('P0002', 'media: profile not found'),
        isA<ProfileNotFoundException>(),
      );
      expect(
        map('P0002', 'privacy: profile not found'),
        isA<ProfileNotFoundException>(),
      );
      for (final e in [
        map('42501', 'media: avatar_path is set through set_my_avatar'),
        map('22023', 'media: file not found'),
      ]) {
        expect(
          text(e),
          isNot(contains('media:')),
          reason: 'never the raw text',
        );
      }
    });

    test('media refusals', () {
      expect(
        map('42501', 'media: not owner'),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.notAllowed,
        ),
      );
      expect(
        map('42501', 'media: invalid path'),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.failed,
        ),
      );
      expect(
        map('22023', 'media: too large'),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.tooLarge,
        ),
      );
      expect(
        map('22023', 'media: unsupported type'),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.unsupported,
        ),
      );
      expect(
        map('42501', 'media: not authenticated'),
        isA<NotSignedInException>(),
      );
      // Other 42501s are unchanged.
      expect(
        map('42501', 'permission denied for table profiles'),
        isA<PermissionDeniedException>(),
      );
    });

    test('Storage API refusals are translated (raw text never shown)', () {
      GatewayException t(int status, String message, {String? error}) =>
          SupabaseMediaGateway.translate(
            sb.StorageException(message, statusCode: '$status', error: error),
          );
      Object mapped(GatewayException e) => SupabaseErrorMapper.map(e);
      expect(
        mapped(t(413, 'Payload too large')),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.tooLarge,
        ),
      );
      expect(
        mapped(t(400, 'The object exceeded the maximum allowed size')),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.tooLarge,
        ),
      );
      expect(
        mapped(
          t(
            415,
            'mime type image/gif is not supported',
            error: 'invalid_mime_type',
          ),
        ),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.unsupported,
        ),
      );
      expect(
        mapped(t(400, 'new row violates row-level security policy')),
        isA<MediaException>().having(
          (e) => e.kind,
          'kind',
          MediaFailure.notAllowed,
        ),
      );
      expect(mapped(t(503, 'unavailable')), isA<BackendUnavailableException>());
      expect(mapped(t(429, 'slow down')), isA<TooManyRequestsException>());
      expect(mapped(t(418, 'teapot')), isA<BackendOperationException>());
    });

    test(
      'push: too many device moves (P0001) is a typed refusal, not a crash',
      () {
        final e = map('P0001', 'push: too many device moves');
        expect(e, isA<NotificationRuleException>());
        expect(text(e), contains('moved between accounts too often'));
      },
    );
  });
}

UserAccount _filledIn(UserAccount a, {String? photoPath}) => a.copyWith(
  fullName: 'Ali Khan',
  phone: '0300 1234567',
  dateOfBirth: DateTime(2000, 5, 1),
  currentCity: 'Lahore',
  currentArea: 'Gulberg',
  currentAddress: 'House 1, Street 2',
  isPermanentSameAsCurrent: true,
  permanentCity: 'Lahore',
  permanentArea: 'Gulberg',
  permanentAddress: 'House 1, Street 2',
  hasPhoto: photoPath != null,
  photoPath: photoPath,
);

/// The phone consent and the delete-account Edge Function (migration 13–14).
class _Privacy implements AccountPrivacyGateway {
  _Privacy({this.password = 'Cricket@2026'});
  final String password;
  bool sharing = false;
  final calls = <String>[];
  FakeMedia? media;

  /// Every picture removal was before the deletion.
  bool deletedAfterRemoval = false;

  @override
  Future<bool> fetchPhoneSharing() async {
    calls.add('fetchPhoneSharing');
    return sharing;
  }

  @override
  Future<void> setPhoneSharing(bool share) async {
    calls.add('setPhoneSharing:$share');
    sharing = share;
  }

  @override
  Future<void> deleteAccount({required String password}) async {
    calls.add('deleteAccount');
    if (password != this.password) throw const GatewayWrongPasswordException();
    deletedAfterRemoval =
        media?.objects.keys.every((k) => !k.startsWith('avatars/u1/')) ?? false;
  }
}
