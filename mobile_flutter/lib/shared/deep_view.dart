// Port of deep-view/core (Fei2411/deep-view 0.1.2, Apache-2.0): the formula
// language of view cards (`{ "=": "price * qty" }`), the scope a card's inputs
// and `let` names make, the answer check, and the answer's one-line text.
// Numbers follow JavaScript: every number is a double, Math.round rounds halves
// up, `%` keeps the dividend's sign, and numbers print the way String() does.
import 'dart:math' as math;

typedef Lookup = Object? Function(String name);

class FormulaError implements Exception {
  FormulaError(this.message);

  final String message;

  @override
  String toString() => message;
}

Never _fail(String message) => throw FormulaError(message);

double _jsRound(double value) {
  if (!value.isFinite) return value;
  final floor = value.floorToDouble();
  return value - floor >= 0.5 ? floor + 1 : floor;
}

double _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is String && value.trim().isNotEmpty) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  _fail('${_quoted(value)} is not a number');
}

String _quoted(Object? value) {
  if (value == null) return 'null';
  if (value is String) return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  return show(value);
}

int _digitsOf(Object? digits) {
  final value = _num(digits);
  if (value != value.truncateToDouble() || value < 0 || value > 10) _fail('digits must be a whole number from 0 to 10');
  return value.toInt();
}

double _roundTo(double value, int digits) {
  final scale = math.pow(10, digits).toDouble();
  return _jsRound(value * scale) / scale;
}

String _grouped(double value, int digits) {
  if (!value.isFinite) return show(value);
  final fixed = _roundTo(value, digits).abs().toStringAsFixed(digits);
  final parts = fixed.split('.');
  final whole = parts[0];
  final part = parts.length > 1 ? parts[1] : '';
  final sign = value < 0 && double.parse(whole + part) != 0 ? '-' : '';
  final groupedWhole = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$sign$groupedWhole${part.isNotEmpty ? '.$part' : ''}';
}

class _Fn {
  const _Fn(this.min, this.max, this.run);

  final int min;
  final int max;
  final Object? Function(List<Object?> args) run;
}

const _infinity = 1 << 30;

final Map<String, _Fn> _functions = {
  'min': _Fn(1, _infinity, (args) => args.map(_num).reduce(math.min)),
  'max': _Fn(1, _infinity, (args) => args.map(_num).reduce(math.max)),
  'abs': _Fn(1, 1, (args) => _num(args[0]).abs()),
  'floor': _Fn(1, 1, (args) => _num(args[0]).floorToDouble()),
  'ceil': _Fn(1, 1, (args) => _num(args[0]).ceilToDouble()),
  'sqrt': _Fn(1, 1, (args) => math.sqrt(_num(args[0]))),
  'pow': _Fn(2, 2, (args) => math.pow(_num(args[0]), _num(args[1])).toDouble()),
  'round': _Fn(1, 2, (args) => _roundTo(_num(args[0]), args.length > 1 ? _digitsOf(args[1]) : 0)),
  'clamp': _Fn(3, 3, (args) => math.min(math.max(_num(args[0]), _num(args[1])), _num(args[2]))),
  'fixed': _Fn(1, 2, (args) {
    final digits = args.length > 1 ? _digitsOf(args[1]) : 0;
    return _roundTo(_num(args[0]), digits).toStringAsFixed(digits);
  }),
  'format': _Fn(1, 2, (args) => _grouped(_num(args[0]), args.length > 1 ? _digitsOf(args[1]) : 0)),
  'percent': _Fn(1, 2, (args) => '${_grouped(_num(args[0]) * 100, args.length > 1 ? _digitsOf(args[1]) : 0)}%'),
};

List<String> get formulaFunctions => _functions.keys.toList();

const _maxNesting = 64;
final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

bool isName(Object? value) => value is String && _identifier.hasMatch(value);

const _operators = ['==', '!=', '<=', '>=', '&&', '||', '+', '-', '*', '/', '%', '<', '>', '!', '?', ':', '(', ')', ','];

class _Token {
  const _Token(this.kind, this.value, this.at);

  final String kind;
  final Object value;
  final int at;
}

final _numberToken = RegExp(r'^(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');
final _nameToken = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*');
final _space = RegExp(r'\s');

List<_Token> _tokenize(String source) {
  final tokens = <_Token>[];
  var at = 0;
  while (at < source.length) {
    final char = source[at];
    if (_space.hasMatch(char)) {
      at += 1;
      continue;
    }
    final rest = source.substring(at);
    final number = _numberToken.firstMatch(rest);
    if (number != null) {
      tokens.add(_Token('number', double.parse(number[0]!), at));
      at += number[0]!.length;
      continue;
    }
    final name = _nameToken.firstMatch(rest);
    if (name != null) {
      tokens.add(_Token('name', name[0]!, at));
      at += name[0]!.length;
      continue;
    }
    if (char == '"' || char == "'") {
      var end = at + 1;
      final text = StringBuffer();
      while (end < source.length && source[end] != char) {
        if (source[end] == r'\' && end + 1 < source.length) {
          text.write(source[end + 1]);
          end += 2;
          continue;
        }
        text.write(source[end]);
        end += 1;
      }
      if (end >= source.length) _fail('unclosed string at ${at + 1}');
      tokens.add(_Token('string', text.toString(), at));
      at = end + 1;
      continue;
    }
    final op = _operators.where((candidate) => source.startsWith(candidate, at)).firstOrNull;
    if (op == null) _fail('unexpected ${_quoted(char)} at ${at + 1}');
    tokens.add(_Token('op', op, at));
    at += op.length;
  }
  return tokens;
}

const _binary = [
  ['||'],
  ['&&'],
  ['==', '!='],
  ['<', '<=', '>', '>='],
  ['+', '-'],
  ['*', '/', '%'],
];

sealed class FNode {}

class _Value extends FNode {
  _Value(this.value);
  final Object? value;
}

class _Name extends FNode {
  _Name(this.name);
  final String name;
}

class _Unary extends FNode {
  _Unary(this.op, this.value);
  final String op;
  final FNode value;
}

class _Binary extends FNode {
  _Binary(this.op, this.left, this.right);
  final String op;
  final FNode left;
  final FNode right;
}

class _If extends FNode {
  _If(this.test, this.yes, this.no);
  final FNode test;
  final FNode yes;
  final FNode no;
}

class _Call extends FNode {
  _Call(this.name, this.args);
  final String name;
  final List<FNode> args;
}

FNode _parse(String source) {
  final tokens = _tokenize(source);
  var index = 0;
  var depth = 0;
  _Token? peek() => index < tokens.length ? tokens[index] : null;
  bool isOp(String value) => peek()?.kind == 'op' && peek()!.value == value;
  void expect(String value) {
    if (!isOp(value)) {
      final token = peek();
      _fail(token != null ? 'expected "$value" at ${token.at + 1}' : 'expected "$value" at the end');
    }
    index += 1;
  }

  T nest<T>(T Function() read) {
    depth += 1;
    if (depth > _maxNesting) _fail('nested more than $_maxNesting levels');
    final node = read();
    depth -= 1;
    return node;
  }

  late FNode Function() ternary;
  late FNode Function(int level) binary;
  late FNode Function() unary;
  late FNode Function() primary;

  ternary = () => nest(() {
        final test = binary(0);
        if (!isOp('?')) return test;
        index += 1;
        final yes = ternary();
        expect(':');
        return _If(test, yes, ternary());
      });
  binary = (level) {
    if (level == _binary.length) return unary();
    var left = binary(level + 1);
    while (peek()?.kind == 'op' && _binary[level].contains(peek()!.value)) {
      final op = peek()!.value as String;
      index += 1;
      left = _Binary(op, left, binary(level + 1));
    }
    return left;
  };
  unary = () {
    if (isOp('-') || isOp('!') || isOp('+')) {
      final op = peek()!.value as String;
      index += 1;
      return nest(() => _Unary(op, unary()));
    }
    return primary();
  };
  primary = () {
    final token = peek();
    if (token == null) _fail('the formula ends too early');
    index += 1;
    if (token.kind == 'number' || token.kind == 'string') return _Value(token.value);
    if (token.kind == 'op' && token.value == '(') {
      final inner = ternary();
      expect(')');
      return inner;
    }
    if (token.kind != 'name') _fail('unexpected "${token.value}" at ${token.at + 1}');
    final name = token.value as String;
    if (!isOp('(')) {
      if (name == 'true') return _Value(true);
      if (name == 'false') return _Value(false);
      return _Name(name);
    }
    final fn = _functions[name];
    if (fn == null) _fail('unknown function "$name"; allowed: ${formulaFunctions.join(', ')}');
    index += 1;
    final args = <FNode>[];
    if (!isOp(')')) {
      args.add(ternary());
      while (isOp(',')) {
        index += 1;
        args.add(ternary());
      }
    }
    expect(')');
    if (args.length < fn.min || args.length > fn.max) {
      final takes = fn.min == fn.max ? '${fn.min}' : (fn.max == _infinity ? 'at least ${fn.min}' : '${fn.min} or ${fn.max}');
      _fail('$name() takes $takes argument${fn.max == 1 ? '' : 's'}; got ${args.length}');
    }
    return _Call(name, args);
  };

  if (tokens.isEmpty) _fail('the formula is empty');
  final tree = ternary();
  if (index < tokens.length) _fail('unexpected "${peek()!.value}" at ${peek()!.at + 1}');
  return tree;
}

Set<String> _namesIn(FNode node, [Set<String>? found]) {
  final out = found ?? <String>{};
  switch (node) {
    case _Name(:final name):
      out.add(name);
    case _Unary(:final value):
      _namesIn(value, out);
    case _Binary(:final left, :final right):
      _namesIn(left, out);
      _namesIn(right, out);
    case _If(:final test, :final yes, :final no):
      _namesIn(test, out);
      _namesIn(yes, out);
      _namesIn(no, out);
    case _Call(:final args):
      for (final arg in args) {
        _namesIn(arg, out);
      }
    case _Value():
      break;
  }
  return out;
}

class Compiled {
  const Compiled({this.tree, this.names = const [], this.error});

  final FNode? tree;
  final List<String> names;
  final String? error;
}

Compiled compileFormula(Object? source) {
  if (source is! String) return const Compiled(error: 'expected a formula string');
  try {
    final tree = _parse(source);
    return Compiled(tree: tree, names: _namesIn(tree).toList());
  } on FormulaError catch (error) {
    return Compiled(error: error.message);
  }
}

bool _truthy(Object? value) {
  if (value is String) return value.isNotEmpty;
  if (value is bool) return value;
  if (value is num) return value != 0 && !value.isNaN;
  return value != null;
}

bool _strictEquals(Object? left, Object? right) {
  if (left is num && right is num) return left.toDouble() == right.toDouble();
  if (left is num || right is num) return false;
  return left == right;
}

Object? _run(FNode node, Lookup lookup) {
  switch (node) {
    case _Value(:final value):
      return value;
    case _Name(:final name):
      return lookup(name);
    case _Unary(:final op, :final value):
      final result = _run(value, lookup);
      if (op == '!') return !_truthy(result);
      return op == '-' ? -_num(result) : _num(result);
    case _If(:final test, :final yes, :final no):
      return _truthy(_run(test, lookup)) ? _run(yes, lookup) : _run(no, lookup);
    case _Call(:final name, :final args):
      return _functions[name]!.run([for (final arg in args) _run(arg, lookup)]);
    case _Binary(:final op, :final left, :final right):
      if (op == '&&') return _truthy(_run(left, lookup)) ? _run(right, lookup) : false;
      if (op == '||') {
        final first = _run(left, lookup);
        return _truthy(first) ? first : _run(right, lookup);
      }
      final a = _run(left, lookup);
      final b = _run(right, lookup);
      switch (op) {
        case '+':
          return a is String || b is String ? '${show(a)}${show(b)}' : _num(a) + _num(b);
        case '-':
          return _num(a) - _num(b);
        case '*':
          return _num(a) * _num(b);
        case '/':
          return _num(a) / _num(b);
        case '%':
          final divisor = _num(b);
          return divisor == 0 ? double.nan : _num(a).remainder(divisor);
        case '==':
          return _strictEquals(a, b);
        case '!=':
          return !_strictEquals(a, b);
        case '<':
          return _num(a) < _num(b);
        case '<=':
          return _num(a) <= _num(b);
        case '>':
          return _num(a) > _num(b);
        default:
          return _num(a) >= _num(b);
      }
  }
}

/// A number as JavaScript's String() writes it (ECMA-262 Number::toString):
/// the shortest digits that round-trip, then plain or exponent form.
String jsNumber(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? 'Infinity' : '-Infinity';
  if (value == 0) return '0';
  final negative = value < 0;
  // Dart's toString also prints the shortest round-trip digits; only the layout differs.
  final text = value.abs().toString();
  final parts = text.split('e');
  final mantissa = parts[0];
  final exponent = parts.length > 1 ? int.parse(parts[1]) : 0;
  final dot = mantissa.indexOf('.');
  final intPart = dot == -1 ? mantissa : mantissa.substring(0, dot);
  final fracPart = dot == -1 ? '' : mantissa.substring(dot + 1);
  var digits = intPart + fracPart;
  var n = intPart.length + exponent;
  final leading = digits.length - digits.replaceFirst(RegExp('^0+'), '').length;
  digits = digits.substring(leading);
  n -= leading;
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  final k = digits.length;
  String out;
  if (k <= n && n <= 21) {
    out = digits + '0' * (n - k);
  } else if (0 < n && n <= 21) {
    out = '${digits.substring(0, n)}.${digits.substring(n)}';
  } else if (-6 < n && n <= 0) {
    out = '0.${'0' * -n}$digits';
  } else {
    final e = n - 1;
    out = '${digits[0]}${k > 1 ? '.${digits.substring(1)}' : ''}e${e < 0 ? '-' : '+'}${e.abs()}';
  }
  return negative ? '-$out' : out;
}

/// A value as text: numbers lose float noise (0.1 + 0.2 shows 0.3).
String show(Object? value) {
  if (value is num) {
    final number = value.toDouble();
    if (!number.isFinite) return jsNumber(number);
    return jsNumber(double.parse(number.toStringAsPrecision(12)));
  }
  if (value == null) return 'null';
  return '$value';
}

/// A scope for one view: input values, plus `let` names worked out on demand. A
/// cycle or a missing name fails the formula that reads it.
Lookup createScope(Map<String, Object?> inputs, Map<String, FNode> lets) {
  final done = <String, Object?>{};
  final busy = <String>{};
  late Lookup lookup;
  lookup = (name) {
    if (inputs.containsKey(name)) return inputs[name];
    if (done.containsKey(name)) return done[name];
    final tree = lets[name];
    if (tree == null) _fail('unknown name "$name"');
    if (busy.contains(name)) _fail('"$name" refers to itself');
    busy.add(name);
    try {
      final value = _run(tree, lookup);
      done[name] = value;
      return value;
    } finally {
      busy.remove(name);
    }
  };
  return lookup;
}

({Object? value, String? error}) evaluate(FNode tree, Lookup lookup) {
  try {
    return (value: _run(tree, lookup), error: null);
  } on FormulaError catch (error) {
    return (value: null, error: error.message);
  } on StackOverflowError {
    return (value: null, error: 'the formula is too deep to work out');
  }
}

// ---------------------------------------------------------------------------
// Views

const _layout = {'stack', 'row'};
const _inputTypes = {'slider', 'choice', 'toggle', 'number'};
const _answers = {'options', 'confirm', 'form', 'submit'};
const _maxText = 2000;

bool isFormula(Object? value) => value is Map && value.length == 1 && value.containsKey('=');

final Map<String, Compiled> _treeCache = {};

Compiled _treeOf(Map value) {
  final source = value['='];
  if (source is! String) return const Compiled(error: 'expected a formula string');
  return _treeCache.putIfAbsent(source, () => compileFormula(source));
}

Object? choiceValue(Object? option) => option is Map ? (option['value'] ?? option['label']) : null;

void _walk(Object? node, void Function(Map node) visit) {
  if (node is! Map) return;
  visit(node);
  if (_layout.contains(node['type']) && node['children'] is List) {
    for (final child in node['children'] as List) {
      _walk(child, visit);
    }
  }
}

List<Map> viewInputs(Object? view) {
  final found = <Map>[];
  _walk(view, (node) {
    if (_inputTypes.contains(node['type'])) found.add(node);
  });
  return found;
}

Object? inputDefault(Map node) {
  if (node['type'] == 'toggle') return node['value'] == true;
  if (node['type'] == 'choice') {
    final options = node['options'];
    return node['value'] ?? choiceValue(options is List && options.isNotEmpty ? options.first : null);
  }
  return node['value'];
}

/// The values a view's formulas read: each input's default unless [values] sets it.
Lookup viewScope(Object? view, [Map<String, Object?> values = const {}]) {
  final inputs = <String, Object?>{};
  for (final node in viewInputs(view)) {
    final id = '${node['id']}';
    inputs[id] = values.containsKey(id) ? values[id] : inputDefault(node);
  }
  final lets = <String, FNode>{};
  final declared = view is Map && view['let'] is Map ? view['let'] as Map : const {};
  for (final entry in declared.entries) {
    final compiled = compileFormula(entry.value);
    if (compiled.tree != null) lets['${entry.key}'] = compiled.tree!;
  }
  return createScope(inputs, lets);
}

/// A property's value: the literal, or the formula worked out. A formula that
/// fails with these inputs gives [fallback].
Object? resolve(Object? value, Lookup lookup, [Object? fallback]) {
  if (!isFormula(value)) return value;
  final entry = _treeOf(value! as Map);
  if (entry.tree == null) return fallback;
  final result = evaluate(entry.tree!, lookup);
  return result.error == null ? result.value : fallback;
}

String asText(Object? value) => value == null ? '' : show(value);

void _eachNode(Object? view, void Function(Map node) visit) {
  if (view is! Map) return;
  visit(view);
  final children = view['children'];
  if (children is List) {
    for (final child in children) {
      _eachNode(child, visit);
    }
  }
}

/// The answer as one short line for the user's own bubble.
String viewAnswerText(Object? view, Object? answer) {
  final values = answer is Map ? answer['values'] : null;
  if (values is! Map) return '';
  final action = answer is Map ? answer['action'] : null;
  final parts = <String>[];
  if (values['selected'] is List) {
    final labels = <Object?, Object?>{};
    _eachNode(view, (node) {
      for (final option in node['options'] is List ? node['options'] as List : const []) {
        if (option is! Map) continue;
        for (final key in [option['label'], option['value']]) {
          if (key != null) labels[key] = option['label'];
        }
      }
    });
    parts.addAll((values['selected'] as List).map((value) => '${labels[value] ?? value}'));
  } else if (values['confirmed'] is bool) {
    Object? confirmLabel;
    Object? cancelLabel;
    _eachNode(view, (node) {
      if (node['id'] == action) {
        confirmLabel = node['confirmLabel'];
        cancelLabel = node['cancelLabel'];
      }
    });
    parts.add(values['confirmed'] == true ? '${confirmLabel ?? 'Confirmed'}' : '${cancelLabel ?? 'Cancelled'}');
  } else if (values['canceled'] == true) {
    Object? cancelLabel;
    _eachNode(view, (node) {
      if (node['id'] == action) cancelLabel = node['cancelLabel'];
    });
    parts.add('${cancelLabel ?? 'Cancelled'}');
  } else if (values['fields'] is Map) {
    final labels = <Object?, Object?>{};
    _eachNode(view, (node) {
      for (final field in node['fields'] is List ? node['fields'] as List : const []) {
        if (field is Map) labels[field['id']] = (field['label'] is String && (field['label'] as String).isNotEmpty) ? field['label'] : field['id'];
      }
    });
    for (final entry in (values['fields'] as Map).entries) {
      parts.add('${labels[entry.key] ?? entry.key}: ${entry.value}');
    }
  }
  if (values['inputs'] is Map) {
    final labels = <Object?, Object?>{};
    _eachNode(view, (node) {
      if (node['id'] is String && node['label'] != null) labels[node['id']] = node['label'];
    });
    for (final entry in (values['inputs'] as Map).entries) {
      parts.add('${labels[entry.key] ?? entry.key}=${entry.value is num ? show(entry.value) : entry.value}');
    }
  }
  final text = parts.join('; ');
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

List<Map> _interactiveNodes(Object? node) {
  final found = <Map>[];
  _walk(node, (item) {
    if (_answers.contains(item['type'])) found.add(item);
  });
  return found;
}

/// The same check the computer runs on an answer. `{error}` when it would refuse.
Map<String, Object?> validateViewAnswer(Object? view, Object? action, Object? values) {
  final nodes = _interactiveNodes(view);
  final ids = nodes.map((node) => node['id']).join(', ');
  if (action is! String || action.isEmpty) return {'error': 'action: expected an interactive component id; allowed: $ids'};
  final node = nodes.where((item) => item['id'] == action).firstOrNull;
  if (node == null) return {'error': 'action: no interactive component with id "$action"; allowed: $ids'};
  if (values is! Map) return {'error': 'values: expected an object'};
  final inputs = _validateInputs(view, values['inputs']);
  if (inputs['error'] != null) return inputs;
  final extra = inputs['inputs'] == null ? <String, Object?>{} : {'inputs': inputs['inputs']};
  if (node['type'] == 'submit') return extra;
  final own = switch (node['type']) {
    'options' => _validateOptions(node, values),
    'confirm' => values['confirmed'] is bool ? {'confirmed': values['confirmed']} : {'error': 'values.confirmed: expected a boolean'},
    _ => _validateForm(node, values),
  };
  return own['error'] == null ? {...own, ...extra} : own;
}

Map<String, Object?> _validateInputs(Object? view, Object? sent) {
  final nodes = viewInputs(view);
  if (nodes.isEmpty) return sent == null ? {} : {'error': 'values.inputs: this view has no inputs'};
  if (sent != null && sent is! Map) return {'error': 'values.inputs: expected an object of input ids to values'};
  final given = (sent as Map?) ?? const {};
  final ids = nodes.map((node) => node['id']).toList();
  final unknown = given.keys.where((key) => !ids.contains(key)).firstOrNull;
  if (unknown != null) return {'error': 'values.inputs.$unknown: unknown input; allowed: ${ids.join(', ')}'};
  final inputs = <String, Object?>{};
  for (final node in nodes) {
    final value = given.containsKey(node['id']) ? given[node['id']] : inputDefault(node);
    final at = 'values.inputs.${node['id']}';
    if (node['type'] == 'toggle' && value is! bool) return {'error': '$at: expected true or false'};
    if (node['type'] == 'choice') {
      final options = node['options'] is List ? node['options'] as List : const [];
      if (!options.any((option) => choiceValue(option) == value)) return {'error': "$at: expected one of the options' values"};
    }
    if (node['type'] == 'slider' || node['type'] == 'number') {
      if (value is! num || !value.isFinite) return {'error': '$at: expected a number'};
      final min = node['min'];
      final max = node['max'];
      if ((min is num && value < min) || (max is num && value > max)) {
        return {'error': '$at: expected a number from ${min ?? '-∞'} to ${max ?? '∞'}'};
      }
    }
    inputs['${node['id']}'] = value;
  }
  return {'inputs': inputs};
}

Map<String, Object?> _validateOptions(Map node, Map values) {
  final selected = values['selected'];
  if (selected is! List) return {'error': 'values.selected: expected an array of option labels'};
  final labels = (node['options'] is List ? node['options'] as List : const []).map((option) => option is Map ? option['label'] : null).toSet();
  final picked = selected.where((label) => label is String && labels.contains(label)).toList();
  final chosen = node['multi'] == true ? picked.toSet().toList() : picked.take(1).toList();
  if (chosen.isEmpty) return {'error': 'values.selected: select at least one option'};
  return {'selected': chosen};
}

Map<String, Object?> _validateForm(Map node, Map values) {
  if (values['canceled'] == true) return {'canceled': true};
  final fieldsIn = values['fields'];
  if (fieldsIn is! Map) return {'error': 'values.fields: expected an object of field ids to strings'};
  final declared = (node['fields'] is List ? node['fields'] as List : const []).whereType<Map>().where((field) => field['id'] is String).toList();
  final byId = {for (final field in declared) field['id']: field};
  final fields = <String, Object?>{};
  for (final entry in fieldsIn.entries) {
    if (!byId.containsKey(entry.key)) return {'error': 'values.fields.${entry.key}: unknown field; allowed: ${byId.keys.join(', ')}'};
    final value = entry.value;
    if (value is! String) return {'error': 'values.fields.${entry.key}: expected a string'};
    if (value.length > _maxText) return {'error': 'values.fields.${entry.key}: ${value.length} characters exceeds the limit of $_maxText'};
    final spec = byId[entry.key]!;
    fields['${entry.key}'] = spec['readOnly'] == true ? (spec['value'] ?? '') : value;
  }
  return {'fields': fields};
}
