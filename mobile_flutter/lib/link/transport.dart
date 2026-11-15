// Port of link/src/transport.ts, plus a small WebSocket-shaped socket so the
// Relay transport can be driven by dart:io or by a fake in tests.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'frames.dart';

typedef Unsubscribe = void Function();

class TransportStats {
  const TransportStats({required this.connected, required this.bytesSent, required this.bytesReceived});

  final bool connected;
  final int bytesSent;
  final int bytesReceived;

  String get mode => connected ? 'Relay' : 'Disconnected';
}

abstract class RemoteTransport {
  Future<void> connect();
  Future<void> send(Uint8List data);
  Unsubscribe onMessage(void Function(Uint8List data) handler);
  Unsubscribe onClose(void Function() handler);

  /// Ask the far end for a liveness reply now, when the transport supports it.
  void probe() {}
  Future<void> close();
  TransportStats getStats();
}

abstract class SecureHandshakeTransport extends RemoteTransport {
  ({String connectionId, String localDeviceId, String remoteDeviceId}) connectionInfo();
  Future<void> sendHandshake(int step, Uint8List data);
  Unsubscribe onHandshake(void Function(int step, Uint8List data) handler);
  Object? get closeReason;
}

abstract class BaseTransport implements RemoteTransport {
  final Set<void Function(Uint8List)> _handlers = {};
  final Set<void Function()> _closeHandlers = {};

  @override
  Unsubscribe onMessage(void Function(Uint8List data) handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  @override
  Unsubscribe onClose(void Function() handler) {
    _closeHandlers.add(handler);
    return () => _closeHandlers.remove(handler);
  }

  void emit(Uint8List data) {
    for (final handler in [..._handlers]) {
      handler(data);
    }
  }

  void emitClose() {
    for (final handler in [..._closeHandlers]) {
      handler();
    }
  }

  @override
  void probe() {}
}

/// The parts of a browser WebSocket the Relay transport uses.
abstract class RelaySocket {
  static const connecting = 0;
  static const open = 1;
  static const closed = 3;

  int get readyState;
  void Function()? onOpen;
  void Function(Object data)? onMessage;
  void Function()? onError;
  void Function()? onClose;
  void send(String data);
  void close();
}

typedef RelaySocketFactory = RelaySocket Function(String url);

/// dart:io WebSocket behind the browser-style callbacks. No Origin header is
/// sent, which is what the Relay Server expects from an app.
class IoRelaySocket extends RelaySocket {
  IoRelaySocket(String url) {
    WebSocket.connect(url).then((socket) {
      if (_closedEarly) {
        socket.close();
        return;
      }
      _socket = socket;
      _readyState = RelaySocket.open;
      onOpen?.call();
      socket.listen(
        (data) => onMessage?.call(data as Object),
        onError: (_) => onError?.call(),
        onDone: _finish,
        cancelOnError: true,
      );
    }, onError: (_) {
      onError?.call();
      _finish();
    });
  }

  WebSocket? _socket;
  int _readyState = RelaySocket.connecting;
  bool _closedEarly = false;
  bool _finished = false;

  @override
  int get readyState => _readyState;

  void _finish() {
    if (_finished) return;
    _finished = true;
    _readyState = RelaySocket.closed;
    onClose?.call();
  }

  @override
  void send(String data) {
    final socket = _socket;
    if (socket == null || _readyState != RelaySocket.open) throw StateError('The socket is not open');
    socket.add(data);
  }

  @override
  void close() {
    if (_socket == null) {
      _closedEarly = true;
      Timer.run(_finish);
      return;
    }
    _socket!.close();
  }
}

final Expando<double> _nextSends = Expando<double>('relay-pacing');

/// Paces encoded envelopes on one socket under the Server's per-second budget,
/// without changing frame order. Call from serialized sends.
///
/// dart:io has no bufferedAmount, so only the pacing half of the TypeScript
/// waitForRelayCapacity applies here.
Future<void> waitForRelayCapacity(RelaySocket socket, [int wireBytes = 0]) async {
  if (wireBytes > 0) {
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    final last = _nextSends[socket] ?? now;
    final due = last > now ? last : now;
    final byFrames = 1000 / (maxRelayFramesPerSecond - 1);
    final byBytes = 1000 * wireBytes / (maxRelayBytesPerSecond - maxRelayFrameBytes);
    final interval = byFrames > byBytes ? byFrames : byBytes;
    _nextSends[socket] = due + interval;
    if (due > now) await Future<void>.delayed(Duration(milliseconds: (due - now).ceil()));
  }
  if (socket.readyState != RelaySocket.open) throw StateError('Relay transport closed');
}
