import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router/routes.dart';
import '../../app/theme/tokens.dart';
import '../../core/utils/validators.dart';
import '../../demo/seed_data.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_surfaces.dart';
import '../../shared/widgets/ce_top_bar.dart';
import '../../shared/widgets/demo_widgets.dart';
import '../auth/widgets/auth_widgets.dart';
import 'join_club_controller.dart';

/// Join a Club — Enter Club Code (prototype `screens.enterClubCode`, :3166).
/// Back returns to Set Up Your Club (fixes the prototype's jump to Continue As).
class EnterClubCodeScreen extends ConsumerStatefulWidget {
  const EnterClubCodeScreen({super.key});

  @override
  ConsumerState<EnterClubCodeScreen> createState() => _EnterClubCodeScreenState();
}

class _EnterClubCodeScreenState extends ConsumerState<EnterClubCodeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    await ref.read(joinClubProvider.notifier).send(_code.text);
    if (!mounted) return;
    setState(() => _sending = false);
    context.go(Routes.waitingApproval);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: const CeTopBar(title: 'Join a Club', fallbackLocation: Routes.chooseOption),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(CeSpace.form, 20, CeSpace.form, CeSpace.form),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CenterBlock(
              icon: 'key',
              title: 'Enter Club Code',
              subtitle: 'Ask your club owner for their club code and enter it below to send a join request',
            ),
            const CeFieldLabel('Club Code', required: true),
            CeTextField(
              fieldKey: const Key('join.code'),
              controller: _code,
              hint: 'e.g. ${SeedData.demoJoinCode}',
              icon: 'key',
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.send,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(10),
                TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
              ],
              validator: CeValidators.clubCode,
              onFieldSubmitted: (_) => _send(),
            ),
            CeButton(label: 'Send Join Request', loading: _sending, onPressed: _send),
            const DemoOnly(
              child: Padding(
                padding: EdgeInsets.only(top: 14),
                child: CeInfoNote(
                  margin: EdgeInsets.zero,
                  text: 'Try club code ${SeedData.demoJoinCode} to explore a pre-built club',
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
