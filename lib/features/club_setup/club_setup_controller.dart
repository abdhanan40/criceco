import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// Create Club (step 1) + Club Details (step 2) answers, kept across Back.
class ClubSetupDraft {
  const ClubSetupDraft({
    this.name = '',
    this.ownerName = '',
    this.address = '',
    this.city,
    this.email = '',
    this.type,
    this.homeGroundId,
    this.hasLogo = false,
  });

  final String name;
  final String ownerName;
  final String address;
  final String? city;
  final String email;
  final ClubType? type;
  final String? homeGroundId;
  final bool hasLogo;

  ClubSetupDraft copyWith({
    String? name,
    String? ownerName,
    String? address,
    String? city,
    String? email,
    ClubType? type,
    String? homeGroundId,
    bool? hasLogo,
  }) =>
      ClubSetupDraft(
        name: name ?? this.name,
        ownerName: ownerName ?? this.ownerName,
        address: address ?? this.address,
        city: city ?? this.city,
        email: email ?? this.email,
        type: type ?? this.type,
        homeGroundId: homeGroundId ?? this.homeGroundId,
        hasLogo: hasLogo ?? this.hasLogo,
      );
}

/// Prototype `cities` (Create Club city list).
const kClubCities = [
  'Karachi', 'Lahore', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan',
  'Peshawar', 'Quetta', 'Sialkot', 'Hyderabad', 'Other',
];

class ClubSetupController extends Notifier<ClubSetupDraft> {
  @override
  ClubSetupDraft build() {
    final name = ref.watch(sessionProvider.select((s) => s.account?.fullName)) ?? '';
    return ClubSetupDraft(ownerName: name);
  }

  void update(ClubSetupDraft Function(ClubSetupDraft d) change) => state = change(state);

  /// "Create Club" — creates the club, grants the Club Owner profile and
  /// makes Club Owner the active role (the only role-granting path).
  Future<Club> createClub() async {
    final d = state;
    final club = await ref.read(sessionProvider.notifier).createClub(
          name: d.name.trim(),
          city: d.city!,
          type: d.type!,
          ownerName: d.ownerName.trim().isEmpty ? null : d.ownerName.trim(),
          address: d.address.trim().isEmpty ? null : d.address.trim(),
          email: d.email.trim().isEmpty ? null : d.email.trim(),
          homeGroundId: d.homeGroundId,
          hasLogo: d.hasLogo,
        );
    ref.read(roleControllerProvider.notifier).becomeClubOwner();
    ref.invalidateSelf();
    return club;
  }
}

final clubSetupProvider = NotifierProvider<ClubSetupController, ClubSetupDraft>(ClubSetupController.new);
