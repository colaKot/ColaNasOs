import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../backup_page.dart';
import 'photo_backup_status.dart';

/// 「手机备份」大横条：工作台顶部与相册独立端「更多」页共用同一个入口。
///
/// 进度直接读进程级状态源，不自己建控制器：用户从备份页切回来、甚至 App
/// 最小化后再回来，横条都还显示同一轮的百分比，不会「从头开始」。
class PhotoBackupBanner extends StatelessWidget {
  const PhotoBackupBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BackupStatusSnapshot>(
      valueListenable: PhotoBackupStatus.instance,
      builder: (context, s, _) {
        final scheme = Theme.of(context).colorScheme;
        final running = s.running;
        final paused = s.waitingWifi;
        final showBar = running || paused;
        final title = running
            ? tr('home.backup.running')
            : tr('home.backup.title');
        final String hint;
        if (running && s.total > 0) {
          hint = tr('home.backup.progress', <String, Object>{
            'done': '${s.done}',
            'total': '${s.total}',
          });
        } else if (running) {
          hint = tr('home.backup.scanning');
        } else if (paused) {
          hint = tr('home.backup.waitingWifi');
        } else if (s.lastFinishedAtMs > 0) {
          hint = tr('home.backup.lastDone', <String, Object>{
            'count': '${s.lastUploaded}',
            'time': _shortTime(s.lastFinishedAtMs),
          });
        } else {
          hint = tr('home.backup.hint');
        }
        return InkWell(
          borderRadius: BorderRadius.circular(NasTokens.radiusMd),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PhotoBackupPage()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: NasTokens.spaceMd,
              vertical: NasTokens.spaceMd,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primary, const Color(0xFF8B5CF6)],
              ),
              borderRadius: BorderRadius.circular(NasTokens.radiusMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.cloud_upload_outlined,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: NasTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: NasTokens.fontBody,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontSize: NasTokens.fontMicro,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (showBar && s.progress != null)
                      Text(
                        '${s.percent}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      )
                    else if (showBar)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    else
                      const Icon(Icons.chevron_right, color: Colors.white),
                  ],
                ),
                if (showBar) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: s.progress,
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.28),
                      color: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _shortTime(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
