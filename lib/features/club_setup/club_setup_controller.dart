import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../core/models/models.dart';

/// Club Setup Details answers (one screen), kept across Back.
class ClubSetupDraft {
  const ClubSetupDraft({
    this.name = '',
    this.ownerName = '',
    this.address = '',
    this.city,
    this.type,
    this.hasHomeGround,
    this.homeGroundId,
    this.hasLogo = false,
  });

  final String name;
  final String ownerName;
  final String address;

  /// Required by the club model (shown across every club screen), so kept.
  final String? city;
  final ClubType? type;

  /// Home Ground: Yes / No — `null` until answered.
  final bool? hasHomeGround;

  /// The ground chosen when [hasHomeGround] is Yes.
  final String? homeGroundId;
  final bool hasLogo;

  ClubSetupDraft copyWith({
    String? name,
    String? ownerName,
    String? address,
    String? city,
    ClubType? type,
    bool? hasHomeGround,
    String? homeGroundId,
    bool? hasLogo,
  }) =>
      ClubSetupDraft(
        name: name ?? this.name,
        ownerName: ownerName ?? this.ownerName,
        address: address ?? this.address,
        city: city ?? this.city,
        type: type ?? this.type,
        hasHomeGround: hasHomeGround ?? this.hasHomeGround,
        homeGroundId: homeGroundId ?? this.homeGroundId,
        hasLogo: hasLogo ?? this.hasLogo,
      );
}

/// Prototype `cities` (club city list).
const kClubCities = [
  'Karachi', 'Lahore', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan',
  'Peshawar', 'Quetta', 'Sialkot', 'Hyderabad', 'Other',
];

class ClubSetupController extends Notifier<ClubSetupDraft> {
  @override
  ClubSetupDraft build() {
    // Owner Name starts as the account's name (editable).
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
          ownerName: d.ownerName.trim(),
          address: d.address.trim(),
          homeGroundId: d.hasHomeGround == true ? d.homeGroundId : null,
          hasLogo: d.hasLogo,
        );
    ref.read(roleControllerProvider.notifier).becomeClubOwner();
    ref.invalidateSelf();
    return club;
  }
}

final clubSetupProvider = NotifierProvider<ClubSetupController, ClubSetupDraft>(ClubSetupController.new);
