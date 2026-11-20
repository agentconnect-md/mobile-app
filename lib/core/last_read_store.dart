import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How far each conversation was read on this device: a session id and the
/// last transcript seq seen there. Nothing else is kept: no message content,
/// no titles, no names.
class LastReadStore {
  LastReadStore._();
  static final instance = LastReadStore._();

  /// Sessions remembered at most; the least recently read fall out first.
  static const maxSessions = 300;
  static const _key = 'transcript.lastRead';

  /// Session id → seq, least recently read first.
  Map<String, int>? _map;

  Future<Map<String, int>> _load() async {
    final cached = _map;
    if (cached != null) return cached;
    final map = <String, int>{};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final list = raw == null ? null : jsonDecode(raw);
      if (list is List) {
        for (final e in list) {
          if (e is List && e.length == 2 && e[0] is String && e[1] is int) map[e[0] as String] = e[1] as int;
        }
      }
    } catch (_) {
      // Unreadable: start over. The divider is a convenience.
    }
    return _map ??= map;
  }

  /// The last seq read in [sessionId] on this device; null when it was never
  /// read here (or has fallen out).
  Future<int?> read(String sessionId) async => (await _load())[sessionId];

  /// Records that [sessionId] was read up to [seq]. It never moves back, and
  /// only the [maxSessions] most recently read sessions are kept.
  Future<void> write(String sessionId, int seq) async {
    final map = await _load();
    final had = map[sessionId];
    if (had != null && (had > seq || (had == seq && map.keys.last == sessionId))) return;
    map.remove(sessionId);
    map[sessionId] = seq;
    while (map.length > maxSessions) {
      map.remove(map.keys.first);
    }
    await _save(map);
  }

  /// Forgets everything (the last account signed out).
  Future<void> clear() async {
    _map = {};
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }

  Future<void> _save(Map<String, int> map) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode([
        for (final e in map.entries) [e.key, e.value],
      ]));
    } catch (_) {
      // Not saved: reading goes on without it.
    }
  }

  /// Tests: drop the in-memory copy so the next call reads the saved one.
  @visibleForTesting
  void debugReload() => _map = null;
}
