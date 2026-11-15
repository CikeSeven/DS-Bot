// Cards a Bot shows (show_view): a fixed set of nodes rendered here, never HTML
// or code from the Bot. Values can be formulas over the card's inputs, worked out
// on the phone with the deep-view port. Answers go back with `view-reply`.
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../data/gate.dart';
import '../../shared/deep_view.dart';
import '../../ui/i18n.dart';
import '../../ui/markdown.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ViewCard extends StatefulWidget {
  const ViewCard({super.key, required this.sessionId, this.id, this.title, required this.root, this.readOnly = false, this.framed = true});

  final String sessionId;
  final String? id;
  final String? title;
  final Object? root;
  final bool readOnly;
  final bool framed;

  @override
  State<ViewCard> createState() => _ViewCardState();
}

class _ViewCardState extends State<ViewCard> {
  late Map<String, Object?> _inputs;
  late Map<String, FNode> _lets;
  String? _done;
  String? _failed;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _inputs = {for (final node in viewInputs(widget.root)) '${node['id']}': inputDefault(node)};
    _lets = {};
    void collect(Object? node) {
      if (node is! Map) return;
      final lets = node['let'];
      if (lets is Map) {
        for (final entry in lets.entries) {
          final source = entry.value is Map ? (entry.value as Map)['='] : entry.value;
          final compiled = compileFormula(source);
          if (compiled.tree != null) _lets['${entry.key}'] = compiled.tree!;
        }
      }
      for (final child in node['children'] is List ? node['children'] as List : const []) {
        collect(child);
      }
    }

    collect(widget.root);
  }

  Lookup get _lookup => createScope(_inputs, _lets);

  bool get _locked => widget.readOnly || _done != null || _busy;

  /// A literal, or a formula's value; null when the formula fails here.
  Object? _val(Object? value) => isFormula(value) ? resolve(value, _lookup) : value;

  void _set(String id, Object? value) {
    if (_locked) return;
    setState(() => _inputs = {..._inputs, id: value});
  }

  Future<void> _answer(String component, Map<String, Object?> values) async {
    if (_locked) return;
    final sent = {...values, if (_inputs.isNotEmpty) 'inputs': _inputs};
    final checked = validateViewAnswer(widget.root, component, sent);
    if (checked['error'] != null) {
      setState(() => _failed = '${checked['error']}');
      return;
    }
    setState(() {
      _busy = true;
      _failed = null;
    });
    try {
      await TeamScope.read(context).call('view-reply', {'sessionId': widget.sessionId, 'viewId': widget.id, 'action': component, 'values': sent});
      HapticFeedback.lightImpact();
      if (mounted) setState(() => _done = component);
    } on Object catch (error) {
      if (mounted && !isUnlockCancel(error)) setState(() => _failed = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (widget.framed && (widget.title ?? '').isNotEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(widget.title!, style: TypeScale.rowNameStrong.copyWith(color: p.ink))),
      _node(widget.root, p),
      if (_done == null && !widget.readOnly)
        Center(
          child: TextButton(
            onPressed: () => run(context, 'dismiss-view', {'sessionId': widget.sessionId}),
            child: Text(t('Dismiss'), style: TypeScale.caption.copyWith(color: p.ink3)),
          ),
        ),
      if (_failed != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_failed!, style: TypeScale.caption.copyWith(color: Palette.danger))),
      if (_done != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(t('Done'), style: TypeScale.caption.copyWith(color: Palette.green))),
    ]);
    if (!widget.framed) return content;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
      child: content,
    );
  }

  Widget _placeholder(Palette p) => Text('…', style: TypeScale.caption.copyWith(color: p.ink3, fontStyle: FontStyle.italic));

  String _text(Object? value) => value == null ? '' : (value is num ? show(value) : '$value');

  Widget _node(Object? raw, Palette p) {
    if (raw is! Map) return const SizedBox.shrink();
    final n = raw;
    List<Widget> kids() => [for (final child in n['children'] is List ? n['children'] as List : const []) _node(child, p)];
    switch (n['type']) {
      case 'stack':
        final children = kids();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 10), child],
        ]);
      case 'row':
        return LayoutBuilder(builder: (context, constraints) {
          final children = kids();
          final perRow = math.max(1, (constraints.maxWidth / 220).floor());
          final width = (constraints.maxWidth - 10 * (math.min(perRow, children.length) - 1)) / math.min(perRow, math.max(1, children.length));
          return Wrap(spacing: 10, runSpacing: 10, children: [for (final child in children) SizedBox(width: width, child: child)]);
        });
      case 'text':
        final text = _val(n['text']);
        if (text == null) return _placeholder(p);
        return MarkdownText(_text(text), color: n['tone'] == 'muted' ? p.ink2 : p.ink, background: p.card, style: TypeScale.settingsRow);
      case 'metric':
        final value = _val(n['value']);
        if (value == null) return _placeholder(p);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_text(_val(n['label'])), style: TypeScale.caption.copyWith(color: p.ink3)),
          Text(_text(value), style: TypeScale.largeTitle.copyWith(color: switch (n['tone']) { 'good' => Palette.green, 'warn' => Palette.star, 'bad' => Palette.danger, _ => p.ink })),
          if (n['caption'] != null) Text(_text(_val(n['caption'])), style: TypeScale.caption.copyWith(color: p.ink2)),
        ]);
      case 'table':
        final columns = _val(n['columns']);
        final rows = _val(n['rows']);
        if (columns is! List || rows is! List) return _placeholder(p);
        String label(Object? column) => column is Map ? _text(_val(column['label']) ?? column['key']) : _text(column);
        String cell(Object? value) {
          final out = _val(value);
          return out == null && isFormula(value) ? '…' : _text(out);
        }
        return DataTableView(
          columns: columns.map(label).toList(),
          rows: [
            for (final row in rows)
              if (row is List) row.map(cell).toList() else if (row is Map) [for (final column in columns) cell(column is Map ? row[column['key']] : null)],
          ],
        );
      case 'chart':
        final categories = _val(n['categories']);
        final series = _val(n['series']);
        if (categories is! List || series is! List) return _placeholder(p);
        return ChartView(
          kind: _text(_val(n['kind']) ?? 'bar'),
          categories: categories.map(_text).toList(),
          series: [
            for (final (i, entry) in series.indexed)
              if (entry is Map)
                (
                  name: _text(entry['name'] ?? '${i + 1}'),
                  values: [for (final value in (entry['values'] ?? entry['data'] ?? const []) as List) (_val(value) is num ? (_val(value)! as num).toDouble() : double.tryParse(_text(_val(value))) ?? 0)],
                ),
          ],
          unit: _text(_val(n['unit'])),
          caption: n['caption'] == null ? null : _text(_val(n['caption'])),
        );
      case 'progress':
        final percent = _val(n['percent']);
        final max = _val(n['max']);
        final value = _val(n['value']);
        final pct = percent is num ? percent.toDouble() : ((value is num ? value.toDouble() : 0) / math.max(1, max is num ? max.toDouble() : 1) * 100);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(_text(_val(n['label'])), style: TypeScale.caption.copyWith(color: p.ink2))),
            Text(n['valueLabel'] != null ? _text(_val(n['valueLabel'])) : '${pct.round()}%', style: TypeScale.caption.copyWith(color: p.ink3)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: (pct / 100).clamp(0, 1), minHeight: 6, backgroundColor: p.hover, color: switch (n['tone']) { 'good' => Palette.green, 'warn' => Palette.star, 'bad' => Palette.danger, _ => p.accent }),
          ),
        ]);
      case 'callout':
        final tone = switch (n['tone']) { 'good' => Palette.green, 'warn' => Palette.star, 'bad' => Palette.danger, _ => p.accent };
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: tone.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.item), border: Border(left: BorderSide(color: tone, width: 3))),
          child: MarkdownText(_text(_val(n['text'])), background: p.card, style: TypeScale.small),
        );
      case 'sources':
        final items = _val(n['items']);
        if (items is! List) return _placeholder(p);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final item in items.whereType<Map>())
            if (RegExp(r'^https?:', caseSensitive: false).hasMatch('${item['url'] ?? ''}'))
              InkWell(
                onTap: () => launchUrl(Uri.parse('${item['url']}'), mode: LaunchMode.externalApplication),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${item['label'] ?? item['title'] ?? item['url']}', style: TypeScale.small.copyWith(color: p.accent)),
                ),
              ),
        ]);
      case 'html':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (n['summary'] != null) MarkdownText(_text(_val(n['summary'])), color: p.ink2, background: p.card, style: TypeScale.small),
          Text(t('Open it on the computer'), style: TypeScale.caption.copyWith(color: p.ink3)),
        ]);
      case 'slider':
        final id = '${n['id']}';
        final min = (n['min'] as num?)?.toDouble() ?? 0;
        final max = (n['max'] as num?)?.toDouble() ?? 100;
        final step = (n['step'] as num?)?.toDouble() ?? 1;
        final value = ((_inputs[id] ?? n['value'] ?? min) as num).toDouble().clamp(min, max);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(_text(_val(n['label'])), style: TypeScale.caption.copyWith(color: p.ink2))),
            Text('${show(value)}${n['unit'] != null ? ' ${_text(_val(n['unit']))}' : ''}', style: TypeScale.smallStrong.copyWith(color: p.ink)),
          ]),
          SliderTheme(
            data: SliderThemeData(trackHeight: 4, activeTrackColor: p.accent, inactiveTrackColor: p.hover, thumbColor: p.accent, overlayColor: p.accent.withValues(alpha: 0.15)),
            child: Slider(
              value: value.toDouble(),
              min: min,
              max: max,
              divisions: step > 0 && (max - min) / step <= 1000 ? ((max - min) / step).round() : null,
              onChanged: _locked ? null : (next) => _set(id, (next / step).round() * step),
            ),
          ),
        ]);
      case 'number':
        final id = '${n['id']}';
        final min = (n['min'] as num?)?.toDouble() ?? double.negativeInfinity;
        final max = (n['max'] as num?)?.toDouble() ?? double.infinity;
        final step = (n['step'] as num?)?.toDouble() ?? 1;
        final value = ((_inputs[id] ?? n['value'] ?? 0) as num).toDouble();
        Widget stepper(String sign, double delta) => Pressable(
              onTap: _locked ? null : () => _set(id, (value + delta).clamp(min, max)),
              scale: 0.9,
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: p.hover, shape: BoxShape.circle),
                child: Text(sign, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
              ),
            );
        return Row(children: [
          Expanded(child: Text(_text(_val(n['label'])), style: TypeScale.caption.copyWith(color: p.ink2))),
          stepper('−', -step),
          SizedBox(
            width: 64,
            child: Text('${show(value)}${n['unit'] != null ? ' ${_text(_val(n['unit']))}' : ''}', textAlign: TextAlign.center, style: TypeScale.settingsRow.copyWith(color: p.ink)),
          ),
          stepper('+', step),
        ]);
      case 'choice':
        final id = '${n['id']}';
        final options = n['options'] is List ? n['options'] as List : const [];
        final current = _inputs[id] ?? n['value'];
        final labels = [for (final option in options) _text(option is Map ? (option['label'] ?? choiceValue(option)) : option)];
        final values = [for (final option in options) choiceValue(option)];
        final short = labels.every((label) => label.length <= 12) && labels.length <= 4;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (n['label'] != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(_text(_val(n['label'])), style: TypeScale.caption.copyWith(color: p.ink2))),
          if (short && values.isNotEmpty)
            Segmented<int>(
              values: [for (var i = 0; i < values.length; i++) i],
              labels: labels,
              value: math.max(0, values.indexWhere((value) => '$value' == '$current')),
              onChanged: (i) => _set(id, values[i]),
            )
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (i, label) in labels.indexed)
                ChoiceChip(
                  label: Text(label),
                  selected: '${values[i]}' == '$current',
                  onSelected: _locked ? null : (_) => _set(id, values[i]),
                  selectedColor: p.accent.withValues(alpha: 0.18),
                  side: BorderSide(color: '${values[i]}' == '$current' ? p.accent : p.line),
                  showCheckmark: false,
                ),
            ]),
        ]);
      case 'toggle':
        final id = '${n['id']}';
        return Row(children: [
          Expanded(child: Text(_text(_val(n['label'])), style: TypeScale.small.copyWith(color: p.ink2))),
          Switch(value: (_inputs[id] ?? n['value']) == true, onChanged: _locked ? null : (on) => _set(id, on)),
        ]);
      case 'options':
        return _OptionsNode(node: n, locked: _locked, onAnswer: (selected) => _answer('${n['id']}', {'selected': selected}));
      case 'confirm':
        final id = '${n['id']}';
        return Row(children: [
          Expanded(child: Btn(_text(_val(n['cancelLabel'])).isEmpty ? t('Cancel') : _text(_val(n['cancelLabel'])), kind: BtnKind.secondary, small: true, onTap: _locked ? null : () => _answer(id, {'confirmed': false}))),
          const SizedBox(width: 8),
          Expanded(child: Btn(_text(_val(n['confirmLabel'])).isEmpty ? t('Confirm') : _text(_val(n['confirmLabel'])), small: true, busy: _busy, onTap: _locked ? null : () => _answer(id, {'confirmed': true}))),
        ]);
      case 'form':
        return _FormNode(node: n, val: _val, locked: _locked, busy: _busy, onAnswer: (fields) => _answer('${n['id']}', {'fields': fields}));
      case 'submit':
        return Btn(_text(_val(n['label'])).isEmpty ? t('Send') : _text(_val(n['label'])), expand: true, busy: _busy, onTap: _locked ? null : () => _answer('${n['id']}', {}));
      default:
        return const SizedBox.shrink();
    }
  }
}

class _OptionsNode extends StatefulWidget {
  const _OptionsNode({required this.node, required this.locked, required this.onAnswer});

  final Map node;
  final bool locked;
  final ValueChanged<List<String>> onAnswer;

  @override
  State<_OptionsNode> createState() => _OptionsNodeState();
}

class _OptionsNodeState extends State<_OptionsNode> {
  final List<String> _picked = [];

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final multi = widget.node['multi'] == true;
    final options = [for (final option in widget.node['options'] is List ? widget.node['options'] as List : const []) if (option is Map) '${option['label'] ?? choiceValue(option)}'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final option in options)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Pressable(
            onTap: widget.locked
                ? null
                : () {
                    if (!multi) {
                      widget.onAnswer([option]);
                      return;
                    }
                    setState(() => _picked.contains(option) ? _picked.remove(option) : _picked.add(option));
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: _picked.contains(option) ? p.accent.withValues(alpha: 0.12) : p.bubble.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(Radii.option),
                border: Border.all(color: _picked.contains(option) ? p.accent : Colors.transparent),
              ),
              child: Text(option, style: TypeScale.settingsRow.copyWith(color: p.ink)),
            ),
          ),
        ),
      if (multi) Btn(t('Submit'), small: true, onTap: widget.locked || _picked.isEmpty ? null : () => widget.onAnswer([..._picked])),
    ]);
  }
}

class _FormNode extends StatefulWidget {
  const _FormNode({required this.node, required this.val, required this.locked, required this.busy, required this.onAnswer});

  final Map node;
  final Object? Function(Object?) val;
  final bool locked;
  final bool busy;
  final ValueChanged<Map<String, String>> onAnswer;

  @override
  State<_FormNode> createState() => _FormNodeState();
}

class _FormNodeState extends State<_FormNode> {
  final Map<String, TextEditingController> _fields = {};

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fields = [for (final field in widget.node['fields'] is List ? widget.node['fields'] as List : const []) if (field is Map) field];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, field) in fields.indexed) ...[
        Field(
          controller: _fields.putIfAbsent('${field['id'] ?? i}', () => TextEditingController(text: field['value'] is String ? field['value'] as String : '')),
          label: field['label'] == null ? null : '${widget.val(field['label']) ?? ''}',
          hint: field['placeholder'] == null ? null : '${widget.val(field['placeholder']) ?? ''}',
          maxLines: field['multiline'] == true || field['kind'] == 'multiline' ? 5 : 1,
          minLines: field['multiline'] == true || field['kind'] == 'multiline' ? 3 : 1,
        ),
        const SizedBox(height: 8),
      ],
      Btn(
        '${widget.val(widget.node['submitLabel']) ?? t('Submit')}',
        busy: widget.busy,
        onTap: widget.locked ? null : () => widget.onAnswer({for (final entry in _fields.entries) entry.key: entry.value.text}),
      ),
    ]);
  }
}

/// Columns share the card's width; a table too wide for it scrolls sideways.
class DataTableView extends StatelessWidget {
  const DataTableView({super.key, required this.columns, required this.rows});

  final List<String> columns;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return LayoutBuilder(builder: (context, constraints) {
      final cell = math.max(88.0, columns.isEmpty ? 0.0 : constraints.maxWidth / columns.length);
      Widget text(String value, {bool head = false}) => SizedBox(
            width: cell,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Text(value, style: (head ? TypeScale.caption : TypeScale.small).copyWith(color: head ? p.ink2 : p.ink, fontWeight: head ? FontWeight.w500 : null)),
            ),
          );
      return Container(
        decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(Radii.item)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(color: p.hover, child: Row(children: [for (final column in columns) text(column, head: true)])),
            for (final row in rows)
              DecoratedBox(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
                child: Row(children: [for (var i = 0; i < columns.length; i++) text(i < row.length ? row[i] : '')]),
              ),
          ]),
        ),
      );
    });
  }
}

/// bar, hbar, line, area and donut charts in theme colors, the first series on
/// the accent. A tap on a category shows its values; a legend tap hides a
/// series; the menu swaps to a table or copies the data as CSV.
class ChartView extends StatefulWidget {
  const ChartView({super.key, required this.kind, required this.categories, required this.series, this.unit = '', this.caption});

  final String kind;
  final List<String> categories;
  final List<({String name, List<double> values})> series;
  final String unit;
  final String? caption;

  @override
  State<ChartView> createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  final Set<int> _hidden = {};
  int _pinned = -1;
  bool _table = false;

  Color _color(int i, Palette p) {
    const extra = [Palette.green, Color(0xFFD3458B), Color(0xFF7D5AFF), Color(0xFF12A5B4), Palette.star];
    return i == 0 ? p.accent : extra[(i - 1) % extra.length];
  }

  List<({String name, List<double> values, Color color})> _rows(Palette p) => widget.kind == 'donut'
      ? [
          for (final (i, category) in widget.categories.indexed)
            (name: category, values: [widget.series.isEmpty || i >= widget.series.first.values.length ? 0.0 : widget.series.first.values[i]], color: _color(i, p)),
        ]
      : [for (final (i, s) in widget.series.indexed) (name: s.name, values: s.values, color: _color(i, p))];

  String _csv(Palette p) {
    final rows = _rows(p);
    final head = ['', ...rows.map((row) => row.name)];
    return [
      head.join(','),
      for (final (i, category) in widget.categories.indexed) [category, ...rows.map((row) => i < row.values.length ? show(row.values[i]) : '')].join(','),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final rows = _rows(p);
    if (_table) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DataTableView(
          columns: ['', ...rows.map((row) => row.name)],
          rows: [
            for (final (i, category) in widget.categories.indexed) [category, ...rows.map((row) => i < row.values.length ? '${show(row.values[i])}${widget.unit}' : '—')],
          ],
        ),
        TextButton(onPressed: () => setState(() => _table = false), child: Text(t('View as chart'), style: TypeScale.small.copyWith(color: p.accent))),
      ]);
    }
    final visible = [for (final (i, row) in rows.indexed) if (!_hidden.contains(i)) (index: i, row: row)];
    final labelStyle = TypeScale.caption.copyWith(color: p.ink3, fontSize: 10);
    Widget chart;
    switch (widget.kind) {
      case 'donut':
        chart = PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 34,
          pieTouchData: PieTouchData(touchCallback: (event, response) {
            if (event is FlTapUpEvent) setState(() => _pinned = response?.touchedSection?.touchedSectionIndex ?? -1);
          }),
          sections: [
            for (final (i, row) in rows.indexed)
              PieChartSectionData(
                value: _hidden.contains(i) ? 0.0001 : math.max(0.0001, row.values.first),
                color: row.color.withValues(alpha: _pinned == -1 || _pinned == i ? 1 : 0.3),
                radius: _pinned == i ? 46 : 40,
                showTitle: false,
              ),
          ],
        ));
      case 'line' || 'area':
        chart = LineChart(LineChartData(
          gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: p.line, strokeWidth: 0.5)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36, getTitlesWidget: (value, meta) => Text(show(value), style: labelStyle))),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final i = value.round();
                  return i >= 0 && i < widget.categories.length && value == i ? Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.categories[i], style: labelStyle)) : const SizedBox.shrink();
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(getTooltipColor: (_) => p.user)),
          lineBarsData: [
            for (final entry in visible)
              LineChartBarData(
                spots: [for (final (i, value) in entry.row.values.indexed) FlSpot(i.toDouble(), value)],
                color: entry.row.color,
                barWidth: 2.5,
                isCurved: true,
                preventCurveOverShooting: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: widget.kind == 'area', color: entry.row.color.withValues(alpha: 0.18)),
              ),
          ],
        ));
      default:
        final horizontal = widget.kind == 'hbar';
        chart = RotatedBox(
          quarterTurns: horizontal ? 1 : 0,
          child: BarChart(BarChartData(
            gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: p.line, strokeWidth: 0.5)),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: !horizontal, reservedSize: 36, getTitlesWidget: (value, meta) => Text(show(value), style: labelStyle))),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: horizontal ? 64 : 22,
                  getTitlesWidget: (value, meta) {
                    final i = value.round();
                    if (i < 0 || i >= widget.categories.length) return const SizedBox.shrink();
                    return RotatedBox(quarterTurns: horizontal ? -1 : 0, child: Padding(padding: const EdgeInsets.all(4), child: Text(widget.categories[i], style: labelStyle, overflow: TextOverflow.ellipsis)));
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchCallback: (event, response) {
                if (event is FlTapUpEvent) setState(() => _pinned = response?.spot?.touchedBarGroupIndex ?? -1);
              },
              touchTooltipData: BarTouchTooltipData(getTooltipColor: (_) => p.user),
            ),
            barGroups: [
              for (final (i, _) in widget.categories.indexed)
                BarChartGroupData(x: i, barsSpace: 2, barRods: [
                  for (final entry in visible)
                    BarChartRodData(
                      toY: i < entry.row.values.length ? entry.row.values[i] : 0,
                      color: entry.row.color.withValues(alpha: _pinned == -1 || _pinned == i ? 1 : 0.3),
                      width: math.max(4, 120 / math.max(1, widget.categories.length * visible.length)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                ]),
            ],
          )),
        );
    }
    final pinnedText = _pinned >= 0 && _pinned < widget.categories.length
        ? widget.kind == 'donut'
            ? '${widget.categories[_pinned]} ${show(rows[_pinned].values.first)}${widget.unit}'
            : '${widget.categories[_pinned]}: ${visible.map((entry) => '${entry.row.name} ${_pinned < entry.row.values.length ? show(entry.row.values[_pinned]) : '—'}${widget.unit}').join(' · ')}'
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 180, child: Padding(padding: const EdgeInsets.only(top: 8, right: 8), child: chart)),
      if (pinnedText != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(pinnedText, style: TypeScale.caption.copyWith(color: p.ink))),
      Row(children: [
        Expanded(
          child: Wrap(spacing: 10, runSpacing: 4, children: [
            for (final (i, row) in rows.indexed)
              GestureDetector(
                onTap: () => setState(() => _hidden.contains(i) ? _hidden.remove(i) : _hidden.add(i)),
                child: Opacity(
                  opacity: _hidden.contains(i) ? 0.35 : 1,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: row.color, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 4),
                    Text(row.name, style: TypeScale.caption.copyWith(color: p.ink2)),
                  ]),
                ),
              ),
          ]),
        ),
        PopupMenuButton<String>(
          icon: Text('…', style: TextStyle(color: p.ink3, fontSize: 18)),
          onSelected: (choice) {
            if (choice == 'table') setState(() => _table = true);
            if (choice == 'csv') {
              Clipboard.setData(ClipboardData(text: _csv(p)));
              toast(context, t('Copied'));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'table', child: Text(t('View as table'))),
            PopupMenuItem(value: 'csv', child: Text(t('Copy data (CSV)'))),
          ],
        ),
      ]),
      if (widget.caption != null && widget.caption!.isNotEmpty) Text(widget.caption!, style: TypeScale.caption.copyWith(color: p.ink3)),
    ]);
  }
}
