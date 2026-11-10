import '../../core/api/models.dart';

/// The composer's console commands: a leading `/` or `!` runs one as a
/// console action. Command text never reaches the agent.
enum ControlName { stop, model, effort, permission, fast }

/// Words that reach each command (the chat surfaces' aliases).
const controlWords = <ControlName, List<String>>{
  ControlName.stop: ['stop', 'cancel'],
  ControlName.model: ['model', 'models'],
  ControlName.effort: ['effort'],
  ControlName.permission: ['permission', 'permissions', 'perm'],
  ControlName.fast: ['fast'],
};

class ControlChoice {
  const ControlChoice(this.value, this.label, {this.current = false});
  final String value;
  final String label;
  final bool current;
}

/// A console command offered now. [choices] null: runs on pick; a list opens
/// a second level the typed argument narrows.
class ControlCommand {
  const ControlCommand(this.name, [this.choices]);
  final ControlName name;
  final List<ControlChoice>? choices;
  String get word => controlWords[name]!.first;
}

/// The draft's leading command: `/word arg` on the first line.
class CommandDraft {
  const CommandDraft(this.sigil, this.word, this.arg, {required this.hasSpace});
  final String sigil;
  final String word;

  /// Text after the word (trimmed), empty when none yet.
  final String arg;

  /// The word is finished (a space follows it).
  final bool hasSpace;
}

final _draftRe = RegExp(r'^[ \t]*([/!])([^\s/!]*)([ \t]+([^\n]*))?$');

/// The leading command of [text], when the draft is one (a single line).
CommandDraft? parseCommandDraft(String text) {
  final m = _draftRe.firstMatch(text);
  if (m == null) return null;
  return CommandDraft(m.group(1)!, m.group(2)!, (m.group(4) ?? '').trim(), hasSpace: m.group(3) != null);
}

/// 0 for a prefix, 1 for a substring, null for no match.
int? _rank(Iterable<String> words, String q) {
  if (q.isEmpty) return 1;
  if (words.any((w) => w.startsWith(q))) return 0;
  return words.any((w) => w.contains(q)) ? 1 : null;
}

List<T> _ranked<T>(List<T> items, int? Function(T) rank) {
  final scored = <(T, int, int)>[];
  for (var i = 0; i < items.length; i++) {
    final r = rank(items[i]);
    if (r != null) scored.add((items[i], r, i));
  }
  scored.sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$3 - b.$3);
  return [for (final s in scored) s.$1];
}

/// Console commands a typed word reaches: prefix matches first.
List<ControlCommand> matchControls(List<ControlCommand> controls, String query) {
  final q = query.trim().toLowerCase();
  return _ranked(controls, (c) => _rank(controlWords[c.name]!, q));
}

/// The command a whole word names (any alias), case-insensitively.
ControlName? controlForWord(String word) {
  final w = word.toLowerCase();
  for (final e in controlWords.entries) {
    if (e.value.contains(w)) return e.key;
  }
  return null;
}

/// Choices a typed argument reaches by value or label.
List<ControlChoice> matchChoices(List<ControlChoice> choices, String arg) {
  final q = arg.trim().toLowerCase();
  return _ranked(choices, (c) => _rank([c.value.toLowerCase(), c.label.toLowerCase()], q));
}

/// Skills a typed word reaches (skills only answer to `/`).
List<RuntimeCommand> matchSkills(List<RuntimeCommand> skills, String query) {
  final q = query.trim().toLowerCase();
  return _ranked(skills, (s) => _rank([s.name.toLowerCase()], q));
}

/// One row of the picker.
sealed class CommandRow {
  const CommandRow();
}

class ControlRow extends CommandRow {
  const ControlRow(this.command);
  final ControlCommand command;
}

class ChoiceRow extends CommandRow {
  const ChoiceRow(this.command, this.choice);
  final ControlCommand command;
  final ControlChoice choice;
}

class SkillRow extends CommandRow {
  const SkillRow(this.skill);
  final RuntimeCommand skill;
}

/// What the picker lists for [text]: a command's choices once its word is
/// finished, else console commands then skills.
List<CommandRow> commandRows(String text, List<ControlCommand> controls, List<RuntimeCommand> skills) {
  final d = parseCommandDraft(text);
  if (d == null) return const [];
  if (d.hasSpace) {
    final name = controlForWord(d.word);
    final cmd = controls.where((c) => c.name == name).firstOrNull;
    final choices = cmd?.choices;
    if (cmd == null || choices == null) return const [];
    return [for (final c in matchChoices(choices, d.arg)) ChoiceRow(cmd, c)];
  }
  return [
    for (final c in matchControls(controls, d.word)) ControlRow(c),
    if (d.sigil == '/')
      for (final s in matchSkills(skills, d.word)) SkillRow(s),
  ];
}
