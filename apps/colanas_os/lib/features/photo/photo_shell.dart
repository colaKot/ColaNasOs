import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_visibility.dart';
import '../../shell/app_nav_shell.dart';
import 'backup_page.dart';
import 'cleanup_page.dart';
import 'footprint_map_page.dart';
import 'memory_page.dart';
import 'photo_page.dart';
import 'photo_on_this_day_page.dart';
import 'photo_ai_settings_page.dart';
import 'photo_ai_center_page.dart';
import 'photo_collection_page.dart';
import 'photo_folders_page.dart';
import 'photo_home_page.dart';
import 'photo_face_relations_page.dart';
import 'photo_models_page.dart';
import 'photo_preview_settings_page.dart';
import 'photo_geo_page.dart';

import 'photo_source_page.dart';
import 'photo_timeline_tab.dart';
import 'photo_trash_page.dart';
import 'smart_page.dart';

/// 相册主页：左侧二级导航 + 右侧内容区。
///
/// 分组顺序与参考实现一致：照片 / 回忆 / 相册 / AI / 设置。
/// 导航本身由 [AppNavShell] 统一实现，菜单内容来自 `contracts/apps.json#nav`；
/// 这里只剩「菜单项 id → 页面」。
class PhotoShellPage extends StatefulWidget {
  const PhotoShellPage({super.key});

  @override
  State<PhotoShellPage> createState() => _PhotoShellPageState();
}

class _PhotoShellPageState extends State<PhotoShellPage> {
  /// 相册首页的卡片要能跳到别的菜单项（如「回忆」「人物」），走外部选中项
  final NavSelection _selection = NavSelection('home');

  Widget _content(String key) {
    // 契约里没有、但页面已实现的入口：onThisDay（往年今日）/ backup（相册备份）/
    // models（AI 模型管理）。页面都在（194 / 258 / 132 行），是否恢复成菜单项待定，
    // 先在这里登记，避免被当成死代码删掉（`app-nav.check` 的 nav-orphan 白名单）。
    // nav-orphan: onThisDay, models
    switch (key) {
      case 'home':
        return PhotoHomePage(embedded: true, onNavigate: _selection.select);
      case 'timeline':
        // 手机端这一个 tab 里还有「全部 / 年份 / 今天 / 收藏」四种看法（浮动胶囊），
        // 桌面端 PhotoTimelineTab 会直接退回 PhotoPage，形态不变。
        return const PhotoTimelineTab();
      case 'onThisDay':
        return const PhotoOnThisDayPage(embedded: true);
      case 'photoAiCenter':
        return PhotoAiCenterPage(onNavigate: _selection.select);
      case 'favorites':
        return const PhotoPage(favoriteOnly: true);
      case 'album':
        return const PhotoPage(view: PhotoPageView.album);
      case 'footprint':
        return const FootprintMapPage(embedded: true);
      case 'memory':
        return const PhotoMemoryPage(embedded: true);
      case 'dayFrame':
        return const PhotoDayFramePage(embedded: true);
      case 'tickets':
        return const PhotoTicketsPage(embedded: true);
      case 'year':
        return const PhotoAnnualPage(embedded: true);
      case 'smartRules':
        return const PhotoSmartPage(embedded: true, section: 'rules');
      case 'activities':
        return const PhotoSmartPage(embedded: true, section: 'activities');
      case 'search':
        return const PhotoSmartPage(embedded: true, section: 'search');
      case 'faces':
        return const PhotoSmartPage(embedded: true, section: 'faces');
      case 'relations':
        return const PhotoFaceRelationsPage(embedded: true);
      case 'scenes':
        return const PhotoSmartPage(embedded: true, section: 'scenes');
      case 'cleanup':
        return const PhotoCleanupPage(embedded: true);
      case 'backup':
        return const PhotoBackupPage(embedded: true);
      case 'trash':
        return const PhotoTrashPage();
      case 'source':
        return const PhotoSourcePage();
      case 'collection':
        return const PhotoCollectionPage();
      case 'gps':
        return const PhotoGeoPage();
      case 'folders':
        return const PhotoFoldersPage();
      case 'preview':
        return const PhotoPreviewSettingsPage();
      case 'aiSettings':
        return const PhotoAiSettingsPage();
      case 'models':
        return const PhotoModelsPage();
      default:
        return const _PendingPane();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(
      appId: 'photo',
      defaultKey: 'home',
      selection: _selection,
      // 「相册备份」只在手机 App 出现（契约里该项 `when: mobileApp`）：
      // 它要读本机相册权限，web / 桌面没有这个东西
      conditions: {if (isMobileApp()) 'mobileApp'},
      content: _content,
    );
  }
}

class _PendingPane extends StatelessWidget {
  const _PendingPane();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.construction_outlined,
            size: 40,
            color: context.nasTextSecondary,
          ),
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            tr('common.pending'),
            style: TextStyle(
              fontSize: NasTokens.fontSubtitle,
              color: context.nasTextSecondary,
            ),
          ),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            tr('common.pendingHint'),
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
