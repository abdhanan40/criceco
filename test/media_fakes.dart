import 'dart:typed_data';

import 'package:criceco/data/supabase/media_uploader.dart';
import 'package:criceco/data/supabase/supabase_gateways.dart';

import 'supabase_fakes.dart';

/// Stand-in for migration 31 (M5 / M6): the private `avatars` and
/// `club-logos` buckets (2 MB, JPEG / PNG / WebP; a user writes only in
/// their own `avatars/<uid>/` folder, a club owner only in
/// `club-logos/<club id>/`), `set_my_avatar` / `set_club_logo` (the object
/// must be in that folder and exist; the club's owner only) and the profile
/// visibility (`my_profile_visibility` / `set_profile_visibility`), with the
/// same `media:` refusals. Uses [FakeDb]'s profiles and signed-in user and
/// [FakeClubDb]'s clubs. In memory only; no network.
class FakeMedia implements MediaGateway {
  FakeMedia(this.db);
  final FakeDb db;

  /// Stored objects by `bucket/path`.
  final objects = <String, ({Uint8List bytes, String contentType})>{};
  final calls = <String>[];

  /// `bucket/path` of every upload and every removed object, in order.
  final uploads = <String>[];
  final removed = <String>[];

  /// `p_path` of each `set_my_avatar` / `set_club_logo` call.
  final avatarCalls = <String?>[];
  final logoCalls = <String?>[];

  /// The parameters of each `set_profile_visibility` call.
  final visibilityCalls = <({bool? publicProfile, bool? showStats})>[];

  var _signed = 0;
  final _failOn = <String, GatewayException>{};

  /// The next [call] (by name) fails with [e].
  void addFailure(String call, GatewayException e) => _failOn[call] = e;

  static GatewayConstraintException _err(String sqlState, String message) =>
      GatewayConstraintException(sqlState: sqlState, message: message);

  String _uid(String call) {
    calls.add(call);
    final f = _failOn.remove(call);
    if (f != null) throw f;
    final uid = db.auth.current?.id;
    if (uid == null) throw const GatewayPermissionException();
    return uid;
  }

  bool _ownsClub(String uid, String clubId) =>
      db.clubDb?.clubs[uid]?['id'] == clubId;

  bool _mayWrite(String uid, String bucket, String path) {
    final folder = path.split('/').first;
    return switch (bucket) {
      'avatars' => folder == uid,
      'club-logos' => _ownsClub(uid, folder),
      _ => false,
    };
  }

  /// Migration 31's object names: lowercase, one folder level,
  /// `<folder>/<uuid>.<jpg|jpeg|png|webp>`.
  static final _objectName = RegExp(
    r'^[0-9a-z-]+/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$',
  );

  /// Lets the tests use short object ids (`obj-1.jpg`); the real
  /// uploader's uuids are checked in profile_media_test.
  bool strictNames = false;

  @override
  Future<void> upload(
    String bucket,
    String path,
    Uint8List bytes, {
    required String contentType,
  }) async {
    final uid = _uid('upload');
    if (!_mayWrite(uid, bucket, path)) {
      throw _err('42501', 'media: not allowed');
    }
    if (strictNames && !_objectName.hasMatch(path)) {
      throw _err('22023', 'media: invalid path');
    }
    if (bytes.length > 2 * 1024 * 1024) throw _err('22023', 'media: too large');
    if (!const {
      'image/jpeg',
      'image/png',
      'image/webp',
    }.contains(contentType)) {
      throw _err('22023', 'media: unsupported type');
    }
    final key = '$bucket/$path';
    if (objects.containsKey(key)) throw _err('23505', 'media: already exists');
    objects[key] = (bytes: bytes, contentType: contentType);
    uploads.add(key);
  }

  @override
  Future<void> remove(String bucket, List<String> paths) async {
    final uid = _uid('remove');
    for (final p in paths) {
      if (!_mayWrite(uid, bucket, p)) continue; // RLS: silently not removed
      if (objects.remove('$bucket/$p') != null) removed.add('$bucket/$p');
    }
  }

  @override
  Future<List<String>> list(String bucket, String folder) async {
    _uid('list');
    final prefix = '$bucket/$folder/';
    return [
      for (final k in objects.keys)
        if (k.startsWith(prefix)) k.substring(bucket.length + 1),
    ];
  }

  @override
  Future<String> signedUrl(
    String bucket,
    String path, {
    required Duration expiresIn,
  }) async {
    _uid('signedUrl');
    if (!objects.containsKey('$bucket/$path')) {
      throw const GatewayUnexpectedException('storage:400');
    }
    return 'https://storage.test/$bucket/$path?expires=${expiresIn.inSeconds}&n=${++_signed}';
  }

  @override
  Future<void> setMyAvatar(String? path) async {
    final uid = _uid('setMyAvatar');
    avatarCalls.add(path);
    if (path != null) {
      if (!path.startsWith('$uid/')) throw _err('22023', 'media: invalid path');
      if (!objects.containsKey('avatars/$path')) {
        throw _err('22023', 'media: file not found');
      }
    }
    db.profiles[uid] = {...?db.profiles[uid], 'avatar_path': path};
  }

  @override
  Future<void> setClubLogo(String clubId, String? path) async {
    final uid = _uid('setClubLogo');
    logoCalls.add(path);
    if (!_ownsClub(uid, clubId)) throw _err('42501', 'media: not allowed');
    if (path != null) {
      if (!path.startsWith('$clubId/')) {
        throw _err('22023', 'media: invalid path');
      }
      if (!objects.containsKey('club-logos/$path')) {
        throw _err('22023', 'media: file not found');
      }
    }
    final row = db.clubDb!.clubs[uid]!;
    db.clubDb!.clubs[uid] = {...row, 'logo_path': path};
  }

  @override
  Future<ProfileVisibility> fetchProfileVisibility() async {
    final uid = _uid('fetchProfileVisibility');
    final p = db.profiles[uid];
    if (p == null) throw _err('P0002', 'privacy: profile not found');
    return ProfileVisibility.parse([
      {
        'public_profile': p['public_profile'] ?? true,
        'show_stats': p['show_stats'] ?? true,
      },
    ]);
  }

  @override
  Future<void> setProfileVisibility({
    bool? publicProfile,
    bool? showStats,
  }) async {
    final uid = _uid('setProfileVisibility');
    visibilityCalls.add((publicProfile: publicProfile, showStats: showStats));
    db.profiles[uid] = {
      ...?db.profiles[uid],
      'public_profile': ?publicProfile,
      'show_stats': ?showStats,
    };
  }
}

/// Picture files on the "device" for the uploads.
class FakeFiles extends LocalMediaFiles {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String path) async => files[path];
}

/// File contents of [length] bytes that read as the given picture type.
Uint8List jpegBytes([int length = 64]) =>
    _withHeader(const [0xFF, 0xD8, 0xFF, 0xE0], length);
Uint8List pngBytes([int length = 64]) =>
    _withHeader(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], length);
Uint8List webpBytes([int length = 64]) => _withHeader(const [
  0x52,
  0x49,
  0x46,
  0x46,
  0,
  0,
  0,
  0,
  0x57,
  0x45,
  0x42,
  0x50,
], length);
Uint8List gifBytes([int length = 64]) =>
    _withHeader(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61], length);

Uint8List _withHeader(List<int> header, int length) {
  final b = Uint8List(length < header.length ? header.length : length);
  b.setAll(0, header);
  return b;
}
