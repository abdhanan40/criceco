import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_top_bar.dart';
import 'onboarding_controller.dart';
import 'widgets/auth_widgets.dart';

/// Playing Style (prototype `screens.roleDetails`, :3064). Step 3 of 3.
/// Blocks and their order depend on the role chosen in Step 2.
class PlayingStyleScreen extends ConsumerStatefulWidget {
  const PlayingStyleScreen({super.key});

  @override
  ConsumerState<PlayingStyleScreen> createState() => _PlayingStyleScreenState();
}

class _PlayingStyleScreenState extends ConsumerState<PlayingStyleScreen> {
  bool _showErrors = false;
  bool _saving = false;

  Future<void> _save() async {
    final d = ref.read(onboardingProvider);
    // Prototype rule: both styles are required for every role.
    if (d.battingStyle == null || d.bowlingStyle == null) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() => _saving = true);
    await ref.read(onboardingProvider.notifier).savePlayingStyleAndFinish();
    if (mounted) context.go(Routes.continueAs);
  }

  Future<void> _skip() async {
    await ref.read(onboardingProvider.notifier).skip();
    if (mounted) context.go(Routes.continueAs);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingProvider);
    final notifier = ref.read(onboardingProvider.notifier);
    final role = draft.role;

    Widget block(PlayingStyleBlock b) => switch (b) {
          PlayingStyleBlock.batting => _StyleBlock(
              label: 'Batting Style',
              error: _showErrors && draft.battingStyle == null ? 'Please select your batting style' : null,
              child: CeChoiceGroup<BattingStyle>(
                values: BattingStyle.values,
                selected: draft.battingStyle,
                labelOf: (s) => s.label,
                onSelected: notifier.setBattingStyle,
              ),
            ),
          PlayingStyleBlock.bowling => _StyleBlock(
              label: 'Bowling Style',
              error: _showErrors && draft.bowlingStyle == null ? 'Please select your bowling style' : null,
              child: CeChoiceGroup<BowlingStyle>(
                values: BowlingStyle.values,
                selected: draft.bowlingStyle,
                labelOf: (s) => s.label,
                onSelected: notifier.setBowlingStyle,
              ),
            ),
          PlayingStyleBlock.wicketkeeper => _StyleBlock(
              label: 'Also a Wicketkeeper?',
              required: false,
              child: draft.isWicketkeeper
                  ? CeButton(label: 'Wicketkeeper', icon: CeIcons.of('check'), onPressed: notifier.toggleWicketkeeper)
                  : CeButton.soft(
                      label: 'Mark as Wicketkeeper', icon: CeIcons.of('hand'), onPressed: notifier.toggleWicketkeeper),
            ),
        };

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: CeTopBar(
        title: 'Playing Style',
        fallbackLocation: Routes.completeProfile,
        actions: [TextButton(onPressed: _skip, child: const Text('Skip', style: TextStyle(fontWeight: FontWeight.w600)))],
      ),
      body: Column(children: [
        CeStepProgress(value: 0.9, label: 'Step 3 of 3 — ${role?.label ?? 'Player'}'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(CeSpace.form, 14, CeSpace.form, CeSpace.form),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AuthHeading(
                title: 'Tell us how you play',
                subtitle: role == null
                    ? 'Choose your role first so we can show the right options.'
                    : 'As a ${role.label}, this helps clubs match you to the right spot.',
              ),
              const SizedBox(height: 4),
              if (role == null) ...[
                const SizedBox(height: 18),
                CeButton.soft(label: 'Choose your role', onPressed: () => context.go(Routes.completeProfile)),
              ] else ...[
                for (final b in draft.styleBlocks) block(b),
                if (_showErrors && (draft.battingStyle == null || draft.bowlingStyle == null))
                  const Padding(padding: EdgeInsets.only(top: 12), child: CeErrorBanner('Please select both styles')),
                const SizedBox(height: 20),
                CeButton(label: 'Save Profile', loading: _saving, onPressed: _save),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _StyleBlock extends StatelessWidget {
  const _StyleBlock({required this.label, required this.child, this.error, this.required = true});
  final String label;
  final Widget child;
  final String? error;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CeFieldLabel(label, required: required),
          child,
          CeInlineError(error),
        ]),
      );
}
