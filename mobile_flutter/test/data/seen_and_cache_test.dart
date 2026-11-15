import 'package:dsbot_mobile/data/chat_cache.dart';
import 'package:dsbot_mobile/data/seen.dart';
import 'package:dsbot_mobile/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

class FlakyStore extends MemoryStore {
  int failures = 0;

  @override
  Future<void> write(String key, String value) async {
    if (failures > 0) {
      failures -= 1;
      throw StateError('disk full');
    }
    await super.write(key, value);
  }
}

void main() {
  test('read times survive a restart, per computer', () async {
    final kv = MemoryStore();
    final first = SeenStore(kv);
    await first.load();
    await first.markSeen('h1', 'bot', 100);
    await first.markSeen('h2', 'bot', 50);

    final again = SeenStore(kv);
    await again.load();
    expect(again.seenAt('h1', 'bot'), 100);
    expect(again.seenAt('h2', 'bot'), 50);
    expect(again.isUnread('h1', 'bot', 90), isFalse);
    expect(again.isUnread('h1', 'bot', 120), isTrue);
    expect(again.isUnread('h1', 'bot', 120, open: true), isFalse);
  });

  test('marking before the load finishes merges with what is on disk', () async {
    final kv = MemoryStore({'dsbot.seenAt': '{"h1":{"a":10,"b":20}}'});
    final store = SeenStore(kv);
    await store.markSeen('h1', 'a', 15);
    await store.load();
    expect(store.seenAt('h1', 'a'), 15);
    expect(store.seenAt('h1', 'b'), 20);
    expect(SeenStore(kv)..load(), isNotNull);
    final reread = SeenStore(kv);
    await reread.load();
    expect(reread.seenAt('h1', 'b'), 20);
  });

  test('corrupted data starts fresh, and a failed write is retried', () async {
    final broken = SeenStore(MemoryStore({'dsbot.seenAt': '{not json'}));
    await broken.load();
    expect(broken.seenAt('h1', 'a'), 0);

    final kv = FlakyStore()..failures = 1;
    final store = SeenStore(kv);
    await store.markSeen('h1', 'a', 10);
    expect(kv.values.containsKey('dsbot.seenAt'), isFalse);
    await store.markSeen('h1', 'a', 10);
    expect(kv.values['dsbot.seenAt'], '{"h1":{"a":10}}');
  });

  test('the chat cache refuses a page written under another chat key', () {
    final cache = ChatCache<String, int>();
    expect(cache.keep('h:bot:a', 'h:bot:b', const CachedChat(page: 'p', older: [], cursor: null)), isFalse);
    expect(cache.has('h:bot:a'), isFalse);
    expect(cache.keep('h:bot:a', 'h:bot:a', const CachedChat(page: 'p', older: [], cursor: null)), isTrue);
  });

  test('the chat cache evicts the least recently used page', () {
    final cache = ChatCache<String, int>(2);
    cache.keep('a', 'a', const CachedChat(page: 'a', older: [], cursor: null));
    cache.keep('b', 'b', const CachedChat(page: 'b', older: [], cursor: null));
    cache.keep('a', 'a', const CachedChat(page: 'a2', older: [], cursor: null));
    cache.keep('c', 'c', const CachedChat(page: 'c', older: [], cursor: null));
    expect(cache.has('b'), isFalse);
    expect(cache.get('a')!.page, 'a2');
    expect(cache.size, 2);
  });
}
