// Markdown for chat bubbles and readers: parsed with package:markdown (GitHub
// flavor), drawn here so code, tables and CJK spacing look right on a phone.
// Links open only for http(s) and mailto. Images show their alt text, unless the
// caller draws them (`images`).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'i18n.dart';
import 'icons.dart';
import 'theme.dart';

final Map<String, List<md.Node>> _cache = {};

List<md.Node> _parse(String text) {
  final cached = _cache[text];
  if (cached != null) return cached;
  final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false).parseLines(text.split('\n'));
  if (_cache.length > 400) _cache.remove(_cache.keys.first);
  return _cache[text] = nodes;
}

final _blockPattern = RegExp(r'(^|\n)\s*(```|~~~|\|.*\|)');

/// A message with a code block or a table takes the full bubble width.
bool hasBlockContent(String text) => _blockPattern.hasMatch(text);

/// An image a Markdown text shows: its destination as written, and its alt text.
typedef MarkdownImage = ({String src, String alt});

/// Draws a run of images that stand together in a paragraph, or returns null to
/// leave them as their alt text.
typedef MarkdownImages = Widget? Function(List<MarkdownImage> images);

class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {super.key, this.color, this.background, this.style = TypeScale.bubble, this.images});

  final String text;
  final Color? color;

  /// What the text sits on, so code and quotes tint against it.
  final Color? background;
  final TextStyle style;
  final MarkdownImages? images;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final ink = color ?? p.ink;
    final renderer = _Renderer(context, style.copyWith(color: ink), ink, background ?? p.main, images);
    final blocks = renderer.blocks(_parse(text));
    if (blocks.length == 1) return blocks.single;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: blocks);
  }
}

class _Renderer {
  _Renderer(this.context, this.base, this.ink, this.background, this.images);

  final BuildContext context;
  final TextStyle base;
  final Color ink;
  final Color background;
  final MarkdownImages? images;

  Color get tint => ink.withValues(alpha: 0.07);
  Color get line => ink.withValues(alpha: 0.15);

  List<Widget> blocks(List<md.Node> nodes, {int depth = 0}) {
    final out = <Widget>[];
    for (final (index, node) in nodes.indexed) {
      final widget = block(node, depth: depth);
      if (widget == null) continue;
      if (out.isNotEmpty || index > 0) out.add(const SizedBox(height: 8));
      out.add(widget);
    }
    if (out.isNotEmpty && out.first is SizedBox) out.removeAt(0);
    return out;
  }

  Widget? block(md.Node node, {int depth = 0}) {
    if (node is md.Text) return _rich([TextSpan(text: autospace(node.text))]);
    if (node is! md.Element) return null;
    switch (node.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final bump = switch (node.tag) { 'h1' => 4.0, 'h2' => 2.0, 'h3' => 1.0, _ => 0.0 };
        return _rich(inline(node.children ?? const []), style: base.copyWith(fontSize: (base.fontSize ?? 16) + bump, fontWeight: FontWeight.w600));
      case 'p':
        return _paragraph(node.children ?? const []);
      case 'pre':
        return _code(node);
      case 'ul' || 'ol':
        return _list(node, ordered: node.tag == 'ol', depth: depth);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: line, width: 3))),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: ink.withValues(alpha: 0.75)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks(node.children ?? const [], depth: depth)),
          ),
        );
      case 'table':
        return _table(node);
      case 'hr':
        return Divider(height: 8, thickness: 0.5, color: line);
      default:
        final children = node.children;
        if (children == null || children.isEmpty) return null;
        return _paragraph(children);
    }
  }

  static bool _isImage(md.Node node) => node is md.Element && node.tag == 'img';

  static bool _isBlank(md.Node node) => (node is md.Text && node.text.trim().isEmpty) || (node is md.Element && node.tag == 'br');

  /// Inline content as text, with each run of images in it drawn by [images]
  /// between the text around it. Without a drawn run it stays one text.
  Widget _paragraph(List<md.Node> nodes) {
    final draw = images;
    if (draw == null || !nodes.any(_isImage)) return _rich(inline(nodes));
    final parts = <(List<md.Node>, Widget?)>[];
    var text = <md.Node>[];
    var run = <md.Element>[];
    void endText() {
      if (text.any((node) => !_isBlank(node))) parts.add((text, null));
      text = [];
    }
    void endRun() {
      if (run.isEmpty) return;
      parts.add((run, draw([for (final image in run) (src: image.attributes['src'] ?? '', alt: image.attributes['alt'] ?? '')])));
      run = [];
    }
    for (final node in nodes) {
      if (_isImage(node)) {
        endText();
        run.add(node as md.Element);
      } else if (run.isNotEmpty && _isBlank(node)) {
        continue;
      } else {
        endRun();
        text.add(node);
      }
    }
    endRun();
    endText();
    if (parts.every((part) => part.$2 == null)) return _rich(inline(nodes));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, spacing: 6, children: [
      for (final (part, drawn) in parts) drawn ?? _rich(inline(part)),
    ]);
  }

  Widget _rich(List<InlineSpan> spans, {TextStyle? style}) =>
      Text.rich(TextSpan(children: spans), style: style ?? base, textScaler: MediaQuery.textScalerOf(context));

  List<InlineSpan> inline(List<md.Node> nodes, {TextStyle? style}) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        out.add(TextSpan(text: autospace(node.text), style: style));
        continue;
      }
      if (node is! md.Element) continue;
      final children = node.children ?? const [];
      switch (node.tag) {
        case 'strong':
          out.addAll(inline(children, style: (style ?? const TextStyle()).copyWith(fontWeight: FontWeight.w600)));
        case 'em':
          out.addAll(inline(children, style: (style ?? const TextStyle()).copyWith(fontStyle: FontStyle.italic)));
        case 'del':
          out.addAll(inline(children, style: (style ?? const TextStyle()).copyWith(decoration: TextDecoration.lineThrough)));
        case 'code':
          // A thin space where inline code touches Han characters.
          out.add(TextSpan(
            text: ' ${node.textContent} ',
            style: TypeScale.mono.copyWith(fontSize: (base.fontSize ?? 16) - 2, color: ink, backgroundColor: tint),
          ));
        case 'br':
          out.add(const TextSpan(text: '\n'));
        case 'img':
          out.add(TextSpan(text: node.attributes['alt'] ?? '', style: style));
        case 'a':
          final href = node.attributes['href'] ?? '';
          final ok = RegExp(r'^(https?:|mailto:)', caseSensitive: false).hasMatch(href);
          final recognizer = ok ? (TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication)) : null;
          final linkStyle = (style ?? const TextStyle()).copyWith(color: context.p.accent, decoration: TextDecoration.underline, decorationColor: context.p.accent.withValues(alpha: 0.4));
          for (final span in inline(children, style: linkStyle)) {
            out.add(span is TextSpan ? TextSpan(text: span.text, style: span.style, recognizer: recognizer) : span);
          }
        case 'input':
          out.add(TextSpan(text: node.attributes['checked'] != null ? '☑ ' : '☐ '));
        default:
          out.addAll(inline(children, style: style));
      }
    }
    return out;
  }

  Widget _code(md.Element node) {
    final text = node.textContent.replaceFirst(RegExp(r'\n$'), '');
    final codeNode = node.children?.whereType<md.Element>().firstOrNull;
    final language = (codeNode?.attributes['class'] ?? '').replaceFirst('language-', '');
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(Radii.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(children: [
              Expanded(child: Text(language, style: TypeScale.caption.copyWith(color: ink.withValues(alpha: 0.5)))),
              _CopyButton(text: text, color: ink.withValues(alpha: 0.5)),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(text, style: TypeScale.mono.copyWith(color: ink)),
          ),
        ],
      ),
    );
  }

  Widget _list(md.Element node, {required bool ordered, required int depth}) {
    final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items = (node.children ?? const []).whereType<md.Element>().where((child) => child.tag == 'li').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, item) in items.indexed)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: ordered ? 24 : 16,
                  child: Text(ordered ? '${start + index}.' : (depth.isEven ? '•' : '◦'), style: base.copyWith(color: ink.withValues(alpha: 0.6))),
                ),
                Expanded(child: _listItem(item, depth)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _listItem(md.Element item, int depth) {
    final children = item.children ?? const [];
    final hasBlocks = children.any((child) => child is md.Element && const {'p', 'ul', 'ol', 'pre', 'blockquote', 'table'}.contains(child.tag));
    if (!hasBlocks) return _paragraph(children);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks(children, depth: depth + 1));
  }

  Widget _table(md.Element node) {
    final rows = <md.Element>[];
    for (final section in (node.children ?? const []).whereType<md.Element>()) {
      rows.addAll((section.children ?? const []).whereType<md.Element>().where((row) => row.tag == 'tr'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: line, width: 0.5), borderRadius: BorderRadius.circular(Radii.input)),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.symmetric(inside: BorderSide(color: line, width: 0.5)),
          children: [
            for (final (index, row) in rows.indexed)
              TableRow(
                decoration: index == 0 ? BoxDecoration(color: tint) : null,
                children: [
                  for (final cell in (row.children ?? const []).whereType<md.Element>())
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: _rich(inline(cell.children ?? const []), style: base.copyWith(fontSize: (base.fontSize ?? 16) - 2, fontWeight: cell.tag == 'th' ? FontWeight.w600 : null)),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        HapticFeedback.lightImpact();
        if (!mounted) return;
        setState(() => _copied = true);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _copied = false);
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Ico(_copied ? AppIcon.check : AppIcon.copy, size: 14, color: widget.color),
          const SizedBox(width: 4),
          Text(_copied ? t('Copied') : t('Copy'), style: TypeScale.caption.copyWith(color: widget.color)),
        ]),
      ),
    );
  }
}
