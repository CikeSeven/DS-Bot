// Phone services behind the data layer's small interfaces: the keystore, the
// device unlock, and the phone's name for the computer's device list.
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../api/link_client.dart';
import '../data/gate.dart';
import '../data/store.dart';
import '../ui/i18n.dart';

/// Keychain on iOS, Keystore-backed storage on Android. The keys never leave
/// this phone, not even in a backup.
class SecureKeyValueStore implements KeyValueStore {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
    aOptions: AndroidOptions(),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class DeviceUnlocker implements Unlocker {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<void> unlock(String reason) async {
    final supported = await _auth.isDeviceSupported();
    if (!supported) throw BotError('unlock/unavailable', t('Set a screen lock on this phone to do this'));
    bool ok;
    try {
      ok = await _auth.authenticate(localizedReason: t('Unlock to continue'));
    } on Object {
      ok = false;
    }
    if (!ok) throw BotError('unlock/canceled', t('Canceled'));
  }
}

String? _phoneName;

/// "Manufacturer Model" on Android; iPhone or iPad on iOS.
Future<String> phoneName() async {
  final cached = _phoneName;
  if (cached != null) return cached;
  final info = DeviceInfoPlugin();
  String name;
  try {
    if (Platform.isAndroid) {
      final android = await info.androidInfo;
      name = [android.manufacturer, android.model].where((part) => part.isNotEmpty).join(' ');
      if (name.isEmpty) name = 'Android phone';
    } else if (Platform.isIOS) {
      final ios = await info.iosInfo;
      name = ios.model.toLowerCase().contains('ipad') ? 'iPad' : 'iPhone';
    } else {
      name = 'Phone';
    }
  } on Object {
    name = 'Phone';
  }
  return _phoneName = name.length > 64 ? name.substring(0, 64) : name;
}
