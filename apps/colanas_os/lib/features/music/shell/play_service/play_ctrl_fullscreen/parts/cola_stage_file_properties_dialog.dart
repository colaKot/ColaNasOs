import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../compat/cola_api_controller.dart';
import '../../../compat/getx.dart';
import '../../../compat/host.dart';

/// 文件属性弹窗：读取服务端 attributes 接口后按「位置 / 名称 / 大小 / 时间」展示。
class ColaMusicStageFileInfo {
  const ColaMusicStageFileInfo._();

  static Future<void> show({
    required BuildContext context,
    required String filePath,
  }) async {
    if (filePath.trim().isEmpty) return;

    Map<String, dynamic>? data;
    try {
      data = await _fetchAttributes(filePath);
    } catch (_) {
      data = null;
    }
    if (data == null) {
      DialogUtil.showInfoDialog(
        title: 'error'.tr,
        content: 'get_file_property_failed'.tr,
      );
      return;
    }
    if (!context.mounted) return;
    final info = data;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => DialogUtil.createAlertDialog(
        title: Text('property'.tr),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _row('location'.tr, info['path']?.toString() ?? ''),
              _row('file_name'.tr, info['name']?.toString() ?? ''),
              _row(
                'total_size'.tr,
                FileUtil.formatSize((info['size'] as num?)?.toInt() ?? 0),
              ),
              _row('create_time'.tr, _stampText(info['birthtime'])),
              _row('modified_at'.tr, _stampText(info['mtime'])),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('confirm'.tr),
          ),
        ],
      ),
    );
  }

  static Future<Map<String, dynamic>?> _fetchAttributes(String filePath) async {
    final token = ApiController.instance.accessToken;
    final baseUrl = ApiController.instance.baseUrl;
    final reply = await HttpUtil.get(
      '$baseUrl/api/file/attributes?path=${Uri.encodeComponent(filePath)}',
      headers: token != null ? {'Authorization': 'Bearer $token'} : null,
    );
    if (!reply.isOk) return null;
    return reply.json?['data'] as Map<String, dynamic>?;
  }

  /// 毫秒时间戳 → `yyyy-MM-dd HH:mm:ss`，缺字段时留空。
  static String _stampText(Object? raw) {
    if (raw is! num) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(time);
  }

  static Widget _row(String label, String value) {
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
