import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// Web 端占位页：浏览器没有系统相册可读，备份只能在手机 App 里跑。
///
/// 保留同名同构造参数，首页横条与相册二级导航不需要写 `kIsWeb` 分支。
class PhotoBackupPage extends StatelessWidget {
  const PhotoBackupPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: Padding(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(NasTokens.spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.photo_camera_back_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: NasTokens.spaceMd),
                Text(
                  tr('photo.backup.title'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: NasTokens.spaceSm),
                Text(
                  tr('photo.backup.webHint'),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (embedded) return content;
    return Scaffold(
      appBar: AppBar(title: Text(tr('photo.backup.title'))),
      body: content,
    );
  }
}
