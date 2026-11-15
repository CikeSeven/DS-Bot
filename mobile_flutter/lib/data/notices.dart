// Port of mobile/src/team/notices.ts: tracks the last host notice seq per boot,
// so a reconnect catches up on missed notices without replaying live ones.
import 'json.dart';

class NoticeCursor {
  String? _boot;
  int _seq = 0;

  ({String? boot, int seq}) get snapshot => (boot: _boot, seq: _seq);

  ({bool sameBoot, int since}) connect({required String boot, required int seq}) {
    final sameBoot = _boot != null && _boot == boot;
    if (!sameBoot) {
      _boot = boot;
      _seq = seq;
      return (sameBoot: false, since: _seq);
    }
    return (sameBoot: true, since: _seq);
  }

  bool acceptLive(String helloBoot, Object? data) {
    final seq = jNum(data, 'seq');
    if (seq == null) return true;
    if (_boot != helloBoot) {
      _boot = helloBoot;
      _seq = seq.toInt();
      return true;
    }
    if (seq <= _seq) return false;
    _seq = seq.toInt();
    return true;
  }

  ({bool reset, List<Object?> replay}) acceptCatchUp(String helloBoot, Object? answer) {
    final nextBoot = jStr(answer, 'boot') ?? helloBoot;
    final reset = jBool(answer, 'reset') == true;
    if (_boot != nextBoot) {
      _boot = nextBoot;
      _seq = jInt(answer, 'seq') ?? 0;
      return (reset: reset, replay: const []);
    }
    final replay = <Object?>[];
    if (!reset) {
      for (final entry in jList(answer, 'notices')) {
        final seq = jNum(entry, 'seq');
        if (seq == null) {
          replay.add(entry);
        } else if (seq > _seq) {
          _seq = seq.toInt();
          replay.add(entry);
        }
      }
    }
    final seq = jInt(answer, 'seq');
    if (seq != null && seq > _seq) _seq = seq;
    return (reset: reset, replay: replay);
  }
}
