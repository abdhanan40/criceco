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

/// Why this phone has no push registration (C3 Fix A). Never carries an
/// identifier: only what kind of step failed.
enum PushRegistrationFailure {
  /// Firebase could not start (wrong build values, Play services missing).
  firebase,

  /// FCM refused to register this installation (e.g. the FID API disabled).
  rejected,

  /// FCM accepted register() but sent no Installation ID in time.
  timedOut,
}

class PushRegistrationException implements Exception {
  const PushRegistrationException(this.failure);
  final PushRegistrationFailure failure;

  @override
  String toString() => 'PushRegistrationException(${failure.name})';
}

/// The device side of push (M3 P5, C3 Fix A): permission, this installation's
/// Firebase Installation ID (FID), and the pushes that arrive or are tapped.
/// [FirebasePushMessaging] in the app; a fake in tests.
abstract interface class PushMessaging {
  /// Starts Firebase and listens for registrations. Called at app start
  /// (before anything can call register()), so no FID event is missed.
  Future<void> start();

  Future<PushPermission> permission();

  /// Asks the system (Android 13+ shows its dialog; older versions grant).
  Future<PushPermission> requestPermission();

  /// This installation's FID: registers with FCM if it has none yet and waits
  /// for it. Throws [PushRegistrationException]; never returns empty.
  Future<String> installationId();

  /// Every FID FCM delivers (startup syncs, rotations). A new listener first
  /// gets the latest one already delivered, if any.
  Stream<String> get installationIds;

  /// Pushes tapped while the app was running in the background.
  Stream<PushTap> get taps;

  /// The push whose tap launched the app, if any.
  Future<PushTap?> initialTap();

  /// A push arrived while the app is open (the system shows nothing then).
  Stream<void> get foregroundMessages;

  /// Ends this installation's FCM registration (sign-out, push switched off):
  /// FCM then answers UNREGISTERED and the server drops it on its next send.
  Future<void> unregister();
}

/// The FID bookkeeping of [FirebasePushMessaging], apart from Firebase so it
/// can be tested against streams that behave like the plugin's.
///
/// firebase_messaging forwards each FID to Dart once, on a broadcast stream
/// that does not replay; so this listens from construction (before register()
/// can be called) and keeps the latest FID for whoever asks later.
class FidRegistration {
  FidRegistration({
    required Stream<String> registered,
    required Stream<String> unregistered,
    required this.fcmRegister,
    required this.fcmUnregister,
    this.timeout = const Duration(seconds: 30),
  }) {
    _subs
      ..add(registered.listen(_onRegistered, onError: (Object _) {}))
      ..add(unregistered.listen(_onUnregistered, onError: (Object _) {}));
  }

  /// FirebaseMessaging.register / unregister.
  final Future<void> Function() fcmRegister;
  final Future<void> Function() fcmUnregister;
  final Duration timeout;
  final _subs = <StreamSubscription<String>>[];
  final _fids = StreamController<String>.broadcast(sync: true);
  final _waiting = <Completer<String>>[];
  String? _fid;

  /// The latest FID FCM delivered (null before the first, after unregister).
  String? get current => _fid;

  void _onRegistered(String fid) {
    if (fid.isEmpty) return;
    _fid = fid;
    for (final w in _waiting) {
      if (!w.isCompleted) w.complete(fid);
    }
    _waiting.clear();
    _fids.add(fid);
  }

  void _onUnregistered(String fid) {
    if (fid == _fid) _fid = null;
  }

  Future<String> installationId() async {
    if (_fid case final fid?) return fid;
    final waiter = Completer<String>();
    _waiting.add(waiter);
    try {
      await fcmRegister();
    } catch (_) {
      _waiting.remove(waiter);
      throw const PushRegistrationException(PushRegistrationFailure.rejected);
    }
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw const PushRegistrationException(PushRegistrationFailure.timedOut);
    } finally {
      _waiting.remove(waiter);
    }
  }

  /// Every FID from now on, the latest known one first. The live listener is
  /// attached before the replay, in the same turn: nothing falls in between.
  Stream<String> get ids => Stream.multi((c) {
    final sub = _fids.stream.listen(c.add);
    if (_fid case final fid?) c.add(fid);
    c.onCancel = sub.cancel;
  });

  Future<void> unregister() async {
    _fid = null;
    try {
      await fcmUnregister();
    } catch (_) {
      throw const PushRegistrationException(PushRegistrationFailure.rejected);
    }
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _fids.close();
  }
}

/// [PushMessaging] on Firebase Cloud Messaging, initialized on first use from
/// the build's [PushConfig]. Registration is by Firebase Installation ID
/// (AndroidManifest `firebase_messaging_installation_id_enabled`).
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging(this.config);
  final PushConfig config;

  Future<(FirebaseMessaging, FidRegistration)>? _ready;

  Future<(FirebaseMessaging, FidRegistration)> _messaging() =>
      _ready ??= _init().catchError((Object e) {
        _ready = null; // the next call tries again
        throw e;
      });

  Future<(FirebaseMessaging, FidRegistration)> _init() async {
    try {
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
    } catch (_) {
      throw const PushRegistrationException(PushRegistrationFailure.firebase);
    }
    final m = FirebaseMessaging.instance;
    // Listen right away, in the same turn as the instance is made: an FID the
    // plugin forwards before anyone asks is kept, not lost.
    final fids = FidRegistration(
      registered: m.onRegistered,
      unregistered: m.onUnregistered,
      fcmRegister: m.register,
      fcmUnregister: m.unregister,
    );
    return (m, fids);
  }

  static PushPermission _of(NotificationSettings s) =>
      switch (s.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => PushPermission.granted,
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently => PushPermission.denied,
        AuthorizationStatus.notDetermined => PushPermission.notAsked,
      };

  @override
  Future<void> start() async => _messaging();

  @override
  Future<PushPermission> permission() async =>
      _of(await (await _messaging()).$1.getNotificationSettings());

  @override
  Future<PushPermission> requestPermission() async =>
      _of(await (await _messaging()).$1.requestPermission());

  @override
  Future<String> installationId() async =>
      (await _messaging()).$2.installationId();

  @override
  Stream<String> get installationIds =>
      Stream.fromFuture(_messaging()).asyncExpand((r) => r.$2.ids);

  @override
  Stream<PushTap> get taps => Stream.fromFuture(_messaging()).asyncExpand(
    (_) => FirebaseMessaging.onMessageOpenedApp
        .map((m) => PushTap.fromData(m.data))
        .where((t) => t != null)
        .cast(),
  );

  @override
  Future<PushTap?> initialTap() async {
    final m = await (await _messaging()).$1.getInitialMessage();
    return m == null ? null : PushTap.fromData(m.data);
  }

  @override
  Stream<void> get foregroundMessages =>
      Stream.fromFuture(_messaging())
          .asyncExpand((_) => FirebaseMessaging.onMessage.map((_) {}));

  @override
  Future<void> unregister() async => (await _messaging()).$2.unregister();
}

/// The app's [PushMessaging]; read only when push is available.
final pushMessagingProvider = Provider<PushMessaging>(
  (ref) => FirebasePushMessaging(ref.watch(pushConfigProvider)),
);
