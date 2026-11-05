import 'package:flutter/material.dart';

import '../../shell/app_nav_shell.dart';
import 'book_cache_page.dart';
import 'book_collections_page.dart';
import 'book_folder_page.dart';
import 'book_history_page.dart';
import 'book_lists_page.dart';
import 'book_shelf_page.dart';
import 'book_source_page.dart';

/// 书房：左侧二级导航 + 内容区。
///
///   藏书（书籍 / 漫画 / 收藏 / 阅读历史 / 文件视图）
///   书单（我的书单 / 合集）
///   设置（书库来源 / 缓存下载）
class BookShellPage extends StatefulWidget {
  const BookShellPage({super.key});

  @override
  State<BookShellPage> createState() => _BookShellPageState();
}

class _BookShellPageState extends State<BookShellPage> {
  Widget _content(String key) {
    switch (key) {
      case 'books':
        return const BookShelfPage(type: 'book');
      case 'comics':
        return const BookShelfPage(type: 'comic');
      case 'favorites':
        return const BookShelfPage(favoriteOnly: true, type: null);
      case 'history':
        return const BookHistoryPage();
      case 'files':
        return const BookFolderPage();
      case 'lists':
        return const BookListsPage();
      case 'collections':
        return const BookCollectionsPage();
      case 'settings.source':
        return const BookSourcePage();
      case 'settings.cache':
        return const BookCachePage();
      // nav-default: books
      default:
        return const BookShelfPage(type: 'book');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppNavShell(appId: 'book', defaultKey: 'books', content: _content);
  }
}
