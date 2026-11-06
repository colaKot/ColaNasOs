import 'package:flutter/material.dart';

import '../../shell/app_nav_shell.dart';
import 'ai_news_page.dart';

/// 博客：左侧二级导航 + 内容区。
///
///   AI 新闻（每天定时生成一期，可试听音色、调倍速、填 API Key）
///
/// 菜单只有一项，但**仍然走 AppNavShell**：一级入口点进来要有「侧栏 + 标题」的统一骨架，
/// 以后加「收藏 / 合集 / 文稿」时只改契约，不用重写页面结构。
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
