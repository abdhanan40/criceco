import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/media/photo_picker.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_list_sheet.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club_setup/club_setup_controller.dart' show kClubCities;
import '../club_providers.dart';
import '../teams/teams_controller.dart';

/// Club Owner bottom nav → Profile, and sidebar → Edit Club: the club's
/// profile in a sheet, editable in place (name, owner, city, type, founding
/// year, address, email, picture). [editing] opens straight in edit mode.
Future<void> showClubProfileSheet(BuildContext context, {bool editing = false}) =>
    showCeListSheet<void>(context, builder: (_) => _ClubProfileSheet(startEditing: editing));

/// Sidebar → Edit Club.
Future<void> showEditClubSheet(BuildContext context) => showClubProfileSheet(context, editing: true);

class _ClubProfileSheet extends ConsumerStatefulWidget {
  const _ClubProfileSheet({required this.startEditing});
  final bool startEditing;

  @override
  ConsumerState<_ClubProfileSheet> createState() => _ClubProfileSheetState();
}

class _ClubProfileSheetState extends ConsumerState<_ClubProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _owner = TextEditingController();
  final _address = TextEditingController();
  final _email = TextEditingController();
  final _year = TextEditingController();
  String? _city;
  ClubType? _type;
  late bool _editing = widget.startEditing;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_editing) _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _owner, _address, _email, _year]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fills the form from the saved club.
  void _load() {
    final c = ref.read(currentClubProvider);
    if (c == null) return;
    _name.text = c.name;
    _owner.text = c.ownerName ?? ref.read(currentAccountProvider)?.fullName ?? '';
    _address.text = c.address ?? '';
    _email.text = c.email ?? '';
    _year.text = c.establishedYear?.toString() ?? '';
    _city = c.city;
    _type = c.type;
  }

  void _edit() => setState(() {
        _load();
        _editing = true;
      });

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final address = _address.text.trim();
    final email = _email.text.trim();
    final year = int.tryParse(_year.text.trim());
    await ref.read(sessionProvider.notifier).updateClub((c) => c.copyWith(
          name: _name.text.trim(),
          ownerName: _owner.text.trim(),
          city: _city,
          type: _type,
          address: address.isEmpty ? null : address,
          clearAddress: address.isEmpty,
          email: email.isEmpty ? null : email,
          clearEmail: email.isEmpty,
          establishedYear: year,
          clearEstablished: year == null,
        ));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
    });
    showCeToast(context, 'Club profile updated');
  }

  /// Add / change / remove the club picture (saved right away, as on My Club).
  Future<void> _changePicture(Club club) async {
    final change = await choosePhoto(context, ref, title: 'Club picture', hasPhoto: club.logoPath != null);
    if (change == null || !mounted) return;
    await ref.read(sessionProvider.notifier).updateClub((c) => c.withLogo(change.path));
    if (mounted) showCeToast(context, change.path == null ? 'Club picture removed' : 'Club picture updated');
  }

  String? _validateYear(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null; // optional
    final y = int.tryParse(t);
    final now = ref.read(clockProvider).now().year;
    if (y == null || y < 1850 || y > now) return 'Enter a year between 1850 and $now';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final club = ref.watch(currentClubProvider);
    if (club == null) {
      return const CeListSheetFrame(title: 'Club Profile', children: [
        CeEmptyState(icon: 'shield', title: 'No club yet', body: 'Set up your club to see its profile here.'),
      ]);
    }
    final members = ref.watch(clubMembersProvider).value?.length;
    final teams = ref.watch(teamsProvider).value?.length;

    return CeListSheetFrame(
      key: Key(_editing ? 'clubProfile.edit' : 'clubProfile.view'),
      title: _editing ? 'Edit Club' : 'Club Profile',
      actions: [
        if (!_editing)
          TextButton(
            key: const Key('clubProfile.editButton'),
            onPressed: _edit,
            child: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
      ],
      children: [
        // ---- Identity: picture (tap to change), name, code ----
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
          radius: CeRadius.lg,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CeEditablePhoto(
              key: const Key('clubProfile.photo'),
              size: 52,
              semanticLabel: club.logoPath == null ? 'Add club picture' : 'Change club picture',
              onTap: () => _changePicture(club),
              child: CePhotoImage(
                path: club.logoPath,
                size: 52,
                square: true,
                fallback: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.lg)),
                  child: Icon(CeIcons.of('shield'), size: 26, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(club.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: CeType.display, fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 2),
                Text('Club ${club.code} · ${club.city}',
                    style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
              ]),
            ),
          ]),
        ),
        if (_editing) _form() else ..._details(club, members, teams),
      ],
    );
  }

  List<Widget> _details(Club club, int? members, int? teams) {
    Widget v(String? text) => text == null || text.trim().isEmpty
        ? CeSummaryCard.value(context, 'Not added', color: CeColors.muted)
        : CeSummaryCard.value(context, text.trim());
    return [
      const CeSectionHeader('Details'),
      CeSummaryCard(rows: [
        ('Club name', v(club.name)),
        ('Owner', v(club.ownerName ?? ref.watch(currentAccountProvider)?.fullName)),
        ('City', v(club.city)),
        ('Club type', v(club.type.label)),
        ('Established', v(club.establishedYear?.toString())),
        ('Address', v(club.address)),
        ('Email', v(club.email)),
        ('Club code', v(club.code)),
        if (members != null) ('Members', v('$members')),
        if (teams != null) ('Teams', v('$teams')),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
        child: CeButton(label: 'Edit Club Profile', icon: CeIcons.of('edit-3'), onPressed: _edit),
      ),
    ];
  }

  Widget _form() => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CeFieldLabel('Club Name', required: true),
            CeTextField(
              fieldKey: const Key('clubProfile.name'),
              controller: _name,
              hint: 'e.g., Lahore Lions CC',
              icon: 'shield',
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (v) => CeValidators.required(v, 'Club name'),
            ),
            const CeFieldLabel('Owner Name', required: true),
            CeTextField(
              fieldKey: const Key('clubProfile.owner'),
              controller: _owner,
              hint: 'Owner name',
              icon: 'user',
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (v) => CeValidators.required(v, 'Owner name'),
            ),
            const CeFieldLabel('City', required: true),
            CeSelectField<String>(
              sheetTitle: 'City',
              itemIcon: 'building-2',
              fieldKey: const Key('clubProfile.city'),
              items: kClubCities,
              value: _city,
              labelOf: (c) => c,
              hint: 'Select city',
              icon: 'building-2',
              validator: (v) => v == null ? 'Please select a city' : null,
              onChanged: (v) => setState(() => _city = v),
            ),
            const CeFieldLabel('Club Type', required: true),
            CeSelectField<ClubType>(
              sheetTitle: 'Club Type',
              itemIcon: 'tag',
              fieldKey: const Key('clubProfile.type'),
              items: ClubType.values,
              value: _type,
              labelOf: (t) => t.label,
              hint: 'Select club type',
              icon: 'tag',
              validator: (v) => v == null ? 'Please select a club type' : null,
              onChanged: (v) => setState(() => _type = v),
            ),
            const CeFieldLabel('Established (year)'),
            CeTextField(
              fieldKey: const Key('clubProfile.year'),
              controller: _year,
              hint: 'e.g. 2015',
              icon: 'calendar',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              textInputAction: TextInputAction.next,
              validator: _validateYear,
            ),
            const CeFieldLabel('Address'),
            CeTextField(
              fieldKey: const Key('clubProfile.address'),
              controller: _address,
              hint: 'Mian Mir Road, Lahore',
              icon: 'map-pin',
              textCapitalization: TextCapitalization.words,
              keyboardType: TextInputType.streetAddress,
              textInputAction: TextInputAction.next,
            ),
            const CeFieldLabel('Email'),
            CeTextField(
              fieldKey: const Key('clubProfile.email'),
              controller: _email,
              hint: 'club@example.com',
              icon: 'mail',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              validator: (v) => CeValidators.email(v, optional: true),
            ),
            const SizedBox(height: 12),
            CeButton(label: 'Save Changes', loading: _saving, onPressed: _saving ? null : _save),
            const SizedBox(height: 10),
            CeButton.soft(
              label: 'Cancel',
              onPressed: _saving
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      if (widget.startEditing) {
                        Navigator.of(context).pop();
                      } else {
                        setState(() => _editing = false);
                      }
                    },
            ),
          ]),
        ),
      );
}
