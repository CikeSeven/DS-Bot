// Port of the phone half of link/src/pairing.ts.
import 'dart:convert';
import 'dart:typed_data';

import 'keys.dart';

const _maxName = 64;
const _maxCode = 128;

/// What each side tells the other inside the encrypted handshake.
class HandshakeHello {
  const HandshakeHello({this.name, this.pairingCode});

  final String? name;
  final String? pairingCode;
}

/// What the computer's pairing QR code carries to the phone.
class PairingOffer {
  const PairingOffer({
    required this.server,
    required this.hostDeviceId,
    required this.hostKey,
    required this.code,
    required this.name,
  });

  final String server;
  final String hostDeviceId;
  final String hostKey;
  final String code;
  final String name;
}

Uint8List encodeHandshakeHello(HandshakeHello hello) {
  _checkHello(hello.name, hello.pairingCode);
  final map = <String, Object?>{
    if (hello.name != null) 'name': hello.name,
    if (hello.pairingCode != null) 'pairingCode': hello.pairingCode,
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(map)));
}

HandshakeHello decodeHandshakeHello(List<int> data) {
  if (data.isEmpty) return const HandshakeHello();
  final value = jsonDecode(utf8.decode(data));
  if (value is! Map<String, Object?>) throw const FormatException('The handshake hello is invalid.');
  final name = value['name'];
  final code = value['pairingCode'];
  if (name != null && name is! String) throw const FormatException('The device name is invalid.');
  if (code != null && code is! String) throw const FormatException('The pairing code is invalid.');
  _checkHello(name as String?, code as String?);
  return HandshakeHello(name: name, pairingCode: code);
}

void _checkHello(String? name, String? pairingCode) {
  if (name != null && name.length > _maxName) throw const FormatException('The device name is invalid.');
  if (pairingCode != null && (pairingCode.isEmpty || pairingCode.length > _maxCode)) {
    throw const FormatException('The pairing code is invalid.');
  }
}

String pairingUri(PairingOffer offer) {
  final query = [
    ['v', '1'],
    ['server', offer.server],
    ['host', offer.hostDeviceId],
    ['key', offer.hostKey],
    ['code', offer.code],
    ['name', offer.name],
  ].map((pair) => '${_formEncode(pair[0])}=${_formEncode(pair[1])}').join('&');
  return 'dsbot://pair?$query';
}

// application/x-www-form-urlencoded, as URLSearchParams writes it.
String _formEncode(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final char = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9*\-._]').hasMatch(char)) {
      out.write(char);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

PairingOffer parsePairingUri(String uri) {
  final Uri url;
  try {
    url = Uri.parse(uri.trim());
  } on FormatException {
    throw const FormatException('This is not a DS Bot pairing code.');
  }
  final params = url.queryParameters;
  if (url.scheme != 'dsbot' || url.host != 'pair' || params['v'] != '1') {
    throw const FormatException('This is not a DS Bot pairing code.');
  }
  String field(String name) {
    final value = params[name];
    if (value == null || value.isEmpty) throw FormatException('The pairing code has no $name.');
    return value;
  }

  final server = field('server');
  final serverScheme = Uri.tryParse(server)?.scheme;
  if (serverScheme != 'ws' && serverScheme != 'wss') throw const FormatException('The pairing code names an invalid Server.');
  final name = params['name'] ?? '';
  final offer = PairingOffer(
    server: server,
    hostDeviceId: field('host'),
    hostKey: field('key'),
    code: field('code'),
    name: name.length > _maxName ? name.substring(0, _maxName) : name,
  );
  final String derived;
  try {
    derived = deviceIdFor(offer.hostKey);
  } on Object {
    throw const FormatException('The pairing code does not match its computer.');
  }
  if (derived != offer.hostDeviceId) throw const FormatException('The pairing code does not match its computer.');
  return offer;
}
