import 'package:aveditor/services/premium_usage.dart';
import 'package:flutter/foundation.dart';

/// In-memory unlocks from watching an ad for a specific paid effect.
///
/// Unlocks apply only to the current export attempt — [clear] runs at the
/// start of each save so the next export requires ads again.
class EffectAdUnlockService extends ChangeNotifier {
  EffectAdUnlockService._();

  static final EffectAdUnlockService instance = EffectAdUnlockService._();

  final Set<String> _keys = {};

  static String keyFor(PremiumUse use) => '${use.kind.name}:${use.itemId}';

  static String keyForParts(PremiumUseKind kind, String itemId) =>
      '${kind.name}:$itemId';

  /// No-op kept for call-site symmetry; unlocks are memory-only.
  Future<void> ensureLoaded() async {}

  bool isUnlocked(PremiumUse use) => _keys.contains(keyFor(use));

  bool isUnlockedKey(String key) => _keys.contains(key);

  Future<void> unlock(PremiumUse use) async {
    final key = keyFor(use);
    if (_keys.contains(key)) return;
    _keys.add(key);
    notifyListeners();
  }

  /// Drop all ad unlocks so the next export asks for ads again.
  void clear() {
    if (_keys.isEmpty) return;
    _keys.clear();
    notifyListeners();
  }
}
