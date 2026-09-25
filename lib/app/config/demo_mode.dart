import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compile-time demo build flag. ON by default for the Final Year Project
/// build (approved P25); disable with `--dart-define=CRICECO_DEMO=false`.
const bool kDemoBuild = bool.fromEnvironment('CRICECO_DEMO', defaultValue: true);

/// Runtime switch for prototype/simulation controls. Only toggleable in a
/// demo build (Settings → "Prototype controls").
class DemoModeController extends Notifier<bool> {
  @override
  bool build() => kDemoBuild;

  bool get canToggle => kDemoBuild;

  void set(bool enabled) {
    if (!kDemoBuild) return;
    state = enabled;
  }
}

final demoModeProvider = NotifierProvider<DemoModeController, bool>(DemoModeController.new);
