/// 非 Web 端没有 window.open：文稿弹窗里把链接做成可选中文本让用户复制。
bool get canOpenExternalLinks => false;

bool openExternalLink(String url) => false;
