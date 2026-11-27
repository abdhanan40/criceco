import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/models.dart';

/// D9: the parts of an account that stay on this device in Supabase mode —
/// the profile photo and the app settings — stored per user id in
/// SharedPreferences, so they survive restarts and sign-outs.
class LocalAccountOverlay {
  LocalAccountOverlay(this._prefs);
  final SharedPreferences _prefs;

  static String keyFor(String userId) => 'criceco.local.$userId';

  /// [account] with this device's photo and settings (defaults if none).
  UserAccount applyTo(UserAccount account) {
    final raw = _prefs.getString(keyFor(account.id));
    if (raw == null) return account;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return account; // unreadable local data never blocks sign-in
    }
    final photoPath = m['photoPath'] as String?;
    final s = (m['settings'] as Map<String, dynamic>?) ?? const {};
    final changedAt = s['passwordChangedAt'] as String?;
    return account.copyWith(
      hasPhoto: (m['hasPhoto'] as bool?) ?? photoPath != null,
      photoPath: photoPath,
      clearPhoto: photoPath == null,
      settings: AccountSettings(
        publicProfile: (s['publicProfile'] as bool?) ?? true,
        showStats: (s['showStats'] as bool?) ?? true,
        showPhone: (s['showPhone'] as bool?) ?? false,
        twoStep: (s['twoStep'] as bool?) ?? false,
        loginAlerts: (s['loginAlerts'] as bool?) ?? true,
        passwordChangedAt: changedAt == null
            ? null
            : DateTime.tryParse(changedAt),
      ),
    );
  }

  /// Forgets this device's photo and settings for [userId] (account deleted).
  Future<void> clear(String userId) async {
    await _prefs.remove(keyFor(userId));
    await _prefs.remove(refusedPhotoKeyFor(userId));
  }

  /// M5: the device photo the server refused to take over (too large, not a
  /// JPG / PNG / WebP) — not tried again.
  static String refusedPhotoKeyFor(String userId) =>
      'criceco.local.$userId.photoRefused';

  String? refusedPhoto(String userId) =>
      _prefs.getString(refusedPhotoKeyFor(userId));

  Future<void> markPhotoRefused(String userId, String path) =>
      _prefs.setString(refusedPhotoKeyFor(userId), path);

  /// M5: forgets only the device photo of [userId] (it is on the server now,
  /// or the file is gone); the settings stay.
  Future<void> clearPhoto(String userId) async {
    final raw = _prefs.getString(keyFor(userId));
    if (raw == null) return;
    final Object? m;
    try {
      m = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (m is! Map<String, dynamic>) return;
    await _prefs.setString(
      keyFor(userId),
      jsonEncode({...m, 'hasPhoto': false, 'photoPath': null}),
    );
  }

  /// Saves [account]'s photo and settings for its user id.
  Future<void> save(UserAccount account) => _prefs.setString(
    keyFor(account.id),
    jsonEncode({
      'hasPhoto': account.hasPhoto,
      'photoPath': account.photoPath,
      'settings': {
        'publicProfile': account.settings.publicProfile,
        'showStats': account.settings.showStats,
        'showPhone': account.settings.showPhone,
        'twoStep': account.settings.twoStep,
        'loginAlerts': account.settings.loginAlerts,
        'passwordChangedAt': account.settings.passwordChangedAt
            ?.toIso8601String(),
      },
    }),
  );
}
