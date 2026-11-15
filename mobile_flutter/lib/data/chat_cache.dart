// Port of mobile/src/team/chat-cache.ts: an LRU of the latest page per chat
// (`<computer>:<kind>:<id>`), so returning to a chat shows its messages on the
// first frame while a fresh read brings anything new. A write carries the key
// that loaded the page, so a page for one chat never lands under another's key.
class CachedChat<P, I> {
  const CachedChat({required this.page, required this.older, required this.cursor});

  final P page;
  final List<I> older;
  final Object? cursor;
}

class ChatCache<P, I> {
  ChatCache([this.limit = 16]);

  final int limit;
  final Map<String, CachedChat<P, I>> _map = {};

  CachedChat<P, I>? get(String key) => _map[key];

  bool has(String key) => _map.containsKey(key);

  bool keep(String chatKey, String ownerKey, CachedChat<P, I> entry) {
    if (chatKey.isEmpty || ownerKey != chatKey) return false;
    _map.remove(chatKey);
    _map[chatKey] = entry;
    if (_map.length > limit) _map.remove(_map.keys.first);
    return true;
  }

  int get size => _map.length;

  void clear() => _map.clear();
}
