// Port of link/src/relay-transport.ts: the client side of the Server's Relay.
// The Server only forwards ciphertext.
import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';
import 'frames.dart';
import 'keys.dart';
import 'transport.dart';

const _relayCapability = 'transport.relay';

class RelayTransportOptions {
  const RelayTransportOptions({
    required this.deviceId,
    required this.identityKey,
    required this.accessToken,
    required this.targetDeviceId,
    this.capabilities,
    this.handshakeTimeout = const Duration(seconds: 10),
    this.watchdogInterval = const Duration(seconds: 5),
    this.watchdogSilence = const Duration(seconds: 15),
    this.probeTimeout = const Duration(seconds: 10),
    this.createSocket,
  });

  final String deviceId;
  final String identityKey;
  final String accessToken;
  final String targetDeviceId;
  final List<String>? capabilities;
  final Duration handshakeTimeout;

  /// How often a ready socket's silence is checked.
  final Duration watchdogInterval;

  /// Silence after which a ready socket is probed.
  final Duration watchdogSilence;

  /// Silence after a probe that declares the link dead.
  final Duration probeTimeout;
  final RelaySocketFactory? createSocket;
}

class RelayTransport extends BaseTransport implements SecureHandshakeTransport {
  RelayTransport(this.url, this.options);

  final String url;
  final RelayTransportOptions options;
  final Set<void Function(int, Uint8List)> _handshakeHandlers = {};
  RelaySocket? _socket;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  String? _connectionId;
  int _relayCounter = 0;
  Completer<void>? _ready;
  Timer? _handshakeTimer;
  FrameLimits _limits = const FrameLimits();
  int _lastHeard = 0;
  int _probeAt = 0;
  void Function([Object? reason, bool emit])? _endCurrent;

  /// Why the Host or Server dropped a connection that was already set up, such as a phone no longer paired.
  @override
  Object? closeReason;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    final socket = options.createSocket?.call(url) ?? IoRelaySocket(url);
    _socket = socket;
    _limits = const FrameLimits();
    _relayCounter = 0;
    closeReason = null;
    final ready = Completer<void>();
    _ready = ready;
    _handshakeTimer = Timer(options.handshakeTimeout, () {
      _failConnection(LinkError('SERVER_UNREACHABLE', 'Relay control handshake timed out'));
    });
    // Every event from this socket counts only while it is still the current
    // one: a timed-out or replaced socket may still deliver late events, and a
    // stale close must never clear the live connection.
    bool stale() => !identical(_socket, socket);
    var ended = false;
    Timer? watchdog;
    // Giving up on this socket reports its close at once: on a half-open link
    // the socket's own close event can take minutes to arrive.
    void endSocket([Object? reason, bool emit = true]) {
      if (ended) return;
      ended = true;
      if (reason != null) closeReason = reason;
      socket.close();
      if (identical(_socket, socket)) {
        _socket = null;
        _connectionId = null;
        _endCurrent = null;
      }
      watchdog?.cancel();
      if (emit) emitClose();
    }

    _endCurrent = endSocket;
    _lastHeard = _now();
    _probeAt = 0;
    socket.onMessage = (data) {
      if (stale()) return;
      _lastHeard = _now();
      // A frame heard after a probe answers it, so the next silence probes again.
      _probeAt = 0;
      _handleSocketMessage(data);
    };
    socket.onOpen = () {
      if (stale()) return;
      _sendControl('hello', {
        'role': 'client',
        'deviceId': options.deviceId,
        'identityKey': options.identityKey,
        'accessToken': options.accessToken,
        'protocols': [protocolVersion],
        'capabilities': _offeredCapabilities(),
      });
    };
    socket.onError = () {
      if (!stale()) _failConnection(LinkError('SERVER_UNREACHABLE', 'RelayTransport failed to connect to $url'));
    };
    socket.onClose = () {
      if (ended) return;
      // Only a newer socket makes this close stale: a socket that
      // _failConnection or close() cleared still has to report the close.
      if (_socket != null && stale()) return;
      ended = true;
      watchdog?.cancel();
      if (_ready != null) _failConnection(LinkError('SERVER_UNREACHABLE', 'Relay control channel closed before it was ready'));
      _socket = null;
      _connectionId = null;
      emitClose();
    };
    watchdog = Timer.periodic(options.watchdogInterval, (_) {
      if (ended || !identical(_socket, socket) || _connectionId == null) return;
      final now = _now();
      if (_probeAt > 0) {
        final since = _lastHeard > _probeAt ? _lastHeard : _probeAt;
        if (now - since >= options.probeTimeout.inMilliseconds) {
          endSocket(LinkError('SERVER_UNREACHABLE', 'The Server stopped answering'));
        }
        return;
      }
      if (now - _lastHeard >= options.watchdogSilence.inMilliseconds) _probeNow();
    });
    return ready.future;
  }

  @override
  Future<void> send(Uint8List data) async {
    final socket = _socket;
    if (socket == null || socket.readyState != RelaySocket.open) throw StateError('relay transport is not connected');
    final connectionId = _connectionId;
    if (connectionId == null) throw StateError('relay connection has not been authorized');
    final frame = encodeControlFrame(
      Envelope('relay', {
        'connectionId': connectionId,
        'targetDeviceId': options.targetDeviceId,
        'counter': _relayCounter,
        'ciphertext': toBase64Url(data),
      }),
      _limits,
    );
    // The frame is ASCII (JSON of Base64URL and ids), so its length is its byte count.
    await waitForRelayCapacity(socket, frame.length);
    socket.send(frame);
    _bytesSent += data.length;
    _relayCounter += 1;
  }

  @override
  ({String connectionId, String localDeviceId, String remoteDeviceId}) connectionInfo() {
    final connectionId = _connectionId;
    if (connectionId == null) throw StateError('relay connection has not been authorized');
    return (connectionId: connectionId, localDeviceId: options.deviceId, remoteDeviceId: options.targetDeviceId);
  }

  @override
  Future<void> sendHandshake(int step, Uint8List data) async {
    final connectionId = _connectionId;
    if (_socket?.readyState != RelaySocket.open || connectionId == null) {
      throw StateError('relay connection has not been authorized');
    }
    _sendControl('secure.handshake', {
      'connectionId': connectionId,
      'targetDeviceId': options.targetDeviceId,
      'step': step,
      'data': toBase64Url(data),
    });
  }

  @override
  Unsubscribe onHandshake(void Function(int step, Uint8List data) handler) {
    _handshakeHandlers.add(handler);
    return () => _handshakeHandlers.remove(handler);
  }

  /// Ask the Server for a liveness reply now; a dead socket ends itself via the watchdog.
  @override
  void probe() {
    if (_socket?.readyState != RelaySocket.open || _connectionId == null || _probeAt > 0) return;
    _probeNow();
  }

  void _probeNow() {
    if (_socket == null) return;
    _probeAt = _now();
    // Runs from a timer, so a throw here must not escape.
    try {
      _sendControl('ping', {'nonce': _probeAt});
    } on Object {
      _endCurrent?.call(LinkError('SERVER_UNREACHABLE', 'The Server stopped answering'));
    }
  }

  @override
  Future<void> close() async {
    _clearHandshake();
    final end = _endCurrent;
    if (end != null) {
      end();
      return;
    }
    _socket?.close();
    _socket = null;
    _connectionId = null;
  }

  @override
  TransportStats getStats() => TransportStats(
        connected: _socket?.readyState == RelaySocket.open,
        bytesSent: _bytesSent,
        bytesReceived: _bytesReceived,
      );

  List<String> _offeredCapabilities() => options.capabilities ?? const [_relayCapability];

  void _handleSocketMessage(Object raw) {
    try {
      if (raw is! String) throw const FormatException('Relay control frames must be text JSON');
      final frame = decodeControlFrame(raw, _limits);
      final payload = frame.payload;
      switch (frame.type) {
        case 'hello.ack':
          if (payload['protocol'] != protocolVersion) throw StateError('Server selected an unsupported protocol version');
          final negotiated = acceptNegotiatedCapabilities(_offeredCapabilities(), payload['capabilities']);
          _limits = FrameLimits(
            maxControlFrameBytes: payload['maxControlFrameBytes'] is int ? payload['maxControlFrameBytes'] as int : null,
            maxRelayFrameBytes: payload['maxRelayFrameBytes'] is int ? payload['maxRelayFrameBytes'] as int : null,
          );
          if (!negotiated.contains(_relayCapability)) throw StateError('Server did not negotiate the required Relay capability');
          _sendControl('connect.request', {'hostDeviceId': options.targetDeviceId});
        case 'connect.accepted':
          final connectionId = payload['connectionId'];
          if (connectionId is! String || connectionId.isEmpty) throw StateError('connect.accepted did not include a connectionId');
          _connectionId = connectionId;
          _finishConnection();
        case 'connect.rejected' || 'error':
          final message = payload['message'];
          final code = payload['code'];
          throw LinkError(code is String ? code : null, message is String ? message : 'Server rejected the relay connection');
        case 'relay':
          final counter = payload['counter'];
          final ciphertext = payload['ciphertext'];
          if (payload['connectionId'] != _connectionId ||
              payload['targetDeviceId'] != options.deviceId ||
              counter is! int ||
              ciphertext is! String) {
            throw StateError('Received a relay frame for an unknown connection');
          }
          final data = fromBase64Url(ciphertext);
          _bytesReceived += data.length;
          emit(data);
        case 'secure.handshake':
          final step = payload['step'];
          final data = payload['data'];
          if (payload['connectionId'] != _connectionId ||
              payload['targetDeviceId'] != options.deviceId ||
              step is! int ||
              data is! String) {
            throw StateError('Received a secure handshake frame for an unknown connection');
          }
          final bytes = fromBase64Url(data);
          for (final handler in [..._handshakeHandlers]) {
            handler(step, bytes);
          }
        case 'ping':
          _sendControl('pong', payload);
      }
    } on Object catch (error) {
      _failConnection(error is LinkError ? error : LinkError(null, error is StateError ? error.message : '$error'));
    }
  }

  void _sendControl(String type, Map<String, Object?> payload) {
    final socket = _socket;
    if (socket == null || socket.readyState != RelaySocket.open) throw StateError('relay control socket is not open');
    socket.send(encodeControlFrame(Envelope(type, payload), _limits));
  }

  void _finishConnection() {
    _clearHandshake();
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  void _failConnection(Object error) {
    _clearHandshake();
    final ready = _ready;
    _ready = null;
    if (ready == null) {
      // Already ready: giving up on the socket is a close, reported at once.
      final end = _endCurrent;
      if (end != null) {
        end(error);
        return;
      }
      closeReason = error;
      _socket?.close();
      _socket = null;
      _connectionId = null;
      return;
    }
    if (!ready.isCompleted) ready.completeError(error);
    // A socket that never became ready is ended quietly: its late close event
    // must not be reported as a dropped connection.
    final end = _endCurrent;
    if (end != null) {
      end(null, false);
      return;
    }
    _socket?.close();
    _socket = null;
    _connectionId = null;
  }

  void _clearHandshake() {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
  }
}
