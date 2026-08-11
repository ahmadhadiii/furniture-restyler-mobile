import 'dart:typed_data';

import 'vector3.dart';
import 'quaternion.dart';
import 'ar_animation.dart';

/// Types of AR nodes that can be added to the scene
enum NodeType { sphere, cube, cylinder, model }

/// Supported 3D model formats
enum ModelFormat { gltf, glb, obj, usdz }

/// Represents a 3D node in the AR scene
class ARNode {
  final String id;
  final NodeType type;
  final Vector3 position;
  final Quaternion rotation;
  final Vector3 scale;
  final Map<String, dynamic>? properties;

  /// Path to the 3D model asset (required when type is NodeType.model)
  /// For Flutter assets: 'assets/models/mymodel.glb'
  /// For network URLs: 'https://example.com/model.glb'
  final String? modelPath;

  /// Format of the 3D model (auto-detected from file extension if not specified)
  final ModelFormat? modelFormat;

  /// List of animations for this model
  final List<ARAnimation>? animations;

  // Fork-local addition (see AugenARView.swift's loadTexturedPlane): the
  // upstream package's NodeType.model / modelPath+modelFormat path is an
  // unimplemented stub on both iOS and Android (renders a placeholder cube
  // regardless of what model is requested - confirmed by reading the native
  // source, not just its docs). Rather than depend on a real GLB/USDZ
  // loader that doesn't exist yet, this lets a "model" node carry raw image
  // bytes + real-world plane dimensions instead, which the patched iOS side
  // renders as a procedurally-generated textured plane
  // (MeshResource.generatePlane + TextureResource) - the ACTUAL photo, no
  // 3D file format involved at all.
  final Uint8List? imageBytes;
  final double? planeWidthMeters;
  final double? planeHeightMeters;

  ARNode({
    required this.id,
    required this.type,
    required this.position,
    this.rotation = const Quaternion(0, 0, 0, 1),
    this.scale = const Vector3(1, 1, 1),
    this.properties,
    this.modelPath,
    this.modelFormat,
    this.animations,
    this.imageBytes,
    this.planeWidthMeters,
    this.planeHeightMeters,
  }) : assert(
         type != NodeType.model || modelPath != null || imageBytes != null,
         'modelPath or imageBytes is required when type is NodeType.model',
       ),
       assert(
         imageBytes == null || (planeWidthMeters != null && planeHeightMeters != null),
         'planeWidthMeters and planeHeightMeters are required when imageBytes is set - '
         'the native textured-plane path silently falls back to a placeholder cube '
         '(reporting success) if either is missing, which is very hard to catch without this.',
       );

  factory ARNode.fromMap(Map<dynamic, dynamic> map) {
    final animationsData = map['animations'] as List?;
    final animations = animationsData
        ?.map((e) => ARAnimation.fromMap(e as Map))
        .toList();

    return ARNode(
      id: map['id'] as String,
      type: _parseNodeType(map['type'] as String),
      position: Vector3.fromMap(map['position'] as Map),
      rotation: Quaternion.fromMap(map['rotation'] as Map),
      scale: Vector3.fromMap(map['scale'] as Map),
      properties: map['properties'] as Map<String, dynamic>?,
      modelPath: map['modelPath'] as String?,
      modelFormat: map['modelFormat'] != null
          ? _parseModelFormat(map['modelFormat'] as String)
          : null,
      animations: animations,
    );
  }

  static NodeType _parseNodeType(String type) {
    switch (type.toLowerCase()) {
      case 'sphere':
        return NodeType.sphere;
      case 'cube':
        return NodeType.cube;
      case 'cylinder':
        return NodeType.cylinder;
      case 'model':
        return NodeType.model;
      default:
        return NodeType.sphere;
    }
  }

  static ModelFormat _parseModelFormat(String format) {
    switch (format.toLowerCase()) {
      case 'gltf':
        return ModelFormat.gltf;
      case 'glb':
        return ModelFormat.glb;
      case 'obj':
        return ModelFormat.obj;
      case 'usdz':
        return ModelFormat.usdz;
      default:
        return ModelFormat.glb;
    }
  }

  /// Detect model format from file extension
  static ModelFormat? detectModelFormat(String path) {
    final extension = path.toLowerCase().split('.').last;
    switch (extension) {
      case 'gltf':
        return ModelFormat.gltf;
      case 'glb':
        return ModelFormat.glb;
      case 'obj':
        return ModelFormat.obj;
      case 'usdz':
        return ModelFormat.usdz;
      default:
        return null;
    }
  }

  Map<String, dynamic> toMap() {
    final format =
        modelFormat ??
        (modelPath != null ? detectModelFormat(modelPath!) : null);

    return {
      'id': id,
      'type': type.name,
      'position': position.toMap(),
      'rotation': rotation.toMap(),
      'scale': scale.toMap(),
      'properties': properties,
      if (modelPath != null) 'modelPath': modelPath,
      if (format != null) 'modelFormat': format.name,
      if (animations != null && animations!.isNotEmpty)
        'animations': animations!.map((a) => a.toMap()).toList(),
      if (imageBytes != null) 'imageBytes': imageBytes,
      if (planeWidthMeters != null) 'planeWidthMeters': planeWidthMeters,
      if (planeHeightMeters != null) 'planeHeightMeters': planeHeightMeters,
    };
  }

  ARNode copyWith({
    String? id,
    NodeType? type,
    Vector3? position,
    Quaternion? rotation,
    Vector3? scale,
    Map<String, dynamic>? properties,
    String? modelPath,
    ModelFormat? modelFormat,
    List<ARAnimation>? animations,
    Uint8List? imageBytes,
    double? planeWidthMeters,
    double? planeHeightMeters,
  }) {
    return ARNode(
      id: id ?? this.id,
      type: type ?? this.type,
      position: position ?? this.position,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      properties: properties ?? this.properties,
      modelPath: modelPath ?? this.modelPath,
      modelFormat: modelFormat ?? this.modelFormat,
      animations: animations ?? this.animations,
      imageBytes: imageBytes ?? this.imageBytes,
      planeWidthMeters: planeWidthMeters ?? this.planeWidthMeters,
      planeHeightMeters: planeHeightMeters ?? this.planeHeightMeters,
    );
  }

  /// Factory constructor for creating a custom 3D model node
  factory ARNode.fromModel({
    required String id,
    required String modelPath,
    required Vector3 position,
    Quaternion rotation = const Quaternion(0, 0, 0, 1),
    Vector3 scale = const Vector3(1, 1, 1),
    ModelFormat? modelFormat,
    List<ARAnimation>? animations,
    Map<String, dynamic>? properties,
  }) {
    return ARNode(
      id: id,
      type: NodeType.model,
      position: position,
      rotation: rotation,
      scale: scale,
      modelPath: modelPath,
      modelFormat: modelFormat ?? detectModelFormat(modelPath),
      animations: animations,
      properties: properties,
    );
  }

  @override
  String toString() => 'ARNode(id: $id, type: $type, position: $position)';
}
