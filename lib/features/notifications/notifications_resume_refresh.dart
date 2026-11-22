import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/session/role_controller.dart';
import 'server_inbox_controller.dart';

/// Refreshes the active role's server inbox when the app comes back to the
/// foreground (D12), so the bell badge and an open inbox show what arrived
/// meanwhile. Only an inbox already loaded is refreshed (no extra request
/// otherwise), and only with the notifications switch; a failure is silent —
/// what was shown stays.
class NotificationsResumeRefresh extends ConsumerStatefulWidget {
  const NotificationsResumeRefresh({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<NotificationsResumeRefresh> createState() =>
      _NotificationsResumeRefreshState();
}

class _NotificationsResumeRefreshState
    extends ConsumerState<NotificationsResumeRefresh> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _resumed);
  }

  void _resumed() {
    if (!mounted || !ref.read(notificationsBackendLiveProvider)) return;
    final role = ref.read(activeRoleProvider);
    if (role == null || !ref.exists(serverInboxProvider(role))) return;
    ref
        .read(serverInboxProvider(role).notifier)
        .refresh()
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
