import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../demo/seed_data.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../../shared/widgets/demo_widgets.dart';
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
        backgroundColor: Colors.white,
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
              ),
              const SizedBox(height: 18),
              Center(
                child: CePhotoPicker(
                  placeholderIcon: 'shield',
                  caption: 'Club picture (optional)',
                  hasPhoto: draft.hasLogo,
                  initial: draft.name.trim().isEmpty ? null : draft.name.trim()[0].toUpperCase(),
                  semanticLabel: draft.hasLogo ? 'Remove club picture' : 'Add club picture',
                  onTap: () => setup.update((d) => d.copyWith(hasLogo: !d.hasLogo)),
                ),
              ),
              const SizedBox(height: 18),
              const CeFieldLabel('Club Name', required: true),
              CeTextField(
                fieldKey: const Key('club.name'),
                controller: _name,
                hint: 'e.g., Lahore Lions CC',
                icon: 'shield',
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (v) => CeValidators.required(v, 'Club name'),
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
                validator: (v) => CeValidators.required(v, 'Owner name'),
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
              CeSelectField<ClubType>(
                sheetTitle: 'Club Type',
                itemIcon: 'tag',
                fieldKey: const Key('club.type'),
                items: ClubType.values,
                value: draft.type,
                labelOf: (t) => t.label,
                hint: 'Select club type',
                icon: 'tag',
                validator: (v) => v == null ? 'Please select a club type' : null,
                onChanged: (v) => setup.update((d) => d.copyWith(type: v)),
              ),
              const CeFieldLabel('Do you have a home ground?', required: true),
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
                builder: (field) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  CeChoiceGroup<bool>(
                    values: const [true, false],
                    selected: draft.hasHomeGround,
                    labelOf: (v) => v ? 'Yes' : 'No',
                    onSelected: (v) {
                      setup.update((d) => d.copyWith(hasHomeGround: v));
                      if (field.hasError) WidgetsBinding.instance.addPostFrameCallback((_) => field.validate());
                    },
                  ),
                  if (draft.hasHomeGround == true) ...[
                    const SizedBox(height: 10),
                    ground == null
                        ? CeButton.soft(
                            label: 'Select Home Ground',
                            icon: CeIcons.of('plus'),
                            onPressed: () async {
                              await _pickGround(grounds);
                              if (field.hasError) field.validate();
                            },
                          )
                        : CeButton(
                            label: ground.name,
                            icon: CeIcons.of('flag'),
                            onPressed: () => _pickGround(grounds),
                          ),
                  ],
                  CeInlineError(field.errorText),
                ]),
              ),
              const SizedBox(height: 20),
              if (_error != null) CeErrorBanner(_error!),
              CeButton(label: 'Create Club', loading: _creating, onPressed: _creating ? null : _create),
              // Membership by code lived beside club creation before; kept
              // reachable here (it adds a membership, never Club Owner).
              CeSwitchLine(
                prompt: 'Joining an existing club?',
                action: 'Enter club code',
                onTap: () => context.push('${Routes.enterClubCode}?from=clubSetup'),
              ),
              const DemoOnly(
                child: CeInfoNote(
                  margin: EdgeInsets.only(top: 4),
                  text: 'Try club code ${SeedData.demoJoinCode} to explore a pre-built club',
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
