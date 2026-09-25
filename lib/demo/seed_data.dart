import 'dart:ui' show Color;

import '../core/models/models.dart';
import '../core/utils/formatters.dart';

/// Seed data ported from the approved prototype (criceco-app.js).
///
/// Seed rules:
/// * Past history (scorecards, match log, completed match) keeps the
///   prototype's absolute dates.
/// * Anything "upcoming" (next match, confirmed booking, tournament deadlines)
///   is anchored to [now] with the prototype's relative spacing, so countdowns
///   and "days left" remain meaningful whenever the demo runs.
/// * Approved seed fixes: IU no longer appears twice in the T10 Bash; the Find
///   Match "Rawalpindi Riders" row is the Rawalpindi Rams club it links to.
class SeedData {
  SeedData(DateTime now)
      : _now = now,
        _today = CeFormat.dateOnly(now) {
    _build();
  }

  final DateTime _now;
  final DateTime _today;
  DateTime _day(int offset, [int hour = 0, int minute = 0]) =>
      DateTime(_today.year, _today.month, _today.day + offset, hour, minute);

  static const ownClubId = 'club_sc';
  static const ownAccountId = 'acc_aman';
  static const demoJoinCode = 'KRC001';
  static const demoJoinClubName = 'Karachi Ravians CC';

  late final UserAccount account;
  late final Club ownClub;
  late final Map<String, ClubSummary> clubs;
  late final List<ClubMember> members;
  late final List<JoinRequest> joinRequests;
  late final List<SquadPlayer> squad;
  late final List<Team> teams;
  late final List<Ground> grounds;
  late final List<ClubMatch> clubMatches;
  late final List<ReservationHold> holds;
  late final List<PlayerMatch> playerMatches;
  late final Map<String, Scorecard> scorecards;
  late final PerformanceSummary performance;
  late final List<Challenge> challenges;
  late final List<String> challengeableClubIds;
  late final List<MatchSeekerListing> matchSeekers;
  late final List<PlayerHuntPost> huntPosts;
  late final List<OpenPlayer> openPlayers;
  late final List<Tournament> tournaments;
  late final List<NotificationItem> notifications;

  static const walletStartingBalance = 5000;

  void _build() {
    account = const UserAccount(
      id: ownAccountId,
      fullName: 'Aman Ali',
      contactMethod: ContactMethod.phone,
      phone: '0312 9020000',
      city: 'Islamabad',
      onboardingComplete: true,
    );

    ownClub = const Club(
      id: ownClubId,
      name: 'Shalimar Cricket Club',
      shortName: 'Shalimar CC',
      city: 'Islamabad',
      type: ClubType.professional,
      code: '35HLWZ',
      establishedYear: 2023,
      ownerName: 'Aman Ali',
    );

    ClubSummary c(
      String abbr,
      String name,
      String city,
      String level,
      int est,
      int squadSize,
      String formats,
      String ground,
      ClubCaptain captain,
      List<KeyPlayer> players,
      String form,
      int winRate,
      int wins,
      int losses,
      int played,
      String about,
      int color,
    ) =>
        ClubSummary(
          id: 'club_${abbr.toLowerCase()}',
          abbr: abbr,
          name: name,
          city: city,
          level: level,
          meta: '$city · $level',
          established: est,
          squadSize: squadSize,
          formats: formats,
          homeGround: ground,
          captain: captain,
          keyPlayers: players,
          recentForm: [for (final ch in form.split('')) ch == 'w' ? MatchResult.won : MatchResult.lost],
          winRate: winRate,
          wins: wins,
          losses: losses,
          played: played,
          about: about,
          color: Color(color),
        );
    KeyPlayer kp(String n, String r, [bool cap = false]) => KeyPlayer(name: n, position: r, isCaptain: cap);

    final all = [
      c('KK', 'Karachi Kings CC', 'Karachi', 'District', 2015, 18, 'T20 / ODI', 'National Stadium',
          const ClubCaptain(name: 'Bilal Asif', phone: '+92 300 1112233'), [
        kp('Bilal Asif', 'Captain / Batsman', true), kp('Hamza Rehman', 'Opening Bat'),
        kp('Omer Sheikh', 'Fast Bowler'), kp('Tariq Jamil', 'All-Rounder'), kp('Asad Naqvi', 'Wicketkeeper'),
      ], 'wwwlw', 75, 18, 6, 24,
          "One of Karachi's most competitive district-level clubs. Known for aggressive batting and disciplined fielding.",
          0xFFB7791F),
      c('IU', 'Islamabad United XI', 'Islamabad', 'Club', 2018, 15, 'T20 / T10', 'Pindi Cricket Ground',
          const ClubCaptain(name: 'Zubair Khan', phone: '+92 333 4455667'), [
        kp('Zubair Khan', 'Captain / All-Rounder', true), kp('Fahad Mir', 'Opening Bat'),
        kp('Shayan Malik', 'Spin Bowler'), kp('Rizwan Butt', 'Middle Order'), kp('Kamran Iqbal', 'Wicketkeeper'),
      ], 'wlwww', 56, 10, 8, 18,
          'A well-rounded club side from Islamabad with a strong bowling attack and sharp fielding unit.',
          0xFF2563A8),
      c('RR', 'Rawalpindi Rams', 'Rawalpindi', 'Club', 2012, 20, 'T20 / T10', 'KRL Ground',
          const ClubCaptain(name: 'Junaid Nasir', phone: '+92 321 6677889'), [
        kp('Junaid Nasir', 'Captain / Batsman', true), kp('Waleed Farooq', 'Fast Bowler'),
        kp('Shoaib Anwar', 'All-Rounder'), kp('Danish Kaneria Jr', 'Leg Spinner'), kp('Imran Sethi', 'Wicketkeeper'),
      ], 'lwwlw', 74, 14, 5, 19,
          'A veteran club side known for disciplined bowling and calm run-chases under pressure.',
          0xFFC43B2F),
      c('FW', 'Faisalabad Wolves', 'Faisalabad', 'Casual', 2021, 14, 'Any', 'Iqbal Stadium',
          const ClubCaptain(name: 'Adeel Chaudhry', phone: '+92 300 9988776'), [
        kp('Adeel Chaudhry', 'Captain / Batsman', true), kp('Naveed Ahsan', 'Bowler'),
        kp('Salman Riaz', 'All-Rounder'), kp('Bilal Ashraf', 'Middle Order'), kp('Haris Nadeem', 'Wicketkeeper'),
      ], 'llwlw', 44, 7, 9, 16,
          'A young casual side from Faisalabad, building momentum with an aggressive top order.',
          0xFFC43B2F),
      c('DB', 'DHA Bulls CC', 'Lahore', 'Club', 2016, 17, 'T20', 'DHA Phase 6 Ground',
          const ClubCaptain(name: 'Faisal Qureshi', phone: '+92 345 1122334'), [
        kp('Faisal Qureshi', 'Captain / Batsman', true), kp('Ahsan Raza', 'Fast Bowler'),
        kp('Hassan Iqbal', 'All-Rounder'), kp('Kamran Shahzad', 'Opening Bat'), kp('Zeeshan Malik', 'Wicketkeeper'),
      ], 'wwlwl', 38, 5, 8, 13,
          "DHA's flagship club side, known for a deep batting order and home-ground advantage.",
          0xFFC43B2F),
      c('GC', 'GOR Challengers', 'Lahore', 'Club', 2014, 16, 'ODI', 'Gaddafi Stadium',
          const ClubCaptain(name: 'Umer Farooq', phone: '+92 302 5566778'), [
        kp('Umer Farooq', 'Captain / Batsman', true), kp('Sarmad Iqbal', 'Spin Bowler'),
        kp('Nauman Habib', 'All-Rounder'), kp('Yasir Shah Jr', 'Middle Order'), kp('Talha Riaz', 'Wicketkeeper'),
      ], 'wwwlw', 43, 6, 8, 14,
          'A GOR-based club renowned for sharp fielding and calculated, patient batting.',
          0xFFB7791F),
      c('GT', 'Gulberg Tigers', 'Lahore', 'Club', 2013, 19, 'T20', 'Gulberg Cricket Ground',
          const ClubCaptain(name: 'Danyal Aziz', phone: '+92 311 2233445'), [
        kp('Danyal Aziz', 'Captain / Batsman', true), kp('Rehan Butt', 'Fast Bowler'),
        kp('Owais Tariq', 'All-Rounder'), kp('Sami Ullah', 'Opening Bat'), kp('Arsalan Khan', 'Wicketkeeper'),
      ], 'wwwwl', 80, 16, 4, 20,
          'A dominant Gulberg-based club side with one of the best win records in the city league.',
          0xFF158447),
    ];
    clubs = {for (final club in all) club.id: club};

    members = const [ClubMember(id: 'mem_owner', name: 'ali', phone: '03129020000', role: MemberRole.owner)];

    joinRequests = const [
      JoinRequest(
          id: 'jr_1', name: 'Bilal Ahmed', age: 24, city: 'Rawalpindi',
          battingStyle: BattingStyle.rightHanded, bowlingStyle: BowlingStyle.rightArmMedium,
          role: PlayerRole.batsman, phone: '0301-2345678', appliedLabel: 'Applied 2 days ago',
          performance: JoinRequestPerformance(matches: 18, runs: 642, average: '38.9', wickets: 2)),
      JoinRequest(
          id: 'jr_2', name: 'Hamza Sheikh', age: 21, city: 'Islamabad',
          battingStyle: BattingStyle.leftHanded, bowlingStyle: BowlingStyle.leftArmFast,
          role: PlayerRole.bowler, phone: '0333-9876543', appliedLabel: 'Applied 1 day ago',
          performance: JoinRequestPerformance(matches: 12, runs: 64, average: '9.1', wickets: 23)),
      JoinRequest(
          id: 'jr_3', name: 'Usman Tariq', age: 26, city: 'Rawalpindi',
          battingStyle: BattingStyle.rightHanded, bowlingStyle: BowlingStyle.rightArmOffSpin,
          role: PlayerRole.allRounder, phone: '0345-1122334', appliedLabel: 'Applied today'),
    ];

    const pool = [
      ('Ali Raza', 'Captain / Batsman', PlayerAvailability.available),
      ('Bilal Khan', 'Opening Bat', PlayerAvailability.available),
      ('Usman Tariq', 'Bowler', PlayerAvailability.injured),
      ('Hamza Sheikh', 'All-Rounder', PlayerAvailability.available),
      ('Ahmed Raza', 'Middle Order', PlayerAvailability.available),
      ('Saad Ali', 'Wicketkeeper', PlayerAvailability.available),
      ('Fahad Mir', 'Batsman', PlayerAvailability.unavailable),
      ('Shayan Malik', 'Spin Bowler', PlayerAvailability.available),
      ('Rizwan Butt', 'Middle Order', PlayerAvailability.limited),
      ('Kamran Iqbal', 'Fast Bowler', PlayerAvailability.available),
      ('Zubair Sultan', 'All-Rounder', PlayerAvailability.available),
      ('Danish Aslam', 'Spin Bowler', PlayerAvailability.injured),
      ('Imran Farhan', 'Opening Bat', PlayerAvailability.available),
      ('Yasir Mahmood', 'Leg Spinner', PlayerAvailability.available),
      ('Sarfaraz Iqbal', 'Wicketkeeper', PlayerAvailability.other),
      ('Waqas Ahmed', 'Fast Bowler', PlayerAvailability.available),
      ('Junaid Khalid', 'Batsman', PlayerAvailability.available),
      ('Adnan Rasheed', 'All-Rounder', PlayerAvailability.unavailable),
      ('Faizan Riaz', 'Middle Order', PlayerAvailability.available),
      ('Moiz Yousuf', 'Fast Bowler', PlayerAvailability.available),
    ];
    squad = [
      for (var i = 0; i < pool.length; i++)
        SquadPlayer(id: 'sp_${i + 1}', name: pool[i].$1, position: pool[i].$2, availability: pool[i].$3),
    ];

    // Prototype seeds have no format; T20 is the club's primary format.
    teams = [
      Team(id: 'team_cs', clubId: ownClubId, name: 'BS CS XI', format: MatchFormat.t20, createdAt: _day(-30)),
      Team(id: 'team_it', clubId: ownClubId, name: 'BS IT XI', format: MatchFormat.t20, createdAt: _day(-30)),
    ];

    grounds = const [
      Ground(
          id: 'g_national', name: 'National Stadium', city: 'Karachi', pricePerHour: 8000, rating: '4.8', reviews: 124,
          address: 'Block M, National Stadium Road, Karachi, Sindh',
          specs: GroundSpecs(boundary: '68m', radius: '46m', nets: '4'),
          amenities: ['Floodlights', 'Parking', 'Change Rooms', 'Scoreboard', 'Tuck Shop', 'Washrooms', 'Cafeteria']),
      Ground(
          id: 'g_modeltown', name: 'Model Town Ground', city: 'Lahore', pricePerHour: 5500, rating: '4.5', reviews: 98,
          address: 'Block M, Model Town, Lahore, Punjab',
          specs: GroundSpecs(boundary: '65m', radius: '44m', nets: '3'),
          amenities: ['Floodlights', 'Parking', 'Change Rooms', 'Washrooms']),
      Ground(
          id: 'g_pindi', name: 'Pindi Cricket Ground', city: 'Islamabad', pricePerHour: 6200, rating: '4.6', reviews: 112,
          address: 'Sector G-9, Islamabad, ICT',
          specs: GroundSpecs(boundary: '70m', radius: '48m', nets: '5'),
          amenities: ['Floodlights', 'Scoreboard', 'Change Rooms', 'Cafeteria', 'Parking']),
      Ground(
          id: 'g_krl', name: 'KRL Ground', city: 'Rawalpindi', pricePerHour: 4800, rating: '4.3', reviews: 76,
          address: '6th Road, Rawalpindi, Punjab',
          specs: GroundSpecs(boundary: '62m', radius: '42m', nets: '3'),
          amenities: ['Parking', 'Washrooms', 'Tuck Shop']),
    ];

    final confirmedDate = _day(20, 10);
    clubMatches = [
      ClubMatch(
          id: 'm_1', opponentClubId: 'club_gt', status: MatchStatus.completed, format: MatchFormat.t20,
          city: 'Lahore', groundId: 'g_modeltown', startsAt: DateTime(2026, 7, 20, 16),
          lineup: const Lineup(name: 'BS CS XI', sourceTeamId: 'team_cs', members: []),
          resultText: 'Won by 18 runs'),
      ClubMatch(
          id: 'm_2', opponentClubId: 'club_kk', status: MatchStatus.confirmed, format: MatchFormat.t20,
          city: 'Karachi', groundId: 'g_national', startsAt: confirmedDate,
          lineup: const Lineup(name: 'BS CS XI', sourceTeamId: 'team_cs', members: [])),
      const ClubMatch(id: 'm_3', opponentClubId: 'club_iu', status: MatchStatus.pending, format: MatchFormat.t20, city: 'Islamabad'),
    ];

    holds = [
      ReservationHold(
          id: 'hold_m2', matchId: 'm_2', groundId: 'g_national',
          slotStart: confirmedDate, slotEnd: confirmedDate.add(const Duration(hours: 2)),
          reservedAt: _day(-2), expiresAt: _day(-2), status: HoldStatus.confirmed),
      // Seeded "Reserved by another club" slot, so the Reserved chip is visible.
      ReservationHold(
          id: 'hold_other', matchId: 'm_other_club', groundId: 'g_national',
          slotStart: _day(20, 14), slotEnd: _day(20, 16),
          reservedAt: _day(0), expiresAt: _day(365), status: HoldStatus.active),
    ];

    playerMatches = [
      PlayerMatch(
          id: 'pm_1', status: PlayerMatchStatus.upcoming, ownTeamName: 'Shalimar CC', ownTeamAbbr: 'SC',
          opponentName: 'Falcons CC', opponentAbbr: 'FC', startsAt: _day(1, 8), format: MatchFormat.t20,
          ground: 'National Stadium, Islamabad', playingTeamName: 'BS CS XI', matchType: 'League Match'),
      PlayerMatch(
          id: 'pm_2', status: PlayerMatchStatus.past, ownTeamName: 'Shalimar CC', ownTeamAbbr: 'SC',
          opponentName: 'Titans CC', opponentAbbr: 'TC', startsAt: DateTime(2025, 6, 15, 14), format: MatchFormat.t20,
          ground: 'Pindi Cricket Ground', playingTeamName: 'BS CS XI',
          result: MatchResult.won, resultText: 'Won by 24 runs', scorecardId: 'sc_titans'),
      PlayerMatch(
          id: 'pm_3', status: PlayerMatchStatus.past, ownTeamName: 'Shalimar CC', ownTeamAbbr: 'SC',
          opponentName: 'Warriors CC', opponentAbbr: 'WC', startsAt: DateTime(2025, 6, 1, 10), format: MatchFormat.odi,
          ground: 'Bagh-e-Jinnah Ground', playingTeamName: 'BS CS XI',
          result: MatchResult.lost, resultText: 'Lost by 6 wickets', scorecardId: 'sc_warriors'),
      PlayerMatch(
          id: 'pm_4', status: PlayerMatchStatus.cancelled, ownTeamName: 'Shalimar CC', ownTeamAbbr: 'SC',
          opponentName: 'Strikers CC', opponentAbbr: 'ST', startsAt: DateTime(2025, 6, 10, 16), format: MatchFormat.t10,
          ground: 'Model Town Ground', playingTeamName: 'BS CS XI', cancelReason: 'Rain'),
    ];

    BattingEntry b(String n, int r, int balls, int f, int s, String out) =>
        BattingEntry(name: n, runs: r, balls: balls, fours: f, sixes: s, dismissal: out);
    BowlingEntry w(String n, num o, int m, int r, int wk) =>
        BowlingEntry(name: n, overs: o, maidens: m, runs: r, wickets: wk);
    scorecards = {
      'sc_titans': Scorecard(
        id: 'sc_titans', matchId: 'pm_2', result: 'Shalimar CC won by 24 runs', playerOfMatch: 'Ali Raza (Shalimar CC)',
        innings: [
          Innings(team: 'Shalimar CC', abbr: 'SC', total: 186, wickets: 6, overs: '20.0', batting: [
            b('Ali Raza', 64, 41, 6, 2, 'c Ahmed b Malik'), b('Bilal Khan', 38, 29, 4, 1, 'b Ahmed'),
            b('Hamza Sheikh', 27, 18, 2, 2, 'not out'), b('Ahmed Raza', 19, 15, 1, 0, 'c Iqbal b Malik'),
            b('Saad Ali', 14, 10, 1, 0, 'run out'),
          ], bowling: [w('F. Malik', 4, 0, 32, 2), w('K. Ahmed', 4, 0, 41, 1), w('R. Iqbal', 4, 1, 28, 0)]),
          Innings(team: 'Titans CC', abbr: 'TC', total: 162, wickets: 8, overs: '20.0', batting: [
            b('K. Ahmed', 52, 38, 5, 1, 'c Sheikh b Tariq'), b('F. Malik', 31, 24, 3, 0, 'b Raza'),
            b('R. Iqbal', 22, 19, 2, 0, 'not out'),
          ], bowling: [w('U. Tariq', 4, 0, 29, 3), w('A. Raza', 4, 0, 33, 2), w('H. Sheikh', 4, 1, 22, 1)]),
        ],
      ),
      'sc_warriors': Scorecard(
        id: 'sc_warriors', matchId: 'pm_3', result: 'Warriors CC won by 6 wickets',
        playerOfMatch: 'Zeeshan Warraich (Warriors CC)',
        innings: [
          Innings(team: 'Shalimar CC', abbr: 'SC', total: 198, wickets: 9, overs: '50.0', batting: [
            b('Ali Raza', 45, 56, 4, 0, 'lbw b Warraich'), b('Bilal Khan', 38, 49, 3, 0, 'c Sarwar b Nadeem'),
            b('Hamza Sheikh', 29, 31, 2, 1, 'c & b Warraich'),
          ], bowling: [w('Z. Warraich', 10, 1, 38, 3), w('S. Nadeem', 10, 0, 44, 2)]),
          Innings(team: 'Warriors CC', abbr: 'WC', total: 199, wickets: 4, overs: '46.2', batting: [
            b('S. Nadeem', 72, 81, 6, 1, 'not out'), b('Z. Warraich', 54, 60, 4, 2, 'c Ali b Tariq'),
          ], bowling: [w('U. Tariq', 10, 0, 41, 2), w('A. Raza', 9, 1, 35, 1)]),
        ],
      ),
    };

    StatTile t(String l, String v) => StatTile(label: l, value: v);
    FormEntry fe(String o, MatchResult r, int runs, int wk) => FormEntry(opponentAbbr: o, result: r, runs: runs, wickets: wk);
    MatchLogEntry ml(String a, String n, DateTime d, MatchResult r, int runs, int balls, int wk, String ov) =>
        MatchLogEntry(opponentAbbr: a, opponentName: n, date: d, result: r, runs: runs, balls: balls, wickets: wk, overs: ov);
    const W = MatchResult.won, L = MatchResult.lost;
    performance = PerformanceSummary(
      matches: 8, runs: 256, wickets: 6, rating: '8.2',
      snapshot: [t('Runs', '256'), t('Average', '32.00'), t('Strike Rate', '128.40'), t('Wickets', '6'), t('Best Score', '78*')],
      batting: [
        t('Matches Played', '8'), t('Runs Scored', '256'), t('Batting Average', '32.00'), t('Strike Rate', '128.40'),
        t('Best Score', '78*'), t('Half Centuries', '2'), t('Centuries', '0'), t('Not Outs', '3'), t('Boundaries (4s/6s)', '34 / 8'),
      ],
      bowling: [
        t('Matches Played', '8'), t('Wickets Taken', '6'), t('Bowling Average', '22.16'), t('Economy Rate', '6.80'),
        t('Best Bowling', '3/24'), t('Overs Bowled', '28.4'), t('Maiden Overs', '2'),
      ],
      fielding: [
        t('Matches Played', '8'), t('Catches Taken', '5'), t('Run Outs', '1'), t('Stumpings', '0'), t('Direct Hits', '2'),
      ],
      recentForm: [fe('FC', W, 45, 1), fe('SC', W, 12, 2), fe('IU', L, 78, 0), fe('KK', W, 8, 1), fe('RR', L, 23, 0)],
      // The season's 8 matches — the log IS the season, so it adds up to the
      // summary above (8 matches, 256 runs, 6 wickets). The prototype listed
      // 12 entries (390 runs, 11 wickets) against the same summary, which made
      // My Performance say 8 while Match History said 12. The first five are
      // the Recent Form entries.
      matchLog: [
        ml('FC', 'Falcons CC', DateTime(2026, 7, 28), W, 45, 32, 1, '3.0'),
        ml('SC', 'Shalimar CC', DateTime(2026, 7, 20), W, 12, 18, 2, '4.0'),
        ml('IU', 'Islamabad United', DateTime(2026, 7, 12), L, 78, 54, 0, '2.0'),
        ml('KK', 'Karachi Kings CC', DateTime(2026, 7, 5), W, 8, 9, 1, '3.4'),
        ml('RR', 'Rawalpindi Rams', DateTime(2026, 6, 28), L, 23, 19, 0, '2.2'),
        ml('FW', 'Faisalabad Wolves', DateTime(2026, 6, 21), W, 34, 28, 2, '4.0'),
        ml('DB', 'Defence Blasters', DateTime(2026, 6, 14), W, 51, 37, 0, '0.0'),
        ml('GC', 'Gymkhana CC', DateTime(2026, 6, 7), L, 5, 11, 0, '3.0'),
      ],
    );

    challengeableClubIds = const ['club_kk', 'club_iu', 'club_rr', 'club_fw'];
    challenges = [
      Challenge(
          id: 'ch_db', opponentClubId: 'club_db', direction: ChallengeDirection.received, status: ChallengeStatus.pending,
          createdAt: _day(-1), format: MatchFormat.t20, proposedAt: _day(4), groundName: 'DHA Phase 6 Ground', isNew: true),
      Challenge(
          id: 'ch_gc', opponentClubId: 'club_gc', direction: ChallengeDirection.received, status: ChallengeStatus.pending,
          createdAt: _day(-1), format: MatchFormat.odi, proposedAt: _day(6), groundName: 'Gaddafi Stadium', isNew: true),
      Challenge(
          id: 'ch_gt', opponentClubId: 'club_gt', direction: ChallengeDirection.sent, status: ChallengeStatus.accepted,
          createdAt: _day(-10), format: MatchFormat.t20, proposedAt: _day(-3), matchId: 'm_1'),
    ];
    matchSeekers = [
      MatchSeekerListing(clubId: 'club_kk', rating: '4.7', format: MatchFormat.t20, startsAt: _day(41, 15), venue: 'Model Town Ground'),
      MatchSeekerListing(clubId: 'club_rr', rating: '4.2', format: MatchFormat.t20, startsAt: _day(42, 10), venue: 'Pindi Sports Complex'),
    ];

    huntPosts = [
      PlayerHuntPost(
          id: 'hunt_1001', clubId: ownClubId, clubName: 'Shalimar CC', clubAbbr: 'SC', role: HuntRole.batsman,
          format: MatchFormat.t20, playersNeeded: 2, location: 'Islamabad', date: _day(24), time: '14:00',
          budget: HuntBudget.from2000to5000, notes: 'Need a solid opener for a weekend friendly.'),
      PlayerHuntPost(
          id: 'hunt_1002', clubId: 'club_kk', clubName: 'Karachi Kings CC', clubAbbr: 'KK', role: HuntRole.bowler,
          format: MatchFormat.odi, playersNeeded: 1, location: 'Karachi', date: _day(28), time: '09:00',
          budget: HuntBudget.over5000, notes: 'Looking for an experienced new-ball bowler.'),
      const PlayerHuntPost(
          id: 'hunt_1003', clubId: 'club_iu', clubName: 'Islamabad United XI', clubAbbr: 'IU', role: HuntRole.allRounder,
          format: MatchFormat.t10, playersNeeded: 1),
    ];
    openPlayers = const [
      OpenPlayer(id: 'op_1', name: 'Ali Hassan', role: HuntRole.batsman, availabilityLabel: 'Available Now', city: 'Islamabad'),
      OpenPlayer(id: 'op_2', name: 'Usman Tariq', role: HuntRole.bowler, availabilityLabel: 'Available Weekend', city: 'Rawalpindi'),
      OpenPlayer(id: 'op_3', name: 'Ahmed Raza', role: HuntRole.allRounder, availabilityLabel: 'Available Now', city: 'Islamabad'),
      OpenPlayer(id: 'op_4', name: 'Hamid Shah', role: HuntRole.batsman, availabilityLabel: 'Available Now', city: 'Karachi'),
      OpenPlayer(id: 'op_5', name: 'Muhammad Kaif', role: HuntRole.wicketKeeper, availabilityLabel: 'Available Weekend', city: 'Lahore'),
      OpenPlayer(id: 'op_6', name: 'Saad Ali', role: HuntRole.allRounder, availabilityLabel: 'Available Now', city: 'Rawalpindi'),
    ];

    TournamentEntrant e(String clubId) => TournamentEntrant(id: clubId, clubId: clubId, displayName: clubs[clubId]!.name);
    tournaments = [
      Tournament(
          id: 't_1', name: 'Karachi Premier Cup', organizerClubId: 'club_kk', city: 'Karachi', ground: 'National Stadium',
          format: MatchFormat.t20, type: TournamentType.knockout, prize: 250000, entryFee: 5000, maxTeams: 8,
          registrationDeadline: _day(10), startDate: _day(18), endDate: _day(26),
          status: TournamentStatus.registrationOpen, joined: [e('club_iu'), e('club_rr')],
          rules: const [
            'Each team must submit a squad of 15–18 players before their first match.',
            'Matches are played under standard T20 rules — 20 overs per side.',
            'A minimum of 8 players is required to start a match.',
            'Umpire decisions are final; disputes are handled by the tournament committee.',
          ]),
      Tournament(
          id: 't_2', name: 'Islamabad Corporate League', organizerClubId: 'club_iu', city: 'Islamabad',
          ground: 'Pindi Cricket Ground', format: MatchFormat.odi, type: TournamentType.league, prize: 180000,
          entryFee: 4000, maxTeams: 6, registrationDeadline: _day(13), startDate: _day(23), endDate: _day(35),
          status: TournamentStatus.registrationOpen, joined: [e('club_kk'), e('club_rr'), e('club_fw')],
          rules: const [
            'Round-robin league — every team plays every other team once.',
            'Top 2 teams by points qualify for the final.',
            'Matches are played under standard ODI rules — 50 overs per side.',
            'Points system: 2 for a win, 1 for a no-result, 0 for a loss.',
          ]),
      Tournament(
          id: 't_3', name: 'Rawalpindi Rams T10 Bash', organizerClubId: 'club_rr', city: 'Rawalpindi', ground: 'KRL Ground',
          format: MatchFormat.custom, customOvers: 10, type: TournamentType.knockout, prize: 100000, entryFee: 2500,
          maxTeams: 8, registrationDeadline: _day(6), startDate: _day(14), endDate: _day(16),
          status: TournamentStatus.registrationOpen,
          joined: [e('club_kk'), e('club_iu'), e('club_fw'), e('club_db'), e('club_gc'), e('club_gt')],
          rules: const [
            'Fast-paced 10-overs-per-side knockout format.',
            'Bracket: Quarterfinal → Semifinal → Final.',
            'Each team must have a minimum of 8 players present at toss time.',
          ]),
      Tournament(
          id: 't_4', name: 'Faisalabad Wolves Cup', organizerClubId: 'club_fw', city: 'Faisalabad', ground: 'Iqbal Stadium',
          format: MatchFormat.t20, type: TournamentType.league, prize: 150000, entryFee: 3000, maxTeams: 6,
          registrationDeadline: _day(-1), startDate: _day(8), endDate: _day(18),
          status: TournamentStatus.registrationFull,
          joined: [e('club_kk'), e('club_iu'), e('club_rr'), e('club_db'), e('club_gc'), e('club_gt')],
          rules: const [
            'Round-robin league followed by a final between the top 2 teams.',
            'Matches are played under standard T20 rules — 20 overs per side.',
          ]),
    ];

    // Every row points at a real seeded entity (typed target). Approved seed
    // fixes: the received challenge and the confirmed booking rows now name
    // the entities they open (the prototype said "Karachi Kings CC" /
    // "Pindi Cricket Ground", which match nothing in the seed).
    DateTime ago(Duration d) => _now.subtract(d);
    final nextMatch = playerMatches.firstWhere((m) => m.status == PlayerMatchStatus.upcoming);
    final received = challenges.firstWhere((c) => c.direction == ChallengeDirection.received);
    final confirmed = clubMatches.firstWhere((m) => m.status == MatchStatus.confirmed);
    final confirmedGround = grounds.firstWhere((g) => g.id == confirmed.groundId);
    notifications = [
      NotificationItem(id: 'n_p1', role: UserRole.player, icon: 'swords', title: 'Match request from ${nextMatch.ownTeamName}',
          subtitle: '${CeFormat.weekdayTime(nextMatch.startsAt)} · ${nextMatch.ground}', createdAt: ago(const Duration(hours: 2)),
          tone: NotificationTone.green, target: PlayerMatchTarget(nextMatch.id)),
      NotificationItem(id: 'n_p2', role: UserRole.player, icon: 'check-circle', title: 'Club approved your join request',
          subtitle: 'You are now part of Club $demoJoinCode', createdAt: ago(const Duration(days: 1)),
          tone: NotificationTone.green, target: const PlayerProfileTarget()),
      NotificationItem(id: 'n_p3', role: UserRole.player, icon: 'calendar', title: 'Availability needed for next match',
          subtitle: 'Confirm before Friday', createdAt: ago(const Duration(days: 2)),
          tone: NotificationTone.amber, target: const AvailabilityTarget()),
      // P16: no Player tournament screen exists → non-navigating.
      NotificationItem(id: 'n_p4', role: UserRole.player, icon: 'trophy', title: 'Tournament update: Spring Cup',
          subtitle: 'Fixtures published', createdAt: ago(const Duration(days: 4)), tone: NotificationTone.blue),
      NotificationItem(id: 'n_c1', role: UserRole.clubOwner, icon: 'user', title: 'New join request from Bilal Ahmed',
          subtitle: 'Batsman · Rawalpindi', createdAt: ago(const Duration(minutes: 30)),
          tone: NotificationTone.amber, target: const JoinRequestTarget('jr_1')),
      NotificationItem(id: 'n_c2', role: UserRole.clubOwner, icon: 'swords',
          title: 'Challenge received from ${clubs[received.opponentClubId]!.name}',
          subtitle: '${received.format?.label ?? 'Match'} · ${CeFormat.dayMonth(received.proposedAt!)}',
          createdAt: ago(const Duration(hours: 3)), tone: NotificationTone.green, target: const MyChallengesTarget()),
      NotificationItem(id: 'n_c3', role: UserRole.clubOwner, icon: 'credit-card', title: 'Opponent completed their payment share',
          subtitle: '${confirmedGround.name} booking confirmed', createdAt: ago(const Duration(days: 1)),
          tone: NotificationTone.green, target: const ClubMatchesTarget(MatchTab.scheduled)),
      NotificationItem(id: 'n_c4', role: UserRole.clubOwner, icon: 'trophy', title: 'Tournament registration approved',
          subtitle: 'Spring Cup · 8 teams', createdAt: ago(const Duration(days: 3)),
          tone: NotificationTone.blue, target: const MyRegistrationsTarget(RegistrationStatus.approved)),
    ];
  }
}
