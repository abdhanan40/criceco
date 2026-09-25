import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../core/enums/enums.dart';
import 'ce_indicators.dart';

/// Colour + icon per availability status (prototype `availStatusMeta`).
(Color, String) availabilityStyle(PlayerAvailability s) => switch (s) {
      PlayerAvailability.available => (CeColors.primary, 'check'),
      PlayerAvailability.limited => (CeColors.amber, 'timer'),
      PlayerAvailability.unavailable => (CeColors.red, 'x'),
      PlayerAvailability.injured => (CeColors.blue, 'activity'),
      PlayerAvailability.other => (CeColors.muted, 'more-horizontal'),
    };

/// Status-chip tone for an availability status.
CeTone availabilityTone(PlayerAvailability s) => switch (s) {
      PlayerAvailability.available => CeTone.green,
      PlayerAvailability.limited || PlayerAvailability.other => CeTone.amber,
      PlayerAvailability.unavailable || PlayerAvailability.injured => CeTone.red,
    };
