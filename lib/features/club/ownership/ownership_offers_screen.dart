import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/account_error_text.dart';
import '../../../app/session/role_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import 'ownership_controller.dart';

/// Player → Club ownership offers: a club owner offered this member their
/// club. Accept (the club becomes theirs at once) or Decline (nothing
/// changes). Reached from the Player Dashboard's offer banner.
class OwnershipOffersScreen extends ConsumerStatefulWidget {
  const OwnershipOffersScreen({super.key});

  @override
  ConsumerState<OwnershipOffersScreen> createState() => _OwnershipOffersScreenState();
}

class _OwnershipOffersScreenState extends ConsumerState<OwnershipOffersScreen> {
  String? _busyId;

  Future<void> _accept(OwnershipTransfer offer) async {
    final ok = await showCeConfirmSheet(
      context,
      title: 'Become the owner of ${offer.clubName}?',
      body:
          'You’ll manage the club: its members, join requests and teams. ${offer.fromName} stays in the club as '
          '${offer.previousOwnerRole.label}. You can own only one club.',
      confirmLabel: 'Accept Ownership',
      icon: 'shield',
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = offer.id);
    final OwnershipTransfer result;
    try {
      result = await ref.read(ownershipActionsProvider.notifier).accept(offer.id);
    } catch (e) {
      if (mounted) {
        setState(() => _busyId = null);
        showCeToast(context, accountErrorText(e, fallback: "Couldn't accept the offer — please try again"));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busyId = null);
    if (result.status != OwnershipTransferStatus.accepted) {
      showCeToast(context, 'This offer has expired — nothing changed');
      return;
    }
    showCeToast(context, 'You’re now the owner of ${offer.clubName}');
    final nav = ref.read(roleControllerProvider.notifier).continueAs(UserRole.clubOwner);
    context.go(switch (nav) {
      GoToLocation(:final location) => location,
      NeedsClubSetup() => Routes.playerHome,
    });
  }

  Future<void> _decline(OwnershipTransfer offer) async {
    final ok = await showCeConfirmSheet(
      context,
      title: 'Decline the offer?',
      body: '${offer.fromName} stays the owner of ${offer.clubName}. Nothing else changes.',
      confirmLabel: 'Decline',
      destructive: true,
      icon: 'x-circle',
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = offer.id);
    try {
      await ref.read(ownershipActionsProvider.notifier).decline(offer.id);
      if (mounted) showCeToast(context, 'Offer declined');
    } catch (e) {
      if (mounted) showCeToast(context, accountErrorText(e, fallback: "Couldn't decline the offer — please try again"));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(myOwnershipOffersProvider);
    return Scaffold(
      appBar: const CeTopBar(title: 'Club Ownership Offers', fallbackLocation: Routes.playerHome),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            CeErrorState(title: 'Couldn’t load your offers', onRetry: () => ref.invalidate(myOwnershipOffersProvider)),
        data: (offers) => offers.isEmpty
            ? const CeEmptyState(
                key: Key('offers.empty'),
                icon: 'shield',
                title: 'No open offers',
                body: 'When a club owner offers you their club, it shows up here.',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  for (final o in offers)
                    CeCard(
                      key: Key('offers.offer.${o.id}'),
                      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(o.clubName, style: CeType.listTitle),
                          const SizedBox(height: 6),
                          Text(
                            '${o.fromName} offered you the ownership of this club. They stay as '
                            '${o.previousOwnerRole.label}. Expires ${CeFormat.date(o.expiresAt)}.',
                            style: CeType.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: CeButton.soft(
                                  key: Key('offers.decline.${o.id}'),
                                  label: 'Decline',
                                  onPressed: _busyId != null ? null : () => _decline(o),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: CeButton(
                                  key: Key('offers.accept.${o.id}'),
                                  label: 'Accept',
                                  loading: _busyId == o.id,
                                  onPressed: _busyId != null ? null : () => _accept(o),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Player Dashboard: shown only while an ownership offer is open.
class OwnershipOffersBanner extends ConsumerWidget {
  const OwnershipOffersBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(myOwnershipOffersProvider).value ?? const <OwnershipTransfer>[];
    if (offers.isEmpty) return const SizedBox.shrink();
    final first = offers.first;
    return Container(
      key: const Key('player.ownershipOffer'),
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
      child: Material(
        color: CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.card),
          onTap: () => context.push(Routes.ownershipOffers),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(CeIcons.of('shield'), size: 20, color: CeColors.primaryDark),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    offers.length == 1
                        ? '${first.fromName} offered you the ownership of ${first.clubName}'
                        : '${offers.length} club ownership offers',
                    style: CeType.listTitle,
                  ),
                ),
                Icon(CeIcons.of('chevron-right'), size: 16, color: CeColors.muted2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
