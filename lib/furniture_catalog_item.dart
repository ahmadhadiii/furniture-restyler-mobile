/// A specific real product from `GET /furniture-catalog/:catalogKey`, e.g. a
/// named sofa or coffee table the user can pick - shared between the
/// whole-photo restyle flow (main.dart) and the AR object-placement flow
/// (ar_furniture_placement_page.dart), which both browse the same kind of
/// catalog data.
class FurnitureCatalogItem {
  const FurnitureCatalogItem({
    required this.id,
    required this.name,
    required this.imageUrl,
    this.modelUrl,
    this.widthCm,
    this.depthCm,
    this.heightCm,
    this.planeWidthMeters,
    this.planeHeightMeters,
  });

  final String id;
  final String name;
  final String imageUrl;
  // Textured-quad GLB path (see scripts/generate-furniture-models.js) - kept
  // for potential future use, but NOT what AR placement uses today: augen's
  // GLB/USDZ loader is an unimplemented stub on both platforms (confirmed by
  // reading its native source), so ArFurniturePlacementPage instead
  // downloads `imageUrl` itself and renders a real textured plane via the
  // patched vendor/augen (see planeWidthMeters/planeHeightMeters below).
  final String? modelUrl;
  final double? widthCm;
  final double? depthCm;
  final double? heightCm;
  // Real-world size (meters) of the AR plane - width from scraped
  // dimensions, height from the actual photo's aspect ratio so it isn't
  // stretched. Null until scripts/generate-furniture-models.js has run for
  // this product.
  final double? planeWidthMeters;
  final double? planeHeightMeters;

  static FurnitureCatalogItem fromJson(Map<String, dynamic> json) {
    return FurnitureCatalogItem(
      id: json['id'] as String,
      name: json['name'] as String,
      imageUrl: json['imageUrl'] as String,
      modelUrl: json['modelUrl'] as String?,
      widthCm: (json['widthCm'] as num?)?.toDouble(),
      depthCm: (json['depthCm'] as num?)?.toDouble(),
      heightCm: (json['heightCm'] as num?)?.toDouble(),
      planeWidthMeters: (json['planeWidthMeters'] as num?)?.toDouble(),
      planeHeightMeters: (json['planeHeightMeters'] as num?)?.toDouble(),
    );
  }
}

/// One pickable category offered in the AR room-builder (see
/// ArFurniturePlacementPage) - `catalogKey` matches the backend's
/// `GET /furniture-catalog/:catalogKey` route.
class FurnitureCategory {
  const FurnitureCategory({required this.catalogKey, required this.label});

  final String catalogKey;
  final String label;
}
