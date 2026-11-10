/// Web 端没有系统相册可备份（备份入口只在 App 里出现），保留一份内存实现，
/// 保证条件导入在 Web 构建时也能编译通过。
bool get persistent => false;

final Map<String, String> _files = <String, String>{};

Future<String?> readText(String name) async => _files[name];

Future<void> writeText(String name, String content) async {
  _files[name] = content;
}

Future<void> appendLine(String name, String line) async {
  _files[name] = '${_files[name] ?? ''}$line\n';
}
