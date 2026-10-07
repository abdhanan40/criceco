import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/session_controller.dart';
import '../../core/domain/player_ranking.dart';
import '../../core/models/models.dart';
import '../../demo/seed_data.dart';
import '../club/club_providers.dart';
import '../club/hunt/player_hunt_controller.dart';
import '../player/player_providers.dart';

/// Who is ranked (frontend stage): the players this device knows —
///
/// * the club roster (the pool behind Add Players), on their scouting stats;
/// * Available Players from Player Hunt (a name already in the roster is the
///   same person and is counted once);
/// * the signed-in player, on their own season log (My Performance).
///
/// Derived on every change; nothing is stored. A shared, cross-device
/// leaderboard needs the backend.
final rankingInputsProvider = FutureProvider<List<RankingInput>>((ref) async {
  final account = ref.watch(currentAccountProvider);
  final ownClub = ref.watch(currentClubProvider);
  final roster = await ref.read(clubRepositoryProvider).playerPool(SeedData.ownClubId);
  final rosterClub = ownClub?.id == SeedData.ownClubId
      ? ownClub!.displayShortName
      : ref.read(seedDataProvider).ownClub.displayShortName;
  final open = await ref.watch(openPlayersProvider.future);

  final inputs = <RankingInput>[];
  final names = <String>{};
  String key(String name) => name.trim().toLowerCase();

  // ---- The signed-in player: their own season log ----
  if (account != null) {
    final perf = await ref.watch(performanceProvider.future);
    final role = account.playerProfile.role;
    inputs.add(rankingInputFromPerformance(
      perf,
      playerId: account.id,
      name: account.fullName.trim().isEmpty ? 'You' : account.fullName.trim(),
      club: account.memberships.firstOrNull?.clubName ?? ownClub?.displayShortName ?? 'No club',
      role: role == null ? SquadCategory.batsman : squadCategoryOf(role),
    ));
    names.add(key(account.fullName));
  }

  // ---- The club roster ----
  for (final p in roster) {
    if (!names.add(key(p.name))) continue;
    final stats = ref.watch(squadPlayerStatsProvider((p.name, p.position, p.availability)));
    inputs.add(rankingInputFromStats(stats, playerId: p.id, name: p.name, club: rosterClub));
  }

  // ---- Available Players (free agents) ----
  for (final p in open) {
    if (p.isMe || !names.add(key(p.name))) continue;
    final stats = ref.watch(squadPlayerStatsProvider((p.name, p.role.label, PlayerAvailability.available)));
    inputs.add(rankingInputFromStats(stats, playerId: p.id, name: p.name, club: 'Free agent'));
  }
  return inputs;
});

/// The rankings (Overall + per role), recalculated whenever the inputs change.
final rankingBoardProvider = FutureProvider<RankingBoard>((ref) async {
  return PlayerRankingMath.rank(await ref.watch(rankingInputsProvider.future));
});

SquadCategory squadCategoryOf(PlayerRole role) => switch (role) {
      PlayerRole.batsman => SquadCategory.batsman,
      PlayerRole.bowler => SquadCategory.bowler,
      PlayerRole.allRounder => SquadCategory.allRounder,
    };

double? _num(String? s) => s == null ? null : double.tryParse(s.replaceAll(RegExp(r'[^0-9.]'), ''));

/// A roster / Available player, from the scouting stats (the same numbers as
/// the Player Stats sheet).
RankingInput rankingInputFromStats(PlayerStats s, {required String playerId, required String name, required String club}) =>
    RankingInput(
      playerId: playerId,
      name: name,
      club: club,
      role: s.category,
      completedMatches: s.matches,
      runs: s.batting.runs,
      battingAverage: _num(s.batting.average),
      strikeRate: _num(s.batting.strikeRate),
      wickets: s.bowling.wickets,
      economy: _num(s.bowling.economy),
      bowlingAverage: _num(s.bowling.average),
      rating: _num(s.rating),
      recentWins: s.wins,
      recentPlayed: s.form.length,
    );

/// The signed-in player, from My Performance. Completed matches are the
/// season log — a match is logged only once it has a result, so upcoming
/// and cancelled matches (My Matches) never count.
RankingInput rankingInputFromPerformance(
  PerformanceSummary p, {
  required String playerId,
  required String name,
  required String club,
  required SquadCategory role,
}) {
  double? tile(List<StatTile> tiles, String label) => _num(tiles.where((t) => t.label == label).firstOrNull?.value);
  final form = p.recentForm.take(5).toList();
  return RankingInput(
    playerId: playerId,
    name: name,
    club: club,
    role: role,
    completedMatches: p.matchLog.length,
    runs: p.runs,
    battingAverage: tile(p.batting, 'Batting Average'),
    strikeRate: tile(p.batting, 'Strike Rate'),
    wickets: p.wickets,
    economy: tile(p.bowling, 'Economy Rate'),
    bowlingAverage: tile(p.bowling, 'Bowling Average'),
    rating: _num(p.rating),
    recentWins: form.where((f) => f.result == MatchResult.won).length,
    recentPlayed: form.length,
    isMe: true,
  );
}

/// The ranking for a Player Hunt card: by id, else the same-named roster
/// player (counted once), else the signed-in player for "You".
PlayerRanking? rankingForOpenPlayer(RankingBoard board, OpenPlayer p) {
  if (p.isMe) return board.me;
  return board.byId(p.id) ?? board.all.where((r) => r.input.name.toLowerCase() == p.name.toLowerCase()).firstOrNull;
}
