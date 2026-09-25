import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

/// "03129020000" → "0312 9020000" (the account's stored display form).
String formatPkPhone(String canonical) => '${canonical.substring(0, 4)} ${canonical.substring(4)}';

/// Edit Profile (prototype `screens.editProfile`, :8223). The fields are
/// bound and saved to the account (approved fix), so the name, city and
/// phone update everywhere they appear: profile, drawer, dashboards.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final UserAccount? _account = ref.read(currentAccountProvider);
  late final _name = TextEditingController(text: _account?.fullName ?? '');
  late final _phone = TextEditingController(text: _account?.phone ?? '');
  late String? _city = kPakistanCities.contains(_account?.city) ? _account?.city : null;
  bool _saving = false;

  /// Accounts created with an email may not have a phone number yet.
  bool get _phoneRequired => _account?.contactMethod != ContactMethod.email;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final phone = _phone.text.trim().isEmpty ? null : formatPkPhone(CeValidators.normalizePkPhone(_phone.text)!);
    await ref.read(sessionProvider.notifier).updateAccount(
          (a) => a.copyWith(fullName: _name.text.trim(), city: _city, phone: phone),
        );
    // A player listed as available is shown to clubs with the new details.
    final availability = ref.read(playerAvailabilityProvider);
    if (availability.openToOffers) await ref.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
    if (!mounted) return;
    // Prototype `ceSaved`: the destination + a toast, never a toast alone.
    showCeToast(context, 'Profile updated');
    context.go(Routes.playerProfile);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const CeTopBar(title: 'Edit profile', fallbackLocation: Routes.playerProfile),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(CeSpace.form, 18, CeSpace.form, 28 + MediaQuery.viewInsetsOf(context).bottom),
          child: Form(
            key: _formKey,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const CeFieldLabel('Full name', required: true),
              CeTextField(
                fieldKey: const Key('edit.name'),
                controller: _name,
                hint: 'Muhammad Ali',
                icon: 'user',
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                validator: CeValidators.personName,
              ),
              const CeFieldLabel('City', required: true),
              CeSelectField<String>(
                fieldKey: const Key('edit.city'),
                items: kPakistanCities,
                value: _city,
                labelOf: (c) => c,
                onChanged: (c) => setState(() => _city = c),
                sheetTitle: 'City',
                hint: 'Select city',
                icon: 'map-pin',
                itemIcon: 'building-2',
                validator: (c) => c == null ? 'Please select a city' : null,
              ),
              CeFieldLabel('Phone', required: _phoneRequired),
              CeTextField(
                fieldKey: const Key('edit.phone'),
                controller: _phone,
                hint: '03XX-XXXXXXX',
                icon: 'phone',
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.telephoneNumber],
                validator: (v) => (!_phoneRequired && (v == null || v.trim().isEmpty)) ? null : CeValidators.pkPhone(v),
                onFieldSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 6),
              CeButton(label: 'Save Changes', loading: _saving, onPressed: _saving ? null : _save),
            ]),
          ),
        ),
      ),
    );
  }
}
