import 'dart:math' as math;

/// Clip rotation is stored in clockwise radians about the frame centre, the
/// same convention as `Transform.rotate` and FFmpeg's `rotate` filter.
const double quarterTurn = math.pi / 2;

/// Free rotation lands within a few degrees of an upright frame surprisingly
/// often, so pull it the rest of the way in.
const double _snapWindow = 3 * math.pi / 180;

double snapClipRotation(double radians) {
  final nearest = (radians / quarterTurn).round() * quarterTurn;
  return (radians - nearest).abs() <= _snapWindow ? nearest : radians;
}

/// Folds [radians] into (-pi, pi] so repeated quarter turns return to zero
/// instead of drifting into ever larger numbers.
double normalizeClipRotation(double radians) {
  const turn = 2 * math.pi;
  var value = radians % turn;
  if (value > math.pi) value -= turn;
  if (value <= -math.pi) value += turn;
  // Kill the floating point dust a chain of turns leaves behind.
  return value.abs() < 1e-9 ? 0 : value;
}

/// Change in angle from [fromRadians] to [toRadians], folded into (-pi, pi].
///
/// Used by the two-finger twist so crossing the +/-pi boundary does not throw
/// the rotation a full turn.
double twistDelta(double fromRadians, double toRadians) {
  return normalizeClipRotation(toRadians - fromRadians);
}
