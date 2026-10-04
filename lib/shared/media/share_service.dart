import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Hands text (and optionally a picture) to the platform share sheet.
/// Behind [shareServiceProvider] so tests can swap it.
abstract interface class ShareService {
  /// `false` when sharing isn't available on this device.
  Future<bool> share({required String text, String? subject, String? imagePath});
}

/// The native share sheet (`share_plus`).
class DeviceShareService implements ShareService {
  const DeviceShareService();

  @override
  Future<bool> share({required String text, String? subject, String? imagePath}) async {
    final withImage = imagePath != null && File(imagePath).existsSync();
    final result = await SharePlus.instance.share(ShareParams(
      text: text,
      subject: subject,
      files: withImage ? [XFile(imagePath)] : null,
    ));
    return result.status != ShareResultStatus.unavailable;
  }
}

final shareServiceProvider = Provider<ShareService>((ref) => const DeviceShareService());
