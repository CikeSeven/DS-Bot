// Shared pieces of the management pages: a frosted-bar page, loaders for one
// endpoint, and the photo picker for profile pictures.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/app_state.dart';
import '../../data/json.dart';
import '../../ui/glass.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ManagePage extends StatelessWidget {
  const ManagePage({super.key, required this.title, required this.children, this.actions = const [], this.onRefresh, this.dock});

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;
  final Widget? dock;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Scaffold(
      backgroundColor: p.main,
      body: GlassPage(
        bar: GlassBar(leading: IconBtn(AppIcon.back, onTap: () => Navigator.maybePop(context)), title: Text(title), actions: [...actions, const SizedBox(width: 4)]),
        bodyBuilder: (context) {
          final list = ListView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 4, bottom: MediaQuery.paddingOf(context).bottom + (dock == null ? 32 : 120)),
            children: children,
          );
          return onRefresh == null ? list : RefreshIndicator(edgeOffset: MediaQuery.paddingOf(context).top, color: p.accent, onRefresh: onRefresh!, child: list);
        },
        dock: dock,
      ),
    );
  }
}

/// Reads one endpoint and rebuilds with its answer; reloads on demand and when
/// the team revision moves.
class Loader extends StatefulWidget {
  const Loader({super.key, required this.endpoint, this.payload = const {}, required this.builder, this.follow = true});

  final String endpoint;
  final Json payload;
  final Widget Function(BuildContext context, Object? value, VoidCallback reload) builder;

  /// Read again whenever the team state changes revision.
  final bool follow;

  @override
  State<Loader> createState() => _LoaderState();
}

class _LoaderState extends State<Loader> {
  Object? _value;
  Object? _error;
  bool _loading = true;
  int _revision = -2;

  Future<void> _load() async {
    final session = TeamScope.read(context);
    setState(() => _loading = true);
    try {
      final value = await session.call(widget.endpoint, widget.payload);
      if (mounted) {
        setState(() {
          _value = value;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = widget.follow ? (TeamScope.of(context).team?.revision ?? -1) : -1;
    if (revision != _revision) {
      _revision = revision;
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    if (_value == null && _loading) return Padding(padding: const EdgeInsets.all(32), child: Center(child: CircularProgressIndicator(color: p.accent)));
    if (_value == null && _error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text(errorText(_error), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)),
          TextButton(onPressed: _load, child: const Text('↻')),
        ]),
      );
    }
    return widget.builder(context, _value, _load);
  }
}

/// A square photo from the library as a data URL, for a Bot's picture.
Future<String?> pickPhotoDataUrl() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 85);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final ext = file.name.split('.').last.toLowerCase();
  final mime = ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// A short label above a block on a details page.
class BlockTitle extends StatelessWidget {
  const BlockTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 8),
      child: Row(children: [
        Expanded(child: Text(text, style: TypeScale.smallStrong.copyWith(color: p.ink2))),
        ?trailing,
      ]),
    );
  }
}

String formatTokens(num count) =>
    count >= 1e6 ? '${(count / 1e6).toStringAsFixed(1)}M' : (count >= 1e3 ? '${(count / 1e3).toStringAsFixed(1)}K' : '${count.round()}');
