import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/push_config.dart';
import '../../../core/models/models.dart';

/// Whether the system lets the app show notifications.
enum PushPermission { granted, denied, notAsked }

/// A push the person tapped: the ids the dispatcher sent (no content).
class PushTap {
  const PushTap({
    required this.notificationId,
    required this.type,
    required this.role,
    this.matchId,
    this.subjectId,
    this.clubId,
  });

  final String notificationId;
  final String type;
  final UserRole role;
  final String? matchId;
  final String? subjectId;
  final String? clubId;

  /// The data of a push from push-dispatch; `null` for anything else.
  static PushTap? fromData(Map<String, dynamic> data) {
    final id = data['notification_id'];
    final type = data['type'];
    final role = switch (data['inbox']) {
      'player' => UserRole.player,
      'club_owner' => UserRole.clubOwner,
      _ => null,
    };
    if (id is! String ||
        id.isEmpty ||
        type is! String ||
        type.isEmpty ||
        role == null) {
      return null;
    }
    String? opt(String k) => data[k] is String && (data[k] as String).isNotEmpty
        ? data[k] as String
        : null;
    return PushTap(
      notificationId: id,
      type: type,
      role: role,
      matchId: opt('match_id'),
      subjectId: opt('subject_id'),
      clubId: opt('club_id'),
    );
  }
}

/// The device side of push (M3 P5): permission, this installation's token,
/// and the pushes that arrive or are tapped. [FirebasePushMessaging] in the
/// app; a fake in tests.
abstract interface class PushMessaging {
  Future<PushPermission> permission();

  /// Asks the system (Android 13+ shows its dialog; older versions grant).
  Future<PushPermission> requestPermission();

  /// This installation's FCM token (`null` if Firebase can't give one now).
  Future<String?> token();

  /// A new token for this installation (FCM rotates them).
  Stream<String> get tokenRefreshes;

  /// Pushes tapped while the app was running in the background.
  Stream<PushTap> get taps;

  /// The push whose tap launched the app, if any.
  Future<PushTap?> initialTap();

  /// A push arrived while the app is open (the system shows nothing then).
  Stream<void> get foregroundMessages;

  /// Invalidates this installation's token (sign-out, push switched off): the
  /// server drops it on the next send.
  Future<void> deleteToken();
}

/// [PushMessaging] on Firebase Cloud Messaging, initialized on first use from
/// the build's [PushConfig].
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging(this.config);
  final PushConfig config;

  Future<FirebaseMessaging>? _ready;

  Future<FirebaseMessaging> _messaging() => _ready ??= () async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: config.apiKey,
          appId: config.appId,
          messagingSenderId: config.senderId,
          projectId: config.projectId,
        ),
      );
    }
    return FirebaseMessaging.instance;
  }();

  static PushPermission _of(NotificationSettings s) =>
      switch (s.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.granted,
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently => PushPermission.denied,
        AuthorizationStatus.notDetermined => PushPermission.notAsked,
      };

  @override
  Future<PushPermission> permission() async =>
      _of(await (await _messaging()).getNotificationSettings());

  @override
  Future<PushPermission> requestPermission() async =>
      _of(await (await _messaging()).requestPermission());

  /// Registers with FCM and waits for the token (20 s at most).
  @override
  Future<String?> token() async {
    final m = await _messaging();
    final next = m.onRegistered.first.timeout(const Duration(seconds: 20));
    await m.register();
    try {
      return await next;
    } on TimeoutException {
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes =>
      Stream.fromFuture(_messaging()).asyncExpand((m) => m.onRegistered);

  @override
  Stream<PushTap> get taps => Stream.fromFuture(_messaging()).asyncExpand(
    (_) => FirebaseMessaging.onMessageOpenedApp
        .map((m) => PushTap.fromData(m.data))
        .where((t) => t != null)
        .cast(),
  );

  @override
  Future<PushTap?> initialTap() async {
    final m = await (await _messaging()).getInitialMessage();
    return m == null ? null : PushTap.fromData(m.data);
  }

  @override
  Stream<void> get foregroundMessages =>
      Stream.fromFuture(_messaging())
          .asyncExpand((_) => FirebaseMessaging.onMessage.map((_) {}));

  @override
  Future<void> deleteToken() async => (await _messaging()).unregister();
}

/// The app's [PushMessaging]; read only when push is available.
final pushMessagingProvider = Provider<PushMessaging>(
  (ref) => FirebasePushMessaging(ref.watch(pushConfigProvider)),
);
