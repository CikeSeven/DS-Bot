import 'package:flutter/material.dart';

import '../features/chat/chat_page.dart';

/// Pushes a full page that slides in, with the platform's back gesture.
Future<T?> push<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

/// Opens a chat with a Bot or a group. From inside another chat it replaces
/// that chat, so back always returns to the team.
Future<void> openChat(BuildContext context, {String? botId, String? roomId, bool replace = false}) {
  final page = ChatPage(botId: botId, roomId: roomId);
  final route = MaterialPageRoute<void>(builder: (_) => page, settings: const RouteSettings(name: 'chat'));
  final navigator = Navigator.of(context);
  if (replace) {
    navigator.popUntil((route) => route.isFirst);
  }
  return navigator.push(route);
}
