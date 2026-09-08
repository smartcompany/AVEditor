import 'dart:convert';

import 'package:aveditor/models/transition_item.dart';
import 'package:http/http.dart' as http;

/// Thin data-access layer for the transition catalog API.
///
/// UI and render code should go through [TransitionCatalogService] /
/// [TransitionEngine], not call this repository directly from widgets.
class TransitionRepository {
  TransitionRepository({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<TransitionCatalog> fetchCatalog(String baseUrl) async {
    final root = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse('${root}transitions/catalog.json');
    final response = await _http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final catalog = TransitionCatalog.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (catalog.baseUrl.isEmpty) {
      return TransitionCatalog(
        version: catalog.version,
        baseUrl: root,
        items: catalog.items,
        categories: catalog.categories,
      );
    }
    return catalog;
  }

  Future<TransitionItem?> fetchById(String baseUrl, String id) async {
    final catalog = await fetchCatalog(baseUrl);
    return catalog.byId(id);
  }

  Future<List<TransitionItem>> fetchByCategory(
    String baseUrl,
    String category,
  ) async {
    final catalog = await fetchCatalog(baseUrl);
    final needle = category.trim().toLowerCase();
    return [
      for (final item in catalog.items)
        if (item.category.toLowerCase() == needle ||
            catalog.categories.any(
              (c) =>
                  c.id.toLowerCase() == needle &&
                  c.items.any((i) => i.id == item.id),
            ))
          item,
    ];
  }
}
