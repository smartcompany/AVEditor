import 'package:aveditor/services/pro_service.dart';

/// Catalog access level for transitions / text looks (not AI credits).
///
/// CapCut-style: Free effects are open; Plus unlocks Plus; Pro/Studio unlock
/// Plus + Pro. Credits are unrelated — effects never cost credits.
enum EffectAccessTier {
  free,
  plus,
  pro;

  static EffectAccessTier fromJson(Object? raw, {bool? legacyPremium}) {
    if (raw is String) {
      switch (raw.toLowerCase()) {
        case 'plus':
          return EffectAccessTier.plus;
        case 'pro':
        case 'studio':
          return EffectAccessTier.pro;
        case 'free':
          return EffectAccessTier.free;
      }
    }
    // Bundled catalogs used `premium: true` before accessTier existed.
    // Paid effects are Plus-tier while only Plus is sold.
    if (legacyPremium == true) return EffectAccessTier.plus;
    return EffectAccessTier.free;
  }

  String toJson() => name;

  int get rank => switch (this) {
        EffectAccessTier.free => 0,
        EffectAccessTier.plus => 1,
        EffectAccessTier.pro => 2,
      };

  bool get isPaid => this != EffectAccessTier.free;

  /// Short badge label for picker tiles.
  String get badgeLabel => switch (this) {
        EffectAccessTier.free => '',
        EffectAccessTier.plus => 'Plus',
        EffectAccessTier.pro => 'Pro',
      };
}

/// Plan rank for effect gating. Studio matches Pro for effects.
int planEffectRank(PlanTier tier) => switch (tier) {
      PlanTier.free => 0,
      PlanTier.plus => 1,
      PlanTier.pro || PlanTier.studio => 2,
    };

bool planCoversEffect(PlanTier user, EffectAccessTier required) =>
    planEffectRank(user) >= required.rank;
