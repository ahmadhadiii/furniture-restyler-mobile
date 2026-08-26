import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'ar_room_scan_page.dart';
import 'furniture_catalog_item.dart';

void main() {
  runApp(const FurnitureRestylerApp());
}

class FurnitureRestylerApp extends StatelessWidget {
  const FurnitureRestylerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Furniture Restyler',
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const RestyleHomePage(),
    );
  }
}

class RestyleHomePage extends StatefulWidget {
  const RestyleHomePage({super.key});

  @override
  State<RestyleHomePage> createState() => _RestyleHomePageState();
}

const List<(String, String)> _roomTypeOptions = [
  ('living_room_sofa', 'Living Room (Sofa)'),
  ('living_room_sectional', 'Living Room (Sectional)'),
  ('bedroom', 'Bedroom'),
  ('dining_room', 'Dining Room'),
];

const List<(String, String)> _colorOptions = [
  ('white', 'White'),
  ('cream', 'Cream'),
  ('beige', 'Beige'),
  ('gray', 'Gray'),
  ('black', 'Black'),
  ('natural_wood', 'Natural Wood'),
];


class _RestyleHomePageState extends State<RestyleHomePage> {
  final ImagePicker _picker = ImagePicker();
  // Tailscale IP, not the LAN/Ethernet IP - works from anywhere with
  // internet (any Wi-Fi, cellular data), not just USB or the same subnet as
  // the PC, as long as Tailscale is running and signed in on the phone too.
  final TextEditingController _backendUrlController = TextEditingController(
    text: 'http://100.85.54.54:3000',
  );
  final TextEditingController _roomLengthController = TextEditingController();
  final TextEditingController _roomWidthController = TextEditingController();
  final TextEditingController _roomHeightController = TextEditingController();

  static const int _maxAdditionalPhotos = 3;

  File? _pickedImage;
  final List<File> _additionalPhotos = [];
  Uint8List? _resultImage;
  bool _isLoading = false;
  String? _errorMessage;
  String _selectedRoomType = _roomTypeOptions.first.$1;
  String? _selectedColor;

  // Real per-product catalog for room types that have one prepared server
  // side (currently living_room_sofa/living_room_sectional) - an empty list
  // back from the server means this room type isn't catalog-backed yet, so
  // the picker section just doesn't render and color-only selection still
  // works exactly as before.
  List<FurnitureCatalogItem> _catalogItems = [];
  bool _catalogLoading = false;
  String? _selectedFurnitureProductId;

  String get _backendUrlBase => _backendUrlController.text.trim();

  @override
  void initState() {
    super.initState();
    _fetchCatalog();
    // Room dimensions and the selected product are independent bits of
    // state (typed in, or set from tapping a catalog thumbnail) - a plain
    // TextEditingController doesn't trigger a rebuild on its own, so the fit
    // warning below needs an explicit listener to stay live as either one
    // changes, not just at submit time.
    _roomLengthController.addListener(_onRoomDimensionsChanged);
    _roomWidthController.addListener(_onRoomDimensionsChanged);
  }

  @override
  void dispose() {
    _roomLengthController.removeListener(_onRoomDimensionsChanged);
    _roomWidthController.removeListener(_onRoomDimensionsChanged);
    _backendUrlController.dispose();
    _roomLengthController.dispose();
    _roomWidthController.dispose();
    _roomHeightController.dispose();
    super.dispose();
  }

  void _onRoomDimensionsChanged() => setState(() {});

  FurnitureCatalogItem? get _selectedCatalogItem {
    for (final candidate in _catalogItems) {
      if (candidate.id == _selectedFurnitureProductId) return candidate;
    }
    return null;
  }

  /// Compares the selected product's real width against the room's real
  /// dimensions and returns a plain-language warning if it likely won't
  /// physically fit - null when there's nothing to warn about (no product
  /// selected, no room dimensions entered yet, or it's a comfortable fit).
  /// This is a rough "does it fit at all" check (against the room's two
  /// floor dimensions), not true 3D placement - the app has no way to know
  /// which specific wall a piece would actually go against.
  String? get _furnitureFitWarning {
    final item = _selectedCatalogItem;
    final itemWidthCm = item?.widthCm;
    if (itemWidthCm == null) return null;

    final roomLengthM = double.tryParse(_roomLengthController.text.trim());
    final roomWidthM = double.tryParse(_roomWidthController.text.trim());
    if (roomLengthM == null || roomWidthM == null) return null;

    final itemWidthM = itemWidthCm / 100;
    final roomMax = roomLengthM > roomWidthM ? roomLengthM : roomWidthM;
    final roomMin = roomLengthM < roomWidthM ? roomLengthM : roomWidthM;

    if (itemWidthM > roomMax) {
      return '"${item!.name}" is ${itemWidthCm.toStringAsFixed(0)}cm wide - '
          'that\'s wider than even the longest side of your room (${roomMax.toStringAsFixed(1)}m). '
          'It will not fit.';
    }
    if (itemWidthM > roomMin) {
      return '"${item!.name}" is ${itemWidthCm.toStringAsFixed(0)}cm wide - '
          'it will only fit against your room\'s longer wall (${roomMax.toStringAsFixed(1)}m), '
          'not the shorter one (${roomMin.toStringAsFixed(1)}m).';
    }
    return null;
  }

  Future<void> _fetchCatalog() async {
    final backendUrl = _backendUrlController.text.trim();
    if (backendUrl.isEmpty) return;
    // Captured so a response for a room type the user has since switched
    // away from (e.g. tapping two chips quickly on a slow connection)
    // can't overwrite the catalog for whatever's actually selected now -
    // without this, whichever request happened to resolve LAST won
    // regardless of which one was newer, which could silently show the
    // wrong room type's products under the currently-selected chip.
    final requestedRoomType = _selectedRoomType;
    setState(() => _catalogLoading = true);
    try {
      final response = await http
          .get(Uri.parse('$backendUrl/furniture-catalog/$requestedRoomType'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server returned ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body) as List<dynamic>;
      if (!mounted || requestedRoomType != _selectedRoomType) return;
      setState(() {
        _catalogItems = decoded.map((e) => FurnitureCatalogItem.fromJson(e as Map<String, dynamic>)).toList();
      });
    } catch (_) {
      // Catalog browsing is an enhancement, not required for the core
      // restyle flow - a failed fetch (offline, old backend without this
      // route yet) just means no picker shows, same as an empty catalog.
      if (!mounted || requestedRoomType != _selectedRoomType) return;
      setState(() => _catalogItems = []);
    } finally {
      if (mounted && requestedRoomType == _selectedRoomType) setState(() => _catalogLoading = false);
    }
  }

  void _onRoomTypeChanged(String roomType) {
    setState(() {
      _selectedRoomType = roomType;
      _selectedFurnitureProductId = null; // ids aren't valid across room types
    });
    _fetchCatalog();
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? picked = await _picker.pickImage(source: source, imageQuality: 90);
    if (picked == null || !mounted) return;
    setState(() {
      _pickedImage = File(picked.path);
      _additionalPhotos.clear();
      _resultImage = null;
      _errorMessage = null;
    });
  }

  Future<void> _pickAdditionalPhotoFromCamera() async {
    final remaining = _maxAdditionalPhotos - _additionalPhotos.length;
    if (remaining <= 0) return;
    final XFile? picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 90);
    if (picked == null || !mounted) return;
    setState(() {
      _additionalPhotos.add(File(picked.path));
    });
  }

  Future<void> _pickAdditionalPhotosFromGallery() async {
    final remaining = _maxAdditionalPhotos - _additionalPhotos.length;
    if (remaining <= 0) return;
    final List<XFile> picked = await _picker.pickMultiImage(imageQuality: 90);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _additionalPhotos.addAll(picked.take(remaining).map((f) => File(f.path)));
    });
  }

  Future<void> _restyle() async {
    final image = _pickedImage;
    if (image == null) return;

    final backendUrl = _backendUrlController.text.trim();
    if (backendUrl.isEmpty) {
      setState(() => _errorMessage = 'Enter the backend server URL first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _resultImage = null;
    });

    try {
      final uri = Uri.parse('$backendUrl/restyle');
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('image', image.path))
        ..fields['roomType'] = _selectedRoomType;
      final color = _selectedColor;
      if (color != null) request.fields['color'] = color;
      final furnitureProductId = _selectedFurnitureProductId;
      if (furnitureProductId != null) request.fields['furnitureProductId'] = furnitureProductId;
      final roomLength = _roomLengthController.text.trim();
      final roomWidth = _roomWidthController.text.trim();
      final roomHeight = _roomHeightController.text.trim();
      if (roomLength.isNotEmpty) request.fields['roomLength'] = roomLength;
      if (roomWidth.isNotEmpty) request.fields['roomWidth'] = roomWidth;
      if (roomHeight.isNotEmpty) request.fields['roomHeight'] = roomHeight;
      for (final photo in _additionalPhotos) {
        request.files.add(await http.MultipartFile.fromPath('additionalPhotos', photo.path));
      }

      // The submit call itself only does the fast part (segmentation + mask
      // + queuing the generation job) and returns a jobId immediately -
      // actual generation (50-70s+) is polled for separately below. This
      // avoids holding one single connection open long enough to hit
      // tunnel/proxy timeouts (e.g. zrok's public share cuts a request at
      // ~60s) even though the backend itself would have finished fine.
      final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final jobId = decoded['jobId'] as String;
      final resultBase64 = await _pollForResult(backendUrl, jobId);
      if (!mounted) return;
      setState(() {
        _resultImage = base64Decode(resultBase64);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Failed to restyle: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Polls `GET /restyle/:jobId` every few seconds - each individual check
  /// is fast regardless of how long the underlying generation is taking, so
  /// no single request is ever held open long enough for a tunnel/proxy to
  /// time it out.
  Future<String> _pollForResult(String backendUrl, String jobId) async {
    const pollInterval = Duration(seconds: 3);
    const overallTimeout = Duration(minutes: 10);
    final deadline = DateTime.now().add(overallTimeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      final response = await http
          .get(Uri.parse('$backendUrl/restyle/$jobId'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      switch (decoded['status']) {
        case 'done':
          return decoded['image'] as String;
        case 'error':
          throw Exception(decoded['message'] as String? ?? 'Generation failed');
        default:
          continue; // still processing - poll again
      }
    }
    throw Exception('Timed out waiting for the result after ${overallTimeout.inMinutes} minutes');
  }

  Future<void> _scanRoomWithAr() async {
    final result = await Navigator.of(context).push<Map<String, double>>(
      MaterialPageRoute(builder: (_) => const ArRoomScanPage()),
    );
    if (result == null) return;
    setState(() {
      _roomLengthController.text = result['length']!.toStringAsFixed(2);
      _roomWidthController.text = result['width']!.toStringAsFixed(2);
      _roomHeightController.text = result['height']!.toStringAsFixed(2);
    });
  }

  void _openZoomView(BuildContext context, Uint8List image) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ZoomImagePage(image: image),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Furniture Restyler')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _backendUrlController,
                decoration: const InputDecoration(
                  labelText: 'Backend server URL',
                  hintText: 'http://<PC LAN IP>:3000',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_pickedImage != null) ...[
                const Text('Original', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(_pickedImage!, height: 240, fit: BoxFit.cover),
                ),
                const SizedBox(height: 16),
                Text(
                  'Other angles of this room (optional, up to $_maxAdditionalPhotos) - '
                  'reference only, helps the result but isn\'t restyled itself',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (_additionalPhotos.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final photo in _additionalPhotos)
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(photo, width: 80, height: 80, fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: -8,
                              right: -8,
                              child: IconButton(
                                icon: const Icon(Icons.cancel, size: 20),
                                onPressed: () => setState(() => _additionalPhotos.remove(photo)),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (_additionalPhotos.length < _maxAdditionalPhotos)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickAdditionalPhotoFromCamera,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Camera'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickAdditionalPhotosFromGallery,
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Gallery'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                const Text('Room type', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in _roomTypeOptions)
                      ChoiceChip(
                        label: Text(label),
                        selected: _selectedRoomType == value,
                        onSelected: (_) => _onRoomTypeChanged(value),
                      ),
                  ],
                ),
                if (_catalogLoading || _catalogItems.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Pick a specific real product (optional)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Leave none selected for the AI to design something in your chosen color instead.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  if (_catalogLoading)
                    const Center(child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ))
                  else
                    SizedBox(
                      height: 160,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _catalogItems.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final item = _catalogItems[index];
                          final selected = _selectedFurnitureProductId == item.id;
                          return GestureDetector(
                            onTap: () => setState(() {
                              _selectedFurnitureProductId = selected ? null : item.id;
                            }),
                            child: Container(
                              width: 120,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      '$_backendUrlBase${item.imageUrl}',
                                      height: 110,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        height: 110,
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
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                const Text('Color (optional)', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in _colorOptions)
                      ChoiceChip(
                        label: Text(label),
                        selected: _selectedColor == value,
                        onSelected: (selected) => setState(
                          () => _selectedColor = selected ? value : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Room dimensions in meters (optional)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Type by hand, or scan with AR (needs an ARCore-supported phone) - '
                  'either way this only helps pick correctly-sized furniture, not precise 3D placement.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _scanRoomWithAr,
                  icon: const Icon(Icons.view_in_ar),
                  label: const Text('Scan with AR'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _roomLengthController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Length',
                          suffixText: 'm',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _roomWidthController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Width',
                          suffixText: 'm',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _roomHeightController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Height',
                          suffixText: 'm',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_furnitureFitWarning != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_furnitureFitWarning!, style: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _isLoading ? null : _restyle,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(_isLoading ? 'Restyling...' : 'Restyle Room'),
                ),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              ],
              if (_resultImage != null) ...[
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Restyled', style: TextStyle(fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      onPressed: () => _openZoomView(context, _resultImage!),
                      icon: const Icon(Icons.zoom_in),
                      label: const Text('Zoom'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _openZoomView(context, _resultImage!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(_resultImage!, fit: BoxFit.cover),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomImagePage extends StatelessWidget {
  const _ZoomImagePage({required this.image});

  final Uint8List image;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Image.memory(image),
        ),
      ),
    );
  }
}
