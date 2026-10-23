import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Pinch-zoom that ignores one-finger scale noise.
///
/// One finger pans. Two fingers zoom around the fingers and can also drag.
/// Zoom never changes on a one-finger move, so a zoomed page does not snap back.
class StableZoom extends StatefulWidget {
  const StableZoom({
    super.key,
    required this.child,
    this.minScale = 1,
    this.maxScale = 8,
    this.onScaleChanged,
  });

  final Widget child;
  final double minScale;
  final double maxScale;
  final ValueChanged<double>? onScaleChanged;

  @override
  State<StableZoom> createState() => _StableZoomState();
}

class _StableZoomState extends State<StableZoom> with TickerProviderStateMixin {
  final Map<int, Offset> _points = {};
  final Map<int, VelocityTracker> _trackers = {};

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _view = Size.zero;
  _Mode _mode = _Mode.idle;
  Offset? _lastFocal;
  Offset? _origin;
  double _pinchDist = 1;
  double _pinchScale = 1;
  double _vx = 0;
  double _vy = 0;
  Ticker? _fling;
  Duration _stamp = Duration.zero;

  @override
  void dispose() {
    _fling?.dispose();
    super.dispose();
  }

  void _setScale(double value) {
    final next = value.clamp(widget.minScale, widget.maxScale);
    if (next == _scale) return;
    _scale = next;
    widget.onScaleChanged?.call(_scale);
  }

  void _clamp() {
    final w = _view.width * _scale;
    final h = _view.height * _scale;
    final minX = math.min(0.0, _view.width - w);
    final minY = math.min(0.0, _view.height - h);
    _offset = Offset(_offset.dx.clamp(minX, 0), _offset.dy.clamp(minY, 0));
  }

  void _zoomAt(Offset from, Offset to, double newScale) {
    if (_scale <= 0) return;
    final doc = (from - _offset) / _scale;
    _setScale(newScale);
    _offset = to - doc * _scale;
    _clamp();
  }

  void _stopFling() => _fling?.stop();

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _stamp).inMicroseconds / 1000000;
    _stamp = elapsed;
    if (dt <= 0 || dt > 0.05) return;
    final before = _offset;
    setState(() {
      _offset += Offset(_vx * dt, _vy * dt);
      _clamp();
    });
    final moved = (_offset - before).distance > 0.3;
    final decay = math.exp(-3.6 * dt);
    _vx *= decay;
    _vy *= decay;
    if (!moved || (_vx.abs() < 30 && _vy.abs() < 30)) _stopFling();
  }

  void _syncPinch() {
    final pts = _points.values.take(2).toList();
    if (pts.length < 2) return;
    _pinchDist = math.max(8, (pts[0] - pts[1]).distance);
    _pinchScale = _scale;
    _lastFocal = (pts[0] + pts[1]) / 2;
  }

  void _down(PointerDownEvent event) {
    _stopFling();
    _points[event.pointer] = event.localPosition;
    _trackers[event.pointer] = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    if (_points.length >= 2) {
      _mode = _Mode.pinch;
      _syncPinch();
    } else {
      _mode = _Mode.pending;
      _origin = event.localPosition;
      _lastFocal = event.localPosition;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_points.containsKey(event.pointer)) return;
    _points[event.pointer] = event.localPosition;
    _trackers[event.pointer]?.addPosition(event.timeStamp, event.localPosition);
    if (_points.length >= 2) {
      if (_mode != _Mode.pinch) {
        _mode = _Mode.pinch;
        _syncPinch();
      }
      final pts = _points.values.take(2).toList();
      final dist = math.max(8, (pts[0] - pts[1]).distance);
      final focal = (pts[0] + pts[1]) / 2;
      setState(() {
        _zoomAt(_lastFocal ?? focal, focal, _pinchScale * dist / _pinchDist);
      });
      _lastFocal = focal;
      return;
    }
    final pos = event.localPosition;
    if (_mode != _Mode.pan && _origin != null && (pos - _origin!).distance < 14) return;
    if (_scale <= widget.minScale + 0.01) return;
    _mode = _Mode.pan;
    setState(() {
      _zoomAt(_lastFocal ?? pos, pos, _scale);
    });
    _lastFocal = pos;
  }

  void _up(PointerEvent event) {
    final tracker = _trackers.remove(event.pointer);
    final wasPinch = _points.length >= 2;
    _points.remove(event.pointer);
    if (_points.length >= 2) {
      _syncPinch();
      return;
    }
    if (_points.length == 1) {
      _mode = _Mode.pan;
      _lastFocal = _points.values.first;
      _origin = _lastFocal;
      return;
    }
    if (!wasPinch && _mode == _Mode.pan && tracker != null && _scale > widget.minScale + 0.01) {
      try {
        final velocity = tracker.getVelocity().pixelsPerSecond;
        if (velocity.distance > 280) {
          _vx = velocity.dx;
          _vy = velocity.dy;
          _stamp = Duration.zero;
          _fling ??= createTicker(_onTick);
          _fling!.start();
        }
      } catch (_) {}
    }
    _mode = _Mode.idle;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _view = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: ClipRect(
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                ..scaleByDouble(_scale, _scale, 1, 1),
              child: SizedBox(
                width: _view.width,
                height: _view.height,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _Mode { idle, pending, pan, pinch }
