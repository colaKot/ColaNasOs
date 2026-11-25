import 'package:flutter/material.dart';

import '../../shell/app_nav_shell.dart';
import 'ai_news_page.dart';
import 'blog_collections_page.dart';
import 'blog_local_page.dart';

/// 播客：左侧二级导航 + 内容区。
///
///   AI 新闻（每天定时生成一期，可试听音色、调倍速、填 API Key）
///   本地博客（目录源 + 多层目录浏览，只收音频）
///   博客合集（把本地音频整理成可排序的播放合集）
///
/// 三个入口都是独立页面：不做页内 Tab 切换，侧栏就是唯一的层级。
class BlogShellPage extends StatefulWidget {
  const BlogShellPage({super.key});

  @override
  State<BlogShellPage> createState() => _BlogShellPageState();
}

class _BlogShellPageState extends State<BlogShellPage> {
  Widget _content(String key) {
    switch (key) {
      case 'aiNews':
        return const AiNewsPage();
      case 'localBlog':
        return const LocalBlogPage();
      case 'blogCollections':
        return const BlogCollectionsPage();
      // nav-default: aiNews
      default:
        return const AiNewsPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(appId: 'blog', defaultKey: 'aiNews', content: _content);
  }
}
