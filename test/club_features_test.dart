import 'package:criceco/app/config/backend_config.dart';
import 'package:criceco/app/config/club_features.dart';
import 'package:criceco/data/repositories/repositories.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stage 3B: which club features each backend offers (D-3B-2).
void main() {
  final supabase = BackendConfig.parse(
    backend: 'supabase',
    supabaseUrl: 'https://abcdefghijklmnop.supabase.co',
    supabasePublishableKey: 'sb_publishable_test_0000000000000000',
  );

  test('memory mode keeps joining a club by its code', () {
    expect(ClubFeatures.of(const BackendConfig.memory()).joinByCode, isTrue);
  });

  test('supabase mode: no join-by-code until Phase 3E', () {
    expect(ClubFeatures.of(supabase).joinByCode, isFalse);
  });

  test('the provider follows the backend config (default: memory)', () {
    final memory = ProviderContainer();
    addTearDown(memory.dispose);
    expect(memory.read(clubFeaturesProvider).joinByCode, isTrue);

    final remote = ProviderContainer(
      overrides: [backendConfigProvider.overrideWithValue(supabase)],
    );
    addTearDown(remote.dispose);
    expect(remote.read(clubFeaturesProvider).joinByCode, isFalse);
  });

  test(
    'the Coming Soon wording (D-3B-4), the same as the repository error',
    () {
      expect(
        ClubFeatures.joinComingSoon,
        'Joining a club by code is coming soon',
      );
      expect(
        const ClubJoinUnavailableException().message,
        ClubFeatures.joinComingSoon,
      );
    },
  );
}
