// Scans a topic invite's QR code (uconn://<topic>#<key>) with the camera, or
// reads one from a picture, and hands the link back to whoever opened the
// page. A code that is not an invite is reported and scanning goes on.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../uconnect/uconnect.dart';
import 'theme.dart';

/// Opens the scanner and returns the invite link it read, or null when the
/// user backs out.
Future<String?> scanInviteLink(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => const ScanPage(),
        fullscreenDialog: true,
      ),
    );

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  String _hint = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The first invite link among the codes, if any.
  static String? _invite(BarcodeCapture capture) {
    for (final code in capture.barcodes) {
      final text = (code.rawValue ?? code.displayValue ?? '').trim();
      if (TopicCreds.parse(text) != null) return text;
    }
    return null;
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final link = _invite(capture);
    if (link == null) {
      if (capture.barcodes.isNotEmpty) {
        setState(() => _hint = 'That code is not a uConnect invite.');
      }
      return;
    }
    _done = true;
    Navigator.of(context).pop(link);
  }

  Future<void> _fromPicture() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    try {
      final capture = await _controller.analyzeImage(path);
      if (!mounted) return;
      final link = capture == null ? null : _invite(capture);
      if (link != null) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
      setState(() => _hint = capture == null || capture.barcodes.isEmpty
          ? 'No QR code in that picture.'
          : 'That code is not a uConnect invite.');
    } on Exception {
      if (mounted) setState(() => _hint = 'Could not read that picture.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan invite'),
        actions: [
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, state, _) {
              final torch = state.torchState;
              if (torch == TorchState.unavailable) return const SizedBox();
              return IconButton(
                icon: Icon(torch == TorchState.on
                    ? Icons.flashlight_on
                    : Icons.flashlight_off),
                tooltip: torch == TorchState.on ? 'Light off' : 'Light on',
                onPressed: _controller.toggleTorch,
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            tooltip: 'Other camera',
            onPressed: _controller.switchCamera,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _Problem(error: error),
          ),
          // A frame to aim with; the whole picture is scanned.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _hint.isEmpty
                          ? 'Point the camera at the QR code another '
                              'uConnect device shows for its topic.'
                          : _hint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _hint.isEmpty ? Colors.white : UcColors.error,
                        shadows: const [Shadow(blurRadius: 6)],
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                      icon: const Icon(Icons.image, size: 18),
                      label: const Text('From a picture'),
                      onPressed: _fromPicture,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The camera cannot be used: say why, and still offer a picture.
class _Problem extends StatelessWidget {
  const _Problem({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final text = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'uConnect needs the camera to scan a code. Allow it in the system '
            'settings, or read the code from a picture.',
      MobileScannerErrorCode.unsupported =>
        'This device has no camera to scan with. Read the code from a '
            'picture instead.',
      _ => 'The camera could not be opened'
          '${error.errorDetails?.message == null ? '.' : ': ${error.errorDetails!.message}'}',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
