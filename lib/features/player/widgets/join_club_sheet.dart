import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/validators.dart';
import '../../../demo/seed_data.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../membership/join_club_controller.dart';

/// Join Club (Player Dashboard quick action): the existing join-by-code
/// request ([joinClubProvider]) from a sheet. The standalone Join a Club route
/// stays for compatibility; this is a faster entry point with a club preview.
Future<void> showJoinClubSheet(BuildContext context) =>
    showCeSheet<void>(context, builder: (_) => const _JoinClubSheet());

class _JoinClubSheet extends ConsumerStatefulWidget {
  const _JoinClubSheet();

  @override
  ConsumerState<_JoinClubSheet> createState() => _JoinClubSheetState();
}

class _JoinClubSheetState extends ConsumerState<_JoinClubSheet> {
  final _code = TextEditingController();
  ClubCodePreview? _preview;
  bool _looking = false;
  bool _notFound = false;
  bool _sending = false;
  int _lookupSeq = 0;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Looks the code up as soon as it has a valid shape.
  Future<void> _onCode(String value) async {
    final seq = ++_lookupSeq;
    setState(() {
      _preview = null;
      _notFound = false;
      _looking = CeValidators.clubCode(value) == null;
    });
    if (!_looking) return;
    final preview = await ref.read(joinClubProvider.notifier).lookup(value);
    if (!mounted || seq != _lookupSeq) return;
    setState(() {
      _looking = false;
      _preview = preview;
      _notFound = preview == null;
    });
  }

  Future<void> _send(ClubCodePreview club) async {
    setState(() => _sending = true);
    final request = await ref.read(joinClubProvider.notifier).send(club.code);
    if (!mounted) return;
    Navigator.of(context).pop();
    showCeToast(context, 'Join request sent to ${request.clubName}');
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(joinClubProvider);
    if (pending != null && pending.status == JoinRequestStatus.pending) {
      return _PendingRequest(request: pending);
    }
    final account = ref.watch(currentAccountProvider);
    final ownClub = ref.watch(currentClubProvider);
    final club = _preview;
    final member = club != null && (account?.memberships.any((m) => m.clubCode.toUpperCase() == club.code) ?? false);
    final owner = club != null && ownClub?.code.toUpperCase() == club.code.toUpperCase();
    final canSend = club != null && !member && !owner && !_sending;
    final shapeError = _code.text.isEmpty ? null : CeValidators.clubCode(_code.text);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text('Join Club', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      const Text('Enter the club code your club owner shared with you.',
          style: TextStyle(fontSize: 12.5, color: CeColors.muted, height: 1.4)),
      const SizedBox(height: 14),
      const CeFieldLabel('Club Code', required: true),
      CeTextField(
        fieldKey: const Key('joinClub.code'),
        controller: _code,
        hint: 'e.g. ${SeedData.demoJoinCode}',
        icon: 'key',
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          LengthLimitingTextInputFormatter(10),
          TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
        ],
        onChanged: _onCode,
      ),
      if (_looking)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else if (_notFound)
        _Note(key: const Key('joinClub.notFound'), icon: 'x-circle', tone: CeColors.red, text: 'No club found with code ${_code.text}. Check the code and try again.')
      else if (shapeError != null && _code.text.length >= 4)
        _Note(icon: 'info', tone: CeColors.muted, text: shapeError)
      else if (club != null) ...[
        _ClubPreviewCard(club: club),
        if (member) ...[
          const SizedBox(height: 8),
          _Note(icon: 'check-circle', tone: CeColors.primaryDark, text: 'You’re already a member of ${club.name}.'),
        ] else if (owner) ...[
          const SizedBox(height: 8),
          _Note(icon: 'crown', tone: CeColors.primaryDark, text: 'You own ${club.name} — no request needed.'),
        ],
      ],
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: CeButton.soft(label: 'Cancel', onPressed: _sending ? null : () => Navigator.of(context).pop())),
        const SizedBox(width: 8),
        Expanded(
          child: CeButton(
            label: 'Send Join Request',
            loading: _sending,
            onPressed: canSend ? () => _send(club) : null,
          ),
        ),
      ]),
    ]);
  }
}

class _ClubPreviewCard extends StatelessWidget {
  const _ClubPreviewCard({required this.club});
  final ClubCodePreview club;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (club.city != null) club.city!,
      if (club.type != null) club.type!.label,
      if (club.memberCount != null) '${club.memberCount} member${club.memberCount == 1 ? '' : 's'}',
    ];
    return Container(
      key: const Key('joinClub.preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CeColors.mint,
        borderRadius: BorderRadius.circular(CeRadius.row),
        border: Border.all(color: CeColors.mint2),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(CeRadius.md)),
          child: Icon(CeIcons.of('shield'), size: 19, color: CeColors.primaryDark),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(club.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: CeColors.ink)),
            const SizedBox(height: 2),
            Text(details.isEmpty ? 'Club ${club.code}' : '${details.join(' · ')} · ${club.code}',
                style: const TextStyle(fontSize: 11.5, color: CeColors.ink2)),
          ]),
        ),
      ]),
    );
  }
}

/// A request is already waiting: show it instead of sending a duplicate.
class _PendingRequest extends StatelessWidget {
  const _PendingRequest({required this.request});
  final ClubJoinRequest request;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Join Club', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Container(
          key: const Key('joinClub.pending'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: CeColors.amberSoft, borderRadius: BorderRadius.circular(CeRadius.row)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CeIcons.of('hourglass'), size: 18, color: CeColors.amberInk),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your request to join ${request.clubName} (${request.clubCode}) is pending. '
                'The club owner will review it — you can send another request once it’s decided.',
                style: const TextStyle(fontSize: 12.5, color: CeColors.amberInk, height: 1.45, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: CeButton.soft(label: 'Close', onPressed: () => Navigator.of(context).pop())),
          const SizedBox(width: 8),
          Expanded(
            child: CeButton(
              label: 'View Request',
              onPressed: () {
                Navigator.of(context).pop();
                context.go(Routes.waitingApproval);
              },
            ),
          ),
        ]),
      ]);
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.tone, required this.text});
  final String icon;
  final Color tone;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(CeIcons.of(icon), size: 14, color: tone)),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: tone, height: 1.4))),
      ]);
}
