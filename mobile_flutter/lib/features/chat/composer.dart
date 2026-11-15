// The message box: text, photos (and files when the computer takes them), @ to
// call a group member, send, and stop while a Bot works with an empty draft.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/chat_session.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ComposerController {
  _ComposerState? _state;

  /// Puts text into the box, as a quote or a mention.
  void insert(String text) => _state?._insert(text);
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.name,
    required this.running,
    required this.canStop,
    required this.canPhotos,
    required this.canFiles,
    required this.onSend,
    required this.onStop,
    this.members = const [],
    this.enterToSend = false,
    this.controller,
  });

  final String name;
  final bool running;
  final bool canStop;
  final bool canPhotos;
  final bool canFiles;
  final void Function(String text, List<OutgoingPhoto> photos, List<OutgoingFile> files) onSend;
  final VoidCallback onStop;

  /// Group members, for @ suggestions.
  final List<Bot> members;
  final bool enterToSend;
  final ComposerController? controller;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final List<OutgoingPhoto> _photos = [];
  final List<OutgoingFile> _files = [];
  bool _preparing = false;
  String? _mention;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _text.addListener(_onText);
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._state = null;
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    widget.controller?._state = null;
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onText() {
    final value = _text.value;
    final cursor = value.selection.baseOffset < 0 ? value.text.length : value.selection.baseOffset;
    final before = value.text.substring(0, cursor.clamp(0, value.text.length));
    final match = RegExp(r'(^|\s)@([^\s@]*)$').firstMatch(before);
    final mention = widget.members.isEmpty ? null : match?.group(2);
    if (mention != _mention) setState(() => _mention = mention);
    setState(() {});
  }

  void _insert(String text) {
    final current = _text.text;
    _text.text = current.isEmpty ? text : '$current${current.endsWith('\n') ? '' : '\n'}$text';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    _focus.requestFocus();
  }

  void _pickMention(Bot bot) {
    final value = _text.value;
    final cursor = value.selection.baseOffset < 0 ? value.text.length : value.selection.baseOffset;
    final before = value.text.substring(0, cursor);
    final start = before.lastIndexOf('@');
    final next = '${value.text.substring(0, start)}@${bot.name} ${value.text.substring(cursor)}';
    _text.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: start + bot.name.length + 2));
    HapticFeedback.selectionClick();
  }

  bool get _hasContent => _text.text.trim().isNotEmpty || _photos.isNotEmpty || _files.isNotEmpty;

  void _send() {
    if (!_hasContent || _preparing) return;
    HapticFeedback.lightImpact();
    widget.onSend(_text.text.trim(), [..._photos], [..._files]);
    _text.clear();
    setState(() {
      _photos.clear();
      _files.clear();
    });
  }

  Future<void> _pickPhotos({bool camera = false}) async {
    final picker = ImagePicker();
    setState(() => _preparing = true);
    try {
      // The long side at most 2048 px: well under what the link carries in one
      // message, and as much as the models look at.
      final picked = camera
          ? [await picker.pickImage(source: ImageSource.camera, maxWidth: 2048, maxHeight: 2048, imageQuality: 82)].whereType<XFile>().toList()
          : await picker.pickMultiImage(maxWidth: 2048, maxHeight: 2048, imageQuality: 82, limit: 6);
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        _photos.add(OutgoingPhoto(bytes: bytes, mediaType: _imageType(file.name), base64: _b64(bytes)));
      }
    } on Object catch (error) {
      if (mounted) toast(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles();
    for (final file in picked) {
      final bytes = await file.readAsBytes();
      _files.add(OutgoingFile(name: file.name, mediaType: _fileType(file.name), bytes: bytes));
    }
    if (mounted) setState(() {});
  }

  void _attach() {
    showActions(context, [
      if (widget.canPhotos) MenuAction(t('Photos'), AppIcon.image, _pickPhotos),
      if (widget.canPhotos) MenuAction(t('Camera'), AppIcon.camera, () => _pickPhotos(camera: true)),
      if (widget.canFiles) MenuAction(t('Files'), AppIcon.clip, _pickFiles),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final showStop = widget.canStop && !_hasContent;
    final suggestions = _mention == null
        ? const <Bot>[]
        : widget.members.where((bot) => bot.name.toLowerCase().contains(_mention!.toLowerCase())).take(8).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (suggestions.isNotEmpty)
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final bot in suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 6),
                  child: ActionChip(
                    avatar: BotAvatar(bot: bot, size: 20),
                    label: Text(bot.name),
                    onPressed: () => _pickMention(bot),
                    backgroundColor: p.card,
                    side: BorderSide(color: p.line),
                  ),
                ),
            ],
          ),
        ),
      if (_photos.isNotEmpty || _files.isNotEmpty || _preparing)
        SizedBox(
          height: 72,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            children: [
              for (final (i, photo) in _photos.indexed)
                _Thumb(onRemove: () => setState(() => _photos.removeAt(i)), child: Image.memory(photo.bytes, fit: BoxFit.cover)),
              for (final (i, file) in _files.indexed)
                _Thumb(
                  onRemove: () => setState(() => _files.removeAt(i)),
                  child: ColoredBox(
                    color: p.bubble,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(file.name, maxLines: 3, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TypeScale.caption.copyWith(color: p.ink2, fontSize: 10)),
                      ),
                    ),
                  ),
                ),
              if (_preparing) SizedBox.square(dimension: 64, child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3)))),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (widget.canPhotos || widget.canFiles)
            Padding(padding: const EdgeInsets.only(bottom: 2), child: IconBtn(AppIcon.plus, filled: true, onTap: _attach)),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: p.card.withValues(alpha: p.dark ? 0.8 : 0.9), borderRadius: BorderRadius.circular(Radii.composer), border: Border.all(color: p.line)),
              child: TextField(
                controller: _text,
                focusNode: _focus,
                minLines: 1,
                maxLines: 6,
                textInputAction: widget.enterToSend ? TextInputAction.send : TextInputAction.newline,
                onSubmitted: widget.enterToSend ? (_) => _send() : null,
                style: TypeScale.bubble.copyWith(color: p.ink),
                decoration: InputDecoration(
                  hintText: t('Message {name}', {'name': widget.name}),
                  filled: false,
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
              child: showStop
                  ? _RoundButton(key: const ValueKey('stop'), icon: AppIcon.stop, color: p.ink, ink: p.main, onTap: widget.onStop)
                  : _RoundButton(key: const ValueKey('send'), icon: AppIcon.send, color: _hasContent ? p.accent : p.line2, ink: _hasContent ? p.accentInk : p.ink3, onTap: _hasContent ? _send : null),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.color, required this.ink, this.onTap});

  final AppIcon icon;
  final Color color;
  final Color ink;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.88,
      child: Container(width: 38, height: 38, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Center(child: Ico(icon, size: 20, color: ink))),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.child, required this.onRemove});

  final Widget child;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(clipBehavior: Clip.none, children: [
        ClipRRect(borderRadius: BorderRadius.circular(Radii.card), child: SizedBox.square(dimension: 64, child: child)),
        Positioned(
          right: -6,
          top: -6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), shape: BoxShape.circle),
              child: const Center(child: Ico(AppIcon.close, size: 12, color: Colors.white)),
            ),
          ),
        ),
      ]),
    );
  }
}

String _imageType(String name) {
  final ext = name.split('.').last.toLowerCase();
  return switch (ext) { 'png' => 'image/png', 'webp' => 'image/webp', 'gif' => 'image/gif', _ => 'image/jpeg' };
}

String _fileType(String name) {
  final ext = name.split('.').last.toLowerCase();
  return switch (ext) {
    'pdf' => 'application/pdf',
    'txt' || 'log' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'zip' => 'application/zip',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };
}

String _b64(List<int> bytes) => base64Encode(bytes);
