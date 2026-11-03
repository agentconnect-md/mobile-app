import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';

/// Pops with the scanned text, or [cameraDenied].
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});
  static const cameraDenied = '__camera_denied__';
  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.scanQr)),
      body: MobileScanner(
        controller: _controller,
        onDetect: (cap) {
          if (_done) return;
          final v = cap.barcodes.map((b) => b.rawValue).whereType<String>();
          if (v.isEmpty) return;
          _done = true;
          Navigator.of(context).pop(v.first);
        },
        errorBuilder: (context, error) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_done) {
              _done = true;
              Navigator.of(context).pop(QrScanScreen.cameraDenied);
            }
          });
          return Center(
              child: Text(l.errCamera, style: TextStyle(color: context.pal.secondary)));
        },
      ),
    );
  }
}
