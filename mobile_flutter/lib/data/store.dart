// What the phone keeps: its identity, the paired computers, prefs, read times.
// Port of the Expo app's src/store.ts over a small key-value interface, so tests run
// without the platform keystore.
import 'dart:convert';

import '../api/link_client.dart';
import '../link/rust_link.dart';

abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryStore implements KeyValueStore {
  MemoryStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class ComputerList {
  const ComputerList(this.activeId, this.computers);

  final String? activeId;
  final List<SavedComputer> computers;

  SavedComputer? get active {
    for (final computer in computers) {
      if (computer.hostDeviceId == activeId) return computer;
    }
    return computers.isEmpty ? null : computers.first;
  }

  Map<String, Object?> toJson() => {'activeId': activeId, 'computers': computers.map((item) => item.toJson()).toList()};
}

class PhoneStore {
  PhoneStore(this._kv);

  static const _identityKey = 'dsbot.identity';
  static const _computersKey = 'dsbot.computers';
  static const _prefsKey = 'dsbot.prefs';
  static const _lastChatKey = 'dsbot.lastChat';

  final KeyValueStore _kv;
  Map<String, String>? _prefs;

  KeyValueStore get kv => _kv;

  Future<Object?> _readJson(String key) async {
    final text = await _kv.read(key);
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<PhoneIdentity> loadIdentity() async {
    final saved = PhoneIdentity.fromJson(await _readJson(_identityKey));
    if (saved != null) return saved;
    final identity = PhoneIdentity.generate();
    await _kv.write(_identityKey, jsonEncode(identity.toJson()));
    return identity;
  }

  Future<ComputerList> listComputers() async {
    final saved = await _readJson(_computersKey);
    if (saved is! Map) return const ComputerList(null, []);
    final computers = (saved['computers'] is List ? saved['computers'] as List : const [])
        .map(SavedComputer.fromJson)
        .whereType<SavedComputer>()
        .toList();
    final activeId = saved['activeId'];
    return ComputerList(activeId is String ? activeId : null, computers);
  }

  Future<void> _saveComputers(ComputerList list) => _kv.write(_computersKey, jsonEncode(list.toJson()));

  /// Pairing again with a known computer (new Server address, new key) replaces its entry in place.
  Future<SavedComputer> addComputer(PairingOffer offer, {String? name}) async {
    final list = await listComputers();
    final known = list.computers.where((item) => item.hostDeviceId == offer.hostDeviceId).firstOrNull;
    var computer = SavedComputer.fromOffer(offer, addedAt: known?.addedAt);
    if (name != null && name.isNotEmpty && offer.name.isEmpty) computer = computer.copyWith(name: name);
    final computers = known == null
        ? [...list.computers, computer]
        : list.computers.map((item) => item.hostDeviceId == offer.hostDeviceId ? computer : item).toList();
    await _saveComputers(ComputerList(computer.hostDeviceId, computers));
    return computer;
  }

  Future<void> setActiveComputer(String hostDeviceId) async {
    final list = await listComputers();
    await _saveComputers(ComputerList(hostDeviceId, list.computers));
  }

  Future<List<SavedComputer>> removeComputer(String hostDeviceId) async {
    final list = await listComputers();
    final computers = list.computers.where((item) => item.hostDeviceId != hostDeviceId).toList();
    final activeId = list.activeId == hostDeviceId ? computers.firstOrNull?.hostDeviceId : list.activeId;
    await _saveComputers(ComputerList(activeId, computers));
    return computers;
  }

  Future<Map<String, String>> readPrefs() async {
    final cached = _prefs;
    if (cached != null) return cached;
    final saved = await _readJson(_prefsKey);
    final prefs = <String, String>{};
    if (saved is Map) {
      for (final entry in saved.entries) {
        if (entry.key is String && entry.value is String) prefs[entry.key as String] = entry.value as String;
      }
    }
    return _prefs = prefs;
  }

  Future<void> writePrefs(Map<String, String> patch) async {
    final next = {...await readPrefs(), ...patch};
    _prefs = next;
    await _kv.write(_prefsKey, jsonEncode(next));
  }

  /// The chat the app opens on, per computer.
  Future<({String kind, String id})?> lastChat(String hostDeviceId) async {
    final saved = await _readJson(_lastChatKey);
    final entry = saved is Map ? saved[hostDeviceId] : null;
    if (entry is! Map || entry['kind'] is! String || entry['id'] is! String) return null;
    return (kind: entry['kind'] as String, id: entry['id'] as String);
  }

  Future<void> saveLastChat(String hostDeviceId, String kind, String id) async {
    final saved = await _readJson(_lastChatKey);
    final next = saved is Map ? Map<String, Object?>.from(saved) : <String, Object?>{};
    next[hostDeviceId] = {'kind': kind, 'id': id};
    await _kv.write(_lastChatKey, jsonEncode(next));
  }
}
