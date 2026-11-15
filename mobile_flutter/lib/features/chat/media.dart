// Photos and files in a chat: previews fetched once per attachment, the original
// when a photo opens full screen, and files read or saved onto the phone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../data/file_transfer.dart';
import '../../data/json.dart';
import '../../data/team_session.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/markdown.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

final Map<String, Uint8List> _previews = {};
final Map<String, Uint8List> _originals = {};
final Map<String, Future<Uint8List>> _loading = {};

Future<Uint8List> loadImage(TeamSession session, String sessionId, String attachmentId, {bool original = false}) {
  final key = '$sessionId:$attachmentId:${original ? 'o' : 'p'}';
  final cache = original ? _originals : _previews;
  final known = cache[key];
  if (known != null) return Future.value(known);
  return _loading.putIfAbsent(key, () async {
    try {
      final value = asJson(await session.call('image', {'sessionId': sessionId, 'attachmentId': attachmentId, if (!original) 'preview': true}));
      final bytes = base64Decode(jStr(value, 'data') ?? '');
      cache[key] = bytes;
      if (original && _originals.length > 6) _originals.remove(_originals.keys.first);
      return bytes;
    } finally {
      unawaited(Future<void>.delayed(Duration.zero, () => _loading.remove(key)));
    }
  });
}

class ImageGrid extends StatelessWidget {
  const ImageGrid({super.key, required this.refs, required this.sessionId});

  final List<Json> refs;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final tile = refs.length == 1 ? 200.0 : 120.0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (index, ref) in refs.indexed)
          GestureDetector(
            onTap: () => showPhotos(context, sessionId, refs, index),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: SizedBox.square(dimension: tile, child: _Preview(sessionId: sessionId, attachmentId: jStr(ref, 'attachmentId') ?? '')),
            ),
          ),
      ]),
    );
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.sessionId, required this.attachmentId});

  final String sessionId;
  final String attachmentId;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late Future<Uint8List> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = loadImage(TeamScope.read(context), widget.sessionId, widget.attachmentId);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) return Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true);
        return ColoredBox(
          color: p.bubble,
          child: Center(
            child: snapshot.hasError
                ? Padding(padding: const EdgeInsets.all(8), child: Text(t('View it on the computer'), textAlign: TextAlign.center, style: TypeScale.caption.copyWith(color: p.ink3)))
                : SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3)),
          ),
        );
      },
    );
  }
}

/// Photos picked on this phone, shown from memory until the computer has them.
class LocalImages extends StatelessWidget {
  const LocalImages({super.key, required this.photos});

  final List<Uint8List> photos;

  @override
  Widget build(BuildContext context) {
    final tile = photos.length == 1 ? 200.0 : 120.0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final bytes in photos) ClipRRect(borderRadius: BorderRadius.circular(Radii.card), child: Image.memory(bytes, width: tile, height: tile, fit: BoxFit.cover)),
      ]),
    );
  }
}

/// Full-screen photos, swiped side to side and pinched to zoom: the preview at
/// once, the original once it arrives.
Future<void> showPhotos(BuildContext context, String sessionId, List<Json> refs, int index) {
  final session = TeamScope.read(context);
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (context, animation, _) => FadeTransition(
      opacity: animation,
      child: _PhotoViewer(session: session, sessionId: sessionId, refs: refs, index: index),
    ),
  ));
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.session, required this.sessionId, required this.refs, required this.index});

  final TeamSession session;
  final String sessionId;
  final List<Json> refs;
  final int index;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _at = widget.index;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pages,
          itemCount: widget.refs.length,
          onPageChanged: (i) => setState(() => _at = i),
          itemBuilder: (context, i) {
            final id = jStr(widget.refs[i], 'attachmentId') ?? '';
            return GestureDetector(
              onTap: () => Navigator.pop(context),
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0).abs() > 600) Navigator.pop(context);
              },
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: FutureBuilder<Uint8List>(
                    future: loadImage(widget.session, widget.sessionId, id, original: true),
                    builder: (context, original) {
                      if (original.hasData) return Image.memory(original.data!, fit: BoxFit.contain, gaplessPlayback: true);
                      return FutureBuilder<Uint8List>(
                        future: loadImage(widget.session, widget.sessionId, id),
                        builder: (context, preview) => preview.hasData
                            ? Image.memory(preview.data!, fit: BoxFit.contain, gaplessPlayback: true)
                            : const CircularProgressIndicator(color: Colors.white),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              IconBtn(AppIcon.close, color: Colors.white, onTap: () => Navigator.pop(context)),
              const Spacer(),
              if (widget.refs.length > 1) Text('${_at + 1} / ${widget.refs.length}', style: TypeScale.small.copyWith(color: Colors.white70)),
              const SizedBox(width: 12),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// A file a message carries: open it to read, or save it onto the phone.
class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.file, required this.sessionId, this.onDark = false});

  final Json file;
  final String sessionId;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final name = jStr(file, 'name') ?? t('File');
    final bytes = jInt(file, 'bytes');
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
    final ink = onDark ? p.userInk : p.ink;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(color: (onDark ? p.userInk : p.ink).withValues(alpha: 0.06), borderRadius: BorderRadius.circular(Radii.card), border: Border.all(color: ink.withValues(alpha: 0.12))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.card),
            onTap: () => openFileText(context, file),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                  child: Text(ext.length > 4 ? ext.substring(0, 4) : ext, style: TypeScale.caption.copyWith(color: p.accent, fontWeight: FontWeight.w600, fontSize: 10)),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TypeScale.smallStrong.copyWith(color: ink)),
                    if (bytes != null) Text(_size(bytes), style: TypeScale.caption.copyWith(color: ink.withValues(alpha: 0.55))),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        if (jStr(file, 'attachmentId') != null || jInt(file, 'seq') != null)
          IconBtn(AppIcon.download, size: 18, color: onDark ? p.userInk : p.accent, onTap: () => saveFile(context, file, sessionId)),
      ]),
    );
  }
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Reads a text file the chat names, in a sheet.
Future<void> openFileText(BuildContext context, Json file) async {
  final session = TeamScope.read(context);
  try {
    final value = await session.call('file-text', {'file': file});
    final text = value is String ? value : (jStr(value, 'text') ?? '');
    if (!context.mounted) return;
    await showReader(context, text, title: jStr(file, 'name'));
  } on Object catch (error) {
    if (context.mounted) toast(context, errorText(error), error: true);
  }
}

/// Saves a delivered file onto the phone through the system share sheet.
Future<void> saveFile(BuildContext context, Json file, String sessionId) async {
  final session = TeamScope.read(context);
  final target = {
    'sessionId': jStr(file, 'sessionId') ?? sessionId,
    if (jStr(file, 'attachmentId') != null) 'attachmentId': jStr(file, 'attachmentId') else ...{'seq': file['seq'], 'index': file['index']},
  };
  toast(context, t('Downloading…'));
  try {
    final saved = await downloadFile(session.call, target, await getTemporaryDirectory());
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    await SharePlus.instance.share(ShareParams(files: [XFile(saved.path, mimeType: saved.mime, name: saved.name)], title: saved.name));
  } on Object catch (error) {
    if (context.mounted) toast(context, errorText(error), error: true);
  }
}

/// Text in a page the user can select from; Markdown for .md, plain otherwise.
Future<void> showReader(BuildContext context, String text, {String? title}) {
  final p = context.p;
  final markdown = title == null || RegExp(r'\.(md|markdown|txt)$', caseSensitive: false).hasMatch(title);
  return showGlassSheet<void>(
    context,
    maxHeightFactor: 0.94,
    builder: (sheet) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetTitle(title ?? t('Select text'), trailing: IconBtn(AppIcon.close, onTap: () => Navigator.pop(sheet))),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: SelectionArea(
            child: markdown
                ? MarkdownText(text, background: p.main)
                : Text(text, style: TypeScale.mono.copyWith(color: p.ink)),
          ),
        ),
      ),
    ]),
  );
}
