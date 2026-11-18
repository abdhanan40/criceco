import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_config.dart';

/// Whether `--dart-define=CRICECO_DEMO=…` was passed at build time, and its
/// value.
const bool kDemoDefined = bool.hasEnvironment('CRICECO_DEMO');
const bool kDemoFlag = bool.fromEnvironment('CRICECO_DEMO');

/// Prototype / simulation controls (Settings → "Prototype controls", the
/// demo panels). `CRICECO_DEMO=true|false` decides when it is passed (approved
/// P25: on for the Final Year Project demo). When it isn't, only the
/// in-memory demo backend has them: a Supabase build never shows simulators
/// because a define was forgotten. (A release Supabase build refuses
/// `CRICECO_DEMO=true` outright — [BackendConfig.parse].)
bool demoControlsFor(BackendConfig config, {bool defined = kDemoDefined, bool flag = kDemoFlag}) =>
    defined ? flag : !config.isSupabase;

/// This build's demo controls, from [backendConfigProvider]. Tests override it.
final demoBuildProvider = Provider<bool>((ref) => demoControlsFor(ref.watch(backendConfigProvider)));

/// Runtime switch for prototype/simulation controls. Only toggleable in a
/// demo build (Settings → "Prototype controls").
class DemoModeController extends Notifier<bool> {
  @override
  bool build() => ref.watch(demoBuildProvider);

  bool get canToggle => ref.read(demoBuildProvider);

  void set(bool enabled) {
    if (!canToggle) return;
    state = enabled;
  }
}

final demoModeProvider = NotifierProvider<DemoModeController, bool>(DemoModeController.new);
