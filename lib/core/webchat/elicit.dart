import 'dart:convert';

import '../api/models.dart';

/// The agent's question card (`elicitation` event, protocol `ElicitCard`) and
/// the rules for answering it. The daemon re-checks every answer; the checks
/// here only say, before sending, why an answer would be refused.

class ElicitOption {
  const ElicitOption(this.value, this.label);
  final String value;
  final String label;

  static List<ElicitOption> listFrom(dynamic j) => [
        for (final o in asList(j))
          if (asStr(asMap(o)['value']) case final v?) ElicitOption(v, asStr(asMap(o)['label']) ?? v),
      ];
}

/// Bounds of a multi-select (`ElicitMulti`).
class ElicitMulti {
  const ElicitMulti({this.minItems, this.maxItems});
  final int? minItems;
  final int? maxItems;

  static ElicitMulti? fromJson(dynamic j) =>
      j is Map ? ElicitMulti(minItems: _int(j['minItems']), maxItems: _int(j['maxItems'])) : null;
}

/// Constraints of a typed text answer (`ElicitText`).
class ElicitText {
  const ElicitText({this.minLength, this.maxLength, this.pattern, this.format});
  final int? minLength;
  final int? maxLength;
  final String? pattern;

  /// email, uri, date or date-time.
  final String? format;

  static ElicitText? fromJson(dynamic j) => j is Map
      ? ElicitText(
          minLength: _int(j['minLength']),
          maxLength: _int(j['maxLength']),
          pattern: asStr(j['pattern']),
          format: asStr(j['format']))
      : null;
}

/// Constraints of a numeric answer (`ElicitNumber`).
class ElicitNumber {
  const ElicitNumber({this.integer = false, this.minimum, this.maximum});
  final bool integer;
  final num? minimum;
  final num? maximum;

  static ElicitNumber? fromJson(dynamic j) => j is Map
      ? ElicitNumber(
          integer: j['integer'] == true,
          minimum: j['minimum'] is num ? j['minimum'] as num : null,
          maximum: j['maximum'] is num ? j['maximum'] as num : null)
      : null;
}

int? _int(dynamic v) => v is num ? v.toInt() : null;

/// What a single-field card and each field of a form share.
class ElicitSpec {
  const ElicitSpec({this.options = const [], this.multi, this.text, this.number, this.defaultValue});
  final List<ElicitOption> options;
  final ElicitMulti? multi;
  final ElicitText? text;
  final ElicitNumber? number;

  /// The schema's default: a string, number, bool or list of strings.
  final Object? defaultValue;

  /// What a typed control starts out holding.
  String get typedDefault => switch (defaultValue) {
        final String s => s,
        final num n => formatNum(n),
        _ => '',
      };

  /// The options a choice starts out holding.
  List<String> get pickedDefault => switch (defaultValue) {
        final List<dynamic> l => l.whereType<String>().toList(),
        final String s => [s],
        final bool b => ['$b'],
        _ => const [],
      };
}

Object? _default(dynamic v) => v is String || v is num || v is bool
    ? v
    : v is List
        ? v.whereType<String>().toList()
        : null;

/// One field of a form card (`ElicitField`).
class ElicitField extends ElicitSpec {
  const ElicitField({
    required this.propName,
    required this.label,
    required this.kind,
    this.required = false,
    this.description,
    this.customAnswerFor,
    super.options,
    super.multi,
    super.text,
    super.number,
    super.defaultValue,
  });

  /// The key the answer is returned under.
  final String propName;
  final String label;

  /// enum, boolean, multi-enum, text or number.
  final String kind;
  final bool required;
  final String? description;

  /// Set on a question's free-text box: the property whose question it answers.
  final String? customAnswerFor;

  bool get isTyped => kind == 'text' || kind == 'number';
  bool get isMulti => kind == 'multi-enum';

  ElicitField copyWith({String? customAnswerFor, List<ElicitOption>? options, bool dropDefault = false}) => ElicitField(
        propName: propName,
        label: label,
        kind: kind,
        required: required,
        description: description,
        customAnswerFor: customAnswerFor ?? this.customAnswerFor,
        options: options ?? this.options,
        multi: multi,
        text: text,
        number: number,
        defaultValue: dropDefault ? null : defaultValue,
      );

  static const kinds = {'enum', 'boolean', 'multi-enum', 'text', 'number'};

  static ElicitField? fromJson(dynamic j) {
    final m = asMap(j);
    final name = asStr(m['propName']);
    final kind = asStr(m['kind']);
    if (name == null || name.isEmpty || !kinds.contains(kind)) return null;
    final custom = asStr(m['customAnswerFor']);
    return ElicitField(
      propName: name,
      label: asStr(m['label']) ?? name,
      kind: kind!,
      required: m['required'] == true,
      description: asStr(m['description']),
      customAnswerFor: custom == null || custom.isEmpty ? null : custom,
      options: ElicitOption.listFrom(m['options']),
      multi: ElicitMulti.fromJson(m['multi']),
      text: ElicitText.fromJson(m['text']),
      number: ElicitNumber.fromJson(m['number']),
      defaultValue: _default(m['defaultValue']),
    );
  }
}

enum ElicitMode { url, form, typed, multi, single, unanswerable }

/// One question card as the daemon reduced it. Descriptors only: the answer
/// lives in the card's widget state until it is sent.
class ElicitCard extends ElicitSpec {
  const ElicitCard({
    required this.requestId,
    required this.message,
    this.fields,
    this.url,
    this.unreadable = false,
    super.options,
    super.multi,
    super.text,
    super.number,
    super.defaultValue,
  });
  final String requestId;

  /// The agent's text: untrusted, shown as plain text.
  final String message;

  /// Present: a form, one control per field, answered with a value per field.
  final List<ElicitField>? fields;

  /// Present: a consent card for this exact URL.
  final String? url;

  /// The card carries a field this build can't read: it can only be dismissed.
  final bool unreadable;

  ElicitMode get mode {
    if (unreadable) return ElicitMode.unanswerable;
    if (url != null) return readConsentUrl(url!) == null ? ElicitMode.unanswerable : ElicitMode.url;
    if (fields != null) return ElicitMode.form;
    if (text != null || number != null) return ElicitMode.typed;
    if (options.isEmpty) return ElicitMode.unanswerable;
    return multi != null ? ElicitMode.multi : ElicitMode.single;
  }

  /// The first line names the ask; the rest reads as a preamble.
  String get headLine => message.split('\n').first;
  String get preamble => message.substring(headLine.length).trim();

  static ElicitCard? fromJson(Map<String, dynamic> m) {
    final id = asStr(m['requestId']);
    if (id == null || id.isEmpty) return null;
    List<ElicitField>? fields;
    var unreadable = false;
    if (m['fields'] is List) {
      final parsed = asList(m['fields']).map(ElicitField.fromJson).toList();
      if (parsed.isEmpty || parsed.contains(null)) {
        unreadable = true;
      } else {
        fields = foldCustomAnswers(parsed.whereType<ElicitField>().toList());
      }
    }
    final url = asStr(m['url']);
    return ElicitCard(
      requestId: id,
      message: asStr(m['message']) ?? '',
      fields: fields,
      url: url == null || url.isEmpty ? null : url,
      unreadable: unreadable,
      options: ElicitOption.listFrom(m['options']),
      multi: ElicitMulti.fromJson(m['multi']),
      text: ElicitText.fromJson(m['text']),
      number: ElicitNumber.fromJson(m['number']),
      defaultValue: _default(m['defaultValue']),
    );
  }
}

/// `elicitation_resolved` outcomes.
const elicitOutcomes = {'accepted', 'dismissed', 'cancelled', 'completed'};

/// A saved `elicit` row's body (`ElicitBody`): the card as it was offered,
/// how it ended and the chosen label. The outcome is `unrenderable` for an
/// ask no surface had a control for, and `unanswered` here when none was
/// recorded. [text] is the row's own text, the question.
({ElicitCard card, String outcome, String? label})? savedElicit(String? body, String text) {
  if (body == null || body.isEmpty) return null;
  final Map<String, dynamic> m;
  try {
    m = asMap(jsonDecode(body));
  } catch (_) {
    return null;
  }
  final card = ElicitCard.fromJson({...m, if (text.isNotEmpty) 'message': text});
  if (card == null) return null;
  final outcome = asStr(m['outcome']);
  return (
    card: card,
    outcome: elicitOutcomes.contains(outcome) || outcome == 'unrenderable' ? outcome! : 'unanswered',
    label: asStr(m['answerLabel']),
  );
}

/// Why an answer can't be sent yet, or what a control asks for; the card
/// turns [code] (and [a], [b]) into words.
class ElicitNote {
  const ElicitNote(this.code, [this.a, this.b]);
  final String code;
  final Object? a;
  final Object? b;

  @override
  bool operator ==(Object other) => other is ElicitNote && other.code == code && other.a == a && other.b == b;
  @override
  int get hashCode => Object.hash(code, a, b);
  @override
  String toString() => 'ElicitNote($code, $a, $b)';
}

/// `5` for 5.0, `2.5` for 2.5.
String formatNum(num n) => n is int || (n.isFinite && n == n.roundToDouble()) ? n.toInt().toString() : n.toString();

/// The number a typed draft stands for; an int when it is whole.
num? parseNumber(String draft) {
  final v = num.tryParse(draft.trim());
  if (v == null || !v.isFinite) return null;
  return v is double && v == v.roundToDouble() && v.abs() < 9e15 ? v.toInt() : v;
}

final _email = RegExp(r'^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$');
final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _dateTime =
    RegExp(r'^(\d{4}-\d{2}-\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$');

bool _isDate(String v) {
  final m = _date.firstMatch(v);
  if (m == null) return false;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

bool _isDateTime(String v) {
  final m = _dateTime.firstMatch(v);
  if (m == null || !_isDate(m[1]!)) return false;
  return int.parse(m[2]!) <= 23 && int.parse(m[3]!) <= 59 && int.parse(m[4]!) <= 59;
}

/// Why a typed draft isn't answerable yet, or null once it is.
ElicitNote? typedProblem(ElicitSpec spec, String draft) {
  final n = spec.number;
  if (n != null) {
    final v = parseNumber(draft);
    if (v == null) return const ElicitNote('number');
    if (n.integer && v is! int) return const ElicitNote('whole');
    if (n.minimum != null && v < n.minimum!) return ElicitNote('min', formatNum(n.minimum!));
    if (n.maximum != null && v > n.maximum!) return ElicitNote('max', formatNum(n.maximum!));
    return null;
  }
  final t = spec.text;
  if (t == null) return null;
  if (t.minLength != null && draft.length < t.minLength!) return ElicitNote('minLength', t.minLength);
  if (draft.isEmpty) return const ElicitNote('answer');
  if (t.maxLength != null && draft.length > t.maxLength!) return ElicitNote('maxLength', t.maxLength);
  switch (t.format) {
    case 'email' when !_email.hasMatch(draft):
      return const ElicitNote('email');
    case 'uri' when !(Uri.tryParse(draft)?.hasScheme ?? false):
      return const ElicitNote('uri');
    case 'date' when !_isDate(draft):
      return const ElicitNote('date');
    case 'date-time' when !_isDateTime(draft):
      return const ElicitNote('dateTime');
  }
  final pattern = t.pattern;
  if (pattern != null) {
    try {
      if (!RegExp(pattern).hasMatch(draft)) return ElicitNote('pattern', pattern);
    } catch (_) {
      return const ElicitNote('cannot');
    }
  }
  return null;
}

/// What a multi-select asks of the reader, from the schema's bounds.
ElicitNote selectionHint(ElicitMulti? multi) {
  final min = multi?.minItems ?? 0;
  final max = multi?.maxItems;
  if (min > 0 && max != null) return min == max ? ElicitNote('selectExactly', min) : ElicitNote('selectRange', min, max);
  if (min > 0) return ElicitNote('selectAtLeast', min);
  return max != null ? ElicitNote('selectUpTo', max) : const ElicitNote('selectAny');
}

/// Whether [count] picks fit a multi-select's bounds.
bool selectionFits(ElicitMulti? multi, int count) =>
    count >= (multi?.minItems ?? 0) && (multi?.maxItems == null || count <= multi!.maxItems!);

/// The free-text box a question carries instead of an option, if any.
ElicitField? companionOf(List<ElicitField> fields, ElicitField f) {
  for (final c in fields) {
    if (c.customAnswerFor == f.propName) return c;
  }
  return null;
}

ElicitNote? _fieldProblem(ElicitField f, Map<String, String> drafts, Map<String, List<String>> picks) {
  if (f.isTyped) {
    final draft = drafts[f.propName] ?? '';
    if (draft.trim().isEmpty) {
      if (!f.required) return null;
      // A required field is never left out, whatever constraints it carries.
      return typedProblem(f, draft) ?? ElicitNote(f.kind == 'number' ? 'number' : 'answer');
    }
    return typedProblem(f, draft);
  }
  final picked = picks[f.propName] ?? const [];
  if (f.isMulti) {
    if (picked.isEmpty && !f.required) return null;
    return selectionFits(f.multi, picked.length) ? null : selectionHint(f.multi);
  }
  return picked.length == 1 || (picked.isEmpty && !f.required) ? null : const ElicitNote('chooseOne');
}

bool _customStandsAlone(ElicitField f, ElicitField? companion, Map<String, String> drafts) =>
    companion != null && !f.required && (drafts[companion.propName] ?? '').trim().isNotEmpty;

/// Whether a question holds an answer, by its control or the box that answers for it.
bool rowAnswered(ElicitField f, ElicitField? companion, Map<String, String> drafts, Map<String, List<String>> picks) {
  final own = f.isTyped ? (drafts[f.propName] ?? '').trim().isNotEmpty : (picks[f.propName] ?? const []).isNotEmpty;
  return own || _customStandsAlone(f, companion, drafts);
}

/// Why a question isn't answerable yet: its typed box is always checked, its
/// own control only where the box doesn't answer for it.
ElicitNote? rowProblem(
    ElicitField f, ElicitField? companion, Map<String, String> drafts, Map<String, List<String>> picks) {
  final draft = companion == null ? '' : (drafts[companion.propName] ?? '');
  if (companion != null && draft.trim().isNotEmpty) {
    final typed = typedProblem(companion, draft);
    if (typed != null || _customStandsAlone(f, companion, drafts)) return typed;
  }
  return _fieldProblem(f, drafts, picks);
}

/// A form's answer: each answered field in its schema type; an untouched
/// optional field is left out.
Map<String, Object> formAnswer(List<ElicitField> fields, Map<String, String> drafts, Map<String, List<String>> picks) {
  final out = <String, Object>{};
  for (final f in fields) {
    if (f.isTyped) {
      final draft = drafts[f.propName] ?? '';
      if (draft.trim().isEmpty) continue;
      if (f.kind == 'number') {
        final v = parseNumber(draft);
        if (v != null) out[f.propName] = v;
      } else {
        out[f.propName] = draft;
      }
      continue;
    }
    final picked = picks[f.propName] ?? const <String>[];
    if (f.isMulti) {
      // A required multi-select carries even the empty set.
      if (f.required || picked.isNotEmpty) out[f.propName] = [...picked];
    } else if (picked.length == 1) {
      out[f.propName] = picked.single;
    }
  }
  return out;
}

const _customSuffixes = ['_custom', '_other', '-custom', '-other'];

String? _suffixedOwner(String propName, Set<String> selects) {
  final lower = propName.toLowerCase();
  for (final suffix in _customSuffixes) {
    if (!lower.endsWith(suffix)) continue;
    final stem = propName.substring(0, propName.length - suffix.length);
    for (final owner in [stem, if (stem.isNotEmpty) stem.substring(0, stem.length - 1)]) {
      if (owner.isNotEmpty && selects.contains(owner)) return owner;
    }
  }
  return null;
}

/// A form's fields with every unbound "Other" box folded into its question,
/// read from the pair's names (`question_0` + `question_0_custom`), and the
/// question's own "Other" choice dropped where the box replaces it. Only an
/// optional text field is read this way.
List<ElicitField> foldCustomAnswers(List<ElicitField> fields) {
  final selects = {
    for (final f in fields)
      if (f.kind == 'enum' || f.kind == 'multi-enum') f.propName,
  };
  final bound = [
    for (final f in fields)
      if (f.customAnswerFor != null || f.kind != 'text' || f.required)
        f
      else if (_suffixedOwner(f.propName, selects) case final owner?)
        f.copyWith(customAnswerFor: owner)
      else
        f,
  ];
  final companionLabel = <String, String>{
    for (final f in bound)
      if (f.customAnswerFor != null) f.customAnswerFor!: f.label.trim().toLowerCase(),
  };
  return [
    for (final f in bound)
      if (companionLabel[f.propName] case final label? when f.options.isNotEmpty)
        _withoutOption(f, label)
      else
        f,
  ];
}

ElicitField _withoutOption(ElicitField f, String label) {
  final options = f.options.where((o) => o.label.trim().toLowerCase() != label).toList();
  if (options.isEmpty || options.length == f.options.length) return f;
  final values = {for (final o in options) o.value};
  final d = f.defaultValue;
  final stale = d is List ? d.any((v) => !values.contains(v)) : d is String && !values.contains(d);
  return f.copyWith(options: options, dropDefault: stale);
}

/// A consent URL split for display, with advisory warnings about its host.
class ConsentUrl {
  const ConsentUrl({required this.scheme, required this.host, required this.rest, required this.warnings});
  final String scheme;

  /// The authority exactly as written (what the reader sees).
  final String host;
  final String rest;

  /// `http`, `userinfo` (the text before `@` is not the destination; [a] is
  /// the real host) and `lookalike` (not plain ASCII).
  final List<ElicitNote> warnings;
}

final _nonAscii = RegExp(r'[^\x00-\x7F]');
final _punycode = RegExp(r'(^|\.)xn--', caseSensitive: false);

/// Null when [url] isn't something to open in a browser (only http/https are).
ConsentUrl? readConsentUrl(String url) {
  final Uri parsed;
  try {
    parsed = Uri.parse(url);
  } catch (_) {
    return null;
  }
  if ((parsed.scheme != 'https' && parsed.scheme != 'http') || parsed.host.isEmpty) return null;
  // Split the original string by position: the reader sees the original.
  final slashes = url.indexOf('//');
  if (slashes < 0) return null;
  final afterScheme = slashes + 2;
  final authorityEnd = url.substring(afterScheme).indexOf(RegExp(r'[/?#]'));
  final hostEnd = authorityEnd < 0 ? url.length : afterScheme + authorityEnd;
  final shown = url.substring(afterScheme, hostEnd);
  return ConsentUrl(
    scheme: url.substring(0, afterScheme),
    host: shown,
    rest: url.substring(hostEnd),
    warnings: [
      if (parsed.scheme != 'https') const ElicitNote('http'),
      if (shown.contains('@')) ElicitNote('userinfo', parsed.host),
      if (_punycode.hasMatch(parsed.host) || _nonAscii.hasMatch(shown)) const ElicitNote('lookalike'),
    ],
  );
}
