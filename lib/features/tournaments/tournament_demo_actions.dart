import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/demo_mode.dart';
import '../../demo/demo_tournament_tools.dart';
import 'tournaments_controller.dart';

/// Tournament seam to the Demo Mode simulators in `lib/demo/` (revised
/// architecture §11: screens never import `lib/demo/` directly). Every
/// method is a no-op with Demo Mode OFF (fixtures read-only, decisions come
/// from the real organizer — P10).
class TournamentDemoActions {
  TournamentDemoActions(this._ref);
  final Ref _ref;
  final _results = DemoMatchResults();

  bool get _on => _ref.read(demoModeProvider);

  /// "Simulate Organizer Decision" on My Registrations → Registration
  /// Details. The other club's organizer decides; on approval with enough
  /// teams it also publishes the fixtures (prototype
  /// `buildFixturesForTournament` on the approved view).
  Future<RegistrationDecision?> organizerDecides(String registrationId, {required bool approve}) async {
    if (!_on) return null;
    final decision =
        await _ref.read(tournamentRegistrationsProvider.notifier).decide(registrationId, approve: approve);
    final r = _ref.read(tournamentRegistrationsProvider.notifier).byId(registrationId);
    if (decision == RegistrationDecision.approved && r != null) {
      final t = _ref.read(tournamentsProvider.notifier).byId(r.tournamentId);
      if (t != null && t.fixtures == null && t.canGenerateFixtures) {
        await _ref.read(tournamentsProvider.notifier).generateFixtures(t.id);
      }
    }
    return decision;
  }

  /// "Tap to simulate result": a random winner for a ready fixture. Returns
  /// the winner's entrant id, or `null` when nothing was recorded.
  Future<String?> simulateResult(String tournamentId, FixtureRef f) async {
    if (!_on) return null;
    final winner = _results.pickWinner(f.match);
    if (winner == null) return null;
    final updated =
        await _ref.read(tournamentsProvider.notifier).recordResult(tournamentId, f.roundIdx, f.matchIdx, winner);
    return updated == null ? null : winner;
  }
}

final tournamentDemoActionsProvider = Provider<TournamentDemoActions>(TournamentDemoActions.new);
