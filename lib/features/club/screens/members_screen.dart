import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_rows.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../club_providers.dart';

/// Members (prototype `screens.members`, :5419). The prototype's static
/// search box is a real ranked search (fix: dead control).
class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  late final _search = TextEditingController(text: ref.read(membersQueryProvider));

  /// Role filter (null = all). Offered only when the club has several roles.
  MemberRole? _role;

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
    final roles = [for (final r in MemberRole.values) if (all.any((m) => m.role == r)) r];
    final role = roles.contains(_role) ? _role : null;
    final visible = role == null ? searched : searched.where((m) => m.role == role).toList();
    final narrowed = query.isNotEmpty || role != null;

    return Scaffold(
      appBar: CeTopBar(
        title: 'Members',
        onBack: () => context.go(Routes.clubHome),
        actions: [
          if (total != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
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
            if (roles.length > 1)
              CeChipRow<MemberRole?>(
                values: [null, ...roles],
                selected: role,
                labelOf: (r) => r == null ? 'All' : r.label,
                countOf: (r) => r == null ? all.length : all.where((m) => m.role == r).length,
                onSelected: (r) => setState(() => _role = r),
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
              ),
            if (async.isLoading)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (async.hasError)
              CeErrorState(title: 'Couldn\'t load members', onRetry: () => ref.invalidate(clubMembersProvider))
            else if (visible.isEmpty)
              CeEmptyState(
                icon: 'users',
                title: narrowed ? 'No members found' : 'No members yet',
                body: query.isNotEmpty
                    ? 'No results for "$query".'
                    : narrowed
                        ? 'No ${role!.label.toLowerCase()}s in your club yet.'
                        : 'Share your club code so players can request to join.',
              )
            else ...[
              if (narrowed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
                  child: Text('${visible.length} of ${all.length} members',
                      style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                ),
              for (final m in visible) MemberRow(member: m),
            ],
          ],
        ),
      ),
    );
  }
}

/// `.member-row`: avatar, name, phone and role tag; the Owner gets a badge.
/// [compact] (My Club): name + role only, as in the prototype's list.
class MemberRow extends StatelessWidget {
  const MemberRow({super.key, required this.member, this.compact = false});
  final ClubMember member;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final isOwner = m.role == MemberRole.owner;
    // Dense row: avatar · name · phone (or role) · role tag / Owner badge on
    // the right.
    return CeListRow(
      leading: CeAvatar(m.name, size: 40, background: CeColors.primary, foreground: Colors.white),
      title: m.name,
      subtitle: compact ? m.role.label : (m.phone.isNotEmpty ? m.phone : null),
      trailing: compact
          ? null
          : isOwner
              ? const CeStatusChip('Owner', icon: 'crown')
              : _Tag(m.role.label),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.xs)),
        child: Text(label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: CeColors.primaryDark)),
      );
}
