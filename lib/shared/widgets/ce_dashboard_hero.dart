import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'ce_icons.dart';
import 'ce_top_bar.dart';

/// Time-of-day greeting for the dashboard heroes.
String ceGreeting(DateTime now) => now.hour < 12
    ? 'Good morning'
    : now.hour < 17
        ? 'Good afternoon'
        : 'Good evening';

/// Role dashboard hero, shared by the Player and Club Owner dashboards so
/// they read as one product: stadium photo under a deep CricEco teal overlay,
/// a top row (menu · greeting + name · notifications) and a [card] (usually
/// a [CeHeroGlassCard]). Keys are prefixed with [keyPrefix]
/// (`<prefix>.hero`, `<prefix>.greeting`).
class CeDashboardHero extends StatelessWidget {
  const CeDashboardHero({
    super.key,
    required this.keyPrefix,
    required this.greeting,
    required this.name,
    required this.notificationCount,
    required this.onNotifications,
    required this.card,
  });

  static const photo = 'assets/branding/splash_stadium.png';

  final String keyPrefix;
  final String greeting;
  final String name;
  final int notificationCount;
  final VoidCallback onNotifications;
  final Widget card;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ClipRRect(
        key: Key('$keyPrefix.hero'),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Stack(children: [
          // Stadium photo, then the CricEco teal overlay for contrast.
          const Positioned.fill(child: ColoredBox(color: CeColors.paletteDeep)),
          Positioned.fill(
            child: Image.asset(
              photo,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.45),
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    CeColors.paletteDeep.withValues(alpha: 0.66),
                    CeColors.paletteDeep.withValues(alpha: 0.58),
                    CeColors.paletteTeal.withValues(alpha: 0.90),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(4, top + 2, 8, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // ---- Top row: menu · greeting / name · notifications ----
              Row(children: [
                Builder(
                  builder: (ctx) => IconButton(
                    tooltip: 'Open menu',
                    icon: Icon(CeIcons.of('menu'), color: Colors.white, size: 20),
                    onPressed: () => CeTopBar.openDrawer(ctx),
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(greeting,
                        key: Key('$keyPrefix.greeting'),
                        style: CeType.body.copyWith(fontSize: 13, height: 1.3, color: CeColors.sage)),
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CeType.heroName.copyWith(color: Colors.white)),
                  ]),
                ),
                CeHeroBell(count: notificationCount, onTap: onNotifications),
              ]),
              const SizedBox(height: 12),
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 8, 0), child: card),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Notifications bell with the unread badge (dashboard heroes).
class CeHeroBell extends StatelessWidget {
  const CeHeroBell({super.key, required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: count == 0 ? 'Notifications' : 'Notifications, $count',
        onPressed: onTap,
        icon: Stack(clipBehavior: Clip.none, children: [
          Icon(CeIcons.of('bell'), color: Colors.white, size: 20),
          if (count > 0)
            Positioned(
              top: -6,
              right: -7,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: CeColors.red, shape: BoxShape.circle),
                child: Text(count > 9 ? '9+' : '$count',
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
        ]),
      );
}

/// Frosted card in a dashboard hero: [leading] (avatar / badge), [title],
/// [subtitle], [chips], then an even row of [stats] (value · label) with
/// hairline separators. Tapping the card runs [onTap]; chips with their own
/// tap handlers keep them. Keys: `<prefix>.header` (tap target),
/// `<prefix>.card`, `<prefix>.subtitle`, `<prefix>.stats`.
class CeHeroGlassCard extends StatelessWidget {
  const CeHeroGlassCard({
    super.key,
    required this.keyPrefix,
    required this.leading,
    required this.title,
    required this.stats,
    required this.onTap,
    required this.semanticLabel,
    this.subtitle,
    this.chips = const [],
  });

  final String keyPrefix;
  final Widget leading;
  final String title;
  final String? subtitle;
  final List<Widget> chips;
  final List<(String value, String label)> stats;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: semanticLabel,
        child: GestureDetector(
          key: Key('$keyPrefix.header'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(CeRadius.hero),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                key: Key('$keyPrefix.card'),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(CeRadius.hero),
                  color: Colors.white.withValues(alpha: 0.10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: CeType.sectionTitle.copyWith(color: Colors.white, height: 1.2)),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!,
                              key: Key('$keyPrefix.subtitle'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: CeType.bodySmall.copyWith(fontSize: 12, height: 1.3, color: Colors.white.withValues(alpha: 0.82))),
                        ],
                        if (chips.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(spacing: 6, runSpacing: 6, children: chips),
                        ],
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.16)),
                  const SizedBox(height: 10),
                  IntrinsicHeight(
                    child: Row(key: Key('$keyPrefix.stats'), children: [
                      for (final (i, (value, label)) in stats.indexed) ...[
                        if (i > 0) VerticalDivider(width: 1, color: Colors.white.withValues(alpha: 0.16)),
                        Expanded(
                          child: Column(children: [
                            // Fixed line height: a shrunk value never shifts its label.
                            SizedBox(
                              height: 22,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(value,
                                    style: CeType.statValue(17).copyWith(
                                        color: Colors.white, fontFeatures: const [FontFeature.tabularFigures()])),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CeType.statLabel.copyWith(color: Colors.white.withValues(alpha: 0.72))),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Small translucent pill on a dashboard hero (status, role, club…).
class CeHeroPill extends StatelessWidget {
  const CeHeroPill({super.key, required this.label, this.icon, this.dotColor, this.trailingIcon});
  final String label;
  final String? icon;
  final Color? dotColor;
  final String? trailingIcon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(CeRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(CeIcons.of(icon!), size: 12, color: Colors.white),
          if (dotColor != null)
            Container(width: 7, height: 7, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 5),
            Icon(CeIcons.of(trailingIcon!), size: 12, color: Colors.white),
          ],
        ]),
      );
}
