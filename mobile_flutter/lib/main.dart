import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/app_state.dart';
import 'background/wiring.dart';
import 'data/demo_link.dart';
import 'link/rust_link.dart';
import 'shared/shared_data.dart';
import 'ui/liquid_glass.dart';
import 'ui/i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await initRustLink();
  await SharedData.load();
  await I18n.load();
  await LiquidGlassShader.load();
  Map<String, dynamic>? demo;
  if (demoMode) demo = jsonDecode(await rootBundle.loadString('assets/demo/team.json')) as Map<String, dynamic>;
  final state = await AppState.load(demoData: demo);
  if (demo == null) await wireBackground(state);
  runApp(DsBotApp(state: state));
}
