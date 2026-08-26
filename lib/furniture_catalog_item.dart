/// A specific real product from `GET /furniture-catalog/:catalogKey`, e.g. a
/// named sofa or coffee table the user can pick as a generation reference in
/// the whole-photo restyle flow (main.dart).
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
  final String? modelUrl;
  final double? widthCm;
  final double? depthCm;
  final double? heightCm;
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
