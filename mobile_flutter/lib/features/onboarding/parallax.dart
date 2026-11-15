// One parallax offset for the onboarding scene, about -1..1 on each axis: the
// phone's turning (gyroscope, leaked back to center so the scene recenters) plus
// a finger drag that springs home on release. A ticker eases the value toward
// that target once per frame, so layers move smoothly at any sensor rate.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

class ParallaxController extends ChangeNotifier implements ValueListenable<Offset> {
  ParallaxController({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  StreamSubscription<GyroscopeEvent>? _gyro;
  Offset _value = Offset.zero;
  Offset _tilt = Offset.zero;
  Offset _drag = Offset.zero;
  Duration _last = Duration.zero;

  @override
  Offset get value => _value;

  Offset get _target {
    final sum = _tilt + _drag;
    return Offset(sum.dx.clamp(-1.0, 1.0), sum.dy.clamp(-1.0, 1.0));
  }

  /// Follows the phone's turning while the scene shows. Without a gyroscope
  /// (an emulator, a test) only the finger moves the scene.
  void listenToMotion() {
    if (_gyro != null) return;
    try {
      _gyro = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (event) {
          // Turning about y (roll) moves the scene sideways, about x (pitch) up
          // and down. 20 ms samples; the leak pulls it back to center.
          const dt = 0.02;
          final next = Offset(_tilt.dx * 0.97 + event.y * dt * 0.9, _tilt.dy * 0.97 + event.x * dt * 0.9);
          _tilt = Offset(next.dx.clamp(-1.0, 1.0), next.dy.clamp(-1.0, 1.0));
          _wake();
        },
        onError: (Object _) => _stopMotion(),
        cancelOnError: true,
      );
    } on Object {
      _gyro = null;
    }
  }

  void _stopMotion() {
    unawaited(_gyro?.cancel());
    _gyro = null;
  }

  void stopMotion() {
    _stopMotion();
    _tilt = Offset.zero;
    _wake();
  }

  /// A drag across the scene, in fractions of the scene's size.
  void drag(Offset delta) {
    _drag = Offset((_drag.dx + delta.dx * 1.6).clamp(-1.0, 1.0), (_drag.dy + delta.dy * 1.6).clamp(-1.0, 1.0));
    _wake();
  }

  void release() {
    _drag = Offset.zero;
    _wake();
  }

  void _wake() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 1 / 60 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final target = _target;
    // Critically damped easing toward the target, frame-rate independent.
    final k = 1 - math.exp(-dt * 9);
    final next = _value + (target - _value) * k;
    if ((next - target).distance < 0.0005 && _gyro == null && _drag == Offset.zero) {
      _value = target;
      _ticker.stop();
    } else {
      _value = next;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopMotion();
    _ticker.dispose();
    super.dispose();
  }
}
