import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// In-progress onboarding answers (Complete Profile → Playing Style). Lives
/// in feature state so selections survive Back/forward between the steps.
class OnboardingDraft {
  const OnboardingDraft({
    this.fullName = '',
    this.dateOfBirth,
    this.phone = '',
    this.role,
    this.battingStyle,
    this.bowlingStyle,
    this.isWicketkeeper = false,
    this.hasPhoto = false,
  });

  final String fullName;
  final DateTime? dateOfBirth;
  final String phone;
  final PlayerRole? role;
  final BattingStyle? battingStyle;
  final BowlingStyle? bowlingStyle;
  final bool isWicketkeeper;
  final bool hasPhoto;

  OnboardingDraft copyWith({
    String? fullName,
    DateTime? dateOfBirth,
    String? phone,
    PlayerRole? role,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    bool? isWicketkeeper,
    bool? hasPhoto,
  }) =>
      OnboardingDraft(
        fullName: fullName ?? this.fullName,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        phone: phone ?? this.phone,
        role: role ?? this.role,
        battingStyle: battingStyle ?? this.battingStyle,
        bowlingStyle: bowlingStyle ?? this.bowlingStyle,
        isWicketkeeper: isWicketkeeper ?? this.isWicketkeeper,
        hasPhoto: hasPhoto ?? this.hasPhoto,
      );

  /// Prototype `roleDetails` block order per role: Batsman = batting,
  /// bowling, wicketkeeper · Bowler = bowling, batting · All-Rounder =
  /// batting, bowling.
  List<PlayingStyleBlock> get styleBlocks => switch (role) {
        PlayerRole.batsman => const [PlayingStyleBlock.batting, PlayingStyleBlock.bowling, PlayingStyleBlock.wicketkeeper],
        PlayerRole.bowler => const [PlayingStyleBlock.bowling, PlayingStyleBlock.batting],
        PlayerRole.allRounder => const [PlayingStyleBlock.batting, PlayingStyleBlock.bowling],
        null => const [],
      };
}

enum PlayingStyleBlock { batting, bowling, wicketkeeper }

class OnboardingController extends Notifier<OnboardingDraft> {
  @override
  OnboardingDraft build() {
    // Seeded from the account once; rebuilt if a different account signs in.
    final account = ref.watch(sessionProvider.select((s) => s.account?.id)) == null
        ? null
        : ref.read(sessionProvider).account;
    if (account == null) return const OnboardingDraft();
    final p = account.playerProfile;
    return OnboardingDraft(
      fullName: account.fullName,
      dateOfBirth: account.dateOfBirth,
      phone: account.phone ?? '',
      role: p.role,
      battingStyle: p.battingStyle,
      bowlingStyle: p.bowlingStyle,
      isWicketkeeper: p.isWicketkeeper,
      hasPhoto: p.hasPhoto,
    );
  }

  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setDateOfBirth(DateTime v) => state = state.copyWith(dateOfBirth: v);
  void setPhone(String v) => state = state.copyWith(phone: v);
  void setRole(PlayerRole v) => state = state.copyWith(role: v);
  void setBattingStyle(BattingStyle v) => state = state.copyWith(battingStyle: v);
  void setBowlingStyle(BowlingStyle v) => state = state.copyWith(bowlingStyle: v);
  void toggleWicketkeeper() => state = state.copyWith(isWicketkeeper: !state.isWicketkeeper);
  void togglePhoto() => state = state.copyWith(hasPhoto: !state.hasPhoto);

  /// Step 2 → saves personal details and role to the account.
  Future<void> savePlayerDetails() => ref.read(sessionProvider.notifier).updateAccount((a) => a.copyWith(
        fullName: state.fullName.trim(),
        dateOfBirth: state.dateOfBirth,
        phone: state.phone.trim(),
        playerProfile: a.playerProfile.copyWith(role: state.role, hasPhoto: state.hasPhoto),
      ));

  /// Step 3 → saves the playing style and completes onboarding.
  Future<void> savePlayingStyleAndFinish() async {
    final session = ref.read(sessionProvider.notifier);
    await session.updateAccount((a) => a.copyWith(
          playerProfile: PlayerProfile(
            role: state.role,
            battingStyle: state.battingStyle,
            bowlingStyle: state.bowlingStyle,
            // Only Batsmen are offered the wicketkeeper option (prototype).
            isWicketkeeper: state.role == PlayerRole.batsman && state.isWicketkeeper,
            hasPhoto: state.hasPhoto,
          ),
        ));
    await session.completeOnboarding();
  }

  /// "Skip" on either step: keep what was entered, finish onboarding.
  Future<void> skip() async {
    await savePlayerDetails();
    await ref.read(sessionProvider.notifier).completeOnboarding();
  }
}

final onboardingProvider = NotifierProvider<OnboardingController, OnboardingDraft>(OnboardingController.new);
