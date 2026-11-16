// The message box: text, photos (and files when the computer takes them), @ to
// call a group member, send, and stop while a Bot works with an empty draft.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/chat_session.dart';
import '../../data/photos.dart';
import '../../data/team_state.dart';
import '../../ui/avatar.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/island.dart';
import '../../ui/menu/action_menu.dart';
import '../../ui/menu/expressive_menu.dart';
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
    this.hint,
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

  /// Shown in the empty box instead of "Message {name}" (for example, offline).
  final String? hint;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> with SingleTickerProviderStateMixin {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final List<OutgoingPhoto> _photos = [];
  final List<OutgoingFile> _files = [];
  bool _preparing = false;
  String? _mention;

  /// The text has its own row above + and send. It opens once the draft needs a
  /// second line and stays open while anything is written; only an empty box
  /// closes it, so the layout never flips back and forth while editing.
  bool _open = false;
  late final AnimationController _morph = AnimationController(vsync: this);

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
    _morph.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (open == _open) return;
    setState(() => _open = open);
    final target = open ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _morph.value = target;
    } else {
      _morph.animateTo(target, duration: Duration(milliseconds: open ? 380 : 320), curve: SpringCurve.shape);
    }
  }

  /// The draft no longer fits one row. Found during layout, which already
  /// shows the first frame of the move; the move starts on the next frame.
  void _onOverflow() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _text.text.isNotEmpty) _setOpen(true);
    });
  }

  void _onText() {
    final value = _text.value;
    final cursor = value.selection.baseOffset < 0 ? value.text.length : value.selection.baseOffset;
    final before = value.text.substring(0, cursor.clamp(0, value.text.length));
    final match = RegExp(r'(^|\s)@([^\s@]*)$').firstMatch(before);
    final mention = widget.members.isEmpty ? null : match?.group(2);
    if (mention != _mention) setState(() => _mention = mention);
    setState(() {});
    if (value.text.isEmpty) _setOpen(false);
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
      // A camera photo is shrunk by the picker. The gallery gives originals: the
      // picker would make a GIF a still JPEG, so photos.dart shrinks all but GIFs.
      final picked = camera
          ? [await picker.pickImage(source: ImageSource.camera, maxWidth: photoEdge.toDouble(), maxHeight: photoEdge.toDouble(), imageQuality: photoQuality)].whereType<XFile>().toList()
          : await picker.pickMultiImage(limit: 6);
      for (final file in picked) {
        final read = await file.readAsBytes();
        final bytes = camera ? read : await photoToSend(read);
        _photos.add(OutgoingPhoto(bytes: bytes, mediaType: imageTypeOf(bytes) ?? 'image/jpeg', base64: _b64(bytes)));
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

  List<MenuAction> get _attachActions => [
        if (widget.canPhotos) MenuAction(t('Photos'), AppIcon.image, _pickPhotos),
        if (widget.canPhotos) MenuAction(t('Camera'), AppIcon.camera, () => _pickPhotos(camera: true)),
        if (widget.canFiles) MenuAction(t('Files'), AppIcon.clip, _pickFiles),
      ];

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final showStop = widget.canStop && !_hasContent;
    final canAttach = widget.canPhotos || widget.canFiles;
    final suggestions = _mention == null
        ? const <Bot>[]
        : widget.members.where((bot) => bot.name.toLowerCase().contains(_mention!.toLowerCase())).take(8).toList();
    final attachments = _photos.isNotEmpty || _files.isNotEmpty || _preparing;
    final field = TextField(
      controller: _text,
      focusNode: _focus,
      minLines: 1,
      maxLines: _open ? 8 : 6,
      textInputAction: widget.enterToSend ? TextInputAction.send : TextInputAction.newline,
      onSubmitted: widget.enterToSend ? (_) => _send() : null,
      style: TypeScale.bubble.copyWith(color: p.ink),
      cursorWidth: 1.6,
      decoration: InputDecoration(
        hintText: widget.hint ?? t('Message {name}', {'name': widget.name}),
        hintMaxLines: 1,
        hintStyle: TypeScale.bubble.copyWith(color: p.ink3),
        filled: false,
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      ),
    );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: SpringCurve.shape,
        alignment: Alignment.bottomCenter,
        child: suggestions.isEmpty
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassIsland(
                  radius: 24,
                  child: SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      children: [
                        for (final bot in suggestions)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Pressable(
                              onTap: () => _pickMention(bot),
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                                decoration: BoxDecoration(color: p.ink.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(Radii.pill)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  BotAvatar(bot: bot, size: 26),
                                  const SizedBox(width: 6),
                                  Text(bot.name, style: TypeScale.smallStrong.copyWith(color: p.ink)),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
      GlassIsland(
        radius: 26,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: SpringCurve.shape,
            alignment: Alignment.topCenter,
            child: !attachments
                ? const SizedBox(width: double.infinity)
                : SizedBox(
                    height: 82,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                      children: [
                        for (final (i, photo) in _photos.indexed)
                          _Thumb(onRemove: () => setState(() => _photos.removeAt(i)), child: Image.memory(photo.bytes, fit: BoxFit.cover)),
                        for (final (i, file) in _files.indexed)
                          _Thumb(
                            onRemove: () => setState(() => _files.removeAt(i)),
                            child: ColoredBox(
                              color: p.ink.withValues(alpha: 0.05),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Ico(AppIcon.clip, size: 16, color: p.ink3),
                                  const SizedBox(height: 4),
                                  Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TypeScale.caption.copyWith(color: p.ink2, fontSize: 10, height: 1.2)),
                                ]),
                              ),
                            ),
                          ),
                        if (_preparing) SizedBox.square(dimension: 64, child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3)))),
                      ],
                    ),
                  ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _focus.requestFocus,
            child: AnimatedBuilder(
              animation: _morph,
              builder: (context, _) => _BoxLayout(
                open: _open,
                morph: _morph.value,
                empty: _text.text.isEmpty,
                onOverflow: _onOverflow,
                attach: canAttach
                    ? ActionMenu(
                        actions: _attachActions,
                        placement: ExpressiveMenuPlacement.start,
                        builder: (context, toggle) => _RoundButton(icon: AppIcon.plus, color: Colors.transparent, ink: p.ink2, onTap: toggle, tooltip: t('Attach')),
                      )
                    : null,
                field: field,
                send: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: SpringCurve.pop,
                  transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
                  child: showStop
                      ? _RoundButton(key: const ValueKey('stop'), icon: AppIcon.stop, color: p.ink, ink: p.main, onTap: widget.onStop, tooltip: t('Stop'))
                      : _RoundButton(
                          key: ValueKey(_hasContent ? 'send' : 'idle'),
                          icon: AppIcon.send,
                          color: _hasContent ? p.ink : p.ink.withValues(alpha: 0.07),
                          ink: _hasContent ? p.main : p.ink3,
                          onTap: _hasContent && !_preparing ? _send : null,
                          tooltip: t('Send'),
                        ),
                ),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.color, required this.ink, this.onTap, this.tooltip});

  final AppIcon icon;
  final Color color;
  final Color ink;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Pressable(
      onTap: onTap,
      scale: 0.86,
      child: Container(width: 38, height: 38, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Center(child: Ico(icon, size: 20, color: ink))),
    );
    return tooltip == null || onTap == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

enum _Slot { attach, field, send }

/// The box's inside, in one of two layouts: one row (+, text, send), or the
/// text on its own row above + and send. Both buttons stay on the bottom edge.
/// Between the layouts the text is already at its new width (so it never
/// reflows mid-way), slides into place, and the box's height eases from what
/// was on screen to the new layout's height.
class _BoxLayout extends SlottedMultiChildRenderObjectWidget<_Slot, RenderBox> {
  const _BoxLayout({required this.open, required this.morph, required this.empty, required this.onOverflow, required this.field, required this.send, this.attach});

  /// The layout the box moves to.
  final bool open;

  /// 0 for one row, 1 for the text on its own row.
  final double morph;
  final bool empty;
  final VoidCallback onOverflow;
  final Widget? attach;
  final Widget field;
  final Widget send;

  @override
  Iterable<_Slot> get slots => _Slot.values;

  @override
  Widget? childForSlot(_Slot slot) => switch (slot) {
        _Slot.attach => attach,
        _Slot.field => field,
        _Slot.send => send,
      };

  @override
  _RenderBoxLayout createRenderObject(BuildContext context) => _RenderBoxLayout(open, morph, empty, onOverflow);

  @override
  void updateRenderObject(BuildContext context, _RenderBoxLayout renderObject) {
    renderObject
      ..open = open
      ..morph = morph
      ..empty = empty
      ..onOverflow = onOverflow;
  }
}

class _RenderBoxLayout extends RenderBox with SlottedContainerRenderObjectMixin<_Slot, RenderBox> {
  _RenderBoxLayout(this._open, this._morph, this._empty, this.onOverflow);

  static const _pad = 6.0;
  static const _button = 38.0;
  static const _gap = 4.0;
  static const _inset = 14.0;

  bool _open;
  set open(bool value) {
    if (value == _open) return;
    _open = value;
    _turned = true;
    markNeedsLayout();
  }

  double _morph;
  set morph(double value) {
    if (value == _morph) return;
    _morph = value;
    markNeedsLayout();
  }

  bool _empty;
  set empty(bool value) {
    if (value == _empty) return;
    _empty = value;
    markNeedsLayout();
  }

  VoidCallback onOverflow;

  /// The field's height with one line, read while the box is empty.
  double? _oneLine;

  // Where the move started: what was on screen when the target last changed.
  bool _turned = false;
  double _fromHeight = 0;
  Offset _fromField = Offset.zero;
  double _fromProgress = 1;
  double _moved = 1;

  final _fade = LayerHandle<OpacityLayer>();

  BoxParentData _data(RenderBox child) => child.parentData! as BoxParentData;

  /// + steps aside while the text slides over its place, and comes back below.
  double get _attachShown {
    double ease(double from, double to) => Curves.easeInOut.transform(((_moved - from) / (to - from)).clamp(0.0, 1.0));
    return _moved < 0.5 ? 1 - ease(0.12, 0.38) : ease(0.6, 0.95);
  }

  @override
  void dispose() {
    _fade.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final t = _morph.clamp(0.0, 1.0);
    final attach = childForSlot(_Slot.attach);
    final field = childForSlot(_Slot.field)!;
    final send = childForSlot(_Slot.send)!;
    attach?.layout(const BoxConstraints(), parentUsesSize: true);
    send.layout(const BoxConstraints(), parentUsesSize: true);

    final rowLeft = attach == null ? 16.0 : _pad + _button + _gap;
    double fieldAt(bool open) {
      final w = open ? width - _inset * 2 : width - rowLeft - _pad - _button - _gap;
      field.layout(BoxConstraints.tightFor(width: math.max(0.0, w)), parentUsesSize: true);
      return field.size.height;
    }

    var open = _open;
    var progress = open ? t : 1 - t;
    if (_turned) {
      _turned = false;
      _start(field, progress);
    }
    var fieldHeight = fieldAt(open);
    if (!open && progress >= 1) {
      if (_empty) _oneLine = fieldHeight;
      final one = _oneLine;
      if (!_empty && one != null && fieldHeight > one + 2) {
        // A second line would grow the row: draw the move's first frame instead.
        onOverflow();
        _start(field, 0);
        open = true;
        progress = 0;
        fieldHeight = fieldAt(true);
      }
    }

    final targetHeight = open ? _pad + fieldHeight + _button + _pad : math.max(_button, fieldHeight) + _pad * 2;
    final target = open ? const Offset(_inset, _pad) : Offset(rowLeft, targetHeight - _pad - fieldHeight);
    _moved = _fromProgress >= 1 ? 1.0 : ((progress - _fromProgress) / (1 - _fromProgress)).clamp(0.0, 1.0);
    final height = _moved >= 1 ? targetHeight : lerpDouble(_fromHeight, targetHeight, _moved)!;

    _data(field).offset = _moved >= 1 ? target : Offset.lerp(_fromField, target, _moved)!;
    if (attach != null) _data(attach).offset = Offset(_pad, height - _pad - attach.size.height);
    _data(send).offset = Offset(width - _pad - send.size.width, height - _pad - send.size.height);
    size = constraints.constrain(Size(width, height));
  }

  void _start(RenderBox field, double progress) {
    _fromHeight = hasSize ? size.height : 0;
    _fromField = field.hasSize ? _data(field).offset : Offset.zero;
    _fromProgress = hasSize ? progress : 1;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final field = childForSlot(_Slot.field)!;
    context.paintChild(field, offset + _data(field).offset);
    final attach = childForSlot(_Slot.attach);
    final shown = _attachShown;
    if (attach != null && shown >= 1) {
      _fade.layer = null;
      context.paintChild(attach, offset + _data(attach).offset);
    } else if (attach != null && shown > 0) {
      _fade.layer = context.pushOpacity(offset + _data(attach).offset, (shown * 255).round(), (context, offset) => context.paintChild(attach, offset), oldLayer: _fade.layer);
    } else {
      _fade.layer = null;
    }
    final send = childForSlot(_Slot.send)!;
    context.paintChild(send, offset + _data(send).offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final slot in const [_Slot.send, _Slot.attach, _Slot.field]) {
      final child = childForSlot(slot);
      if (child == null || (slot == _Slot.attach && _attachShown < 0.5)) continue;
      final hit = result.addWithPaintOffset(
        offset: _data(child).offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
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
        ClipRRect(borderRadius: BorderRadius.circular(14), child: SizedBox.square(dimension: 64, child: child)),
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
