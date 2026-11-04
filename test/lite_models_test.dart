import 'package:agentconnect/core/api/approvals.dart';
import 'package:agentconnect/core/api/models.dart';
import 'package:agentconnect/core/api/workspace.dart';
import 'package:agentconnect/core/webchat/frames.dart';
import 'package:agentconnect/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

// Anonymized fixtures shaped like GET /orgs/{org}/daemons and permission-requests.
Map<String, dynamic> daemon(String id, String status, {bool cloud = false, num? cpu, int active = 0}) => {
      'daemonId': id,
      'name': 'machine-$id',
      'status': status,
      'health': 'ok',
      'cloud': cloud,
      'agentVersion': '1.9.4',
      'activeSessions': active,
      'load': cpu == null ? null : {'cpu': cpu, 'mem': 0.3, 'agents': 1},
    };

void main() {
  test('machine status maps to online / paused / offline', () {
    expect(Machine.fromJson(daemon('a', 'ready')).state, AgentHealth.online);
    expect(Machine.fromJson(daemon('b', 'draining')).state, AgentHealth.paused);
    expect(Machine.fromJson(daemon('c', 'connecting')).state, AgentHealth.paused);
    expect(Machine.fromJson(daemon('d', 'unreachable')).state, AgentHealth.offline);
    expect(Machine.fromJson(daemon('e', 'offline')).state, AgentHealth.offline);
  });

  test('cpu accepts 0–1 and 0–100', () {
    expect(Machine.fromJson(daemon('a', 'ready', cpu: 0.41)).cpu, closeTo(41, 0.001));
    expect(Machine.fromJson(daemon('a', 'ready', cpu: 72)).cpu, 72);
    expect(Machine.fromJson(daemon('a', 'ready')).cpu, isNull);
  });

  test('cloud pool is one row: any member online, sessions summed, cpu averaged', () {
    final members = [
      Machine.fromJson(daemon('p1', 'ready', cloud: true, cpu: 0.2, active: 2)),
      Machine.fromJson(daemon('p2', 'ready', cloud: true, cpu: 0.4, active: 1)),
      Machine.fromJson(daemon('p3', 'offline', cloud: true)),
    ];
    final pool = Machine.pool(members);
    expect(pool.state, AgentHealth.online);
    expect(pool.nodes, 3);
    expect(pool.activeSessions, 3);
    expect(pool.cpu, closeTo(30, 0.001));
    expect(Machine.pool([members[2]]).state, AgentHealth.offline);
  });

  test('source: web chat only for webchat; background runs are other', () {
    expect(sourceOf('webchat'), 'chat');
    expect(sourceOf('slack'), 'slack');
    expect(sourceOf('hook'), 'github');
    expect(sourceOf('dream'), 'other');
  });

  test('list time: clock today, weekday this week, date otherwise', () {
    final now = DateTime(2026, 11, 4, 15);
    expect(listTime(DateTime(2026, 11, 4, 14, 14), now: now).replaceAll('\u202f', ' '), '2:14 PM');
    expect(listTime(DateTime(2026, 11, 2, 9), now: now), 'Mon');
    expect(listTime(DateTime(2026, 10, 3, 9), now: now), 'Oct 3');
  });

  test('approval keeps kind and resolution', () {
    final a = Approval.fromJson({
      'id': 'r1',
      'agentId': 'ag1',
      'sessionId': 's1',
      'createdAt': '2026-11-04T10:00:00.000Z',
      'requesterName': 'Sam',
      'command': 'Sam · @sam — not a member',
      'status': 'allowed',
      'kind': 'join',
      'resolvedAt': '2026-11-04T10:05:00.000Z',
      'resolvedByName': 'Dana',
      'options': [],
    });
    expect(a.isJoin, isTrue);
    expect(a.pending, isFalse);
    expect(a.resolvedBy, 'Dana');
  });

  test('run status snapshot: parse and merge partial updates', () {
    final f = decodeFrame('{"type":"output","output":{"turnId":"t","index":3,"status":'
        '{"model":"model-b","effort":"high","permissionMode":"auto","models":["model-a","model-b"],'
        '"efforts":["low","medium","high"],"permissionModes":["default","plan","auto"]}}}') as OutputFrame;
    final s = f.status!;
    expect(s.model, 'model-b');
    expect(s.models, ['model-a', 'model-b']);
    final merged = s.merge(const RunStatus(effort: 'low'));
    expect(merged.effort, 'low');
    expect(merged.model, 'model-b');
    expect(merged.permissionModes, ['default', 'plan', 'auto']);
  });

  test('task and git status decoding', () {
    final t = AgentTask.fromJson({
      'sessionId': 's2',
      'title': 'Find what blocks the release',
      'state': 'open',
      'startedAt': '2026-11-04T10:00:00.000Z',
      'summary': '3 of 5 PRs are clear',
      'replies': 3,
      'threaded': true,
      'openedForMessageId': 'm1',
      'visible': true,
    });
    expect(t.running, isTrue);
    expect(t.replies, 3);
    expect(t.openedForMessageId, 'm1');
    final g = GitStatus.fromJson({
      'isRepo': true,
      'clean': false,
      'branch': 'release/1.5',
      'tracking': 'origin/main',
      'files': [
        {'path': 'CHANGELOG.md', 'index': ' ', 'workingDir': 'M', 'additions': 18, 'deletions': 2},
        {'path': 'docs/new.md', 'index': '?', 'workingDir': '?', 'additions': 42},
      ],
    });
    expect(g.base, 'main');
    expect(g.files.map((f) => f.code), ['M', 'A']);
  });
}
