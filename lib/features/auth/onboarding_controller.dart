import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/constants/city_areas.dart';
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
    this.currentCity,
    this.currentArea,
    this.currentAddress,
    this.permanentCity,
    this.permanentArea,
    this.permanentAddress,
    this.isPermanentSameAsCurrent = true,
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

  final String? currentCity;
  final String? currentArea;
  final String? currentAddress;
  final String? permanentCity;
  final String? permanentArea;
  final String? permanentAddress;
  final bool isPermanentSameAsCurrent;

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
    String? currentCity,
    String? currentArea,
    String? currentAddress,
    String? permanentCity,
    String? permanentArea,
    String? permanentAddress,
    bool? isPermanentSameAsCurrent,
    bool clearCurrentArea = false,
    bool clearPermanentArea = false,
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
        currentCity: currentCity ?? this.currentCity,
        currentArea: clearCurrentArea ? null : (currentArea ?? this.currentArea),
        currentAddress: currentAddress ?? this.currentAddress,
        permanentCity: permanentCity ?? this.permanentCity,
        permanentArea: clearPermanentArea ? null : (permanentArea ?? this.permanentArea),
        permanentAddress: permanentAddress ?? this.permanentAddress,
        isPermanentSameAsCurrent: isPermanentSameAsCurrent ?? this.isPermanentSameAsCurrent,
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
      currentCity: account.currentCity,
      currentArea: account.currentArea,
      currentAddress: account.currentAddress,
      permanentCity: account.permanentCity,
      permanentArea: account.permanentArea,
      permanentAddress: account.permanentAddress,
      isPermanentSameAsCurrent: account.isPermanentSameAsCurrent,
      role: p.role,
      battingStyle: p.battingStyle,
      bowlingStyle: p.bowlingStyle,
      isWicketkeeper: p.isWicketkeeper,
    );
  }

  void setFullName(String v) => state = state.copyWith(fullName: v);
  void setDateOfBirth(DateTime v) => state = state.copyWith(dateOfBirth: v);
  void setPhone(String v) => state = state.copyWith(phone: v);
  /// A different city clears an Area that isn't one of its listed areas
  /// (a listed area, or an area typed under the old city, no longer applies).
  void setCurrentCity(String? v) => state = state.copyWith(
        currentCity: v,
        clearCurrentArea: !_areaStillValid(state.currentCity, v, state.currentArea),
      );
  void setCurrentArea(String v) => state = state.copyWith(currentArea: v);
  void setCurrentAddress(String v) => state = state.copyWith(currentAddress: v);
  void setPermanentCity(String? v) => state = state.copyWith(
        permanentCity: v,
        clearPermanentArea: !_areaStillValid(state.permanentCity, v, state.permanentArea),
      );

  /// Whether [area] still fits after the city changes:
  /// * same city, or the area is listed under the new city → keep;
  /// * the new city has listed areas (the area isn't one) → clear;
  /// * the new city has none (typed Area) → keep a typed area, clear one that
  ///   came from the old city's list.
  bool _areaStillValid(String? oldCity, String? newCity, String? area) {
    if (oldCity == newCity || area == null || area.trim().isEmpty) return true;
    final areas = ref.read(cityAreasProvider).value ?? CityAreas.empty;
    if (areas.isListed(newCity, area)) return true;
    if (areas.areasFor(newCity).isNotEmpty) return false;
    return !areas.isListed(oldCity, area);
  }
  void setPermanentArea(String v) => state = state.copyWith(permanentArea: v);
  void setPermanentAddress(String v) => state = state.copyWith(permanentAddress: v);
  /// Yes / No only flips the flag — permanent answers typed under No stay.
  void setPermanentSameAsCurrent(bool v) => state = state.copyWith(isPermanentSameAsCurrent: v);
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
  /// Name, cities, areas and addresses come from this draft (the screen's
  /// fields write to it as the user types or picks). With "same as current"
  /// the session saves the current address as the permanent one; the draft's
  /// own permanent answers are kept, so switching back to No restores them.
  Future<void> saveProfile({required String phone}) {
    final d = state;
    String text(String? v) => (v ?? '').trim();
    return ref.read(sessionProvider.notifier).completeProfile(
          fullName: d.fullName.trim(),
          phone: phone,
          dateOfBirth: d.dateOfBirth!,
          photoPath: d.photoPath,
          currentCity: text(d.currentCity),
          currentArea: text(d.currentArea),
          currentAddress: text(d.currentAddress),
          permanentCity: text(d.permanentCity),
          permanentArea: text(d.permanentArea),
          permanentAddress: text(d.permanentAddress),
          isPermanentSameAsCurrent: d.isPermanentSameAsCurrent,
        );
  }

  /// Role Selection → Player → Continue: saves the Player profile and makes
  /// Player the active role (the caller then enters the Player Dashboard).
  Future<void> completePlayerSetup() async {
    await ref.read(sessionProvider.notifier).savePlayerProfile(state.playerProfile);
    ref.read(roleControllerProvider.notifier).becomePlayer();
  }
}

final onboardingProvider = NotifierProvider<OnboardingController, OnboardingDraft>(OnboardingController.new);
