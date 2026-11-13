/// Nationwide location lookup (Stage 4.2, migration 6): provinces and
/// territories → districts → cities / towns. Ids are the database's; never
/// shown to people. Area / locality stays free text elsewhere.
library;

/// `provinces.kind`.
enum ProvinceKind { province, federalTerritory, administrativeTerritory }

class Province {
  const Province({required this.id, required this.name, required this.kind});

  final int id;

  /// What the app shows (the province's display name when it has one).
  final String name;
  final ProvinceKind kind;
}

class District {
  const District({
    required this.id,
    required this.provinceId,
    required this.name,
  });

  final int id;
  final int provinceId;
  final String name;
}

/// One pickable city / town (`v_city_options` / `search_cities()`).
class CityOption {
  const CityOption({
    required this.id,
    required this.name,
    this.qualifier,
    this.provinceId,
    this.provinceName,
    this.primaryDistrictId,
    this.primaryDistrictName,
    this.districtCount = 0,
    this.featuredRank,
  });

  final int id;
  final String name;

  /// Tells apart two cities of one province with the same name.
  final String? qualifier;

  /// `null` in memory mode (no province data there).
  final int? provinceId;
  final String? provinceName;
  final int? primaryDistrictId;
  final String? primaryDistrictName;

  /// How many active districts the city is linked to (Karachi: several or none).
  final int districtCount;

  /// 1–20 for the featured cities (shown first), else `null`.
  final int? featuredRank;

  bool get isFeatured => featuredRank != null;

  /// The picker's main line: "Kamra (Attock)" when a qualifier is needed.
  String get label => qualifier == null ? name : '$name ($qualifier)';

  /// The picker's second line: "Lahore, Punjab" (district, province); empty
  /// when unknown.
  String get subtitle => [
    if (primaryDistrictName != null && primaryDistrictName != qualifier)
      primaryDistrictName,
    ?provinceName,
  ].join(', ');
}
