import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(clubMembersProvider);
    final total = async.value?.length;
    final visible = ref.watch(visibleMembersProvider);
    final query = ref.watch(membersQueryProvider).trim();

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
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 4),
              child: CeSearchField(
                hint: 'Search members...',
                controller: _search,
                onChanged: ref.read(membersQueryProvider.notifier).select,
              ),
            ),
            if (async.isLoading)
              const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
            else if (visible.isEmpty)
              CeEmptyState(
                icon: 'users',
                title: query.isEmpty ? 'No members yet' : 'No members found',
                body: query.isEmpty
                    ? 'Share your club code so players can request to join.'
                    : 'No results for "$query".',
              )
            else
              for (final m in visible) MemberRow(member: m),
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
    return Container(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(CeRadius.row),
        border: Border.all(color: CeColors.line),
        boxShadow: CeShadows.card,
      ),
      child: Row(children: [
        CeAvatar(m.name, size: 42, background: CeColors.primary, foreground: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
            if (compact)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(m.role.label, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
              )
            else ...[
              if (m.phone.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(m.phone, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                ),
              if (!isOwner) ...[
                const SizedBox(height: 5),
                _Tag(m.role.label),
              ],
            ],
          ]),
        ),
        if (isOwner && !compact) ...[
          const SizedBox(width: 8),
          const CeStatusChip('Owner', icon: 'crown'),
        ],
      ]),
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
