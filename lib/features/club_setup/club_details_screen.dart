import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../auth/widgets/auth_widgets.dart';
import 'club_setup_controller.dart';

final _groundsProvider = FutureProvider<List<Ground>>((ref) => ref.read(groundRepositoryProvider).grounds());

/// Club Details — step 2 (prototype `screens.clubDetails`, :4143). "Create
/// Club" creates the club, grants the Club Owner profile and opens the
/// Club Owner Dashboard.
class ClubDetailsScreen extends ConsumerStatefulWidget {
  const ClubDetailsScreen({super.key});

  @override
  ConsumerState<ClubDetailsScreen> createState() => _ClubDetailsScreenState();
}

class _ClubDetailsScreenState extends ConsumerState<ClubDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _email;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: ref.read(clubSetupProvider).email);
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
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
    final draft = ref.read(clubSetupProvider);
    if (draft.name.trim().isEmpty || draft.city == null) {
      // Step 1 incomplete (e.g. deep link) — send the user back to fix it.
      context.go(Routes.createClub);
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _creating = true);
    try {
      await ref.read(clubSetupProvider.notifier).createClub();
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

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const CeTopBar(title: 'Club Details', fallbackLocation: Routes.createClub),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(CeSpace.form),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CenterBlock(
              icon: 'shield',
              title: draft.name.trim().isEmpty ? 'Your Club' : draft.name.trim(),
              subtitle: 'Just a few more details',
            ),
            const CeFieldLabel('Club Email (optional)'),
            CeTextField(
              fieldKey: const Key('club.email'),
              controller: _email,
              hint: 'club@example.com',
              icon: 'mail',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              validator: (v) => CeValidators.email(v, optional: true),
              onChanged: (v) => setup.update((d) => d.copyWith(email: v)),
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
            const CeFieldLabel('Home Ground'),
            ground == null
                ? CeButton.soft(
                    label: 'Add Home Ground', icon: CeIcons.of('plus'), onPressed: () => _pickGround(grounds))
                : CeButton(label: ground.name, icon: CeIcons.of('flag'), onPressed: () => _pickGround(grounds)),
            const SizedBox(height: 20),
            if (_error != null) CeErrorBanner(_error!),
            CeButton(label: 'Create Club', loading: _creating, onPressed: _create),
          ]),
        ),
      ),
    );
  }
}
