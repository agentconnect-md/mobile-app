import 'dart:convert';

import '../api/models.dart';
import 'oauth_session.dart';

/// One signed-in organization on one server. Identified by server + org, so
/// adding another organization never overwrites this one. Tokens live in the
/// Keychain under [id]; this record holds nothing secret.
class Account {
  const Account({
    required this.id,
    required this.apiBase,
    required this.auth,
    required this.orgId,
    required this.orgName,
    required this.userId,
    required this.userName,
  });
  final String id;
  final String apiBase;
  final AuthInfo auth;
  final String orgId;
  final String orgName;
  final String userId;
  final String userName;

  bool sameOrg(String base, String org) => apiBase == base && orgId == org;

  Map<String, dynamic> toJson() => {
    'id': id,
    'apiBase': apiBase,
    'auth': auth.toJson(),
    'orgId': orgId,
    'orgName': orgName,
    'userId': userId,
    'userName': userName,
  };

  static Account? fromJson(dynamic j) {
    final m = asMap(j);
    final auth = AuthInfo.fromJson(m['auth']);
    final id = asStr(m['id']);
    final base = asStr(m['apiBase']);
    final org = asStr(m['orgId']);
    if (auth == null || id == null || base == null || org == null) return null;
    return Account(
      id: id,
      apiBase: base,
      auth: auth,
      orgId: org,
      orgName: asStr(m['orgName']) ?? '',
      userId: asStr(m['userId']) ?? '',
      userName: asStr(m['userName']) ?? '',
    );
  }

  static String encodeList(List<Account> l) =>
      jsonEncode([for (final a in l) a.toJson()]);

  /// Accounts from older versions (API key sign-in) have no `auth` and are dropped.
  static List<Account> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      return asList(jsonDecode(s))
          .map(Account.fromJson)
          .whereType<Account>()
          .toList();
    } catch (_) {
      return [];
    }
  }
}

/// Normalises a typed server address to an API base. Accepts the address with
/// or without `/v1` (a bare host gets `/v1`). Null unless https.
String? normalizeApiBase(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || !u.host.contains('.')) return null;
  if (u.scheme != 'https' || u.hasQuery || u.hasFragment) return null;
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) path = '/v1';
  return 'https://${u.authority}$path';
}
