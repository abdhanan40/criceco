import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/config/push_config.dart';
import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import 'push_messaging.dart';

/// Push on this device (M3 P5), as the app sees it.
class PushState {
  const PushState({
    this.available = false,
    this.enabled = false,
    this.asked = false,
    this.permission = PushPermission.notAsked,
  });

  static const unavailable = PushState();

  /// The build can receive push ([pushAvailableProvider]).
  final bool available;

  /// The person turned push on for this phone ("Push on this device").
  final bool enabled;

  /// The one-time explanation was shown (answered either way).
  final bool asked;
  final PushPermission permission;

  /// Pushes actually arrive: on, and the system allows it.
  bool get active =>
      available && enabled && permission == PushPermission.granted;

  PushState copyWith({
    bool? enabled,
    bool? asked,
    PushPermission? permission,
  }) => PushState(
    available: available,
    enabled: enabled ?? this.enabled,
    asked: asked ?? this.asked,
    permission: permission ?? this.permission,
  );
}

/// Registers this installation for push while someone is signed in and push
/// is on (D: asked once from the inbox; "Push on this device" in Notification
/// settings). Off until the person says yes. Signing out invalidates the
/// token at Firebase (the server then drops it on its next send) — no call
/// that needs the old session. Every failure is quiet: push is a bonus on
/// top of the inbox, never a reason for an error screen.
class PushController extends Notifier<PushState> {
  static const enabledKey = 'push.enabled.v1';
  static const askedKey = 'push.asked.v1';

  /// Survives rebuilds (an account change rebuilds the controller).
  _PushRegistration get _r => ref.read(_pushRegistrationProvider);

  PushMessaging get _messaging => ref.read(pushMessagingProvider);

  @override
  PushState build() {
    final available = ref.watch(pushAvailableProvider);
    final accountId = ref.watch(currentAccountProvider.select((a) => a?.id));
    if (!available) return PushState.unavailable;
    final prefs = ref.watch(sharedPreferencesProvider);
    final initial = PushState(
      available: true,
      enabled: prefs.getBool(enabledKey) ?? false,
      asked: prefs.getBool(askedKey) ?? false,
    );
    Future.microtask(() => _sync(accountId));
    return initial;
  }

  Future<void> _sync(String? accountId) async {
    try {
      if (accountId == null) {
        // Signed out: this installation no longer belongs to anyone.
        if (_r.token != null) {
          _r.token = null;
          unawaited(_r.refreshes?.cancel());
          _r.refreshes = null;
          await _messaging.deleteToken();
        }
        return;
      }
      final permission = await _messaging.permission();
      if (!ref.mounted) return;
      state = state.copyWith(permission: permission);
      if (!state.active) return;
      await _register(await _messaging.token());
      _r.refreshes ??= _messaging.tokenRefreshes.listen(
        (t) => _register(t).catchError((Object _) {}),
      );
    } catch (_) {
      // Quiet: the inbox works without push; the next start tries again.
    }
  }

  Future<void> _register(String? token) async {
    if (token == null || token.isEmpty || token == _r.token) return;
    await ref.read(pushDeviceRepositoryProvider).register(token);
    _r.token = token;
  }

  /// Should the inbox offer push now (signed in, available, never asked)?
  bool get shouldOffer =>
      state.available &&
      !state.asked &&
      !state.enabled &&
      ref.read(currentAccountProvider) != null;

  /// "Turn on": asks the system if needed, then registers. Returns whether
  /// pushes will now arrive.
  Future<bool> turnOn() async {
    if (!state.available) return false;
    await _remember(asked: true);
    final permission = await _messaging.requestPermission();
    if (!ref.mounted) return false;
    state = state.copyWith(permission: permission, asked: true);
    if (permission != PushPermission.granted) return false;
    await _remember(enabled: true);
    state = state.copyWith(enabled: true);
    await _sync(ref.read(currentAccountProvider)?.id);
    return state.active;
  }

  /// "Push on this device" off: unregisters and invalidates the token.
  Future<void> turnOff() async {
    if (!state.available) return;
    await _remember(enabled: false);
    state = state.copyWith(enabled: false);
    final token = _r.token;
    _r.token = null;
    unawaited(_r.refreshes?.cancel());
    _r.refreshes = null;
    try {
      if (token != null) {
        await ref.read(pushDeviceRepositoryProvider).unregister(token);
      }
    } catch (_) {
      // The token is invalidated below anyway; the server drops it then.
    }
    try {
      await _messaging.deleteToken();
    } catch (_) {}
  }

  /// "Not now" on the explanation: never offered again (settings still can).
  Future<void> notNow() async {
    await _remember(asked: true);
    state = state.copyWith(asked: true);
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
  String? token;
  StreamSubscription<String>? refreshes;
}

final _pushRegistrationProvider = Provider<_PushRegistration>((ref) {
  final r = _PushRegistration();
  ref.onDispose(() => r.refreshes?.cancel());
  return r;
});
