import 'package:dsbot_mobile/api/link_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a computer paired through a v1 relay address is reached at its v2 path', () {
    final saved = SavedComputer.fromJson({
      'server': 'wss://bot.sisct.xyz/v1/link',
      'hostDeviceId': 'd-host',
      'hostKey': 'key',
      'name': 'Desk',
      'addedAt': 1,
    })!;
    expect(saved.server, 'wss://bot.sisct.xyz/v2/link');
    expect(saved.toJson()['server'], 'wss://bot.sisct.xyz/v2/link');
    expect(linkV2Address('ws://relay.test:8787/custom'), 'ws://relay.test:8787/custom');
    expect(linkV2Address('wss://relay.test/v2/link'), 'wss://relay.test/v2/link');
  });
}
