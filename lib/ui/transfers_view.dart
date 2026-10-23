// Running and finished transfers, with cancel, share and clear -- the mobile
// TransfersPopup.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_state.dart';
import '../core/session.dart';
import '../core/storage/storage_client.dart';
import 'theme.dart';

class TransfersView extends StatelessWidget {
  const TransfersView({required this.state, super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final transfers = state.storageClient.transfers.reversed.toList();
    if (transfers.isEmpty) {
      return Center(
        child: Text('No transfers yet.',
            style: TextStyle(color: UcColors.textSecondary)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: transfers.length,
            itemBuilder: (context, i) => _tile(context, transfers[i]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: state.storageClient.clearFinishedTransfers,
                  child: const Text('Clear finished'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, Transfer t) {
    final peer = state.session.peers[t.dev];
    final devName = peer?.displayName ?? shortId(t.dev);
    final progress =
        t.total > 0 ? (t.done / t.total).clamp(0.0, 1.0) : null;
    final subtitle = switch (t.state) {
      TransferState.queued => 'queued',
      TransferState.running =>
        '${_bytes(t.done)}${t.total > 0 ? ' of ${_bytes(t.total)}' : ''}',
      TransferState.done => 'done · ${_bytes(t.total)}',
      TransferState.failed => t.error,
      TransferState.cancelled => 'cancelled',
    };
    return Card(
      child: ListTile(
        leading: Icon(
          t.kind == TransferKind.download
              ? Icons.download_outlined
              : Icons.upload_outlined,
          color: switch (t.state) {
            TransferState.done => UcColors.success,
            TransferState.failed => UcColors.error,
            _ => UcColors.textSecondary,
          },
        ),
        title: Text(
          t.remotePath.split('/').last,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${t.kind == TransferKind.download ? 'from' : 'to'} $devName · $subtitle',
              style: TextStyle(
                  fontSize: 12, color: UcColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
            if (t.state == TransferState.running) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                  value: progress, backgroundColor: UcColors.border),
            ],
          ],
        ),
        trailing: switch (t.state) {
          TransferState.running || TransferState.queued => IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Cancel',
              onPressed: () => t.kind == TransferKind.download
                  ? state.storageClient.cancelDownload(t)
                  : state.storageClient.cancelUpload(t),
            ),
          TransferState.done when t.kind == TransferKind.download => IconButton(
              icon: const Icon(Icons.ios_share, size: 20),
              tooltip: 'Share / open',
              onPressed: () async {
                if (await File(t.localPath).exists()) {
                  await SharePlus.instance
                      .share(ShareParams(files: [XFile(t.localPath)]));
                }
              },
            ),
          _ => null,
        },
      ),
    );
  }

  String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
