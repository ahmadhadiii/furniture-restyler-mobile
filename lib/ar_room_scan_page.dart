import 'dart:async';
import 'dart:math' as math;

import 'package:augen/augen.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

enum _ArState { requestingPermission, permissionDenied, checking, unsupported, error, ready }

Vector3 _vecAdd(Vector3 a, Vector3 b) => Vector3(a.x + b.x, a.y + b.y, a.z + b.z);

Vector3 _vecScale(Vector3 v, double s) => Vector3(v.x * s, v.y * s, v.z * s);

Vector3 _cross(Vector3 a, Vector3 b) => Vector3(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
    );

/// Rotates [v] by quaternion [q] (v' = v + 2*w*(qv x v) + 2*(qv x (qv x v))).
Vector3 _rotateVector(Quaternion q, Vector3 v) {
  final qv = Vector3(q.x, q.y, q.z);
  final t = _vecScale(_cross(qv, v), 2);
  return _vecAdd(_vecAdd(v, _vecScale(t, q.w)), _cross(qv, t));
}

/// Automatic "point and hold" room scan: point the camera at a wall and hold
/// steady - once the same surface is tracked continuously for about 5s, its
/// real-world width/height (averaged across the whole hold, not just the
/// last frame) is captured automatically and the screen prompts for the
/// second (adjacent) wall, with no tapping required to take a reading.
///
/// Requires ARCore (Google Play Services for AR) - on a phone without ARCore
/// support, this screen shows a clear error with a way back to manual entry
/// instead of a blank/broken camera view.
///
/// History (verified on a real ARCore-certified device, Xiaomi 15 Ultra):
/// the original version required tapping 3 corner points via hitTest(), and
/// needed two bug fixes first - (1) CAMERA permission was never actually
/// requested (manifest declaration alone isn't enough on modern Android),
/// and (2) `controller.initialize(config)` was never called, so ARCore's
/// Session/camera GL surface never actually started even though
/// isARSupported() correctly returned true. Once both were fixed and the
/// camera feed worked, manual tap-to-measure was reported as slow/laggy to
/// use - replaced with this automatic hold-steady-to-capture flow, which
/// continuously hit-tests the screen center against ARCore's live plane
/// tracking (`planesStream`) instead of waiting for discrete taps.
class ArRoomScanPage extends StatefulWidget {
  const ArRoomScanPage({super.key});

  @override
  State<ArRoomScanPage> createState() => _ArRoomScanPageState();
}

class _ArRoomScanPageState extends State<ArRoomScanPage> {
  AugenController? _controller;
  StreamSubscription? _errorSubscription;
  StreamSubscription<List<ARPlane>>? _planesSubscription;
  Timer? _measureTimer;
  // Reentrancy guard: the 300ms Timer.periodic below doesn't wait for the
  // previous _sampleCenter's hit-test await to resolve before firing again.
  // If a hit-test is ever slow enough to overlap the next tick, two
  // in-flight calls could otherwise resolve out of order and update
  // _stableDims/_stableCount/_currentPlaneId using a stale result after a
  // newer one already updated the running average.
  bool _sampling = false;

  _ArState _state = _ArState.requestingPermission;
  String? _errorMessage;
  bool _permissionPermanentlyDenied = false;

  List<ARPlane> _planes = [];
  String? _currentPlaneId;
  ({double width, double height})? _currentDims;
  PlaneType? _currentPlaneType;
  int _stableCount = 0;
  int _missedSamples = 0;
  static const _sampleInterval = Duration(milliseconds: 300);
  // ~5.1s at the 300ms sampling interval - long enough that a genuinely held,
  // averaged reading is consistent run-to-run, rather than capturing
  // whatever single frame happened to land right at the old ~1.5s mark.
  static const _stableThreshold = 17;
  // A single missed hit-test is normal camera-shake noise, not genuine
  // tracking loss - only treat the wall as lost after several consecutive
  // misses (~0.9s), otherwise the outline flickers on/off on every hand
  // tremor even while still pointed at the same wall.
  static const _missGraceSamples = 3;
  // If a new reading disagrees with the running average of the current hold
  // by more than this, the hold restarts rather than averaging in a
  // probably-inaccurate number - this is what makes "hold steady" actually
  // require an accurate, agreeing reading throughout, not just elapsed time.
  static const _maxRelativeDeviation = 0.03;
  static const _minAbsoluteTolerance = 0.02;

  // Every resolved (width, height) reading during the current hold streak,
  // so the captured measurement is an average across the whole hold rather
  // than just whichever single frame happened to be live at capture time.
  final List<({double width, double height})> _stableDims = [];

  String? _firstPlaneId;
  double? _capturedLength;
  double? _capturedWidth;
  double? _capturedHeight;

  // Live outline drawn directly on the tracked wall using AR nodes, so the
  // measurement being read can be visually verified against the real wall
  // edges instead of trusting a number alone. Tracks which edge ids are
  // confirmed to actually exist server-side (not just "we tried to add
  // them") - if any single edge's addNode call fails, it's left out of this
  // set so the next tick retries addNode for just that edge, rather than
  // calling updateNode on a node that was never really created (which
  // silently fails and permanently freezes/hides that one edge while the
  // others keep moving - this was the main cause of the outline looking
  // incomplete, stuck in a stale spot, or flickering).
  final Set<String> _createdNodeIds = {};
  // The `augen` plugin's cube primitive is a fixed 0.1m mesh on iOS and
  // `scale` is a multiplier on that base size, not a size in meters - so
  // real-world dimensions must be divided by this before being used as scale.
  static const double _outlineBaseNodeSize = 0.1;
  static const double _outlineThickness = 0.02;

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
      // onViewCreated firing doesn't mean AR actually works - the plugin can
      // still hand back a controller on a device with no real ARCore
      // support. If onViewCreated never fires at all (or the supported
      // check/initialize hangs), fail after a few seconds instead of
      // leaving the screen stuck on "checking".
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
    _measureTimer?.cancel();
    _errorSubscription?.cancel();
    _planesSubscription?.cancel();
    unawaited(_clearWallOutline());
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
      // AugenView creates the controller and hands it over via
      // onViewCreated, but does NOT start an AR session by itself -
      // initialize() is a separate call the app must make explicitly. This
      // is what actually creates ARCore's Session and sets up the camera GL
      // surface.
      await controller.initialize(_sessionConfig);
      if (!mounted) return;
      _errorSubscription = controller.errorStream.listen((error) {
        // Best-effort AR-node housekeeping (the live wall outline) can throw
        // benign, already-handled errors on this same shared stream - e.g.
        // "node with id ... not found" when a remove races an add/update
        // for the same id. Those are caught locally in
        // _updateWallOutlineImpl/_clearWallOutlineImpl already; don't also
        // let them bubble up here and kill the whole scan session over a
        // harmless outline hiccup that isn't a real AR failure.
        if (error.toString().toLowerCase().contains('node')) return;
        _fail('AR error: $error');
      });
      _planesSubscription = controller.planesStream.listen((planes) {
        _planes = planes;
      });
      setState(() => _state = _ArState.ready);
      _measureTimer = Timer.periodic(_sampleInterval, (_) => _sampleCenter());
    } catch (error) {
      _fail('Could not start AR session: $error');
    }
  }

  Future<void> _sampleCenter() async {
    final controller = _controller;
    if (controller == null || !mounted || _capturedWidth != null || _sampling) return;

    _sampling = true;
    final size = MediaQuery.of(context).size;
    try {
      final results = await controller.hitTest(size.width / 2, size.height / 2);
      if (!mounted) return;

      final hit = results.isNotEmpty ? results.first : null;
      final planeId = hit?.planeId;
      if (planeId == null || (_firstPlaneId != null && planeId == _firstPlaneId)) {
        // Nothing hit, or the user is still pointing at the already-captured
        // first wall - don't let it re-trigger a capture of the same wall.
        // Debounced via _missGraceSamples (see field doc) so a single
        // dropped frame doesn't flicker the outline away.
        _missedSamples++;
        if (_missedSamples >= _missGraceSamples) {
          setState(() {
            _currentPlaneId = null;
            _currentDims = null;
            _stableCount = 0;
            _stableDims.clear();
          });
          unawaited(_clearWallOutline());
        }
        return;
      }
      _missedSamples = 0;

      ARPlane? plane;
      for (final p in _planes) {
        if (p.id == planeId) {
          plane = p;
          break;
        }
      }
      final trackedPlane = plane;
      if (trackedPlane == null) return;

      if (trackedPlane.type != PlaneType.vertical) {
        // Both measurements this page captures are meant to come from a
        // wall (vertical plane) - _resolveWallDims's axis-picking heuristic
        // assumes one tangent axis is markedly more vertical than the
        // other, which is meaningful for a wall but is just noise for a
        // horizontal floor plane (both tangents are near-horizontal there).
        // Without this check, the reticle drifting onto a detected floor
        // for the ~5s hold window would silently capture bogus floor
        // extents as if they were a wall's width/height.
        _missedSamples++;
        if (_missedSamples >= _missGraceSamples) {
          setState(() {
            _currentPlaneId = null;
            _currentDims = null;
            _stableCount = 0;
            _stableDims.clear();
          });
          unawaited(_clearWallOutline());
        }
        return;
      }

      final dims = _resolveWallDims(trackedPlane.extent, hit!.rotation);

      setState(() {
        if (planeId == _currentPlaneId && _isConsistentWithHold(dims)) {
          _stableCount++;
          _stableDims.add(dims);
        } else {
          // Either a new plane, or this reading disagrees too much with the
          // current hold's running average - restart the hold rather than
          // average in a likely-inaccurate number (see _maxRelativeDeviation).
          _currentPlaneId = planeId;
          _stableCount = 1;
          _stableDims
            ..clear()
            ..add(dims);
        }
        _currentDims = dims;
        _currentPlaneType = trackedPlane.type;
      });
      unawaited(_updateWallOutline(trackedPlane, hit.rotation));

      if (_stableCount >= _stableThreshold) {
        _captureCurrentMeasurement();
      }
    } catch (_) {
      // Transient hit-test errors (e.g. tracking briefly lost) - ignore and
      // let the next sample try again rather than surfacing every blip.
    } finally {
      _sampling = false;
    }
  }

  /// ARKit's legacy plane `.extent` (which the `augen` plugin's iOS side
  /// reads) doesn't reliably guarantee which local axis is the wall's real
  /// width vs height for vertical planes - this is a documented Apple
  /// limitation (it's why the newer `planeExtent.width`/`.height` API was
  /// added to replace `.extent`). Rather than assuming one axis is always
  /// "up", check which of the two rotated local axes actually points
  /// closest to true world-up and use that one as height, whichever raw
  /// field (x or z) it happens to come from on this particular reading.
  ({double width, double height}) _resolveWallDims(Vector3 extent, Quaternion rotation) {
    final rotatedX = _rotateVector(rotation, const Vector3(1, 0, 0));
    final rotatedZ = _rotateVector(rotation, const Vector3(0, 0, 1));
    final zIsUp = rotatedZ.y.abs() >= rotatedX.y.abs();
    return zIsUp ? (width: extent.x, height: extent.z) : (width: extent.z, height: extent.x);
  }

  /// Averages every reading across the whole hold streak, rather than just
  /// the single frame that happened to be live when the threshold was
  /// reached - this is what actually makes repeated scans agree with each
  /// other, since any one frame's AR plane extent has real frame-to-frame
  /// jitter even while genuinely holding still on the same wall.
  ({double width, double height}) _averageDims(List<({double width, double height})> dims) {
    var sumWidth = 0.0, sumHeight = 0.0;
    for (final d in dims) {
      sumWidth += d.width;
      sumHeight += d.height;
    }
    return (width: sumWidth / dims.length, height: sumHeight / dims.length);
  }

  /// Whether [dims] agrees closely enough with the current hold's running
  /// average to count as a continuation of a genuinely steady reading,
  /// rather than drift/noise that should restart the hold - this is the
  /// actual accuracy gate: the hold only completes once readings agree
  /// throughout, not merely once enough time has passed.
  bool _isConsistentWithHold(({double width, double height}) dims) {
    if (_stableDims.isEmpty) return true;
    final avg = _averageDims(_stableDims);
    final widthTolerance = math.max(_minAbsoluteTolerance, avg.width * _maxRelativeDeviation);
    final heightTolerance = math.max(_minAbsoluteTolerance, avg.height * _maxRelativeDeviation);
    return (dims.width - avg.width).abs() <= widthTolerance &&
        (dims.height - avg.height).abs() <= heightTolerance;
  }

  void _captureCurrentMeasurement() {
    if (_stableDims.isEmpty) return;
    final dims = _averageDims(_stableDims);
    setState(() {
      if (_capturedLength == null) {
        _capturedLength = dims.width;
        _capturedHeight = dims.height;
        _firstPlaneId = _currentPlaneId;
      } else {
        _capturedWidth = dims.width;
      }
      _currentPlaneId = null;
      _currentDims = null;
      _stableCount = 0;
      _stableDims.clear();
    });
    unawaited(_clearWallOutline());
  }

  void _reset() {
    setState(() {
      _capturedLength = null;
      _capturedWidth = null;
      _capturedHeight = null;
      _firstPlaneId = null;
      _currentPlaneId = null;
      _currentDims = null;
      _stableCount = 0;
      _stableDims.clear();
      _missedSamples = 0;
    });
    unawaited(_clearWallOutline());
  }

  void _confirm() {
    Navigator.of(context).pop({
      'length': _capturedLength!,
      'width': _capturedWidth!,
      'height': _capturedHeight!,
    });
  }

  // Serializes every outline add/update/remove call so a clear triggered by
  // capturing a measurement (or losing tracking) can never race a
  // still-in-flight update from the ~300ms sample timer over the same node
  // ids - that race (two overlapping async native calls touching
  // 'wallOutlineLeft' etc. out of order) is what produced spurious "node
  // not found" errors that looked like the whole AR session had failed.
  Future<void> _outlineQueue = Future.value();

  Future<void> _enqueueOutlineOp(Future<void> Function() op) {
    final result = _outlineQueue.then((_) => op());
    _outlineQueue = result.catchError((_) {});
    return result;
  }

  Future<void> _updateWallOutline(ARPlane plane, Quaternion rotation) {
    return _enqueueOutlineOp(() => _updateWallOutlineImpl(plane, rotation));
  }

  Future<void> _clearWallOutline() {
    return _enqueueOutlineOp(_clearWallOutlineImpl);
  }

  /// Draws (or moves) a live rectangular outline directly on the tracked
  /// wall using four thin AR nodes as edges, so the detected width/height
  /// can be visually checked against the real wall instead of trusting the
  /// on-screen number alone.
  Future<void> _updateWallOutlineImpl(ARPlane plane, Quaternion rotation) async {
    final controller = _controller;
    if (controller == null) return;

    final width = plane.extent.x;
    final height = plane.extent.z;
    if (width <= 0 || height <= 0) return;

    final halfWidth = width / 2;
    final halfHeight = height / 2;
    // Nudge the outline slightly out along the wall's own normal (local Y)
    // so it doesn't z-fight with the wall surface itself.
    const forwardOffset = 0.01;

    final edges = <String, (Vector3 localOffset, Vector3 sizeMeters)>{
      'wallOutlineTop': (
        Vector3(0, forwardOffset, halfHeight),
        Vector3(width, _outlineThickness, _outlineThickness),
      ),
      'wallOutlineBottom': (
        Vector3(0, forwardOffset, -halfHeight),
        Vector3(width, _outlineThickness, _outlineThickness),
      ),
      'wallOutlineLeft': (
        Vector3(-halfWidth, forwardOffset, 0),
        Vector3(_outlineThickness, _outlineThickness, height),
      ),
      'wallOutlineRight': (
        Vector3(halfWidth, forwardOffset, 0),
        Vector3(_outlineThickness, _outlineThickness, height),
      ),
    };

    for (final entry in edges.entries) {
      final id = entry.key;
      final (localOffset, sizeMeters) = entry.value;
      final node = ARNode(
        id: id,
        type: NodeType.cube,
        position: _vecAdd(plane.center, _rotateVector(rotation, localOffset)),
        rotation: rotation,
        scale: _vecScale(sizeMeters, 1 / _outlineBaseNodeSize),
      );
      try {
        if (_createdNodeIds.contains(id)) {
          await controller.updateNode(node);
        } else {
          await controller.addNode(node);
          _createdNodeIds.add(id);
        }
      } catch (_) {
        // Leave this id out of _createdNodeIds so the next tick retries
        // addNode for just this one edge, instead of a failed edge getting
        // permanently stuck calling updateNode on a node that was never
        // really created (see the _createdNodeIds field doc comment).
        _createdNodeIds.remove(id);
      }
    }
  }

  Future<void> _clearWallOutlineImpl() async {
    if (_createdNodeIds.isEmpty) return;
    final ids = _createdNodeIds.toList();
    _createdNodeIds.clear();
    final controller = _controller;
    if (controller == null) return;
    for (final id in ids) {
      try {
        await controller.removeNode(id);
      } catch (_) {}
    }
  }

  String get _statusText {
    if (_capturedWidth != null) return 'Got both measurements!';
    if (_capturedLength != null) return 'Now point the camera at the adjacent wall';
    if (_currentDims != null) return 'Hold steady...';
    return 'Point the camera at a wall';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Room (AR)')),
      body: switch (_state) {
        _ArState.requestingPermission => const Center(child: CircularProgressIndicator()),
        _ArState.permissionDenied => _PermissionDeniedView(permanentlyDenied: _permissionPermanentlyDenied),
        _ArState.unsupported => const _ErrorView(
            message: 'This device does not support AR (ARCore unavailable).',
          ),
        _ArState.error => _ErrorView(message: _errorMessage ?? 'Unknown AR error.'),
        _ArState.checking || _ArState.ready => Stack(
            children: [
              AugenView(config: _sessionConfig, onViewCreated: _onViewCreated),
              if (_state == _ArState.checking) const Center(child: CircularProgressIndicator()),
              if (_state == _ArState.ready) ...[
                // Center reticle showing exactly where the live measurement
                // is being sampled - point this at the wall.
                const Center(
                  child: Icon(Icons.add, color: Colors.white, size: 32),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(_statusText, style: const TextStyle(fontWeight: FontWeight.bold)),
                          if (_currentDims != null && _capturedWidth == null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _currentPlaneType == PlaneType.vertical
                                  ? 'Wall: ${_currentDims!.width.toStringAsFixed(2)} m wide '
                                      '× ${_currentDims!.height.toStringAsFixed(2)} m tall'
                                  : 'Floor: ${_currentDims!.width.toStringAsFixed(2)} m',
                              style: const TextStyle(fontSize: 20),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(value: _stableCount / _stableThreshold),
                          ],
                          if (_capturedLength != null) ...[
                            const SizedBox(height: 8),
                            Text('Length: ${_capturedLength!.toStringAsFixed(2)} m'),
                          ],
                          if (_capturedHeight != null && _capturedWidth == null) ...[
                            Text('Height: ${_capturedHeight!.toStringAsFixed(2)} m'),
                          ],
                          if (_capturedWidth != null) ...[
                            Text('Width: ${_capturedWidth!.toStringAsFixed(2)} m'),
                            if (_capturedHeight != null)
                              Text('Height: ${_capturedHeight!.toStringAsFixed(2)} m'),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(onPressed: _reset, child: const Text('Redo')),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton(onPressed: _confirm, child: const Text('Use these')),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
      },
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
                  : 'Camera permission is required for AR room scanning.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (permanentlyDenied)
              FilledButton(
                onPressed: openAppSettings,
                child: const Text('Open Settings'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go back'),
              ),
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
            Text(
              'AR isn\'t available on this device.\n$message\n\n'
              'You can still enter room dimensions manually.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}
