// The phone link's Rust library (rust/), for tests that make keys or read
// pairing links: built for this computer with cargo and loaded once per file.
// The first build takes a minute or two; later ones only check.
import 'dart:io';

import 'package:dsbot_mobile/link/rust_link.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;

Future<void> loadRustLink() async {
  final build = await Process.run('cargo', ['build', '--quiet', '--manifest-path', 'rust/Cargo.toml']);
  if (build.exitCode != 0) throw StateError('cargo could not build rust/:\n${build.stderr}');
  final file = switch (Platform.operatingSystem) {
    'macos' => 'libdsbot_link_ffi.dylib',
    'windows' => 'dsbot_link_ffi.dll',
    _ => 'libdsbot_link_ffi.so',
  };
  await initRustLink(library: ExternalLibrary.open('rust/target/debug/$file'));
}

/// A pairing link for a new computer key, as the computer's QR code carries it.
String testPairLink({String name = 'Desk', String server = 'wss://bot.example/v2/link', String code = 'ABCD-1234'}) {
  final keys = generateKeyPair();
  return Uri(scheme: 'dsbot', host: 'pair', queryParameters: {
    'v': '1',
    'server': server,
    'host': deviceIdFor(keys.publicKey),
    'key': keys.publicKey,
    'code': code,
    'name': name,
  }).toString();
}
