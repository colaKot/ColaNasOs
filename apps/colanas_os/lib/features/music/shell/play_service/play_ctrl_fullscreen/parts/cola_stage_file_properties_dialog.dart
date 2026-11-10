import 'package:flutter/material.dart';

import '../../../compat/getx.dart';

import 'package:intl/intl.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/host.dart';

class MusicPlayCtrlFullScreenFilePropertiesDialog {
  static Future<void> show({
    required BuildContext context,
    required String filePath,
  }) async {
    if (filePath.trim().isEmpty) return;
    try {
      final localData = await _getFileProperties(filePath);
      if (localData != null) {
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (ctx) {
            return DialogUtil.createAlertDialog(
              title: Text('property'.tr),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildPropertyRow(
                      'location'.tr,
                      localData['path']?.toString() ?? '',
                    ),
                    _buildPropertyRow(
                      'file_name'.tr,
                      localData['name']?.toString() ?? '',
                    ),
                    _buildPropertyRow(
                      'total_size'.tr,
                      FileUtil.formatSize(
                        (localData['size'] as num?)?.toInt() ?? 0,
                      ),
                    ),
                    _buildPropertyRow(
                      'create_time'.tr,
                      localData['birthtime'] != null
                          ? _formatDateTime(
                              (localData['birthtime'] as num).toInt(),
                            )
                          : '',
                    ),
                    _buildPropertyRow(
                      'modified_at'.tr,
                      localData['mtime'] != null
                          ? _formatDateTime((localData['mtime'] as num).toInt())
                          : '',
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('confirm'.tr),
                ),
              ],
            );
          },
        );
        return;
      }
    } catch (_) {}

    DialogUtil.showInfoDialog(
      title: 'error'.tr,
      content: 'get_file_property_failed'.tr,
    );
  }

  static Future<Map<String, dynamic>?> _getFileProperties(
    String filePath,
  ) async {
    try {
      final localToken = ApiController.instance.accessToken;
      final localBaseUrl = ApiController.instance.baseUrl;
      final localReply = await HttpUtil.get(
        '$localBaseUrl/api/file/attributes?path=${Uri.encodeComponent(filePath)}',
        headers: localToken != null
            ? {'Authorization': 'Bearer $localToken'}
            : null,
      );
      if (localReply.isOk && localReply.json != null) {
        return localReply.json!['data'] as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static String _formatDateTime(int timestampMs) {
    final localFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    return localFormat.format(DateTime.fromMillisecondsSinceEpoch(timestampMs));
  }

  static Widget _buildPropertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 80.0,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
