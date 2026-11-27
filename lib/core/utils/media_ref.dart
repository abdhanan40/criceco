import 'dart:math';
import 'dart:typed_data';

/// A picture kept in Supabase Storage (M5), as the app carries it in the
/// models' picture fields (`UserAccount.photoPath`, `Club.logoPath`,
/// `ClubMember.photoPath`, …): `storage://<bucket>/<object path>`. Any other
/// value is a picture file on this device (the photo picker's path).
///
/// Nothing here talks to Supabase: screens show a stored picture through a
/// signed URL (`signedMediaUrlProvider`), the repositories upload and
/// delete them.
abstract final class MediaRef {
  static const _scheme = 'storage://';

  /// Profile pictures: `avatars/<user id>/<uuid>.<ext>`.
  static const avatarsBucket = 'avatars';

  /// Club pictures: `club-logos/<club id>/<uuid>.<ext>`.
  static const clubLogosBucket = 'club-logos';

  /// The buckets' upload limit (migration 31): 2 MB.
  static const maxUploadBytes = 2 * 1024 * 1024;

  /// A picture kept on this device only (no upload): 10 MB.
  static const maxLocalBytes = 10 * 1024 * 1024;

  /// How long a signed picture URL works (1 hour).
  static const signedUrlLifetime = Duration(hours: 1);

  /// `storage://<bucket>/<path>` for an object of [bucket]; `null` for none.
  static String? of(String bucket, String? objectPath) {
    final p = objectPath?.trim();
    return p == null || p.isEmpty ? null : '$_scheme$bucket/$p';
  }

  /// A stored picture (not a file on this device).
  static bool isStored(String? ref) => ref != null && ref.startsWith(_scheme);

  /// The bucket and object path of a stored picture; `null` otherwise.
  static ({String bucket, String path})? parse(String? ref) {
    if (!isStored(ref)) return null;
    final rest = ref!.substring(_scheme.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    return (bucket: rest.substring(0, slash), path: rest.substring(slash + 1));
  }

  /// The object path of [ref] when it is in [bucket]; `null` otherwise.
  static String? objectPathIn(String bucket, String? ref) {
    final p = parse(ref);
    return p != null && p.bucket == bucket ? p.path : null;
  }

  /// The picture type from the file's first bytes (not its name): JPEG, PNG
  /// or WebP — the types the buckets accept. `null` for anything else.
  static ({String ext, String mime})? imageTypeOf(Uint8List bytes) {
    bool at(int offset, List<int> sig) {
      if (bytes.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (bytes[offset + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, const [0xFF, 0xD8, 0xFF])) {
      return (ext: 'jpg', mime: 'image/jpeg');
    }
    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return (ext: 'png', mime: 'image/png');
    }
    // RIFF....WEBP
    if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
        at(8, const [0x57, 0x45, 0x42, 0x50])) {
      return (ext: 'webp', mime: 'image/webp');
    }
    return null;
  }

  static final _random = Random.secure();

  /// A random (version 4) UUID for a new object name.
  static String newObjectId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}
