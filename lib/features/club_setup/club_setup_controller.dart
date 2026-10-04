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
    this.logoPath,
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

  /// Local path of the club picture chosen here (device photo picker).
  final String? logoPath;
  bool get hasLogo => logoPath != null;

  ClubSetupDraft copyWith({
    String? name,
    String? ownerName,
    String? address,
    String? city,
    ClubType? type,
    bool? hasHomeGround,
    String? homeGroundId,
    String? logoPath,
    bool clearLogo = false,
  }) =>
      ClubSetupDraft(
        name: name ?? this.name,
        ownerName: ownerName ?? this.ownerName,
        address: address ?? this.address,
        city: city ?? this.city,
        type: type ?? this.type,
        hasHomeGround: hasHomeGround ?? this.hasHomeGround,
        homeGroundId: homeGroundId ?? this.homeGroundId,
        logoPath: clearLogo ? null : (logoPath ?? this.logoPath),
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
    // The chosen picture is stored on the club the same way My Club does it.
    if (d.logoPath != null) {
      await ref.read(sessionProvider.notifier).updateClub((c) => c.withLogo(d.logoPath));
    }
    final saved = ref.read(currentClubProvider) ?? club;
    ref.read(roleControllerProvider.notifier).becomeClubOwner();
    ref.invalidateSelf();
    return saved;
  }
}

final clubSetupProvider = NotifierProvider<ClubSetupController, ClubSetupDraft>(ClubSetupController.new);
