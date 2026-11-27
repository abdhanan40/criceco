import 'dart:typed_data';

import 'package:image_picker/image_picker.dart' show XFile;

import '../../core/utils/media_ref.dart';
import '../repositories/repositories.dart';
import 'supabase_error_mapper.dart';
import 'supabase_gateways.dart';

/// Reads a picked picture file on this device (the photo picker's path;
/// on the web a blob URL). `null` when it is gone or can't be read.
class LocalMediaFiles {
  const LocalMediaFiles();

  Future<Uint8List?> read(String path) async {
    try {
      return await XFile(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

/// Uploads profile and club pictures to Storage (M5, migration 31) and
/// deletes replaced ones. Checks the picture on this device first, so a
/// file the buckets would refuse never leaves the phone: at most 2 MB, and a
/// JPEG, PNG or WebP by its content (not its name). The object is named
/// `<folder>/<uuid>.<ext>`.
class MediaUploader {
  MediaUploader({
    required this.gateway,
    this.files = const LocalMediaFiles(),
    String Function()? newId,
  }) : newId = newId ?? MediaRef.newObjectId;

  final MediaGateway gateway;
  final LocalMediaFiles files;
  final String Function() newId;

  /// Uploads the picture at [localPath] into [bucket]/[folder]; returns the
  /// new object path. Throws [MediaException] (or another
  /// [AccountException]) when it can't.
  Future<String> upload({
    required String bucket,
    required String folder,
    required String localPath,
  }) async {
    final bytes = await files.read(localPath);
    if (bytes == null || bytes.isEmpty) throw const MediaException.unreadable();
    if (bytes.length > MediaRef.maxUploadBytes) {
      throw const MediaException.tooLarge();
    }
    final type = MediaRef.imageTypeOf(bytes);
    if (type == null) throw const MediaException.unsupported();
    // Migration 31: lowercase, exactly one folder level, a known extension.
    final path = '${folder.toLowerCase()}/${newId().toLowerCase()}.${type.ext}';
    await call(
      () => gateway.upload(bucket, path, bytes, contentType: type.mime),
    );
    return path;
  }

  /// Deletes a replaced picture — best effort: a failure leaves an unused
  /// object behind, never an error for the user.
  Future<void> removeQuietly(String bucket, String? path) async {
    if (path == null) return;
    try {
      await gateway.remove(bucket, [path]);
    } on GatewayException {
      // Offline or refused: the object stays unused.
    }
  }

  /// Runs a gateway call, turning its failures into app errors.
  static Future<T> call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on GatewayException catch (e) {
      throw SupabaseErrorMapper.map(e);
    }
  }
}
