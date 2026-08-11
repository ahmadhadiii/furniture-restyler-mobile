import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:augen/augen.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'furniture_catalog_item.dart';

enum _ArState { requestingPermission, permissionDenied, checking, unsupported, error, ready }

/// Builds a room up piece by piece in AR: pick a category (Sofa, Coffee
/// Table, ...), pick the exact real product, tap the floor to place it, then
/// pick the next category and repeat - all within ONE continuous AR session,
/// so earlier placements stay put (world tracking/anchors don't survive
/// closing and reopening an AR session, so this can't be built as
/// "navigate to AR, place one thing, go back, repeat" without losing
/// everything placed so far).
///
/// Each category gets exactly one placement slot (`placed_<catalogKey>`) -
/// picking a different product in the same category moves/replaces it;
/// picking a product in a DIFFERENT category adds a new, independent object.
/// Uses the ACTUAL chosen product's photo (see generate-furniture-models.js)
/// via augen's NodeType.model, not an SDXL-generated approximation - same
/// mechanism as the original single-product version of this page, just
/// extended to hold several placements + their own catalog pickers at once.
class ArFurniturePlacementPage extends StatefulWidget {
  const ArFurniturePlacementPage({
    super.key,
    required this.backendUrlBase,
    required this.categories,
    this.roomLengthM,
    this.roomWidthM,
    this.roomHeightM,
  });

  final String backendUrlBase;
  final List<FurnitureCategory> categories;

  // Previously scanned/entered room dimensions (see main.dart), used only
  // for the fit-check warnings below - null when the user hasn't measured
  // their room yet.
  final double? roomLengthM;
  final double? roomWidthM;
  final double? roomHeightM;

  @override
  State<ArFurniturePlacementPage> createState() => _ArFurniturePlacementPageState();
}

class _ArFurniturePlacementPageState extends State<ArFurniturePlacementPage> {
  AugenController? _controller;
  StreamSubscription? _errorSubscription;
  StreamSubscription<List<ARPlane>>? _planesSubscription;

  _ArState _state = _ArState.requestingPermission;
  String? _errorMessage;
  bool _permissionPermanentlyDenied = false;
  bool _placing = false;
  // Whether ARCore/ARKit has found ANY plane yet - used only to give a more
  // specific "keep scanning" vs "try tapping elsewhere" hint on a missed tap
  // (see _onTap), not to gate tapping itself.
  bool _planeDetected = false;

  final Map<String, List<FurnitureCatalogItem>> _catalogCache = {};
  final Set<String> _catalogLoading = {};
  String? _openCategoryKey;

  // The product armed to be placed on the next floor tap - null when
  // nothing is queued up (e.g. right after opening the page, or right after
  // a placement completes).
  ({String categoryKey, FurnitureCatalogItem item})? _armed;

  // What's currently standing in the AR scene, one slot per category - node
  // id is always `placed_<categoryKey>` so re-placing within the same
  // category updates that same node instead of adding a duplicate.
  final Map<String, FurnitureCatalogItem> _placed = {};

  // Categories with an in-flight tap-to-place operation (hit-test + image
  // download + addNode/updateNode) - guards _removePlaced from racing a
  // removeNode call against that same node id while it's still being
  // created/updated, which could otherwise leave the native scene and
  // _placed out of sync with each other.
  final Set<String> _busyCategoryKeys = {};

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _state = _ArState.checking);
      Future.delayed(const Duration(seconds: 8), () {
        if (mounted && _state == _ArState.checking) {
          _fail('AR session check timed out (ARCore may be unavailable).');
        }
      });
    } else {
      setState(() {
        _state = _ArState.permissionDenied;
        _permissionPermanentlyDenied = status.isPermanentlyDenied;
      });
    }
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    _planesSubscription?.cancel();
    for (final categoryKey in _placed.keys) {
      unawaited(_controller?.removeNode('placed_$categoryKey'));
    }
    super.dispose();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _state = _ArState.error;
      _errorMessage = message;
    });
  }

  static const _sessionConfig = ARSessionConfig(planeDetection: true, lightEstimation: true);

  Future<void> _onViewCreated(AugenController controller) async {
    _controller = controller;
    try {
      final supported = await controller.isARSupported();
      if (!mounted) return;
      if (!supported) {
        setState(() => _state = _ArState.unsupported);
        return;
      }
      await controller.initialize(_sessionConfig);
      if (!mounted) return;
      // onViewCreated can fire more than once on the same State (e.g.
      // Android recreating the platform view's GL surface after the app is
      // backgrounded/foregrounded) - cancel any previous subscriptions
      // first so they don't leak for the rest of this page's lifetime.
      await _errorSubscription?.cancel();
      await _planesSubscription?.cancel();
      _errorSubscription = controller.errorStream.listen((error) {
        if (error.toString().toLowerCase().contains('node')) return;
        _fail('AR error: $error');
      });
      _planesSubscription = controller.planesStream.listen((planes) {
        if (planes.isNotEmpty && !_planeDetected && mounted) {
          setState(() => _planeDetected = true);
        }
      });
      setState(() => _state = _ArState.ready);
    } catch (error) {
      _fail('Could not start AR session: $error');
    }
  }

  Future<void> _loadCatalog(String categoryKey) async {
    if (_catalogCache.containsKey(categoryKey) || _catalogLoading.contains(categoryKey)) return;
    setState(() => _catalogLoading.add(categoryKey));
    try {
      final response = await http
          .get(Uri.parse('${widget.backendUrlBase}/furniture-catalog/$categoryKey'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server returned ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _catalogCache[categoryKey] = decoded.map((e) => FurnitureCatalogItem.fromJson(e as Map<String, dynamic>)).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _catalogCache[categoryKey] = []);
    } finally {
      if (mounted) setState(() => _catalogLoading.remove(categoryKey));
    }
  }

  void _onCategoryTap(String categoryKey) {
    setState(() => _openCategoryKey = _openCategoryKey == categoryKey ? null : categoryKey);
    if (_openCategoryKey != null) _loadCatalog(categoryKey);
  }

  void _armProduct(String categoryKey, FurnitureCatalogItem item) {
    // Nothing to place - generate-furniture-models.js hasn't computed real
    // plane dimensions for this product yet (e.g. no scraped width_cm).
    if (item.planeWidthMeters == null || item.planeHeightMeters == null) return;
    setState(() {
      _armed = (categoryKey: categoryKey, item: item);
      _openCategoryKey = null;
    });
  }

  Future<void> _onTap(TapUpDetails details) async {
    final controller = _controller;
    final armed = _armed;
    if (controller == null || armed == null || _state != _ArState.ready || _placing) return;
    setState(() {
      _placing = true;
      _busyCategoryKeys.add(armed.categoryKey);
    });
    try {
      final results = await controller.hitTest(
        details.localPosition.dx,
        details.localPosition.dy,
      );
      if (!mounted) return;
      if (results.isEmpty) {
        // No detected surface at that exact screen point - this is the
        // single most common "I tapped and nothing happened" cause in AR
        // apps: ARKit/ARCore needs the phone moved around for a moment to
        // build a floor plane from camera feature points before hit-testing
        // can succeed anywhere, and a plane that DOES exist elsewhere on
        // screen won't extend to a spot that hasn't been scanned yet either.
        // Silently no-op-ing here (the previous behavior) is indistinguishable
        // from the app being broken, so surface it explicitly instead.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _planeDetected
                  ? 'No surface detected at that exact spot - try tapping closer to the middle of the floor.'
                  : 'No floor detected yet - slowly move your phone around the room for a few seconds, then try tapping again.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }
      final hit = results.first;
      final nodeId = 'placed_${armed.categoryKey}';

      // Downloaded here (not passed as a URL to the native side) because
      // augen's native model downloader is a stub anyway (see
      // vendor/augen's AugenARView.swift) - this http client is the same
      // one already used successfully for the catalog JSON/thumbnails, so
      // it's also known not to trip the zrok tunnel's browser-interstitial
      // page the way a native URLSession fetch of the same host might.
      final imageResponse = await http
          .get(Uri.parse('${widget.backendUrlBase}${armed.item.imageUrl}'))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (imageResponse.statusCode < 200 || imageResponse.statusCode >= 300) {
        throw Exception('Could not download product photo (${imageResponse.statusCode})');
      }

      final node = ARNode(
        id: nodeId,
        type: NodeType.model,
        position: hit.position,
        imageBytes: imageResponse.bodyBytes,
        planeWidthMeters: armed.item.planeWidthMeters,
        planeHeightMeters: armed.item.planeHeightMeters,
      );
      if (_placed.containsKey(armed.categoryKey)) {
        await controller.updateNode(node);
      } else {
        await controller.addNode(node);
      }
      if (!mounted) return;
      setState(() {
        _placed[armed.categoryKey] = armed.item;
        // Only clear _armed if it's still the same request we started with -
        // the user may have armed a DIFFERENT product/category while this
        // one's hit-test+download was in flight (e.g. slow network), and
        // blindly nulling it here would silently discard that newer
        // selection with no error, forcing them to re-tap the catalog item.
        if (_armed == armed) _armed = null;
      });
    } catch (error) {
      _fail('Could not place object: $error');
    } finally {
      if (mounted) {
        setState(() {
          _placing = false;
          _busyCategoryKeys.remove(armed.categoryKey);
        });
      }
    }
  }

  Future<void> _removePlaced(String categoryKey) async {
    // Refuses to race a removeNode call against an in-flight
    // addNode/updateNode for the same node id (see _busyCategoryKeys) - that
    // race could otherwise leave a node in the AR scene with no chip to
    // remove it, or a chip with nothing actually rendered.
    if (_busyCategoryKeys.contains(categoryKey)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Still placing that item - try removing it again in a moment.')),
      );
      return;
    }
    final nodeId = 'placed_$categoryKey';
    try {
      await _controller?.removeNode(nodeId);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _placed.remove(categoryKey));
  }

  /// Compares every currently-placed product against previously
  /// scanned/entered room dimensions - a rough "does this even fit" check
  /// (width against the room's two floor dimensions, plus height against
  /// ceiling height), not true 3D collision detection between the placed
  /// objects themselves.
  List<String> get _fitWarnings {
    final messages = <String>[];
    final roomLengthM = widget.roomLengthM;
    final roomWidthM = widget.roomWidthM;
    final roomHeightM = widget.roomHeightM;

    for (final item in _placed.values) {
      final widthCm = item.widthCm;
      if (widthCm != null && roomLengthM != null && roomWidthM != null) {
        final itemWidthM = widthCm / 100;
        final roomMax = math.max(roomLengthM, roomWidthM);
        final roomMin = math.min(roomLengthM, roomWidthM);
        if (itemWidthM > roomMax) {
          messages.add(
            '${item.name} is ${widthCm.toStringAsFixed(0)}cm wide - wider than even '
            'the longest side of your room (${roomMax.toStringAsFixed(1)}m). It will not fit.',
          );
        } else if (itemWidthM > roomMin) {
          messages.add(
            '${item.name} is ${widthCm.toStringAsFixed(0)}cm wide - it will only fit '
            'against your room\'s longer wall (${roomMax.toStringAsFixed(1)}m), '
            'not the shorter one (${roomMin.toStringAsFixed(1)}m).',
          );
        }
      }

      final heightCm = item.heightCm;
      if (heightCm != null && roomHeightM != null) {
        final itemHeightM = heightCm / 100;
        if (itemHeightM > roomHeightM) {
          messages.add(
            '${item.name} is ${heightCm.toStringAsFixed(0)}cm tall - taller than '
            'your room\'s measured height (${roomHeightM.toStringAsFixed(1)}m).',
          );
        }
      }
    }
    return messages;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Design your room in AR')),
      body: switch (_state) {
        _ArState.requestingPermission => const Center(child: CircularProgressIndicator()),
        _ArState.permissionDenied => _PermissionDeniedView(permanentlyDenied: _permissionPermanentlyDenied),
        _ArState.unsupported => const _ErrorView(
            message: 'This device does not support AR (ARCore unavailable).',
          ),
        _ArState.error => _ErrorView(message: _errorMessage ?? 'Unknown AR error.'),
        _ArState.checking || _ArState.ready => Stack(
            children: [
              GestureDetector(
                onTapUp: _state == _ArState.ready ? _onTap : null,
                child: AugenView(config: _sessionConfig, onViewCreated: _onViewCreated),
              ),
              if (_state == _ArState.checking) const Center(child: CircularProgressIndicator()),
              if (_state == _ArState.ready) ..._buildReadyOverlay(context),
            ],
          ),
      },
    );
  }

  List<Widget> _buildReadyOverlay(BuildContext context) {
    final warnings = _fitWarnings;
    return [
      Positioned(
        left: 16,
        right: 16,
        top: 16,
        child: Card(
          color: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _placing
                  ? 'Placing...'
                  : _armed != null
                      ? (_planeDetected
                          ? 'Tap the floor to place "${_armed!.item.name}"'
                          : 'Slowly move your phone around for a moment so it can see the floor, '
                              'then tap to place "${_armed!.item.name}"')
                      : _placed.isEmpty
                          ? 'Pick a category below to add furniture'
                          : 'Tap a category below to add or change an item',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      if (_placed.isNotEmpty)
        Positioned(
          left: 16,
          right: 16,
          top: 72,
          child: Wrap(
            spacing: 6,
            children: [
              for (final entry in _placed.entries)
                Chip(
                  label: Text(entry.value.name, style: const TextStyle(fontSize: 12)),
                  onDeleted: () => _removePlaced(entry.key),
                  backgroundColor: Colors.white,
                ),
            ],
          ),
        ),
      if (warnings.isNotEmpty)
        Positioned(
          left: 16,
          right: 16,
          bottom: _openCategoryKey != null ? 200 : 88,
          child: Card(
            color: Colors.orange.shade100,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final warning in warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.deepOrange, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(warning, style: const TextStyle(fontSize: 12))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      if (_openCategoryKey != null) _buildCatalogSheet(context, _openCategoryKey!),
      Positioned(
        left: 16,
        right: 16,
        bottom: 16,
        child: Wrap(
          spacing: 8,
          children: [
            for (final category in widget.categories)
              ChoiceChip(
                label: Text(category.label),
                selected: _openCategoryKey == category.catalogKey,
                onSelected: (_) => _onCategoryTap(category.catalogKey),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _buildCatalogSheet(BuildContext context, String categoryKey) {
    final loading = _catalogLoading.contains(categoryKey);
    final items = _catalogCache[categoryKey] ?? [];
    return Positioned(
      left: 16,
      right: 16,
      bottom: 64,
      child: Card(
        child: SizedBox(
          height: 160,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No products available yet.')))
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(8),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final placeable = item.planeWidthMeters != null && item.planeHeightMeters != null;
                        return GestureDetector(
                          onTap: placeable ? () => _armProduct(categoryKey, item) : null,
                          child: Opacity(
                            opacity: placeable ? 1 : 0.4,
                            child: SizedBox(
                              width: 110,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      '${widget.backendUrlBase}${item.imageUrl}',
                                      height: 100,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        height: 100,
                                        color: Colors.black12,
                                        child: const Icon(Icons.broken_image_outlined),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.permanentlyDenied});

  final bool permanentlyDenied;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              permanentlyDenied
                  ? 'Camera permission was denied and can\'t be requested again automatically - '
                      'enable it for this app in system Settings, then come back.'
                  : 'Camera permission is required for AR furniture placement.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (permanentlyDenied)
              FilledButton(onPressed: openAppSettings, child: const Text('Open Settings'))
            else
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Go back')),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('AR isn\'t available on this device.\n$message', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Go back')),
          ],
        ),
      ),
    );
  }
}
