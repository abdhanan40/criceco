import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_modules.dart';

/// The Firebase project the app receives push through (M3 P5), as built:
///   --dart-define=FCM_API_KEY=… --dart-define=FCM_APP_ID=…
///   --dart-define=FCM_SENDER_ID=… --dart-define=FCM_PROJECT_ID=…
/// The four values are the PUBLIC identifiers from the Firebase console
/// (Android app: google-services.json — api_key, mobilesdk_app_id,
/// project_number, project_id); nothing secret. No google-services.json is
/// committed and no Gradle plugin is needed. Without them the app has no
/// push and behaves exactly as before.
class PushConfig {
  const PushConfig({
    required this.apiKey,
    required this.appId,
    required this.senderId,
    required this.projectId,
  });

  static const fromEnvironment = PushConfig(
    apiKey: String.fromEnvironment('FCM_API_KEY'),
    appId: String.fromEnvironment('FCM_APP_ID'),
    senderId: String.fromEnvironment('FCM_SENDER_ID'),
    projectId: String.fromEnvironment('FCM_PROJECT_ID'),
  );

  static const none = PushConfig(
    apiKey: '',
    appId: '',
    senderId: '',
    projectId: '',
  );

  final String apiKey;
  final String appId;
  final String senderId;
  final String projectId;

  bool get isComplete =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      senderId.isNotEmpty &&
      projectId.isNotEmpty;
}

/// The build's Firebase settings, overridden in tests.
final pushConfigProvider = Provider<PushConfig>(
  (ref) => PushConfig.fromEnvironment,
);

/// Android only for now (iOS needs APNs, later).
final pushPlatformSupportedProvider = Provider<bool>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
);

/// `true` when this build can receive push: the server inbox is live
/// ([notificationsBackendLiveProvider]), the Firebase settings are complete,
/// and the platform is Android.
final pushAvailableProvider = Provider<bool>(
  (ref) =>
      ref.watch(notificationsBackendLiveProvider) &&
      ref.watch(pushConfigProvider).isComplete &&
      ref.watch(pushPlatformSupportedProvider),
);
