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
    this.photoPath,
    this.role,
    this.battingStyle,
    this.bowlingStyle,
    this.isWicketkeeper = false,
  });

  // ---- Common user profile (belongs to the account) ----
  final String fullName;
  final DateTime? dateOfBirth;
  final String phone;

  /// Local path of the picture chosen on Profile Setup (device picker).
  final String? photoPath;
  bool get hasPhoto => photoPath != null;

  // ---- Player role profile ----
  final PlayerRole? role;
  final BattingStyle? battingStyle;
  final BowlingStyle? bowlingStyle;

  /// Optional extra for Batsmen — never the primary role.
  final bool isWicketkeeper;

  OnboardingDraft copyWith({
    String? fullName,
    DateTime? dateOfBirth,
    String? phone,
    String? photoPath,
    bool clearPhoto = false,
    PlayerRole? role,
    BattingStyle? battingStyle,
    BowlingStyle? bowlingStyle,
    bool? isWicketkeeper,
    bool clearBatting = false,
    bool clearBowling = false,
  }) =>
      OnboardingDraft(
        fullName: fullName ?? this.fullName,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        phone: phone ?? this.phone,
        photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
        role: role ?? this.role,
        battingStyle: clearBatting ? null : (battingStyle ?? this.battingStyle),
        bowlingStyle: clearBowling ? null : (bowlingStyle ?? this.bowlingStyle),
        isWicketkeeper: isWicketkeeper ?? this.isWicketkeeper,
      );

  /// What the current role still needs (hidden fields never count).
  String? get missingPlayerDetail {
    final r = role;
    if (r == null) return 'role';
    if (r.bats && battingStyle == null) return 'batting';
    if (r.bowls && bowlingStyle == null) return 'bowling';
    return null;
  }

  /// Only the details that apply to the role are saved.
  PlayerProfile get playerProfile => PlayerProfile(
        role: role,
        battingStyle: role == null || role!.bats ? battingStyle : null,
        bowlingStyle: role == null || role!.bowls ? bowlingStyle : null,
        isWicketkeeper: (role?.canKeepWicket ?? false) && isWicketkeeper,
      );
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
      photoPath: account.photoPath,
      role: p.role,
      battingStyle: p.battingStyle,
      bowlingStyle: p.bowlingStyle,
      isWicketkeeper: p.isWicketkeeper,
    );
  }

  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setDateOfBirth(DateTime v) => state = state.copyWith(dateOfBirth: v);
  void setPhone(String v) => state = state.copyWith(phone: v);
  /// A picture from the device picker, or `null` to remove it.
  void setPhoto(String? path) => state = state.copyWith(photoPath: path, clearPhoto: path == null);
  /// A new playing role clears the answers that no longer apply
  /// (e.g. Batsman → Bowler drops Batting Style and Wicket Keeper).
  void setRole(PlayerRole v) => state = state.copyWith(
        role: v,
        clearBatting: !v.bats,
        clearBowling: !v.bowls,
        isWicketkeeper: v.canKeepWicket && state.isWicketkeeper,
      );
  void setBattingStyle(BattingStyle v) => state = state.copyWith(battingStyle: v);
  void setBowlingStyle(BowlingStyle v) => state = state.copyWith(bowlingStyle: v);
  void setWicketkeeper(bool v) => state = state.copyWith(isWicketkeeper: v && (state.role?.canKeepWicket ?? false));

  /// User Profile Setup → Continue. [phone] is the normalized display form.
  Future<void> saveProfile({required String phone}) => ref.read(sessionProvider.notifier).completeProfile(
        fullName: state.fullName.trim(),
        phone: phone,
        dateOfBirth: state.dateOfBirth!,
        photoPath: state.photoPath,
      );

  /// Role Selection → Player → Continue: saves the Player profile and makes
  /// Player the active role (the caller then enters the Player Dashboard).
  Future<void> completePlayerSetup() async {
    await ref.read(sessionProvider.notifier).savePlayerProfile(state.playerProfile);
    ref.read(roleControllerProvider.notifier).becomePlayer();
  }
}

final onboardingProvider = NotifierProvider<OnboardingController, OnboardingDraft>(OnboardingController.new);
