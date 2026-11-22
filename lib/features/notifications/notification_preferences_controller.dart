import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';

/// The signed-in person's notification preferences (migration 26, M3 P4).
/// A switch changes at once; saves go to the server one after another, each
/// with the whole choice at that moment, so quick taps can't arrive out of
/// order. A save the server refuses puts back what was last saved.
class NotificationPreferencesController
    extends AsyncNotifier<NotificationPreferences> {
  NotificationPreferences? _saved;
  Future<void> _queue = Future<void>.value();

  NotificationPreferencesRepository get _repo =>
      ref.read(notificationPreferencesRepositoryProvider);

  @override
  Future<NotificationPreferences> build() async {
    ref.watch(currentAccountProvider.select((a) => a?.id));
    ref.watch(notificationPreferencesRepositoryProvider);
    final loaded = await _repo.load();
    _saved = loaded;
    return loaded;
  }

  /// Turns [category] on or off (membership can't be turned off). Throws if
  /// the server refuses — the switch is put back first.
  Future<void> set(NotificationCategory category, bool on) {
    final current = state.value;
    if (current == null || category.alwaysOn || current.isOn(category) == on) {
      return Future<void>.value();
    }
    state = AsyncData(current.withCategory(category, on));
    final done = _queue.then((_) async {
      final wanted = state.value;
      if (wanted == null) return;
      try {
        final saved = await _repo.save(wanted);
        _saved = saved;
        // A newer tap is already queued: leave its choice on screen.
        if (state.value == wanted) state = AsyncData(saved);
      } catch (_) {
        state = AsyncData(_saved ?? NotificationPreferences.allOn);
        rethrow;
      }
    });
    _queue = done.catchError((Object _) {});
    return done;
  }
}

final notificationPreferencesProvider =
    AsyncNotifierProvider<
      NotificationPreferencesController,
      NotificationPreferences
    >(NotificationPreferencesController.new);
