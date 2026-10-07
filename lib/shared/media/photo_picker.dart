import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme/tokens.dart';
import '../widgets/ce_feedback.dart';
import '../widgets/ce_icons.dart';

enum PhotoSource { gallery, camera }

/// Picks a picture on the device and returns its local path, or `null` when
/// the user backs out. Behind [photoPickerProvider] so tests can swap it.
abstract interface class PhotoPicker {
  Future<String?> pick(PhotoSource source);
}

/// The platform photo picker / camera (`image_picker`). The image is scaled
/// down to avatar size so a large photo doesn't sit in memory.
/// A picked picture that can't be used; [message] is shown to the user.
class PhotoRejected implements Exception {
  const PhotoRejected(this.message);
  final String message;
}

class DevicePhotoPicker implements PhotoPicker {
  const DevicePhotoPicker();

  /// Largest picture accepted (after the picker's own down-scaling).
  static const maxBytes = 10 * 1024 * 1024;

  @override
  Future<String?> pick(PhotoSource source) async {
    final file = await ImagePicker().pickImage(
      source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return null;
    // An empty or oversized file (e.g. a corrupt pick) is rejected.
    final bytes = await file.length();
    if (bytes == 0) throw const PhotoRejected("That picture couldn't be read. Try another one.");
    if (bytes > maxBytes) throw const PhotoRejected('That picture is too large. Choose one under 10 MB.');
    return file.path;
  }
}

final photoPickerProvider = Provider<PhotoPicker>((ref) => const DevicePhotoPicker());

/// Outcome of [choosePhoto]: a new picture ([path]) or removal (`null`).
class PhotoChange {
  const PhotoChange.set(String this.path);
  const PhotoChange.remove() : path = null;
  final String? path;
}

/// Add / change picture: Gallery, Camera, and Remove when one is set.
/// Resolves to `null` when nothing changed (cancelled, or the picker failed —
/// the user is told why, e.g. missing photo permission).
Future<PhotoChange?> choosePhoto(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required bool hasPhoto,
}) async {
  final action = await showCeActionSheet(context, title: title, actions: [
    const CeSheetAction(icon: 'image', label: 'Choose from gallery', id: 'gallery'),
    const CeSheetAction(icon: 'camera', label: 'Take a photo', id: 'camera'),
    if (hasPhoto) const CeSheetAction(icon: 'trash-2', label: 'Remove picture', id: 'remove'),
  ]);
  if (action == null || !context.mounted) return null;
  if (action == 'remove') {
    // Removing can't be undone, so it asks first; Cancel keeps the picture.
    final ok = await showCeConfirmSheet(
      context,
      title: 'Remove picture?',
      body: 'Your current picture will be removed.',
      confirmLabel: 'Remove',
      destructive: true,
      icon: 'trash-2',
    );
    return ok ? const PhotoChange.remove() : null;
  }
  try {
    final path = await ref.read(photoPickerProvider).pick(action == 'camera' ? PhotoSource.camera : PhotoSource.gallery);
    return path == null ? null : PhotoChange.set(path);
  } on PhotoRejected catch (e) {
    if (context.mounted) showCeToast(context, e.message);
  } on PlatformException catch (e) {
    if (context.mounted) {
      final denied = e.code.contains('denied') || e.code.contains('access');
      showCeToast(
        context,
        denied
            ? 'CricEco can’t access your ${action == 'camera' ? 'camera' : 'photos'}. Allow access in Settings and try again.'
            : 'Couldn’t open the picture. Please try again.',
      );
    }
  } catch (_) {
    if (context.mounted) showCeToast(context, 'Couldn’t open the picture. Please try again.');
  }
  return null;
}

/// A picked picture clipped to a circle (or rounded square), falling back
/// to [fallback] when there is no picture or the file can't be read.
class CePhotoImage extends StatelessWidget {
  const CePhotoImage({
    super.key,
    required this.path,
    required this.size,
    required this.fallback,
    this.square = false,
    this.radius = CeRadius.lg,
  });

  final String? path;
  final double size;
  final Widget fallback;

  /// Rounded square (club picture, corner [radius]) instead of a circle.
  final bool square;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (path == null) return fallback;
    final image = Image.file(
      File(path!),
      key: ValueKey(path),
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
    return square
        ? ClipRRect(borderRadius: BorderRadius.circular(radius), child: image)
        : ClipOval(child: image);
  }
}

/// Small camera badge on an editable picture.
class CePhotoEditBadge extends StatelessWidget {
  const CePhotoEditBadge({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: CeColors.primaryDark,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Icon(CeIcons.of('camera'), size: size * 0.5, color: Colors.white),
      );
}

/// A tappable picture with the camera badge: opens [choosePhoto] via [onTap].
class CeEditablePhoto extends StatelessWidget {
  const CeEditablePhoto({
    super.key,
    required this.size,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
  });

  final double size;
  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true, // its own node, not merged into the hero text
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: size + 4,
            height: size + 4,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(left: 0, top: 0, width: size, height: size, child: child),
              const Positioned(right: 0, bottom: 0, child: CePhotoEditBadge()),
            ]),
          ),
        ),
      );
}
