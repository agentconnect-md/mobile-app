import 'dart:convert';

import '../api/models.dart';
import 'oidc_session.dart';

/// One signed-in account. Its credential is either an API key ([key]) or a
/// browser sign-in ([oidc]; the tokens live in the token store). Both only
/// ever live in the Keychain.
class Account {
  const Account({
    required this.id,
    required this.apiBase,
    required this.key,
    this.oidc,
    required this.orgId,
    required this.orgName,
    required this.userId,
    required this.userName,
  });
  final String id;
  final String apiBase;
  final String key;
  final OidcInfo? oidc;
  final String orgId;
  final String orgName;
  final String userId;
  final String userName;

  bool get isBrowser => oidc != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'apiBase': apiBase,
        'key': key,
        if (oidc != null) 'oidc': oidc!.toJson(),
        'orgId': orgId,
        'orgName': orgName,
        'userId': userId,
        'userName': userName,
      };

  factory Account.fromJson(dynamic j) {
    final m = asMap(j);
    return Account(
      id: asStr(m['id']) ?? '',
      apiBase: asStr(m['apiBase']) ?? '',
      key: asStr(m['key']) ?? '',
      oidc: OidcInfo.fromJson(m['oidc']),
      orgId: asStr(m['orgId']) ?? '',
      orgName: asStr(m['orgName']) ?? '',
      userId: asStr(m['userId']) ?? '',
      userName: asStr(m['userName']) ?? '',
    );
  }

  static String encodeList(List<Account> l) =>
      jsonEncode([for (final a in l) a.toJson()]);

  static List<Account> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      return asList(jsonDecode(s))
          .map(Account.fromJson)
          .where((a) => a.id.isNotEmpty && (a.key.isNotEmpty || a.isBrowser))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

/// Normalises what the user typed. Returns null when it is not an https URL.
String? normalizeApiBase(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || !u.host.contains('.')) return null;
  if (u.scheme != 'https') return null;
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return 'https://${u.authority}$path';
}

class QrPayload {
  const QrPayload(this.apiBase, this.key);
  final String apiBase;
  final String key;
}

QrPayload? parseQrPayload(String raw) {
  try {
    final m = asMap(jsonDecode(raw));
    final base = asStr(m['apiBase']);
    final key = asStr(m['key']);
    if (base == null || key == null || key.trim().isEmpty) return null;
    final n = normalizeApiBase(base);
    if (n == null) return null;
    return QrPayload(n, key.trim());
  } catch (_) {
    return null;
  }
}
