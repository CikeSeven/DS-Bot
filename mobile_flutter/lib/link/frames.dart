// Port of link/src/frames.ts: control frames, messages inside Noise, and the
// fragmenting codec that splits plaintext before Noise encryption.
import 'dart:convert';
import 'dart:typed_data';

import 'keys.dart';

const protocolVersion = 1;
const linkPath = '/v1/link';
const maxControlFrameBytes = 64 * 1024;
const maxRelayFrameBytes = 1024 * 1024;
const secureFragmentChunkBytes = 48 * 1024;
const maxRelayBytesPerSecond = 8 * maxRelayFrameBytes;
const maxRelayFramesPerSecond = 512;
const maxSecureMessageBytes = 4 * 1024 * 1024;

const _fragmentMagic = [0x44, 0x53, 0x42, 0x46]; // DSBF
const _fragmentVersion = 1;
const _fragmentHeaderBytes = 17;
const _maxInFlightSecureMessages = 8;

const controlFrameTypes = {
  'hello',
  'hello.ack',
  'connect.request',
  'connect.incoming',
  'connect.accepted',
  'connect.rejected',
  'secure.handshake',
  'relay',
  'ping',
  'pong',
  'error',
};

const messageTypes = {'rpc.request', 'rpc.response', 'rpc.error', 'event'};

class FrameLimits {
  const FrameLimits({this.maxControlFrameBytes, this.maxRelayFrameBytes});

  final int? maxControlFrameBytes;
  final int? maxRelayFrameBytes;
}

/// A control frame or a message: `{v, id, type, timestamp, payload}`, keys in that order.
class Envelope {
  Envelope(this.type, this.payload, {String? id, num? timestamp})
      : id = id ?? randomUuid(),
        timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String type;
  final num timestamp;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {'v': protocolVersion, 'id': id, 'type': type, 'timestamp': timestamp, 'payload': payload};
}

/// Keeps only the capabilities both sides offered, in the order this side offered them.
List<String> acceptNegotiatedCapabilities(List<String> offered, Object? selected) {
  if (selected is! List || !selected.every((item) => item is String)) return const [];
  final chosen = selected.cast<String>().toSet();
  return offered.where(chosen.contains).toList();
}

String encodeControlFrame(Envelope frame, [FrameLimits limits = const FrameLimits()]) {
  if (!controlFrameTypes.contains(frame.type)) throw const FormatException('Control frame is invalid.');
  final encoded = jsonEncode(frame.toJson());
  _assertControlFrameSize(utf8.encode(encoded).length, frame.type, limits);
  return encoded;
}

Envelope decodeControlFrame(String data, [FrameLimits limits = const FrameLimits()]) {
  final bytes = utf8.encode(data).length;
  if (bytes > maxRelayFrameBytes) throw const FormatException('Control frame exceeds the Relay frame limit.');
  final frame = _parseEnvelope(jsonDecode(data), controlFrameTypes, 'Control frame is invalid.');
  _assertControlFrameSize(bytes, frame.type, limits);
  return frame;
}

Uint8List encodeMessage(Envelope message) => Uint8List.fromList(utf8.encode(jsonEncode(message.toJson())));

Envelope decodeMessage(List<int> data) {
  final text = utf8.decode(data, allowMalformed: true);
  return _parseEnvelope(jsonDecode(text), messageTypes, 'Remote message is invalid.');
}

Envelope _parseEnvelope(Object? value, Set<String> types, String error) {
  if (value is! Map<String, Object?>) throw FormatException(error);
  final id = value['id'];
  final type = value['type'];
  final timestamp = value['timestamp'];
  final payload = value['payload'];
  if (value['v'] != protocolVersion ||
      id is! String ||
      id.isEmpty ||
      type is! String ||
      !types.contains(type) ||
      timestamp is! num ||
      payload is! Map<String, Object?>) {
    throw FormatException(error);
  }
  return Envelope(type, payload, id: id, timestamp: timestamp);
}

void _assertControlFrameSize(int bytes, String type, FrameLimits limits) {
  final relay = type == 'relay';
  final configured = relay ? limits.maxRelayFrameBytes : limits.maxControlFrameBytes;
  final protocolMaximum = relay ? maxRelayFrameBytes : maxControlFrameBytes;
  final maximum = configured == null ? protocolMaximum : (configured < protocolMaximum ? configured : protocolMaximum);
  if (maximum <= 0) throw const FormatException('Control frame limit is invalid.');
  if (bytes > maximum) throw FormatException('${relay ? 'Relay' : 'Control'} frame exceeds its limit.');
}

class _Assembly {
  _Assembly(this.total, this.totalBytes);

  final int total;
  final int totalBytes;
  int receivedBytes = 0;
  final List<Uint8List> chunks = [];
}

/// Splits plaintext before Noise encryption and joins it after decryption.
/// One Noise transport message holds at most 65,535 bytes.
class SecureMessageCodec {
  int _nextMessageId = 1;
  final Map<int, _Assembly> _assemblies = {};

  List<Uint8List> encode(Uint8List message) {
    if (message.length > maxSecureMessageBytes) throw StateError('Secure message exceeds the reassembly limit.');
    if (message.length <= secureFragmentChunkBytes) return [message];

    final messageId = _nextMessageId;
    _nextMessageId = messageId == 0xffffffff ? 1 : messageId + 1;
    final total = (message.length + secureFragmentChunkBytes - 1) ~/ secureFragmentChunkBytes;
    final frames = <Uint8List>[];
    for (var index = 0; index < total; index += 1) {
      final start = index * secureFragmentChunkBytes;
      final end = start + secureFragmentChunkBytes < message.length ? start + secureFragmentChunkBytes : message.length;
      final frame = Uint8List(_fragmentHeaderBytes + end - start);
      frame.setRange(0, 4, _fragmentMagic);
      frame[4] = _fragmentVersion;
      final view = ByteData.sublistView(frame);
      view.setUint32(5, messageId);
      view.setUint16(9, index);
      view.setUint16(11, total);
      view.setUint32(13, message.length);
      frame.setRange(_fragmentHeaderBytes, frame.length, message, start);
      frames.add(frame);
    }
    return frames;
  }

  /// The whole message once its last fragment arrives; null while it is still incomplete.
  Uint8List? decode(Uint8List frame) {
    if (!_isSecureFragment(frame)) return frame;
    if (frame.length < _fragmentHeaderBytes || frame[4] != _fragmentVersion) {
      throw const FormatException('Secure fragment header is invalid.');
    }
    final view = ByteData.sublistView(frame);
    final messageId = view.getUint32(5);
    final index = view.getUint16(9);
    final total = view.getUint16(11);
    final totalBytes = view.getUint32(13);
    if (messageId == 0 ||
        total < 2 ||
        index >= total ||
        totalBytes <= secureFragmentChunkBytes ||
        totalBytes > maxSecureMessageBytes ||
        total != (totalBytes + secureFragmentChunkBytes - 1) ~/ secureFragmentChunkBytes) {
      throw const FormatException('Secure fragment metadata is invalid.');
    }
    final remaining = totalBytes - index * secureFragmentChunkBytes;
    final expectedChunkBytes = remaining < secureFragmentChunkBytes ? remaining : secureFragmentChunkBytes;
    final chunk = Uint8List.sublistView(frame, _fragmentHeaderBytes);
    if (chunk.length != expectedChunkBytes) throw const FormatException('Secure fragment length is invalid.');

    var assembly = _assemblies[messageId];
    if (assembly == null) {
      if (index != 0 || _assemblies.length >= _maxInFlightSecureMessages) {
        throw const FormatException('Secure fragment sequence is invalid.');
      }
      assembly = _Assembly(total, totalBytes);
      _assemblies[messageId] = assembly;
    }
    if (assembly.total != total || assembly.totalBytes != totalBytes || index != assembly.chunks.length) {
      _assemblies.remove(messageId);
      throw const FormatException('Secure fragment sequence is invalid.');
    }
    assembly.chunks.add(Uint8List.fromList(chunk));
    assembly.receivedBytes += chunk.length;
    if (assembly.chunks.length < total) return null;
    _assemblies.remove(messageId);
    if (assembly.receivedBytes != totalBytes) throw const FormatException('Secure message length is invalid.');
    final message = Uint8List(totalBytes);
    var offset = 0;
    for (final part in assembly.chunks) {
      message.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return message;
  }

  void reset() {
    _nextMessageId = 1;
    _assemblies.clear();
  }
}

bool _isSecureFragment(Uint8List frame) {
  if (frame.length < _fragmentMagic.length) return false;
  for (var i = 0; i < _fragmentMagic.length; i += 1) {
    if (frame[i] != _fragmentMagic[i]) return false;
  }
  return true;
}
