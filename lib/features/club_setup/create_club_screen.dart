import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'club_setup_controller.dart';

/// Create Club — step 1 (prototype `screens.createClub`, :4087).
class CreateClubScreen extends ConsumerStatefulWidget {
  const CreateClubScreen({super.key});

  @override
  ConsumerState<CreateClubScreen> createState() => _CreateClubScreenState();
}

class _CreateClubScreenState extends ConsumerState<CreateClubScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _owner;
  late final TextEditingController _address;

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

  void _continue() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    context.go(Routes.clubDetails);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(clubSetupProvider);
    final setup = ref.read(clubSetupProvider.notifier);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const CeTopBar(title: 'Create Club', fallbackLocation: Routes.chooseOption),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(CeSpace.form),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: CePhotoPicker(
                placeholderIcon: 'shield',
                caption: 'Club logo (optional)',
                hasPhoto: draft.hasLogo,
                initial: draft.name.trim().isEmpty ? null : draft.name.trim()[0].toUpperCase(),
                semanticLabel: draft.hasLogo ? 'Remove club logo' : 'Add club logo',
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
            const CeFieldLabel('Owner Name'),
            CeTextField(
              fieldKey: const Key('club.owner'),
              controller: _owner,
              hint: 'Owner name',
              icon: 'user',
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (v) => setup.update((d) => d.copyWith(ownerName: v)),
            ),
            const CeFieldLabel('Address'),
            CeTextField(
              fieldKey: const Key('club.address'),
              controller: _address,
              hint: 'Mian Mir Road, Lahore',
              icon: 'map-pin',
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              keyboardType: TextInputType.streetAddress,
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
            const SizedBox(height: 6),
            CeButton(label: 'Continue', onPressed: _continue),
          ]),
        ),
      ),
    );
  }
}
