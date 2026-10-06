import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/enums/enums.dart';
import 'ce_buttons.dart';
import 'ce_feedback.dart';
import 'ce_icons.dart';
import 'ce_surfaces.dart';

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
          borderRadius: BorderRadius.circular(size >= 44 ? CeRadius.input : (size >= 34 ? CeRadius.md : CeRadius.sm)),
          border: onDark ? Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2) : null,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(abbr,
                style: TextStyle(fontFamily: CeType.display, color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.33)),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xs)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CeIcons.of(icon), size: 12, color: CeColors.primary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: CeType.micro.copyWith(fontSize: 11, color: CeColors.ink2)),
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
        color: CeColors.bg,
        borderRadius: BorderRadius.circular(CeRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: directions ? () => openDirections(context, ground) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Icon(CeIcons.of('map-pin'), size: 14, color: CeColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(ground,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CeType.bodySmall.copyWith(fontWeight: FontWeight.w600, color: CeColors.primary)),
              ),
              if (directions) ...[
                const SizedBox(width: 8),
                Text('Directions', style: CeType.chip.copyWith(fontSize: 12, color: CeColors.accent)),
                const SizedBox(width: 2),
                Icon(CeIcons.of('arrow-up-right'), size: 12, color: CeColors.accent),
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
    this.groundDirections = true,
    this.playingTeam,
    this.footer,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
    this.date,
    this.meta,
    this.dimmed = false,
  });

  final String homeAbbr;
  final String awayAbbr;
  final Color homeColor;
  final Color awayColor;
  final String title;
  final Widget status;
  final List<CeInfoChip> infoChips;
  final String? ground;

  /// Show "Directions" on the ground row (off when the ground is unknown).
  final bool groundDirections;
  final String? playingTeam;
  final Widget? footer;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  /// Reference layout: a date block (day + date) leads the card, with [meta]
  /// ("2:00 PM · T20") under the title and the ground + team in a dashed
  /// footer. Without it, the badge layout below.
  final DateTime? date;
  final String? meta;

  /// Cancelled: muted date block with the date struck through.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    if (date != null) return _dated(context);
    return Container(
      margin: margin,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.card),
          side: const BorderSide(color: CeColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(CeSpace.card),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                CeTeamBadge(homeAbbr, color: homeColor, size: 34),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('VS', style: CeType.micro.copyWith(letterSpacing: 1.1, color: CeColors.muted)),
                ),
                CeTeamBadge(awayAbbr, color: awayColor, size: 34),
                const Spacer(),
                status,
              ]),
              const SizedBox(height: 10),
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: CeType.cardTitle),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: infoChips),
              if (ground != null) ...[const SizedBox(height: 8), CeGroundRow(ground: ground!, directions: groundDirections)],
              if (playingTeam != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Icon(CeIcons.of('users'), size: 13, color: CeColors.muted),
                  const SizedBox(width: 5),
                  Text('Playing: ', style: CeType.bodySmall.copyWith(fontSize: 12)),
                  Flexible(
                    child: Text(playingTeam!,
                        overflow: TextOverflow.ellipsis, style: CeType.chip.copyWith(fontSize: 12, color: CeColors.ink)),
                  ),
                ]),
              ],
              if (footer != null) ...[const CeDashedDivider(padding: EdgeInsets.symmetric(vertical: 10)), footer!],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _dated(BuildContext context) {
    final d = date!;
    const days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dateBlock = Container(
      width: 48,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dimmed ? CeColors.hairline : CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.md),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(days[d.weekday - 1],
            style: CeType.micro.copyWith(fontSize: 10, letterSpacing: 0.6, color: dimmed ? CeColors.muted : CeColors.primary)),
        const SizedBox(height: 2),
        Text('${d.day}',
            style: CeType.statValue(19).copyWith(
                height: 1,
                color: dimmed ? CeColors.muted : CeColors.ink,
                decoration: dimmed ? TextDecoration.lineThrough : null)),
      ]),
    );
    final hasFooterRow = ground != null || playingTeam != null;
    return Container(
      margin: margin,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CeRadius.card),
          side: const BorderSide(color: CeColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(CeSpace.card),
            // Narrow cards (320 px phones): the status goes under the time line
            // and the footer stacks, so the title and ground keep their room.
            child: LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 300;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                dateBlock,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: CeType.listTitle.copyWith(fontSize: 14.5, color: dimmed ? CeColors.ink2 : CeColors.ink)),
                    if (meta != null) ...[
                      const SizedBox(height: 3),
                      Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: CeType.bodySmall.copyWith(fontSize: 12)),
                    ],
                    // Extra chips only (date, time and format are in the block / meta).
                    if (infoChips.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: infoChips),
                    ],
                    if (narrow) ...[const SizedBox(height: 6), status],
                  ]),
                ),
                if (!narrow) ...[const SizedBox(width: 8), status],
              ]),
              if (hasFooterRow) ...[
                const CeDashedDivider(padding: EdgeInsets.only(top: 12, bottom: 10)),
                Flex(
                  direction: narrow ? Axis.vertical : Axis.horizontal,
                  mainAxisSize: narrow ? MainAxisSize.min : MainAxisSize.max,
                  crossAxisAlignment: narrow ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  children: [
                  if (ground != null)
                    Flexible(
                      fit: narrow ? FlexFit.loose : FlexFit.tight,
                      child: InkWell(
                        onTap: groundDirections ? () => openDirections(context, ground!) : null,
                        child: Row(children: [
                          Icon(CeIcons.of('map-pin'), size: 13, color: CeColors.primary),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(ground!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CeType.caption.copyWith(fontSize: 12, color: CeColors.primary)),
                          ),
                          if (groundDirections) ...[
                            const SizedBox(width: 3),
                            Icon(CeIcons.of('arrow-up-right'), size: 12, color: CeColors.accent),
                          ],
                        ]),
                      ),
                    )
                  else if (!narrow)
                    const Spacer(),
                  if (playingTeam != null) ...[
                    SizedBox(width: narrow ? 0 : 10, height: narrow ? 6 : 0),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: narrow ? box.maxWidth : 130),
                      // Two texts (the team name stays its own Text).
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Playing: ', style: CeType.caption.copyWith(fontSize: 12)),
                        Flexible(
                          child: Text(playingTeam!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CeType.caption.copyWith(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink)),
                        ),
                      ]),
                    ),
                  ],
                ]),
              ],
              if (footer != null) ...[const CeDashedDivider(padding: EdgeInsets.symmetric(vertical: 10)), footer!],
              ]);
            }),
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
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
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
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.button)),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.button),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(CeIcons.of(icon), size: 20, color: CeColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: CeType.listTitle),
                  const SizedBox(height: 2),
                  Text(subtitle, style: CeType.bodySmall.copyWith(fontSize: 12)),
                ]),
              ),
              const SizedBox(width: 8),
              Semantics(
                toggled: value,
                label: title,
                child: CeSwitch(value: value, onChanged: onChanged),
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
        margin: margin ?? const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.card),
          border: Border.all(color: CeColors.line),
        ),
        child: IntrinsicHeight(
          child: Row(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const VerticalDivider(width: 1, color: CeColors.hairline),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(items[i].$1,
                          style: CeType.statValue(16).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                    const SizedBox(height: 3),
                    Text(items[i].$2, textAlign: TextAlign.center, maxLines: 2, style: CeType.statLabel),
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

  // Compact, horizontal (reference density): icon well beside value + label.
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.button),
          border: Border.all(color: CeColors.line),
        ),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(9)),
            child: Icon(CeIcons.of(icon), size: 15, color: CeColors.primary),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: CeType.statValue(17).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              const SizedBox(height: 1),
              Text(label, maxLines: 2, style: CeType.statLabel),
            ]),
          ),
        ]),
      );
}

/// W / L result pill (`.mp-match-result`).
class CeResultPill extends StatelessWidget {
  const CeResultPill({super.key, required this.won});
  final bool won;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: won ? CeColors.mint : CeColors.redSoft,
          borderRadius: BorderRadius.circular(CeRadius.xs),
        ),
        child: Text(won ? 'WON' : 'LOST',
            style: CeType.micro.copyWith(fontSize: 11, color: won ? CeColors.primary : CeColors.red)),
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

/// Badge initials for a club name: "Shalimar CC" → "SC" (prototype badges).
String clubAbbr(String name) {
  final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.substring(0, words.first.length.clamp(0, 2)).toUpperCase();
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// Format icon (prototype `formatMeta`).
String formatIcon(MatchFormat f) => switch (f) {
      MatchFormat.test => 'hourglass',
      MatchFormat.t20 || MatchFormat.t10 => 'circle-dot',
      MatchFormat.odi => 'sun',
      MatchFormat.custom => 'sliders',
    };

/// Format description line (prototype `formatMeta[f].label`).
String formatBlurb(MatchFormat f) => switch (f) {
      MatchFormat.test => 'Traditional format · longer innings',
      MatchFormat.t20 => '20 overs · the classic format',
      MatchFormat.t10 => '10 overs · quick fire',
      MatchFormat.odi => '50 overs · full day match',
      MatchFormat.custom => 'Set your own number of overs',
    };
