import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// 帮助中心：把「常用操作 + 故障排查」集中到一处。
///
/// 内容刻意只讲**这个实现里真实存在的行为**（Web 强制 H.264、扫描是后台任务、
/// 内嵌字幕可播、文件回收站等），不写不存在的功能。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = <(String, String)>[
      (tr('help.start.title'), tr('help.start.body')),
      (tr('help.video.title'), tr('help.video.body')),
      (tr('help.music.title'), tr('help.music.body')),
      (tr('help.photo.title'), tr('help.photo.body')),
      (tr('help.book.title'), tr('help.book.body')),
      (tr('help.files.title'), tr('help.files.body')),
      (tr('help.trouble.title'), tr('help.trouble.body')),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('help.title'))),
      body: ListView(
        padding: const EdgeInsets.all(NasTokens.spaceLg),
        children: [
          Text(
            tr('help.subtitle'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceLg),
          for (final s in sections)
            Card(
              margin: const EdgeInsets.only(bottom: NasTokens.spaceSm),
              child: ExpansionTile(
                title: Text(s.$1),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.$2,
                    style: const TextStyle(height: 1.5),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
