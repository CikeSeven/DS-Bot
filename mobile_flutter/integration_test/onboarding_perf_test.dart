// Frame timings of the whole first-run flow on a real phone, in profile mode:
// the welcome entrance and its loops, a parallax drag, the button and the warp,
// the pairing page with its glass, the handshake and the connected check.
//
//   flutter drive --profile --driver=test_driver/perf_driver.dart \
//     --target=integration_test/onboarding_perf_test.dart
//
// Frame timings come straight from the engine (FrameTiming), so nothing needs
// the VM Service; the summary, per phase, lands in build/onboarding_perf.json.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:dsbot_mobile/api/link_client.dart';
import 'package:dsbot_mobile/app/app.dart';
import 'package:dsbot_mobile/app/app_state.dart';
import 'package:dsbot_mobile/data/store.dart';
import 'package:dsbot_mobile/features/onboarding/welcome_page.dart';
import 'package:dsbot_mobile/link/rust_link.dart';
import 'package:dsbot_mobile/shared/shared_data.dart';
import 'package:dsbot_mobile/ui/glass_button.dart';
import 'package:dsbot_mobile/ui/i18n.dart';
import 'package:dsbot_mobile/ui/liquid_glass.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A computer that accepts the phone at once and has nothing else to say.
class _AcceptingComputer implements LinkClient {
  @override
  String? get hostName => 'Desk';

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) async => <String, Object?>{};

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) => () {};

  @override
  LinkStatus get status => const LinkStatus(LinkPhase.online);

  @override
  Stream<LinkStatus> get statuses => const Stream.empty();

  @override
  void networkChanged() {}

  @override
  void setForeground(bool foreground) {}

  @override
  Future<void> close() async {}
}

Future<void> _live(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

double _ms(Duration d) => d.inMicroseconds / 1000;

double _percentile(List<double> sorted, double p) =>
    sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];

/// Build, raster and whole-frame times for some frames, against a frame
/// budget in milliseconds.
Map<String, Object> _summary(List<FrameTiming> frames, double budget) {
  Map<String, double> stats(List<double> values) {
    final sorted = [...values]..sort();
    final mean = values.isEmpty ? 0.0 : values.reduce((a, b) => a + b) / values.length;
    return {
      'mean': double.parse(mean.toStringAsFixed(2)),
      'p50': _percentile(sorted, 0.5),
      'p90': _percentile(sorted, 0.9),
      'p99': _percentile(sorted, 0.99),
      'worst': sorted.isEmpty ? 0 : sorted.last,
    };
  }

  final build = [for (final f in frames) _ms(f.buildDuration)];
  final raster = [for (final f in frames) _ms(f.rasterDuration)];
  return {
    'frames': frames.length,
    'build_ms': stats(build),
    'raster_ms': stats(raster),
    'build_over_budget': build.where((t) => t > budget).length,
    'raster_over_budget': raster.where((t) => t > budget).length,
    'raster_series': [for (final t in raster) double.parse(t.toStringAsFixed(1))],
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('the first-run flow keeps within the frame budget', (tester) async {
    await initRustLink();
    await SharedData.load();
    await I18n.load();
    await LiquidGlassShader.load();
    final accept = Completer<LinkClient>();
    final never = Completer<LinkClient>();
    final state = await AppState.load(
      kv: MemoryStore({'dsbot.prefs': '{"lang":"zh"}'}),
      pairOpener: (candidate, identity, code) => accept.future,
      sessionOpener: (computer, identity, {pairingCode}) => never.future,
    );
    final keys = generateKeyPair();
    final link = Uri(scheme: 'dsbot', host: 'pair', queryParameters: {
      'v': '1',
      'server': 'wss://bot.sisct.xyz/v2/link',
      'host': deviceIdFor(keys.publicKey),
      'key': keys.publicKey,
      'code': 'ABCD-1234',
      'name': 'Desk',
    }).toString();

    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> timings) => frames.addAll(timings);
    // Phase marks on the engine's clock, to sort frames by what was on screen.
    final marks = <(String, int)>[];
    void mark(String phase) => marks.add((phase, Timeline.now));

    SchedulerBinding.instance.addTimingsCallback(collect);
    mark('welcome entrance');
    await tester.pumpWidget(DsBotApp(state: state));
    await _live(1900);
    mark('welcome at rest (loops)');
    await _live(1600);
    mark('parallax drag');
    await tester.timedDrag(find.byType(WelcomePage), const Offset(140, 80), const Duration(milliseconds: 600));
    await _live(1200);
    mark('warp (welcome leaves)');
    await tester.tap(find.byType(HighlightGlassButton));
    await _live(470);
    mark('pairing entrance');
    await _live(1030);
    mark('pairing at rest (glass)');
    await _live(1000);
    mark('link field and keyboard');
    await tester.tap(find.text(t('Enter link')));
    await _live(900);
    await tester.enterText(find.byType(EditableText), link);
    await _live(400);
    mark('handshake');
    await tester.tap(find.text(t('Connect')));
    await _live(1600);
    mark('connected check and team page');
    accept.complete(_AcceptingComputer());
    await _live(2600);
    mark('end');
    // Timings arrive in batches; let the last one land.
    await _live(1200);
    SchedulerBinding.instance.removeTimingsCallback(collect);

    final refresh = tester.view.display.refreshRate;
    final budget = 1000 / (refresh > 0 ? refresh : 60);
    final phases = <String, Object>{};
    for (var i = 0; i < marks.length - 1; i++) {
      final (name, from) = marks[i];
      final to = marks[i + 1].$2;
      final inside = [
        for (final f in frames)
          if (f.timestampInMicroseconds(FramePhase.vsyncStart) >= from && f.timestampInMicroseconds(FramePhase.vsyncStart) < to) f,
      ];
      phases[name] = _summary(inside, budget);
    }
    binding.reportData = {
      'refresh_hz': refresh,
      'budget_ms': double.parse(budget.toStringAsFixed(2)),
      'shader_glass': LiquidGlassShader.program != null,
      'all': _summary(frames, budget),
      'phases': phases,
    };
  });
}
