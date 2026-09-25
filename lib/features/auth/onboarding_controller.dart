import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// In-progress onboarding answers: User Profile Setup (common account data)
/// and the Player details revealed on Role Selection. Lives in feature state
/// so answers survive Back and a collapsed/re-expanded Player card.
class OnboardingDraft {
  const OnboardingDraft({
    this.fullName = '',
    this.dateOfBirth,
    this.phone = '',
    this.hasPhoto = false,
    this.role,
    this.battingStyle,
    this.bowlingStyle,
    this.isWicketkeeper = false,
  });

  // ---- Common user profile (belongs to the account) ----
  final String fullName;
  final DateTime? dateOfBirth;
  final String phone;
  final bool hasPhoto;

  // ---- Player role profile ----
  final PlayerRole? role;
  final BattingStyle? battingStyle;
  final BowlingStyle? bowlingStyle;

  /// Optional extra for any playing role — never the primary role.
  final bool isWicketkeeper;

  OnboardingDraft copyWith({
    String? fullName,
    DateTime? dateOfBirth,
    String? phone,
    bool? hasPhoto,
    PlayerRole? role,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    bool? isWicketkeeper,
  }) =>
      OnboardingDraft(
        fullName: fullName ?? this.fullName,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        phone: phone ?? this.phone,
        hasPhoto: hasPhoto ?? this.hasPhoto,
        role: role ?? this.role,
        battingStyle: battingStyle ?? this.battingStyle,
        bowlingStyle: bowlingStyle ?? this.bowlingStyle,
        isWicketkeeper: isWicketkeeper ?? this.isWicketkeeper,
      );

  PlayerProfile get playerProfile =>
      PlayerProfile(role: role, battingStyle: battingStyle, bowlingStyle: bowlingStyle, isWicketkeeper: isWicketkeeper);
}

class OnboardingController extends Notifier<OnboardingDraft> {
  @override
  OnboardingDraft build() {
    // Seeded from the account (saved data is never reset); rebuilt if a
    // different account signs in.
    final signedIn = ref.watch(sessionProvider.select((s) => s.account?.id)) != null;
    final account = signedIn ? ref.read(sessionProvider).account : null;
    if (account == null) return const OnboardingDraft();
    final p = account.playerProfile;
    return OnboardingDraft(
      fullName: account.fullName,
      dateOfBirth: account.dateOfBirth,
      phone: account.phone ?? '',
      hasPhoto: account.hasPhoto,
      role: p.role,
      battingStyle: p.battingStyle,
      bowlingStyle: p.bowlingStyle,
      isWicketkeeper: p.isWicketkeeper,
    );
  }

  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setDateOfBirth(DateTime v) => state = state.copyWith(dateOfBirth: v);
  void setPhone(String v) => state = state.copyWith(phone: v);
  void togglePhoto() => state = state.copyWith(hasPhoto: !state.hasPhoto);
  void setRole(PlayerRole v) => state = state.copyWith(role: v);
  void setBattingStyle(BattingStyle v) => state = state.copyWith(battingStyle: v);
  void setBowlingStyle(BowlingStyle v) => state = state.copyWith(bowlingStyle: v);
  void setWicketkeeper(bool v) => state = state.copyWith(isWicketkeeper: v);

  /// User Profile Setup → Continue. [phone] is the normalized display form.
  Future<void> saveProfile({required String phone}) => ref.read(sessionProvider.notifier).completeProfile(
        fullName: state.fullName.trim(),
        phone: phone,
        dateOfBirth: state.dateOfBirth!,
        hasPhoto: state.hasPhoto,
      );

  /// Role Selection → Player → Continue: saves the Player profile and makes
  /// Player the active role (the caller then enters the Player Dashboard).
  Future<void> completePlayerSetup() async {
    await ref.read(sessionProvider.notifier).savePlayerProfile(state.playerProfile);
    ref.read(roleControllerProvider.notifier).becomePlayer();
  }
}

final onboardingProvider = NotifierProvider<OnboardingController, OnboardingDraft>(OnboardingController.new);
