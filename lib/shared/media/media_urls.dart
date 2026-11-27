import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/profile_media.dart';
import '../../app/providers/core_providers.dart';
import '../../core/utils/media_ref.dart';
import '../../data/supabase/supabase_gateways.dart';

/// A signed URL for a stored picture and when to stop using it.
class SignedMediaUrl {
  const SignedMediaUrl(this.url, {required this.renewAfter});
  final String url;

  /// A little before the URL expires: a picture built after this asks for
  /// a new URL.
  final DateTime renewAfter;
}

/// The signed URL (1 hour) of a stored picture ([MediaRef]), kept for the
/// app run and renewed when it expires or fails to load. `null` when the
/// picture isn't a stored one or this build doesn't use the server's
/// pictures (the profile-media switch is off). A failed request is an error
/// (the picture's fallback is shown), not retried on its own.
final signedMediaUrlProvider = FutureProvider.autoDispose
    .family<SignedMediaUrl?, String>(retry: _noRetry, (ref, mediaRef) async {
      final p = MediaRef.parse(mediaRef);
      if (p == null || !ref.watch(profileMediaLiveProvider)) return null;
      final gateway = ref.watch(mediaGatewayProvider);
      final asked = ref.read(clockProvider).now();
      const lifetime = MediaRef.signedUrlLifetime;
      final url = await gateway.signedUrl(
        p.bucket,
        p.path,
        expiresIn: lifetime,
      );
      ref.keepAlive();
      return SignedMediaUrl(
        url,
        renewAfter: asked.add(lifetime - const Duration(minutes: 5)),
      );
    });

Duration? _noRetry(int count, Object error) => null;

/// A stored picture through its signed URL, clipped like [child]'s owner
/// asks ([clip]); [fallback] while it loads, when it can't be shown, or
/// without the server's pictures. An expired URL is renewed; one that fails
/// to load is renewed once (then the fallback stays).
class StoredPhotoImage extends ConsumerStatefulWidget {
  const StoredPhotoImage({
    super.key,
    required this.mediaRef,
    required this.size,
    required this.fallback,
    required this.clip,
  });

  final String mediaRef;
  final double size;
  final Widget fallback;
  final Widget Function(Widget image) clip;

  @override
  ConsumerState<StoredPhotoImage> createState() => _StoredPhotoImageState();
}

class _StoredPhotoImageState extends ConsumerState<StoredPhotoImage> {
  /// Renewed after a load failure (once: every signed URL is new, so a
  /// picture that can't load would otherwise ask again and again).
  bool _renewedAfterError = false;

  /// The expired URL already renewed.
  String? _renewedExpired;

  void _renew() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(signedMediaUrlProvider(widget.mediaRef));
    });
  }

  @override
  Widget build(BuildContext context) {
    final signed = ref.watch(signedMediaUrlProvider(widget.mediaRef)).value;
    if (signed == null) return widget.fallback;
    if (!ref.read(clockProvider).now().isBefore(signed.renewAfter) &&
        _renewedExpired != signed.url) {
      _renewedExpired = signed.url;
      _renew();
    }
    return widget.clip(
      Image.network(
        signed.url,
        key: ValueKey(widget.mediaRef),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) {
          if (!_renewedAfterError) {
            _renewedAfterError = true;
            _renew();
          }
          return widget.fallback;
        },
      ),
    );
  }
}
