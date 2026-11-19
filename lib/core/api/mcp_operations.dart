import 'models.dart';

/// A side-effecting AgentConnect MCP operation an agent asked for in a
/// webchat conversation (`WebchatMcpOperationDto`). It runs only once the
/// conversation's owner approves it.
class McpOperation {
  const McpOperation({
    required this.operationId,
    required this.toolName,
    required this.status,
    this.arguments,
    this.result,
    this.hasResult = false,
    this.createdAt,
    this.confirmationExpiresAt,
    this.completedAt,
  });
  final String operationId;
  final String toolName;

  /// The tool's arguments as the agent gave them: shown, never logged or kept.
  final Object? arguments;

  /// awaiting_confirmation, executing, completed, failed, ambiguous or stale.
  /// A denial is `failed` (the operation never ran).
  final String status;

  /// The bounded result once it ran (`{statusCode, body}`).
  final Object? result;
  final bool hasResult;
  final DateTime? createdAt;
  final DateTime? confirmationExpiresAt;
  final DateTime? completedAt;

  bool get awaiting => status == 'awaiting_confirmation';
  bool get executing => status == 'executing';

  static McpOperation? fromJson(dynamic j) {
    final m = asMap(j);
    final id = asStr(m['operationId']);
    final status = asStr(m['status']);
    if (id == null || id.isEmpty || status == null) return null;
    return McpOperation(
      operationId: id,
      toolName: asStr(m['toolName']) ?? '',
      status: status,
      arguments: m['arguments'],
      result: m['result'],
      hasResult: m.containsKey('result'),
      createdAt: asDate(m['createdAt']),
      confirmationExpiresAt: asDate(m['confirmationExpiresAt']),
      completedAt: asDate(m['completedAt']),
    );
  }
}

/// What the conversation tells the agent about a settled operation: it got an
/// operation id and ended its turn, so nothing else would. Short and
/// machine-readable; the agent reads the result itself with `getOperation`.
/// A denial lands as `failed`, so the decision is what tells the two apart.
String mcpApprovalNotice(McpOperation operation, {required bool approved, required McpOperation outcome}) {
  final state = !approved && outcome.status == 'failed' ? 'denied' : outcome.status;
  return '[approval] ${operation.toolName} (operation ${operation.operationId}) is now $state. '
      'Read it with getOperation and continue from there.';
}
