import '../core/api/api_client.dart';
import '../l10n/app_localizations.dart';

String errorText(AppLocalizations l, Object e) {
  if (e is NetworkException) return l.errNetwork;
  if (e is ApiException) {
    if (e.status == 403) return l.error403;
    if (e.status == 404) return l.error404;
  }
  return l.genericError;
}

bool isUnauthorized(Object e) => e is ApiException && e.status == 401;
