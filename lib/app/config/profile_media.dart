import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/media_ref.dart';
import 'backend_config.dart';

/// The profile-media switch as built: `--dart-define=CRICECO_PROFILE_MEDIA=true`
/// once migration 31 (the `avatars` / `club-logos` Storage buckets,
/// `profiles.avatar_path`, `clubs.logo_path`, the visibility columns and their
/// functions) is live on the Supabase project. OFF by default: profile and
/// club pictures then stay on this device (`LocalAccountOverlay` /
/// `LocalClubOverlay`) and the profile visibility settings too, exactly as
/// before (M5 / M6).
const bool kProfileMediaBuild = bool.fromEnvironment('CRICECO_PROFILE_MEDIA');

/// The profile-media switch: [kProfileMediaBuild], overridden in tests.
final profileMediaEnabledProvider = Provider<bool>((ref) => kProfileMediaBuild);

/// `true` when profile pictures, club pictures and the profile visibility
/// use the server (Supabase + the profile-media switch).
final profileMediaLiveProvider = Provider<bool>(
  (ref) =>
      ref.watch(backendConfigProvider).isSupabase &&
      ref.watch(profileMediaEnabledProvider),
);

/// The largest picture the photo picker accepts: the Storage buckets' 2 MB
/// limit when pictures are uploaded, otherwise the device-only 10 MB.
final photoMaxBytesProvider = Provider<int>(
  (ref) => ref.watch(profileMediaLiveProvider)
      ? MediaRef.maxUploadBytes
      : MediaRef.maxLocalBytes,
);
