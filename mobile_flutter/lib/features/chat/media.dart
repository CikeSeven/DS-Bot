// Photos and files in a chat: previews fetched once per picture, the original when
// a photo opens full screen, and files read or saved onto the phone. A picture is a
// message's attachment, an image file a turn presented or an image a reply's
// Markdown names on the computer (`image` reads all three), or one on the web.
// A long press on a full-screen photo saves it to the phone's photos.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
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

final _imageName = RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false);

/// A file the chat shows as a picture rather than as a file card.
bool isImageName(String? name) => name != null && _imageName.hasMatch(name);

/// The address of a picture on the web; null for one on the computer.
String? webImageOf(Json ref) => jStr(ref, 'url');

/// What `image` needs to find a picture on the computer. A presented file names
/// its own part's Session, because its seq counts in that Session.
Json imageTarget(String sessionId, Json ref) {
  final path = jStr(ref, 'path');
  final seq = jInt(ref, 'seq');
  return {
    'sessionId': jStr(ref, 'sessionId') ?? sessionId,
    if (path != null)
      'path': path
    else if (seq != null)
      ...{'seq': seq, 'index': jInt(ref, 'index') ?? 0}
    else
      'attachmentId': jStr(ref, 'attachmentId') ?? '',
  };
}

Future<Uint8List> loadImage(TeamSession session, String sessionId, Json ref, {bool original = false}) {
  final target = imageTarget(sessionId, ref);
  final key = '${jsonEncode(target)}:${original ? 'o' : 'p'}';
  final cache = original ? _originals : _previews;
  final known = cache[key];
  if (known != null) return Future.value(known);
  return _loading.putIfAbsent(key, () async {
    try {
      final value = asJson(await session.call('image', {...target, if (!original) 'preview': true}));
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
  const ImageGrid({super.key, required this.refs, required this.sessionId, this.natural = false, this.top = 6});

  final List<Json> refs;
  final String sessionId;

  /// A single picture keeps its own shape (a chart a Bot shows), not a square tile.
  final bool natural;

  /// Space above: after a message's text, or less between Markdown blocks.
  final double top;

  @override
  Widget build(BuildContext context) {
    if (natural && refs.length == 1) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: GestureDetector(
          onTap: () => showPhotos(context, sessionId, refs, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.card),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
              child: _Preview(sessionId: sessionId, ref: refs.single, natural: true),
            ),
          ),
        ),
      );
    }
    final tile = refs.length == 1 ? 200.0 : 120.0;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (index, ref) in refs.indexed)
          GestureDetector(
            onTap: () => showPhotos(context, sessionId, refs, index),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: SizedBox.square(dimension: tile, child: _Preview(sessionId: sessionId, ref: ref)),
            ),
          ),
      ]),
    );
  }
}

class _Preview extends StatefulWidget {
  const _Preview({required this.sessionId, required this.ref, this.natural = false});

  final String sessionId;
  final Json ref;
  final bool natural;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  Future<Uint8List>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (webImageOf(widget.ref) == null) _future = loadImage(TeamScope.read(context), widget.sessionId, widget.ref);
  }

  @override
  Widget build(BuildContext context) {
    final fit = widget.natural ? BoxFit.contain : BoxFit.cover;
    final url = webImageOf(widget.ref);
    if (url != null) {
      return Image.network(
        url,
        fit: fit,
        gaplessPlayback: true,
        loadingBuilder: (context, child, progress) => progress == null ? child : _placeholder(context, failed: false),
        errorBuilder: (context, error, stack) => _placeholder(context, failed: true),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) return Image.memory(snapshot.data!, fit: fit, gaplessPlayback: true);
        return _placeholder(context, failed: snapshot.hasError);
      },
    );
  }

  Widget _placeholder(BuildContext context, {required bool failed}) {
    final p = context.p;
    final box = ColoredBox(
      color: p.bubble,
      child: Center(
        child: failed
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  t(webImageOf(widget.ref) != null ? 'Image not available' : 'View it on the computer'),
                  textAlign: TextAlign.center,
                  style: TypeScale.caption.copyWith(color: p.ink3),
                ),
              )
            : SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3)),
      ),
    );
    return widget.natural ? SizedBox(width: 200, height: 140, child: box) : box;
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

  Widget _picture(Json ref) {
    const waiting = CircularProgressIndicator(color: Colors.white);
    Widget failed(String text) => Text(t(text), style: TypeScale.small.copyWith(color: Colors.white70));
    final url = webImageOf(ref);
    if (url != null) {
      return Image.network(
        url,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        loadingBuilder: (context, child, progress) => progress == null ? child : waiting,
        errorBuilder: (context, error, stack) => failed('Image not available'),
      );
    }
    return FutureBuilder<Uint8List>(
      future: loadImage(widget.session, widget.sessionId, ref, original: true),
      builder: (context, original) {
        if (original.hasData) return Image.memory(original.data!, fit: BoxFit.contain, gaplessPlayback: true);
        return FutureBuilder<Uint8List>(
          future: loadImage(widget.session, widget.sessionId, ref),
          builder: (context, preview) {
            if (preview.hasData) return Image.memory(preview.data!, fit: BoxFit.contain, gaplessPlayback: true);
            return preview.hasError ? failed('View it on the computer') : waiting;
          },
        );
      },
    );
  }

  void _actions(Json ref) {
    HapticFeedback.mediumImpact();
    showActions(context, [
      MenuAction(t('Save to Photos'), AppIcon.download, () => unawaited(_save(ref))),
    ]);
  }

  // Gal asks for the photos permission itself, the first time.
  Future<void> _save(Json ref) async {
    try {
      await savePhoto(widget.session, widget.sessionId, ref);
      if (mounted) toast(context, t('Saved to Photos'));
    } on GalException catch (error) {
      if (!mounted) return;
      toast(context, t(error.type == GalExceptionType.permissionDenied ? 'Allow DS Bot to add photos in Settings' : 'Could not save the picture'), error: true);
    } on Object catch (error) {
      if (mounted) toast(context, errorText(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.refs[_at];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pages,
          itemCount: widget.refs.length,
          onPageChanged: (i) => setState(() => _at = i),
          itemBuilder: (context, i) => GestureDetector(
            onTap: () => Navigator.pop(context),
            onLongPress: () => _actions(widget.refs[i]),
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0).abs() > 600) Navigator.pop(context);
            },
            child: InteractiveViewer(maxScale: 5, child: Center(child: _picture(widget.refs[i]))),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              IconBtn(AppIcon.close, color: Colors.white, onTap: () => Navigator.pop(context)),
              const Spacer(),
              if (widget.refs.length > 1) Text('${_at + 1} / ${widget.refs.length}', style: TypeScale.small.copyWith(color: Colors.white70)),
              const SizedBox(width: 12),
              // A presented image saves whole, as its file card did.
              if (jInt(current, 'seq') != null) IconBtn(AppIcon.download, color: Colors.white, onTap: () => saveFile(context, current, widget.sessionId)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Puts a picture in the phone's photos: a presented image file whole, as its save
/// button does; others as the full-screen view gets them (the computer sends an image
/// over 2 MiB as a JPEG of it).
Future<void> savePhoto(TeamSession session, String sessionId, Json ref) async {
  if (jInt(ref, 'seq') != null) {
    final target = {'sessionId': jStr(ref, 'sessionId') ?? sessionId, 'seq': ref['seq'], 'index': jInt(ref, 'index') ?? 0};
    final saved = await downloadFile(session.call, target, await getTemporaryDirectory());
    try {
      await Gal.putImage(saved.path);
    } finally {
      unawaited(File(saved.path).parent.delete(recursive: true).then((_) {}, onError: (_) {}));
    }
    return;
  }
  final url = webImageOf(ref);
  final bytes = url != null ? await _webPhoto(url) : await loadImage(session, sessionId, ref, original: true);
  await Gal.putImageBytes(bytes, name: _photoName(ref));
}

const _webPhotoMax = 32 * 1024 * 1024;

Future<Uint8List> _webPhoto(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) throw const FormatException('Image not available');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > _webPhotoMax) throw const FormatException('Image not available');
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// The picture's own file name, without its type: the photos app adds the type the
/// bytes have.
String _photoName(Json ref) {
  var name = (jStr(ref, 'name') ?? jStr(ref, 'path') ?? jStr(ref, 'url') ?? '').split(RegExp(r'[?#]')).first.split(RegExp(r'[\\/]')).last;
  try {
    name = Uri.decodeComponent(name);
  } on ArgumentError {
    // A stray % stays as written.
  }
  name = name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '').replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '').trim();
  return name.isEmpty ? 'DS Bot' : name;
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
            // A presented file has no text here to read; it opens by saving.
            onTap: () => jStr(file, 'attachmentId') != null ? openFileText(context, file) : saveFile(context, file, sessionId),
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
