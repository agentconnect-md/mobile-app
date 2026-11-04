import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Raised when the network fails (no answer from the server).
class NetworkException implements Exception {}

class FetchResult {
  const FetchResult(
    this.status,
    this.body, {
    this.location,
    this.wwwAuthenticate,
  });
  final int status;
  final String body;

  /// `WWW-Authenticate` of a 401 (RFC 9728 §5.1 discovery).
  final String? wwwAuthenticate;

  /// `Location` of a redirect (redirects are never followed).
  final String? location;
}

/// One HTTP exchange for the sign-in protocol: GET (no body), form POST
/// ([form]) or JSON POST ([json]). Throws [NetworkException]. Never logs.
typedef Fetch = Future<FetchResult> Function(
  Uri url, {
  Map<String, String>? form,
  Object? json,
});

Future<FetchResult> defaultFetch(
  Uri url, {
  Map<String, String>? form,
  Object? json,
}) async {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'AgentConnect-iOS/1.0';
  try {
    final post = form != null || json != null;
    final req = post ? await http.postUrl(url) : await http.getUrl(url);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (form != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      req.add(utf8.encode(Uri(queryParameters: form).query));
    } else if (json != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(json)));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    return FetchResult(
      res.statusCode,
      text,
      location: res.headers.value(HttpHeaders.locationHeader),
      wwwAuthenticate: res.headers.value(HttpHeaders.wwwAuthenticateHeader),
    );
  } on SocketException {
    throw NetworkException();
  } on TimeoutException {
    throw NetworkException();
  } on TlsException {
    throw NetworkException();
  } on HttpException {
    throw NetworkException();
  } finally {
    http.close(force: true);
  }
}
