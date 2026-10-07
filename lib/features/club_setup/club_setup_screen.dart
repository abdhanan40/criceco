import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../shared/media/photo_picker.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../auth/widgets/auth_widgets.dart';
import 'club_setup_controller.dart';

final _groundsProvider = FutureProvider<List<Ground>>((ref) => ref.read(groundRepositoryProvider).grounds());

/// Club Setup Details — the Club Owner path of Role Selection (one screen,
/// replacing Set Up Your Club → Create Club → Club Details): Club Name,
/// Club Picture, Owner Name, Address, City, Club Type and Home Ground
/// (Yes / No). "Create Club" grants the Club Owner profile and opens the
/// Club Owner Dashboard. Also reached from the drawer's "Set up Club Owner
/// profile".
class ClubSetupScreen extends ConsumerStatefulWidget {
  const ClubSetupScreen({super.key});

  @override
  ConsumerState<ClubSetupScreen> createState() => _ClubSetupScreenState();
}

class _ClubSetupScreenState extends ConsumerState<ClubSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _owner;
  late final TextEditingController _address;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final d = ref.read(clubSetupProvider);
    _name = TextEditingController(text: d.name);
    _owner = TextEditingController(text: d.ownerName);
    _address = TextEditingController(text: d.address);
  }

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    _address.dispose();
    super.dispose();
  }

  /// Back: Role Selection (pushed from there), else where the user came from.
  void _back() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    final role = ref.read(activeRoleProvider);
    context.go(role == null ? Routes.roleSelection : Routes.home(role));
  }

  Future<void> _pickGround(List<Ground> grounds) async {
    final selected = ref.read(clubSetupProvider).homeGroundId;
    final id = await showCeSheet<String>(
      context,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Home Ground', style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 10),
        for (final g in grounds)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(CeIcons.of('flag'), size: 18, color: CeColors.primaryDark),
            title: Text(g.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(g.city, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            trailing: g.id == selected ? Icon(CeIcons.of('check'), size: 18, color: CeColors.primary) : null,
            onTap: () => Navigator.of(ctx).pop(g.id),
          ),
      ]),
    );
    if (id != null) ref.read(clubSetupProvider.notifier).update((d) => d.copyWith(homeGroundId: id));
  }

  Future<void> _create() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _creating = true);
    try {
      await ref.read(clubSetupProvider.notifier).createClub();
      // `go` replaces the stack: Back from the dashboard never reopens setup.
      if (mounted) context.go(Routes.clubHome);
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't create your club. Please try again.");
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(clubSetupProvider);
    final setup = ref.read(clubSetupProvider.notifier);
    final grounds = ref.watch(_groundsProvider).value ?? const <Ground>[];
    final ground = grounds.where((g) => g.id == draft.homeGroundId).firstOrNull;

    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: CeColors.bg,
        appBar: CeTopBar(title: 'Club Setup', onBack: _back),
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
              CeSpace.form, CeSpace.form, CeSpace.form, CeSpace.form + MediaQuery.viewInsetsOf(context).bottom),
          child: Form(
            key: _formKey,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const AuthHeading(
                title: 'Set up your club',
                subtitle: 'A few details and your Club Owner dashboard is ready.',
                large: true,
              ),
              const SizedBox(height: 22),
              Center(
                child: CePhotoPicker(
                  title: 'Club picture',
                  square: true,
                  placeholderIcon: 'shield',
                  caption: draft.hasLogo
                      ? 'Looking good. Tap the picture to change it.'
                      : 'Optional · a square logo or photo works best.',
                  imagePath: draft.logoPath,
                  semanticLabel: draft.hasLogo ? 'Change club picture' : 'Add club picture',
                  // Gallery / camera (and Remove once set) — the same picker as My Club.
                  onTap: () async {
                    final change = await choosePhoto(context, ref, title: 'Club picture', hasPhoto: draft.hasLogo);
                    if (change != null) {
                      setup.update((d) => d.copyWith(logoPath: change.path, clearLogo: change.path == null));
                    }
                  },
                ),
              ),
              const SizedBox(height: 22),
              const CeFieldLabel('Club Name', required: true),
              CeTextField(
                fieldKey: const Key('club.name'),
                controller: _name,
                hint: 'e.g., Lahore Lions CC',
                icon: 'shield',
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: CeValidators.nameMaxLength,
                validator: (v) => CeValidators.entityName(v, 'Club name'),
                onChanged: (v) => setup.update((d) => d.copyWith(name: v)),
              ),
              const CeFieldLabel('Owner Name', required: true),
              CeTextField(
                fieldKey: const Key('club.owner'),
                controller: _owner,
                hint: 'Owner name',
                icon: 'user',
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: CeValidators.nameMaxLength,
                validator: (v) => CeValidators.personName(v, 'Owner name'),
                onChanged: (v) => setup.update((d) => d.copyWith(ownerName: v)),
              ),
              const CeFieldLabel('Address', required: true),
              CeTextField(
                fieldKey: const Key('club.address'),
                controller: _address,
                hint: 'Mian Mir Road, Lahore',
                icon: 'map-pin',
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                keyboardType: TextInputType.streetAddress,
                validator: (v) => CeValidators.required(v, 'Address'),
                onChanged: (v) => setup.update((d) => d.copyWith(address: v)),
              ),
              const CeFieldLabel('City', required: true),
              CeSelectField<String>(
                sheetTitle: 'City',
                itemIcon: 'building-2',
                fieldKey: const Key('club.city'),
                items: kClubCities,
                value: draft.city,
                labelOf: (c) => c,
                hint: 'Select city',
                icon: 'building-2',
                validator: (v) => v == null ? 'Please select a city' : null,
                onChanged: (v) => setup.update((d) => d.copyWith(city: v)),
              ),
              const CeFieldLabel('Club Type', required: true),
              // Reference club-type grid: one tap, no picker sheet.
              FormField<ClubType>(
                key: const Key('club.type'),
                validator: (_) => ref.read(clubSetupProvider).type == null ? 'Please select a club type' : null,
                builder: (field) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  CeChoiceGroup<ClubType>(
                    columns: 2,
                    values: ClubType.values,
                    selected: draft.type,
                    labelOf: (t) => t.label,
                    onSelected: (v) {
                      setup.update((d) => d.copyWith(type: v));
                      if (field.hasError) WidgetsBinding.instance.addPostFrameCallback((_) => field.validate());
                    },
                  ),
                  CeInlineError(field.errorText),
                ]),
              ),
              const SizedBox(height: 18),
              // FormField so the Yes / No answer (and the ground for Yes)
              // validates inline with the rest of the form.
              FormField<bool>(
                key: const Key('club.homeGround'),
                validator: (_) {
                  final d = ref.read(clubSetupProvider);
                  if (d.hasHomeGround == null) return 'Please choose Yes or No';
                  if (d.hasHomeGround! && d.homeGroundId == null) return 'Please select your home ground';
                  return null;
                },
                // Reference home-ground card: question + Yes / No segment, then
                // the ground picker for Yes.
                builder: (field) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(CeRadius.card),
                      border: Border.all(color: field.hasError ? CeColors.redBorder : CeColors.line2, width: 1.5),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Home ground *', style: CeType.listTitle),
                            const SizedBox(height: 3),
                            Text('Do you have a home ground?', style: CeType.bodySmall),
                          ]),
                        ),
                        const SizedBox(width: 12),
                        _YesNo(
                          value: draft.hasHomeGround,
                          onChanged: (v) {
                            setup.update((d) => d.copyWith(hasHomeGround: v));
                            if (field.hasError) WidgetsBinding.instance.addPostFrameCallback((_) => field.validate());
                          },
                        ),
                      ]),
                      if (draft.hasHomeGround == true) ...[
                        const SizedBox(height: 12),
                        CeButton.soft(
                          label: ground?.name ?? 'Select Home Ground',
                          icon: CeIcons.of(ground == null ? 'plus' : 'flag'),
                          onPressed: () async {
                            await _pickGround(grounds);
                            if (field.hasError) field.validate();
                          },
                        ),
                      ],
                    ]),
                  ),
                  CeInlineError(field.errorText),
                ]),
              ),
              const SizedBox(height: 20),
              if (_error != null) CeErrorBanner(_error!),
              CeButton(label: 'Create Club', loading: _creating, onPressed: _creating ? null : _create),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Yes / No segment (reference home-ground toggle: mint track, 34 px
/// options, the chosen one filled #12544F). Nothing is chosen at first.
class _YesNo extends StatelessWidget {
  const _YesNo({required this.value, required this.onChanged});
  final bool? value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(bool v, String label) {
      final on = value == v;
      return Semantics(
        button: true,
        selected: on,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(v),
          child: AnimatedContainer(
            duration: CeMotion.base,
            width: 52,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? CeColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(label, style: CeType.buttonSmall.copyWith(color: on ? Colors.white : CeColors.muted)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.md)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [option(true, 'Yes'), option(false, 'No')]),
    );
  }
}
