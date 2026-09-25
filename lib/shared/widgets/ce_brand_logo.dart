import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

/// The approved CricEco logo (flat rounded tile with the glyph), shown as
/// supplied — never recoloured or re-proportioned. Used where the design
/// expects branding (auth banners, the sign-up intro), not on every screen.
class CeBrandLogo extends StatelessWidget {
  const CeBrandLogo({super.key, this.size = 74, this.onDark = false});

  static const asset = 'assets/branding/criceco_logo.png';

  /// Corner radius of the approved tile, as a fraction of its size.
  static const cornerFrac = 0.185;

  final double size;

  /// On the dark hero gradient the tile's edge would melt into the
  /// background, so a hairline light outline and a soft shadow frame it
  /// (around the logo — the logo itself is untouched).
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain, // square asset: proportions locked
      filterQuality: FilterQuality.high,
      semanticLabel: 'CricEco',
    );
    if (!onDark) return image;
    final radius = BorderRadius.circular(size * cornerFrac);
    return Container(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: CeShadows.raised),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.2),
      ),
      child: image,
    );
  }
}
