import '../core/models/models.dart';

/// Demo Mode only (revised architecture §11): simulates the opponent club
/// accepting a sent challenge straight away — the prototype's approved
/// "instant acceptance" flow. It calls the same accept path a backend reply
/// would use, so a real opponent response can replace it with no UI change.
///
/// With Demo Mode OFF this is never called: a sent challenge stays pending
/// (listed under "Sent" on My Challenges, approved P9) until the opponent
/// responds or it expires.
class DemoChallengeResponder {
  const DemoChallengeResponder();

  Future<Challenge?> respond(Challenge sent, Future<Challenge?> Function(String challengeId) accept) =>
      accept(sent.id);
}
