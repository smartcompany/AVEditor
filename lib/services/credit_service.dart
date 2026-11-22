import 'dart:convert';

import 'package:aveditor/models/remote_plan.dart';
import 'package:aveditor/services/analytics_service.dart';
import 'package:aveditor/services/premium_usage.dart';
import 'package:aveditor/services/pro_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Device-scoped credits (anonymous install id) + plan-aware spend.
class CreditService extends ChangeNotifier {
  CreditService._();

  static final CreditService instance = CreditService._();

  static const baseUrl = 'https://aveditorserver.vercel.app';
  static const _installIdKey = 'analytics_install_id';

  int _balance = 0;
  String _planTier = 'free';
  int _adReward = 0;
  int _startingCredits = 0;
  Map<String, int> _transitionCosts = const {};
  Map<String, int> _textCosts = const {};
  Map<String, int> _monthlyCredits = const {
    'plus': 0,
    'pro': 0,
    'studio': 0,
  };
  List<RemotePlan> _plans = const [];
  int _defaultTransition = 40;
  int _defaultText = 25;
  bool _ready = false;

  int get balance => _balance;
  String get planTier => _planTier;
  int get adReward => _adReward;
  bool get isReady => _ready;
  List<RemotePlan> get plans => _plans;

  RemotePlan? planById(String id) {
    for (final plan in _plans) {
      if (plan.id == id) return plan;
    }
    return null;
  }

  /// Monthly allotment for [tier] (0 for free / unknown).
  int monthlyCreditsFor(String tier) {
    final remote = planById(tier);
    if (remote != null) return remote.monthlyCredits;
    return _monthlyCredits[tier] ?? 0;
  }

  int get plusMonthlyCredits => monthlyCreditsFor('plus');
  int get proMonthlyCredits => monthlyCreditsFor('pro');
  int get studioMonthlyCredits => monthlyCreditsFor('studio');

  /// Paid plan (Plus / Pro / Studio). Effects are unlocked by plan tier;
  /// monthly credits are for AI tools only.
  bool get editingUnlocked {
    if (ProService.instance.isPro) return true;
    return _planTier == 'plus' ||
        _planTier == 'pro' ||
        _planTier == 'studio';
  }

  Future<void> ensureInitialized() async {
    if (_ready) return;
    await AnalyticsService.instance.init();
    await bootstrap();
  }

  Future<String> deviceKey() async {
    await AnalyticsService.instance.init();
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_installIdKey);
    if (id == null || id.isEmpty) {
      throw StateError('analytics_install_id missing');
    }
    return id;
  }

  Future<void> bootstrap() async {
    final key = await deviceKey();
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/credits/bootstrap'),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'deviceKey': key}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _applyPayload(jsonDecode(utf8.decode(res.bodyBytes)));
        _ready = true;
        notifyListeners();
        return;
      }
      debugPrint('[credits] bootstrap ${res.statusCode}');
    } catch (e) {
      debugPrint('[credits] bootstrap failed: $e');
    }
    _balance = _startingCredits;
    _ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    final key = await deviceKey();
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/api/credits').replace(
          queryParameters: {'deviceKey': key},
        ),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _applyPayload(jsonDecode(utf8.decode(res.bodyBytes)));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[credits] refresh failed: $e');
    }
  }

  /// Account-based plan: signed-out users show Free even if device was linked.
  void clearAccountEntitlement() {
    if (_planTier == 'free') return;
    _planTier = 'free';
    notifyListeners();
  }

  bool get _isLoggedIn => FirebaseAuth.instance.currentUser != null;

  void _applyPayload(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<String, dynamic>.from(raw);
    _balance = (map['balance'] as num?)?.toInt() ?? _balance;
    _planTier = (map['planTier'] as String?) ?? _planTier;
    // Device rows may still carry a linked account plan; ignore when signed out.
    if (!_isLoggedIn) {
      _planTier = 'free';
    }

    final plansRaw = map['plans'];
    if (plansRaw is List) {
      final parsed = <RemotePlan>[];
      for (final item in plansRaw) {
        if (item is Map) {
          parsed.add(RemotePlan.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      if (parsed.isNotEmpty) {
        _plans = parsed;
        _monthlyCredits = {
          for (final plan in parsed) plan.id: plan.monthlyCredits,
        };
      }
    }

    final economy = map['economy'];
    if (economy is! Map) return;
    final e = Map<String, dynamic>.from(economy);
    _adReward = (e['adReward'] as num?)?.toInt() ?? _adReward;
    _startingCredits =
        (e['startingCredits'] as num?)?.toInt() ?? _startingCredits;
    final defaults = e['defaults'];
    if (defaults is Map) {
      _defaultTransition =
          (defaults['transition'] as num?)?.toInt() ?? _defaultTransition;
      _defaultText = (defaults['text'] as num?)?.toInt() ?? _defaultText;
    }
    final monthly = e['monthlyCredits'];
    if (monthly is Map) {
      _monthlyCredits = {
        ..._monthlyCredits,
        for (final entry in monthly.entries)
          entry.key.toString(): (entry.value as num).toInt(),
      };
    }
    final transitions = e['transitions'];
    if (transitions is Map) {
      _transitionCosts = {
        for (final entry in transitions.entries)
          entry.key.toString(): (entry.value as num).toInt(),
      };
    }
    final texts = e['texts'];
    if (texts is Map) {
      _textCosts = {
        for (final entry in texts.entries)
          entry.key.toString(): (entry.value as num).toInt(),
      };
    }
  }

  /// Prefer `/api/plans` when bootstrap did not include plan copy yet.
  Future<void> ensurePlansLoaded() async {
    if (_plans.isNotEmpty) return;
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/plans'));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final raw = jsonDecode(utf8.decode(res.bodyBytes));
      if (raw is Map) {
        _applyPayload({'plans': raw['plans'], 'economy': {
          'adReward': (raw['economy'] as Map?)?['adRewardCredits'],
          'startingCredits': (raw['economy'] as Map?)?['startingCredits'],
          'monthlyCredits': {
            for (final p in (raw['plans'] as List? ?? const []))
              if (p is Map)
                '${p['id']}': p['monthlyCredits'],
          },
        }});
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[credits] plans fetch failed: $e');
    }
  }

  int costForUse(PremiumUse use) {
    return switch (use.kind) {
      PremiumUseKind.transition =>
        _transitionCosts[use.itemId] ?? _defaultTransition,
      PremiumUseKind.text => _textCosts[use.itemId] ?? _defaultText,
    };
  }

  int costForUses(List<PremiumUse> uses) {
    var total = 0;
    for (final use in uses) {
      total += costForUse(use);
    }
    return total;
  }

  int adsNeededFor(int cost) {
    final need = cost - _balance;
    if (need <= 0) return 0;
    // Dashboard adRewardCredits is authoritative — including 0 (ads disabled).
    if (_adReward <= 0) return need;
    return ((need + _adReward - 1) / _adReward).floor();
  }

  Future<bool> claimAdReward() async {
    final key = await deviceKey();
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/credits/ad-reward'),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'deviceKey': key}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        if (map is Map) {
          _balance = (map['balance'] as num?)?.toInt() ?? _balance;
          notifyListeners();
        }
        return true;
      }
      if (res.statusCode == 429) {
        await refresh();
        return true;
      }
    } catch (e) {
      debugPrint('[credits] ad-reward failed: $e');
    }
    return false;
  }

  Future<bool> spendForExport(List<PremiumUse> uses) async {
    if (uses.isEmpty) return true;
    final key = await deviceKey();
    final items = [
      for (final use in uses)
        {
          'kind': use.kind == PremiumUseKind.transition ? 'transition' : 'text',
          'id': use.itemId,
        },
    ];
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/credits/spend'),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'deviceKey': key, 'items': items}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        if (map is Map) {
          _balance = (map['balance'] as num?)?.toInt() ?? _balance;
          notifyListeners();
        }
        return true;
      }
      if (res.statusCode == 402) {
        await refresh();
        return false;
      }
    } catch (e) {
      debugPrint('[credits] spend failed: $e');
    }
    return false;
  }

  Future<void> linkFirebaseAccount(String idToken) async {
    final key = await deviceKey();
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/credits/link'),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'deviceKey': key}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(utf8.decode(res.bodyBytes));
        if (map is Map) {
          _balance = (map['balance'] as num?)?.toInt() ?? _balance;
          _planTier = (map['planTier'] as String?) ?? _planTier;
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[credits] link failed: $e');
    }
  }
}
