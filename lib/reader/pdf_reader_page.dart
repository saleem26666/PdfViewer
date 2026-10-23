import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'convert_book.dart';
import 'reflow_reader_page.dart';
import 'urdu_book.dart';

/// PDF reader whose zoom stays put while one finger pans.
///
/// pdfrx's built-in scale gesture treats a one-finger drag as a pinch on some
/// phones, which snaps the page back to fit. Pan and pinch are handled here
/// instead: one finger only moves the page, two fingers change zoom.
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({super.key, required this.path});

  final String path;

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> with TickerProviderStateMixin {
  final PdfViewerController _controller = PdfViewerController();
  final Map<int, Offset> _points = {};
  final Map<int, VelocityTracker> _trackers = {};

  int _page = 1;
  int _pages = 0;
  bool _night = false;
  double _zoomHint = 1;

  _Gesture _gesture = _Gesture.idle;
  Offset? _downPos;
  Offset? _lastFocal;
  double? _lockedZoom;
  double _pinchStartDist = 1;
  double _pinchStartZoom = 1;
  double _flingX = 0;
  double _flingY = 0;
  Ticker? _fling;
  Duration _flingStamp = Duration.zero;

  String get _title => p.basename(widget.path);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onViewChanged);
  }

  @override
  void dispose() {
    _fling?.dispose();
    _controller.removeListener(_onViewChanged);
    super.dispose();
  }

  void _onViewChanged() {
    if (!mounted || !_controller.isReady) return;
    final zoom = _controller.currentZoom;
    final page = _controller.pageNumber ?? _page;
    final pages = _controller.pageCount;
    if (zoom == _zoomHint && page == _page && pages == _pages) return;
    setState(() {
      _zoomHint = zoom;
      _page = page;
      _pages = pages;
    });
  }

  void _stopFling() {
    _fling?.stop();
    _flingX = 0;
    _flingY = 0;
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _flingStamp).inMicroseconds / 1000000;
    _flingStamp = elapsed;
    if (dt <= 0 || dt > 0.05 || !_controller.isReady) return;
    final before = _controller.value.getTranslation();
    _shift(Offset(_flingX * dt, _flingY * dt), zoom: _lockedZoom ?? _controller.currentZoom);
    final after = _controller.value.getTranslation();
    final moved = (after.x - before.x).abs() > 0.3 || (after.y - before.y).abs() > 0.3;
    const drag = 3.6;
    final decay = math.exp(-drag * dt);
    _flingX *= decay;
    _flingY *= decay;
    if (!moved || (_flingX.abs() < 30 && _flingY.abs() < 30)) {
      _stopFling();
    }
  }

  void _startFling(Offset pixelsPerSecond) {
    _flingX = pixelsPerSecond.dx;
    _flingY = pixelsPerSecond.dy;
    _flingStamp = Duration.zero;
    _fling ??= createTicker(_onTick);
    _fling!.start();
  }

  double _clampZoom(double zoom) {
    final minScale = _controller.minScale;
    final maxScale = _controller.maxScale;
    if (zoom < minScale) return minScale;
    if (zoom > maxScale) return maxScale;
    return zoom;
  }

  void _shift(Offset delta, {required double zoom}) {
    final focal = _lastFocal ?? Offset.zero;
    _place(
      fromFocal: focal,
      toFocal: focal + delta,
      fromZoom: _controller.currentZoom,
      toZoom: zoom,
    );
    _lastFocal = focal + delta;
  }

  void _place({
    required Offset fromFocal,
    required Offset toFocal,
    required double fromZoom,
    required double toZoom,
  }) {
    if (!_controller.isReady || fromZoom <= 0 || toZoom <= 0) return;
    final translation = _controller.value.getTranslation();
    final docX = (fromFocal.dx - translation.x) / fromZoom;
    final docY = (fromFocal.dy - translation.y) / fromZoom;
    final tx = toFocal.dx - docX * toZoom;
    final ty = toFocal.dy - docY * toZoom;
    final matrix = Matrix4.identity()
      ..setEntry(0, 0, toZoom)
      ..setEntry(1, 1, toZoom)
      ..setEntry(2, 2, toZoom)
      ..setTranslationRaw(tx, ty, 0);
    _controller.value = matrix;
  }

  void _syncPinch() {
    final pts = _points.values.take(2).toList();
    if (pts.length < 2 || !_controller.isReady) return;
    _pinchStartDist = math.max(8, (pts[0] - pts[1]).distance);
    _pinchStartZoom = _controller.currentZoom;
    _lastFocal = (pts[0] + pts[1]) / 2;
    _lockedZoom = null;
  }

  void _onDown(PointerDownEvent event) {
    _stopFling();
    if (_controller.isReady) _controller.stopInteractiveViewerAnimation();
    _points[event.pointer] = event.localPosition;
    _trackers[event.pointer] = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    if (_points.length >= 2) {
      _gesture = _Gesture.pinch;
      _syncPinch();
    } else {
      _gesture = _Gesture.pending;
      _downPos = event.localPosition;
      _lastFocal = event.localPosition;
      if (_controller.isReady) _lockedZoom = _controller.currentZoom;
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (!_points.containsKey(event.pointer) || !_controller.isReady) return;
    _points[event.pointer] = event.localPosition;
    _trackers[event.pointer]?.addPosition(event.timeStamp, event.localPosition);
    if (_points.length >= 2) {
      if (_gesture != _Gesture.pinch) {
        _gesture = _Gesture.pinch;
        _syncPinch();
      }
      final pts = _points.values.take(2).toList();
      final dist = math.max(8, (pts[0] - pts[1]).distance);
      final focal = (pts[0] + pts[1]) / 2;
      final next = _clampZoom(_pinchStartZoom * dist / _pinchStartDist);
      _place(
        fromFocal: _lastFocal ?? focal,
        toFocal: focal,
        fromZoom: _controller.currentZoom,
        toZoom: next,
      );
      _lastFocal = focal;
      return;
    }
    final pos = event.localPosition;
    final origin = _downPos;
    if (_gesture != _Gesture.pan && origin != null && (pos - origin).distance < 14) {
      return;
    }
    _gesture = _Gesture.pan;
    final locked = _lockedZoom ?? _controller.currentZoom;
    _place(
      fromFocal: _lastFocal ?? pos,
      toFocal: pos,
      fromZoom: _controller.currentZoom,
      toZoom: locked,
    );
    _lastFocal = pos;
  }

  void _onUp(PointerEvent event) {
    final tracker = _trackers.remove(event.pointer);
    final wasPinch = _points.length >= 2;
    _points.remove(event.pointer);
    if (_points.length >= 2) {
      _syncPinch();
      return;
    }
    if (_points.length == 1) {
      _gesture = _Gesture.pan;
      _lastFocal = _points.values.first;
      _downPos = _lastFocal;
      if (_controller.isReady) _lockedZoom = _controller.currentZoom;
      return;
    }
    if (!wasPinch && _gesture == _Gesture.pan && tracker != null) {
      try {
        final velocity = tracker.getVelocity().pixelsPerSecond;
        if (velocity.distance > 280) _startFling(velocity);
      } catch (_) {}
    }
    _gesture = _Gesture.idle;
  }

  Future<String?> _askPassword() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Password required'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'PDF password',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Open')),
        ],
      ),
    );
    return result;
  }

  Future<void> _goToPage() async {
    if (_pages <= 0) return;
    final ctrl = TextEditingController(text: '$_page');
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '1 – $_pages',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Go')),
        ],
      ),
    );
    final n = int.tryParse(raw?.trim() ?? '');
    if (n == null || n < 1 || n > _pages) return;
    await _controller.goToPage(pageNumber: n);
  }

  bool _onTap(BuildContext context, PdfViewerController controller, PdfViewerGeneralTapHandlerDetails details) {
    if (details.type != PdfViewerGeneralTapType.doubleTap || !controller.isReady) {
      return false;
    }
    final minScale = controller.minScale;
    final current = controller.currentZoom;
    final target = current > minScale * 1.25
        ? minScale
        : math.min(math.max(current * 2.5, minScale * 2.5), controller.maxScale);
    controller.zoomOnLocalPosition(
      localPosition: details.localPosition,
      newZoom: target,
      duration: Duration.zero,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final bg = _night ? const Color(0xFF121212) : const Color(0xFFE8E8E8);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'To Urdu',
            onPressed: () async {
              final saved = await translateBookFile(context, widget.path);
              if (saved == null || !context.mounted) return;
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReflowReaderPage(path: saved)));
            },
            icon: const Icon(Icons.translate),
          ),
          IconButton(
            tooltip: 'Convert',
            onPressed: () => convertBookFile(context, widget.path),
            icon: const Icon(Icons.swap_horiz),
          ),
          IconButton(
            tooltip: _night ? 'Light page' : 'Night page',
            onPressed: () => setState(() => _night = !_night),
            icon: Icon(_night ? Icons.light_mode : Icons.dark_mode_outlined),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () async {
              await _controller.zoomDown();
            },
            icon: const Icon(Icons.zoom_out),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () async {
              await _controller.zoomUp();
            },
            icon: const Icon(Icons.zoom_in),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: bg,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
                onPointerCancel: _onUp,
                child: PdfViewer.file(
                  widget.path,
                  controller: _controller,
                  passwordProvider: _askPassword,
                  params: PdfViewerParams(
                    backgroundColor: bg,
                    margin: 8,
                    panEnabled: false,
                    scaleEnabled: false,
                    sizeDelegateProvider: const PdfViewerSizeDelegateProviderLegacy(maxScale: 12),
                    onGeneralTap: _onTap,
                    onPageChanged: (page) {
                      if (page == null || !mounted) return;
                      setState(() {
                        _page = page;
                        _pages = _controller.pageCount;
                        _zoomHint = _controller.currentZoom;
                      });
                    },
                    onViewerReady: (doc, controller) {
                      if (!mounted) return;
                      setState(() {
                        _pages = doc.pages.length;
                        _page = controller.pageNumber ?? 1;
                        _zoomHint = controller.currentZoom;
                      });
                    },
                    errorBannerBuilder: (context, error, stack, documentRef) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Could not open PDF.\n\n$error',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                    loadingBannerBuilder: (context, bytes, total) {
                      return const Center(child: CircularProgressIndicator());
                    },
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Material(
              elevation: 6,
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      onPressed: _page <= 1 ? null : () => _controller.goToPage(pageNumber: _page - 1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: _goToPage,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            _pages > 0 ? 'Page $_page / $_pages' : 'Loading…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: (_pages == 0 || _page >= _pages)
                          ? null
                          : () => _controller.goToPage(pageNumber: _page + 1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                    Text(
                      '${(_zoomHint * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Gesture { idle, pending, pan, pinch }
