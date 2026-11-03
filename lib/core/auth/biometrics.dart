import 'package:local_auth/local_auth.dart';

/// Face ID / passcode confirmation, used before "always allow" only.
class Biometrics {
  final _auth = LocalAuthentication();

  Future<bool> confirm(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
      );
    } catch (_) {
      return false;
    }
  }
}
