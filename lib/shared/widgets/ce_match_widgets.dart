import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/tokens.dart';
import 'ce_feedback.dart';
import 'ce_icons.dart';

/// Opens Google Maps for a place (prototype "Directions ↗" links).
Future<void> openDirections(BuildContext context, String place) async {
  final uri = Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': place});
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showCeToast(context, "Couldn't open Maps");
}

/// Square team/club badge with abbreviation (`.club-badge`, `.pd-nm-shield`).
class CeTeamBadge extends StatelessWidget {
  const CeTeamBadge(this.abbr, {super.key, this.color = CeColors.primaryDark, this.size = 38, this.onDark = false});
  final String abbr;
  final Color color;
  final double size;

  /// On a gradient surface: translucent fill with a light border.
  final bool onDark;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onDark ? Colors.white.withValues(alpha: 0.18) : color,
          borderRadius: BorderRadius.circular(size >= 44 ? CeRadius.md : CeRadius.sm),
          border: onDark ? Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2) : null,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(abbr,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.33)),
          ),
        ),
      );
}

/// Small rounded info chip used inside match cards (`.cmc-info-item`).
class CeInfoChip extends StatelessWidget {
  const CeInfoChip({super.key, required this.icon, required this.label});
  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CeIcons.of(icon), size: 12, color: CeColors.primaryDark),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF1E2B24))),
          ),
        ]),
      );
}

/// Ground row with "Directions ↗" (`.cmc-ground-row`).
class CeGroundRow extends StatelessWidget {
  const CeGroundRow({super.key, required this.ground, this.directions = true});
  final String ground;
  final bool directions;

  @override
  Widget build(BuildContext context) => Material(
        color: CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: directions ? () => openDirections(context, ground) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(CeIcons.of('flag'), size: 14, color: const Color(0xFF1E2B24)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(ground,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF1E2B24))),
              ),
              if (directions) ...[
                const SizedBox(width: 8),
                const Text('Directions',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: CeColors.primaryDark)),
                const SizedBox(width: 2),
                Icon(CeIcons.of('arrow-up-right'), size: 12, color: CeColors.primaryDark),
              ],
            ]),
          ),
        ),
      );
}

/// Match card (`.confirmed-match-card`): badges, status chip, title, info
/// chips, ground + Directions, "Playing: team", optional footer.
class CeMatchCard extends StatelessWidget {
  const CeMatchCard({
    super.key,
    required this.homeAbbr,
    required this.awayAbbr,
    required this.title,
    required this.status,
    required this.infoChips,
    this.homeColor = CeColors.primaryDark,
    this.awayColor = CeColors.red,
    this.ground,
    this.playingTeam,
    this.footer,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
  });

  final String homeAbbr;
  final String awayAbbr;
  final Color homeColor;
  final Color awayColor;
  final String title;
  final Widget status;
  final List<CeInfoChip> infoChips;
  final String? ground;
  final String? playingTeam;
  final Widget? footer;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x0F1B4332), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: CeColors.mint),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                CeTeamBadge(homeAbbr, color: homeColor),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('VS',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: CeColors.muted)),
                ),
                CeTeamBadge(awayAbbr, color: awayColor),
                const Spacer(),
                status,
              ]),
              const SizedBox(height: 10),
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: infoChips),
              if (ground != null) ...[const SizedBox(height: 10), CeGroundRow(ground: ground!)],
              if (playingTeam != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Icon(CeIcons.of('users'), size: 13, color: CeColors.muted),
                  const SizedBox(width: 5),
                  const Text('Playing: ', style: TextStyle(fontSize: 12, color: CeColors.muted)),
                  Flexible(
                    child: Text(playingTeam!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink)),
                  ),
                ]),
              ],
              if (footer != null) ...[const SizedBox(height: 8), footer!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Toggle card (`.oto-card`): mint card with icon, title, subtitle, switch.
class CeToggleCard extends StatelessWidget {
  const CeToggleCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
  });

  final String icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.lg),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Icon(CeIcons.of(icon), size: 22, color: CeColors.primaryDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.4)),
                ]),
              ),
              const SizedBox(width: 8),
              Semantics(
                toggled: value,
                label: title,
                child: Switch(value: value, onChanged: onChanged),
              ),
            ]),
          ),
        ),
      );
}

/// Horizontal summary strip (`.mp-simple-row`): N equal cells with dividers.
class CeSummaryStrip extends StatelessWidget {
  const CeSummaryStrip({super.key, required this.items, this.margin});
  final List<(String value, String label)> items;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: IntrinsicHeight(
          child: Row(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const VerticalDivider(width: 1, color: Color(0xFFF1F5F2)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(items[i].$1,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: CeColors.ink,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                    const SizedBox(height: 3),
                    Text(items[i].$2.toUpperCase(),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: const TextStyle(
                            fontSize: 9.5, color: CeColors.muted, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      );
}

/// Stat tile with tinted icon well (`.mp-stat-card`).
class CeStatTile extends StatelessWidget {
  const CeStatTile({super.key, required this.icon, required this.value, required this.label, this.tint = CeColors.mint});
  final String icon;
  final String value;
  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of(icon), size: 15, color: CeColors.primaryDark),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800, color: CeColors.ink, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 2, style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
        ]),
      );
}

/// W / L result pill (`.mp-match-result`).
class CeResultPill extends StatelessWidget {
  const CeResultPill({super.key, required this.won});
  final bool won;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: won ? CeColors.mint : CeColors.redSoft,
          borderRadius: BorderRadius.circular(CeRadius.pill),
        ),
        child: Text(won ? 'WON' : 'LOST',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: won ? CeColors.primaryDark : CeColors.red)),
      );
}

/// Club badge colours (prototype `clubColors`); unknown clubs use deep green.
Color clubBadgeColor(String abbr) => switch (abbr) {
      'KK' || 'GC' => CeColors.amber,
      'IU' => CeColors.blue,
      'RR' || 'FW' || 'DB' => CeColors.red,
      'GT' => CeColors.primary,
      _ => CeColors.primaryDark,
    };
