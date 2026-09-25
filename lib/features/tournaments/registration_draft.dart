import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';

/// Unsaved registration for one tournament (revised architecture §10:
/// `registrationDraftProvider(tournamentId)` replaces the prototype's
/// `selectedRegisterTeam` / `agreeToRules`). The squad is confirmed through
/// the shared line-up flow (`TournamentEntryTarget`).
class RegistrationDraft {
  const RegistrationDraft({this.lineup, this.agreed = false});
  final Lineup? lineup;
  final bool agreed;
}

class RegistrationDraftController extends Notifier<RegistrationDraft> {
  RegistrationDraftController(this.tournamentId);
  final String tournamentId;

  @override
  RegistrationDraft build() => const RegistrationDraft();

  /// A confirmed squad. The rules must be agreed again for a new squad
  /// (prototype `assignTeamToRegistration` resets `agreeToRules`).
  void setLineup(Lineup lineup) => state = RegistrationDraft(lineup: lineup);

  void setAgreed(bool agreed) => state = RegistrationDraft(lineup: state.lineup, agreed: agreed);

  void clear() => state = const RegistrationDraft();
}

/// Kept alive for the session: a squad picked for a tournament survives
/// leaving the flow and coming back.
final registrationDraftProvider =
    NotifierProvider.family<RegistrationDraftController, RegistrationDraft, String>(RegistrationDraftController.new);
