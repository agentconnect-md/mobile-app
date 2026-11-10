import 'dart:convert';

import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/features/chat/composer_commands.dart';
import 'package:flutter_test/flutter_test.dart';

const _controls = [
  ControlCommand(ControlName.stop),
  ControlCommand(ControlName.model, [ControlChoice('opus', 'opus', current: true), ControlChoice('sonnet', 'sonnet')]),
  ControlCommand(ControlName.effort, [ControlChoice('low', 'Low'), ControlChoice('high', 'High')]),
  ControlCommand(ControlName.permission, [ControlChoice('default', 'Manual'), ControlChoice('auto', 'Auto')]),
  ControlCommand(ControlName.fast, [ControlChoice('on', 'On'), ControlChoice('off', 'Off')]),
];

const _skills = [
  RuntimeCommand(name: 'review', skill: true),
  RuntimeCommand(name: 'code-review', skill: true),
];

void main() {
  test('parses a leading command', () {
    final d = parseCommandDraft('  /effort hi')!;
    expect(d.sigil, '/');
    expect(d.word, 'effort');
    expect(d.arg, 'hi');
    expect(d.hasSpace, isTrue);
    expect(parseCommandDraft('!fast')!.hasSpace, isFalse);
    expect(parseCommandDraft('hello /stop'), isNull);
    expect(parseCommandDraft('/stop\nmore'), isNull);
  });

  test('console commands come first, then skills; aliases match', () {
    final rows = commandRows('/', _controls, _skills);
    expect(rows.whereType<ControlRow>().length, 5);
    expect(rows.whereType<SkillRow>().length, 2);
    expect(rows.indexWhere((r) => r is SkillRow), greaterThan(rows.lastIndexWhere((r) => r is ControlRow)));

    expect((commandRows('/perm', _controls, _skills).single as ControlRow).command.name, ControlName.permission);
    expect((commandRows('!cancel', _controls, _skills).single as ControlRow).command.name, ControlName.stop);
    expect((commandRows('/models', _controls, _skills).single as ControlRow).command.name, ControlName.model);
    // `!` lists console commands only.
    expect(commandRows('!re', _controls, _skills), isEmpty);
    // Prefix before substring: `re` reaches review before code-review.
    final s = commandRows('/re', _controls, _skills).whereType<SkillRow>().map((r) => r.skill.name).toList();
    expect(s, ['review', 'code-review']);
  });

  test('a finished word lists its choices, narrowed by the argument', () {
    final rows = commandRows('/effort hi', _controls, _skills);
    expect(rows.map((r) => (r as ChoiceRow).choice.value), ['high']);
    expect(commandRows('!fast on', _controls, _skills).map((r) => (r as ChoiceRow).choice.value), ['on']);
    expect(commandRows('/model ', _controls, _skills).length, 2);
    expect(commandRows('/stop ', _controls, _skills), isEmpty);
    expect(controlForWord('PERMISSIONS'), ControlName.permission);
    expect(controlForWord('review'), isNull);
  });

  test('skill detection follows the daemon bit, else the naming conventions', () {
    expect(const RuntimeCommand(name: 'compact').isSkill, isFalse);
    expect(const RuntimeCommand(name: r'$rollback').isSkill, isTrue);
    expect(const RuntimeCommand(name: 'mcp:x').isSkill, isFalse);
    expect(const RuntimeCommand(name: 'plugin:skill').isSkill, isTrue);
    expect(const RuntimeCommand(name: 'deploy', description: 'Ship it (project)').isSkill, isTrue);
    expect(const RuntimeCommand(name: 'deploy', skill: false, description: 'x (user)').isSkill, isFalse);
  });

  test('prompt suggestion and fast mode frames', () {
    final s = decodeFrame(jsonEncode({
      'type': 'prompt_suggestion',
      'suggestion': {'conversationId': 'c', 'agentId': 'a', 'text': 'Run the tests'}
    })) as PromptSuggestionFrame;
    expect(s.text, 'Run the tests');
    final clear = decodeFrame(jsonEncode({
      'type': 'prompt_suggestion',
      'suggestion': {'conversationId': 'c', 'agentId': 'a', 'text': null}
    })) as PromptSuggestionFrame;
    expect(clear.text, isNull);
    final st = RunStatus.fromJson({'fastMode': true, 'fastModeAvailable': true})!;
    expect(st.merge(const RunStatus(model: 'm')).fastMode, isTrue);
    final r = decodeFrame('{"type":"ready","conversationId":"c","participants":[{"agentId":"a"},{"agentId":"b"}]}')
        as ReadyFrame;
    expect(r.participants, 2);
  });
}
