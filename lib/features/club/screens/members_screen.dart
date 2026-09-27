import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_rows.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../club_providers.dart';

/// Members — the club's members only (no team listings). Search stays on the
/// screen; the right-side filter panel narrows the players by cricket role
/// and fitness level and sorts them. Players show their role and Fitness
/// Meter score; non-playing staff are listed separately. Tapping any member
/// opens their Member Profile.
class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  late final _search = TextEditingController(text: ref.read(membersQueryProvider));
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(clubMembersProvider);
    final all = async.value ?? const <ClubMember>[];
    final total = async.value?.length;
    final searched = ref.watch(visibleMembersProvider);
    final query = ref.watch(membersQueryProvider).trim();
    final filter = ref.watch(memberFilterProvider);
    FitnessReport? fitnessOf(ClubMember m) => ref.watch(memberFitnessProvider(m.id));

    final players = [
      for (final m in searched)
        if (m.plays && filter.accepts(m, fitnessOf(m)?.level)) m,
    ];
    // Searching keeps the ranked order; otherwise the chosen sort applies.
    if (query.isEmpty) {
      int score(ClubMember m) => fitnessOf(m)?.score ?? 0;
      players.sort(switch (filter.sort) {
        MemberSort.name => (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        MemberSort.fitnessHigh => (a, b) => score(b).compareTo(score(a)),
        MemberSort.fitnessLow => (a, b) => score(a).compareTo(score(b)),
      });
    }
    final staff = filter.narrows ? const <ClubMember>[] : [for (final m in searched) if (!m.plays) m];
    final allPlayers = all.where((m) => m.plays).length;
    final narrowed = query.isNotEmpty || filter.narrows;
    void open(ClubMember m) => context.go(Routes.memberProfile(m.id));

    return Scaffold(
      key: _scaffoldKey,
      endDrawer: const _MemberFilterPanel(),
      endDrawerEnableOpenDragGesture: false,
      appBar: CeTopBar(
        title: 'Members',
        onBack: () => context.go(Routes.clubHome),
        actions: [
          _FilterButton(count: filter.activeCount, onTap: () => _scaffoldKey.currentState?.openEndDrawer()),
          if (total != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 10),
              child: Center(
                child: Semantics(
                  label: '$total members',
                  excludeSemantics: true,
                  child: Text('$total',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.muted)),
                ),
              ),
            ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 4),
              child: CeSearchField(
                hint: 'Search members...',
                controller: _search,
                onChanged: ref.read(membersQueryProvider.notifier).select,
              ),
            ),
            if (filter.activeCount > 0) _ActiveFilters(filter: filter),
            if (async.isLoading)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (async.hasError)
              CeErrorState(title: 'Couldn\'t load members', onRetry: () => ref.invalidate(clubMembersProvider))
            else if (players.isEmpty && staff.isEmpty)
              CeEmptyState(
                icon: 'users',
                title: narrowed ? 'No members found' : 'No members yet',
                body: query.isNotEmpty
                    ? 'No results for "$query".'
                    : narrowed
                        ? 'No players match these filters.'
                        : 'Share your club code so players can request to join.',
              )
            else ...[
              if (players.isNotEmpty || filter.narrows)
                CeSectionHeader(
                  narrowed ? 'Players · ${players.length} of $allPlayers' : 'Players · ${players.length}',
                  padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                ),
              for (final m in players) MemberRow(member: m, fitness: fitnessOf(m), onTap: () => open(m)),
              if (staff.isNotEmpty) ...[
                CeSectionHeader('Club Staff · ${staff.length}',
                    padding: const EdgeInsets.fromLTRB(CeSpace.gutter, CeSpace.section, CeSpace.gutter, 0)),
                for (final m in staff) MemberRow(member: m, onTap: () => open(m)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: count == 0 ? 'Filter members' : 'Filter members, $count active',
        onPressed: onTap,
        icon: Stack(clipBehavior: Clip.none, children: [
          Icon(CeIcons.of('sliders'), size: 20),
          if (count > 0)
            Positioned(
              top: -6,
              right: -8,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: CeColors.primary, shape: BoxShape.circle),
                child: Text('$count',
                    style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
        ]),
      );
}

/// Active filters summary with a one-tap Clear.
class _ActiveFilters extends ConsumerWidget {
  const _ActiveFilters({required this.filter});
  final MemberFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = [
      for (final r in filter.roles) r.label,
      for (final l in filter.levels) l.label,
      if (filter.sort != MemberSort.name) filter.sort.label,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
      child: Row(children: [
        Icon(CeIcons.of('sliders'), size: 13, color: CeColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(parts.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: CeColors.ink2, fontWeight: FontWeight.w600)),
        ),
        TextButton(
          onPressed: () => ref.read(memberFilterProvider.notifier).select(const MemberFilter()),
          child: const Text('Clear'),
        ),
      ]),
    );
  }
}

/// Right-side slide-in filter panel (architecture drawing): Role, Fitness
/// level and Sort; Apply commits, Reset clears.
class _MemberFilterPanel extends ConsumerStatefulWidget {
  const _MemberFilterPanel();

  @override
  ConsumerState<_MemberFilterPanel> createState() => _MemberFilterPanelState();
}

class _MemberFilterPanelState extends ConsumerState<_MemberFilterPanel> {
  late MemberFilter _f = ref.read(memberFilterProvider);

  Set<T> _toggle<T>(Set<T> s, T v) => s.contains(v) ? ({...s}..remove(v)) : {...s, v};

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: CeColors.muted)),
      );

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Drawer(
      key: const Key('members.filters'),
      width: width * 0.86 > 340 ? 340 : width * 0.86,
      backgroundColor: CeColors.bg,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 6, 0),
            child: Row(children: [
              Expanded(child: Text('Filter members', style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                tooltip: 'Close filters',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(CeIcons.of('x'), size: 20),
              ),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(18, 0, 18, 12), children: [
              _label('Role'),
              Wrap(spacing: 7, runSpacing: 7, children: [
                for (final r in MemberRoleFilter.values)
                  CeChip(
                    label: r.label,
                    selected: _f.roles.contains(r),
                    onTap: () => setState(() => _f = _f.copyWith(roles: _toggle(_f.roles, r))),
                  ),
              ]),
              _label('Fitness level'),
              Wrap(spacing: 7, runSpacing: 7, children: [
                for (final l in FitnessLevel.values)
                  CeChip(
                    label: l.label,
                    selected: _f.levels.contains(l),
                    onTap: () => setState(() => _f = _f.copyWith(levels: _toggle(_f.levels, l))),
                  ),
              ]),
              _label('Sort by'),
              Wrap(spacing: 7, runSpacing: 7, children: [
                for (final s in MemberSort.values)
                  CeChip(label: s.label, selected: _f.sort == s, onTap: () => setState(() => _f = _f.copyWith(sort: s))),
              ]),
              const SizedBox(height: 14),
              const Text('Role and fitness filters apply to players; club staff show when no filter is set.',
                  style: TextStyle(fontSize: 11, color: CeColors.muted, height: 1.4)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: CeColors.line))),
            child: Row(children: [
              Expanded(
                child: CeButton.soft(
                  label: 'Reset',
                  dense: true,
                  onPressed: () => setState(() => _f = const MemberFilter()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CeButton(
                  label: 'Apply',
                  dense: true,
                  onPressed: () {
                    ref.read(memberFilterProvider.notifier).select(_f);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A member card. Members screen: name, cricket role (or staff role), the
/// Fitness Meter score for players, Owner badge; tap → Member Profile.
/// [compact] (My Club preview): name + club role only, as before.
class MemberRow extends StatelessWidget {
  const MemberRow({super.key, required this.member, this.compact = false, this.fitness, this.onTap});
  final ClubMember member;
  final bool compact;
  final FitnessReport? fitness;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final isOwner = m.role == MemberRole.owner;
    if (compact) {
      return CeListRow(
        leading: CeAvatar(m.name, size: 40, background: CeColors.primary, foreground: Colors.white),
        title: m.name,
        subtitle: m.role.label,
      );
    }
    return CeListRow(
      semanticLabel: [
        m.name,
        m.roleLine,
        if (isOwner) 'Owner',
        if (fitness != null) 'Fitness ${fitness!.score} out of 10, ${fitness!.level.label}',
        if (onTap != null) 'View profile',
      ].join(', '),
      leading: CeAvatar(m.name, size: 40, background: m.plays ? CeColors.primary : CeColors.muted2, foreground: Colors.white),
      title: m.name,
      subtitle: m.roleLine,
      meta: fitness == null ? null : FitnessBadge(fitness!),
      trailing: isOwner ? const CeStatusChip('Owner', icon: 'crown') : null,
      onTap: onTap,
    );
  }
}
