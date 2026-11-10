import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/models.dart';

/// The club picture stays on this device in Supabase mode (approved D-S2-2):
/// stored per club id in SharedPreferences, so it survives restarts and
/// sign-outs. Everything else about the club is in `public.clubs`.
class LocalClubOverlay {
  LocalClubOverlay(this._prefs);
  final SharedPreferences _prefs;

  static String keyFor(String clubId) => 'criceco.local.club.$clubId';

  /// [club] with this device's picture (none stored: no picture).
  Club applyTo(Club club) {
    final raw = _prefs.getString(keyFor(club.id));
    if (raw == null) return club.withLogo(null);
    final Object? m;
    try {
      m = jsonDecode(raw);
    } on FormatException {
      return club.withLogo(null); // unreadable local data never blocks loading
    }
    final path = m is Map ? m['logoPath'] : null;
    return club.withLogo(path is String ? path : null);
  }

  /// Saves [club]'s picture for this device (removes it when there is none).
  Future<void> save(Club club) async {
    final path = club.logoPath;
    if (path == null) {
      await _prefs.remove(keyFor(club.id));
    } else {
      await _prefs.setString(keyFor(club.id), jsonEncode({'logoPath': path}));
    }
  }
}
