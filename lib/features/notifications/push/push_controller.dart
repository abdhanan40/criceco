import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/push_config.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../data/repositories/repositories.dart' show PushDeviceRepository;
import 'push_messaging.dart';

/// Why push is on but this phone is not registered (C3 Fix A). Shown in
/// Notification settings with "Try again"; the next start tries again too.
enum PushFailure {
  /// Firebase gave this phone no registration (or Firebase didn't start).
  phone,

  /// The registration couldn't be saved at CricEco (offline, server error).
  server,
}

/// Push on this device (M3 P5), as the app sees it.
class PushState {
  const PushState({
    this.available = false,
    this.enabled = false,
    this.asked = false,
    this.permission = PushPermission.notAsked,
    this.failure,
  });

  static const unavailable = PushState();

  /// The build can receive push ([pushAvailableProvider]).
  final bool available;

  /// The person turned push on for this phone ("Push on this device").
  final bool enabled;

  /// The one-time explanation was shown (answered either way).
  final bool asked;
  final PushPermission permission;

  /// The last registration attempt failed (null: fine, or not tried yet).
  final PushFailure? failure;

  /// Push is on and the system allows it (pushes arrive once registered:
  /// see [failure]).
  bool get active =>
      available && enabled && permission == PushPermission.granted;

  PushState copyWith({
    bool? enabled,
    bool? asked,
    PushPermission? permission,
    PushFailure? failure,
    bool clearFailure = false,
  }) => PushState(
    available: available,
    enabled: enabled ?? this.enabled,
    asked: asked ?? this.asked,
    permission: permission ?? this.permission,
    failure: clearFailure ? null : failure ?? this.failure,
  );
}

/// Registers this installation for push while someone is signed in and push
/// is on (asked once from the inbox; "Push on this device" in Notification
/// settings). Off until the person says yes and Android allows it.
///
/// The device is registered by its Firebase Installation ID (FID, C3 Fix A):
/// on each start while push is on, and again whenever FCM delivers a new one
/// (rotation; the old one is then removed). A failure is kept in
/// [PushState.failure] and shown with "Try again" — never silent; the inbox
/// keeps working without push. Push off and sign-out remove the registration
/// at CricEco (sign-out does it before the session ends) and at FCM.
class PushController extends Notifier<PushState> {
  static const enabledKey = 'push.enabled.v1';
  static const askedKey = 'push.asked.v1';

  /// The FID last registered at CricEco from this phone: what to remove on
  /// push off, sign-out and rotation, also after a restart. Not a secret
  /// (FCM keeps it on the phone too); never logged.
  static const registeredKey = 'push.fid.v1';

  /// Survives rebuilds (an account change rebuilds the controller).
  _PushRegistration get _r => ref.read(_pushRegistrationProvider);

  PushMessaging get _messaging => ref.read(pushMessagingProvider);

  @override
  PushState build() {
    final available = ref.watch(pushAvailableProvider);
    final accountId = ref.watch(currentAccountProvider.select((a) => a?.id));
    if (!available) return PushState.unavailable;
    // The rotation listener belongs to the controller that made it; this
    // one's sync makes its own.
    ref.read(_pushRegistrationProvider).stopListening();
    // Logout removes this phone at CricEco before ending the session; each
    // sign-in registers it for the new one.
    final session = ref.read(sessionProvider.notifier);
    final hook = releaseForSignOut;
    void signedIn(String id) => unawaited(_sync(id));
    session
      ..beforeSignOut = hook
      ..afterSignIn = signedIn;
    ref.onDispose(() {
      if (session.beforeSignOut == hook) session.beforeSignOut = null;
      if (session.afterSignIn == signedIn) session.afterSignIn = null;
    });
    final prefs = ref.watch(sharedPreferencesProvider);
    final initial = PushState(
      available: true,
      enabled: prefs.getBool(enabledKey) ?? false,
      asked: prefs.getBool(askedKey) ?? false,
    );
    Future.microtask(() => _sync(accountId));
    return initial;
  }

  /// One sync at a time (start, "Turn on", "Try again", account changes).
  Future<void> _sync(String? accountId) {
    if (!ref.mounted) return Future.value();
    return _r.serial(() => _syncNow(accountId));
  }

  Future<void> _syncNow(String? accountId) async {
    if (!ref.mounted) return; // superseded by a rebuild; its own sync follows
    final r = _r;
    final messaging = _messaging;
    final prefs = ref.read(sharedPreferencesProvider);
    final devices = ref.read(pushDeviceRepositoryProvider);

    if (accountId == null) {
      // Signed out (any way): this installation belongs to no one now.
      // Before the session is restored at start nothing was registered yet.
      if (r.fid == null) return;
      r.forget();
      await prefs.remove(registeredKey);
      try {
        await messaging.unregister();
      } catch (_) {
        // The server drops it once FCM stops accepting it.
      }
      return;
    }

    if (!state.enabled) {
      // Push off: finish a removal that failed earlier (offline at the time).
      final leftover = prefs.getString(registeredKey);
      if (leftover != null && await _unregisterAtServer(devices, leftover)) {
        await prefs.remove(registeredKey);
      }
      return;
    }

    final PushPermission permission;
    try {
      permission = await messaging.permission();
    } catch (_) {
      _fail(PushFailure.phone);
      return;
    }
    if (!ref.mounted) return;
    state = state.copyWith(permission: permission);
    if (!state.active) return; // Android says no: nothing registered

    final String fid;
    try {
      fid = await messaging.installationId();
    } catch (_) {
      _fail(PushFailure.phone);
      return;
    }
    if (!await _register(accountId, fid)) return;
    // Every later FID (FCM rotates it) is registered too. The stream replays
    // the current one first; it is skipped as already registered.
    r.ids ??= messaging.installationIds.listen(
      (next) => r.serial(() async {
        if (!ref.mounted || !state.active) return;
        await _register(accountId, next);
      }),
      onError: (Object _) {},
    );
  }

  /// Registers [fid] for [accountId] at CricEco (once per process for the
  /// same pair; again on each start, which refreshes its last-seen time).
  /// Removes the one it replaces. Returns whether it is registered.
  Future<bool> _register(String accountId, String fid) async {
    if (!ref.mounted) return false; // a rebuild's own sync takes over
    final r = _r;
    if (r.fid == fid && r.account == accountId) {
      if (ref.mounted && state.failure != null) {
        state = state.copyWith(clearFailure: true);
      }
      return true;
    }
    final prefs = ref.read(sharedPreferencesProvider);
    final devices = ref.read(pushDeviceRepositoryProvider);
    try {
      await devices.register(fid);
    } catch (_) {
      _fail(PushFailure.server);
      return false;
    }
    final previous = r.fid ?? prefs.getString(registeredKey);
    r
      ..fid = fid
      ..account = accountId;
    await prefs.setString(registeredKey, fid);
    if (ref.mounted) state = state.copyWith(clearFailure: true);
    if (previous != null && previous != fid) {
      // Rotated: the old FID no longer reaches this phone.
      await _unregisterAtServer(devices, previous);
    }
    return true;
  }

  static Future<bool> _unregisterAtServer(
    PushDeviceRepository devices,
    String fid,
  ) async {
    try {
      await devices.unregister(fid);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _fail(PushFailure failure) {
    if (ref.mounted) state = state.copyWith(failure: failure);
  }

  /// Should the inbox offer push now (signed in, available, never asked)?
  bool get shouldOffer =>
      state.available &&
      !state.asked &&
      !state.enabled &&
      ref.read(currentAccountProvider) != null;

  /// "Turn on": asks the system if needed, then registers. Returns whether
  /// Android allows the pushes; [PushState.failure] says if registering
  /// failed.
  Future<bool> turnOn() async {
    if (!state.available) return false;
    await _remember(asked: true);
    final PushPermission permission;
    try {
      permission = await _messaging.requestPermission();
    } catch (_) {
      _fail(PushFailure.phone);
      return false;
    }
    if (!ref.mounted) return false;
    state = state.copyWith(permission: permission, asked: true);
    if (permission != PushPermission.granted) return false;
    await _remember(enabled: true);
    state = state.copyWith(enabled: true, clearFailure: true);
    await _sync(ref.read(currentAccountProvider)?.id);
    return ref.mounted && state.active;
  }

  /// "Try again" after a failed registration.
  Future<void> retry() async {
    if (!state.available) return;
    state = state.copyWith(clearFailure: true);
    await _sync(ref.read(currentAccountProvider)?.id);
  }

  /// "Push on this device" off: removed at CricEco and at FCM. If CricEco
  /// can't be reached, FCM's removal stops the pushes and the next start
  /// removes it at CricEco too.
  Future<void> turnOff() async {
    if (!state.available) return;
    final r = _r;
    final messaging = _messaging;
    final prefs = ref.read(sharedPreferencesProvider);
    final devices = ref.read(pushDeviceRepositoryProvider);
    await _remember(enabled: false);
    if (ref.mounted) {
      state = state.copyWith(enabled: false, clearFailure: true);
    }
    final fid = r.fid ?? prefs.getString(registeredKey);
    r.forget();
    await r.serial(() async {
      if (fid != null && await _unregisterAtServer(devices, fid)) {
        await prefs.remove(registeredKey);
      }
      try {
        await messaging.unregister();
      } catch (_) {}
    });
  }

  /// Sign-out ([SessionController.beforeSignOut], run by logout): removes this
  /// phone at CricEco while the session still works, then ends the FCM
  /// registration. The returned future completes when CricEco answered (or
  /// failed); logout waits for it at most
  /// [SessionController.beforeSignOutTimeout].
  Future<void> releaseForSignOut() {
    if (!state.available) return Future.value();
    final r = _r;
    final messaging = _messaging;
    final prefs = ref.read(sharedPreferencesProvider);
    final devices = ref.read(pushDeviceRepositoryProvider);
    final fid = r.fid ?? prefs.getString(registeredKey);
    if (fid == null) return Future.value(); // nothing registered from here
    r.forget();
    // Not queued: it must not wait behind a slow registration.
    final atServer = _unregisterAtServer(devices, fid);
    unawaited(
      r.serial(() async {
        await atServer;
        await prefs.remove(registeredKey);
        try {
          await messaging.unregister();
        } catch (_) {}
      }),
    );
    return atServer;
  }

  /// "Not now" on the explanation: never offered again (settings still can).
  Future<void> notNow() async {
    await _remember(asked: true);
    if (ref.mounted) state = state.copyWith(asked: true);
  }

  Future<void> _remember({bool? enabled, bool? asked}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (enabled != null) await prefs.setBool(enabledKey, enabled);
    if (asked != null) await prefs.setBool(askedKey, asked);
  }
}

final pushControllerProvider = NotifierProvider<PushController, PushState>(
  PushController.new,
);

/// What this installation registered, kept across the controller's rebuilds.
class _PushRegistration {
  /// The FID registered at CricEco in this process, and for whom.
  String? fid;
  String? account;
  StreamSubscription<String>? ids;
  Future<void> _last = Future.value();

  /// Runs [task] after the ones before it (they never block it by failing).
  Future<void> serial(Future<void> Function() task) {
    final next = _last.then((_) => task()).catchError((Object _) {});
    _last = next;
    return next;
  }

  void forget() {
    fid = null;
    account = null;
    stopListening();
  }

  void stopListening() {
    unawaited(ids?.cancel());
    ids = null;
  }
}

final _pushRegistrationProvider = Provider<_PushRegistration>((ref) {
  final r = _PushRegistration();
  ref.onDispose(() => r.ids?.cancel());
  return r;
});
