/// 音乐模块从宿主工程带过来的那批通用工具 / 组件的等价实现。
///
/// 参考项目把 toast、格式化、缓存、右键菜单、各种小控件散在 `utils/` 和
/// `modules/base/components/` 里，音乐模块用到其中 29 个文件。
/// 这里按**原签名**重写一份轻量版，让搬运过来的 80 个文件一行都不用改；
/// 实现上尽量贴本项目（Material 3 / 本地 Session / 无 P2P）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';

import '../../../../core/app_navigator.dart';

import '../../../../core/scan_refresh.dart';
// 只取函数，避开本文件里同名的 FolderPickerDialog 占位类
import '../../../photo/folder_picker.dart'
    show showFolderPicker, showFolderPickerMulti;
import 'dio_lite.dart' as dio_lite;
import 'download.dart';
import 'i18n_music.dart';

/// 让 `import compat/host.dart` 的地方也能拿到资源服务（唯一定义在
/// `local_web_asset_server.dart`，避免两处同名冲突）。
export 'local_web_asset_server.dart';

/// 订阅「音乐库扫描完成」（服务端 `scan.done`，domain=music）。
///
/// 扫描是服务端后台任务（可能跑几分钟），跑完必须让页面自己重新拉列表，
/// 否则用户点完扫描切回曲目页看到的还是旧数据 —— 表现就是「点了没什么用」。
/// 返回的函数用于 `onClose` 里取消订阅。
void Function() listenMusicScanDone(void Function() onDone) =>
    listenScanDone('music', onDone);

// ============================================================ 格式化工具

class FormatUtil {
  const FormatUtil._();

  /// 秒（数字）或 Duration → `mm:ss` / `h:mm:ss`
  static String formatDuration(Object seconds, {bool autoPadZero = false}) {
    if (seconds is Duration) {
      return formatDurationSeconds(seconds.inSeconds, autoPadZero: autoPadZero);
    }
    final n = seconds is num ? seconds : 0;
    final total = n.isFinite ? n.round() : 0;
    return formatDurationSeconds(
      total < 0 ? 0 : total,
      autoPadZero: autoPadZero,
    );
  }

  static String formatDurationSeconds(int seconds, {bool autoPadZero = false}) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// `Duration` → `mm:ss`
  static String formatDurationOf(Duration d) =>
      formatDurationSeconds(d.inSeconds);
}

class FileUtil {
  const FileUtil._();

  static String formatSize(num bytes) {
    if (bytes <= 0) return '0 B';
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
  }
}

// ============================================================ Toast

class ToastUtil {
  const ToastUtil._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = _overlay;
    if (overlay == null) return;
    _dismiss();
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 96,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(duration, _dismiss);
  }

  static OverlayState? get _overlay {
    final ctx = kHostNavigatorKey.currentContext;
    return ctx == null ? null : Overlay.maybeOf(ctx);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

/// 全局导航 key：与 `core/app_navigator.dart` 是**同一个对象**，
/// 由 `ColaNasApp` 的 MaterialApp 持有，供无 context 的 controller 弹对话框 / toast。
final GlobalKey<NavigatorState> kHostNavigatorKey = kAppNavigatorKey;

// ============================================================ 本地缓存

/// 轻量键值缓存：参考项目用它记住排序字段这类 UI 状态。
///
/// 本项目不引 shared_preferences（避免多一个原生依赖），进程内记住即可 ——
/// 这类纯 UI 偏好丢了无感，重启回到默认排序。
class CacheManager {
  CacheManager._();
  static final CacheManager _i = CacheManager._();
  factory CacheManager() => _i;

  final Map<String, String> _memory = <String, String>{};

  String? getString(String key) => _memory[key];

  Future<void> setString(String key, String value) async {
    _memory[key] = value;
  }

  bool? getBool(String key) {
    final raw = _memory[key];
    if (raw == null) return null;
    return raw == 'true';
  }

  Future<void> setBool(String key, bool value) async {
    _memory[key] = value.toString();
  }

  int? getInt(String key) => int.tryParse(_memory[key] ?? '');

  Future<void> setInt(String key, int value) async {
    _memory[key] = value.toString();
  }

  double? getDouble(String key) => double.tryParse(_memory[key] ?? '');

  Future<void> setDouble(String key, double value) async {
    _memory[key] = value.toString();
  }

  List<String>? getStringList(String key) {
    final decoded = getJson(key);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList(growable: false);
    }
    return null;
  }

  Future<void> setStringList(String key, List<String> value) =>
      setJson(key, value);

  /// 结构化值：内部按 JSON 字符串存
  dynamic getJson(String key) {
    final raw = _memory[key];
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> setJson(String key, Object? value) async {
    try {
      _memory[key] = jsonEncode(value);
    } catch (_) {
      // 不可序列化的对象直接忽略，别让 UI 因为一个缓存写崩掉
    }
  }

  void remove(String key) => _memory.remove(key);
}

// ============================================================ 对话框

class DialogUtil {
  const DialogUtil._();

  static BuildContext? get _ctx => kHostNavigatorKey.currentContext;

  /// 组装一个标准弹窗（调用方直接 `return DialogUtil.createAlertDialog(...)`）
  static AlertDialog createAlertDialog({
    required Widget title,
    required Widget content,
    List<Widget>? actions,
    bool barrierDismissible = true,
    BoxConstraints? constraints,
  }) => AlertDialog(
    title: title,
    content: content,
    actions: actions,
    scrollable: true,
    constraints: constraints,
  );

  static Future<void> showInfoDialog({
    required String title,
    required String content,
    String? buttonText,
  }) => _simple(title, content, buttonText: buttonText);

  static Future<void> showErrorDialog({
    required String title,
    String? message,
  }) => _simple(title, message ?? '');

  static Future<bool> showConfirmDialog({
    required String title,
    required String content,
    String confirmText = '确定',
    String cancelText = '取消',
    VoidCallback? onConfirm,
  }) async {
    final ctx = _ctx;
    if (ctx == null) return false;
    final r = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(cancelText),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    if (r == true) onConfirm?.call();
    return r == true;
  }

  static Future<void> _simple(
    String title,
    String content, {
    String? buttonText,
  }) async {
    final ctx = _ctx;
    if (ctx == null) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: content.isEmpty ? null : Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: Text(buttonText ?? '确定'),
          ),
        ],
      ),
    );
  }

  static void showLoading({String? message, String? title}) {
    final ctx = _ctx;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(message ?? '加载中…'),
            ],
          ),
        ),
      ),
    );
  }

  static void dismissLoading() {
    final nav = kHostNavigatorKey.currentState;
    if (nav != null && nav.canPop()) nav.pop();
  }
}

// ============================================================ 锚点菜单

class PopupMenuUtil {
  const PopupMenuUtil._();

  /// 在某个 widget 下方弹出菜单（参考实现同名方法的等价版）
  static Future<T?> showBelowButton<T>({
    required BuildContext context,
    required GlobalKey buttonKey,
    required List<PopupMenuEntry<T>> items,
    T? initialValue,
  }) async {
    final box = buttonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    RelativeRect position = const RelativeRect.fromLTRB(80, 120, 0, 0);
    if (box != null && overlay != null && box.hasSize) {
      position = RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      );
    }
    return showMenu<T>(
      context: context,
      position: position,
      items: items,
      initialValue: initialValue,
    );
  }
}

// ============================================================ 右键菜单

/// 参考项目的 `CustomContextMenuItem.create(...)`。
///
/// 注意：这里**不能**定义一个新的 entry 类型 —— 调用方文件同时 import
/// `package:flutter_context_menu`，列表字面量的推断类型是 `ContextMenuEntry`，
/// 自定义类塞不进去。所以直接映射到那个包的 [MenuItem]，返回类型就是 entry。
class CustomContextMenuItem {
  const CustomContextMenuItem._();

  static MenuItem<T> create<T>({
    required Widget label,
    Widget? icon,
    required T value,
    ValueChanged<T?>? onSelected,
    bool enabled = true,
    Color? textColor,
    Color? color,
    BoxConstraints? constraints,
    Widget? trailing,
  }) => MenuItem<T>(
    label: label,
    icon: icon,
    value: value,
    onSelected: onSelected,
    enabled: enabled,
    textColor: textColor ?? color,
    constraints: constraints,
    trailing: trailing,
  );
}

class ContextMenuUtil {
  const ContextMenuUtil._();

  /// 包一层右键菜单：桌面/Web 才生效
  static Widget region({
    required Widget child,
    required List<ContextMenuEntry<dynamic>> entries,
  }) => _RegionMenu(child: child, entries: entries);

  static Future<void> showAtPosition(
    BuildContext context, {
    required Offset position,
    required List<ContextMenuEntry<dynamic>> entries,
  }) async {
    final items = <PopupMenuEntry<int>>[];
    final entryList = <ContextMenuEntry<dynamic>>[];
    for (final e in entries) {
      if (e is MenuItem) {
        entryList.add(e);
        items.add(
          PopupMenuItem<int>(
            value: entryList.length - 1,
            enabled: e.enabled,
            child: Row(
              children: [
                if (e.icon != null) ...[e.icon!, const SizedBox(width: 8)],
                e.label,
              ],
            ),
          ),
        );
      } else if (e is MenuDivider) {
        items.add(const PopupMenuDivider());
      }
    }
    if (items.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (picked == null) return;
    final entry = entryList[picked];
    if (entry is MenuItem) {
      entry.onSelected?.call(entry.value);
    }
  }
}

class _RegionMenu extends StatelessWidget {
  const _RegionMenu({required this.child, required this.entries});

  final Widget child;
  final List<ContextMenuEntry<dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (d) => ContextMenuUtil.showAtPosition(
        context,
        position: d.globalPosition,
        entries: entries,
      ),
      child: child,
    );
  }
}

// ============================================================ 小控件

/// 圆形/方形复选框（参考实现支持 tristate 等一长串参数，这里只保留用到的）
class CustomCheckbox extends StatelessWidget {
  const CustomCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.isCircle = true,
    this.checkColor,
    this.side,
    this.visualDensity,
    this.materialTapTargetSize,
    this.autofocus = false,
    this.focusNode,
    this.shape,
    this.fillColor,
    this.splashRadius,
    this.mouseCursor,
    this.tristate = false,
  });

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color? activeColor;
  final Color? checkColor;
  final Color? fillColor;
  final BorderSide? side;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final bool autofocus;
  final FocusNode? focusNode;
  final OutlinedBorder? shape;
  final double? splashRadius;
  final MouseCursor? mouseCursor;
  final bool tristate;
  final bool isCircle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = BorderSide(
      color: value ? (activeColor ?? scheme.primary) : scheme.outline,
      width: 1.4,
    );
    final box = Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: value
            ? (fillColor ?? activeColor ?? scheme.primary)
            : Colors.transparent,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isCircle ? null : BorderRadius.circular(3),
        border: Border.fromBorderSide(border),
      ),
      child: value
          ? Icon(Icons.check, size: 13, color: checkColor ?? Colors.white)
          : null,
    );
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(4),
      child: Padding(padding: const EdgeInsets.all(2), child: box),
    );
  }
}

/// 精简开关（参考实现是方角样式）
class CustomSwitch extends StatelessWidget {
  const CustomSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.materialTapTargetSize,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? activeTrackColor;
  final Color? inactiveThumbColor;
  final Color? inactiveTrackColor;
  final MaterialTapTargetSize? materialTapTargetSize;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: activeColor,
      activeTrackColor: activeTrackColor,
      inactiveThumbColor: inactiveThumbColor,
      inactiveTrackColor: inactiveTrackColor,
      materialTapTargetSize:
          materialTapTargetSize ?? MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 空数据占位
class CustomNoData extends StatelessWidget {
  const CustomNoData({
    super.key,
    this.text = '无数据',
    this.backgroundColor,
    this.imageWidth = 100,
    this.imageHeight = 100,
    this.imagePath = '',
    this.backgroundColorList = const [],
  });

  final String text;
  final Color? backgroundColor;
  final double imageWidth;
  final double imageHeight;
  final String imagePath;
  final List<Color?> backgroundColorList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_off_outlined,
              size: imageWidth * 0.5,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 10),
            Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 可展开搜索框（收起时是图标，点开变输入框）
class CustomExpandableSearchBar extends StatefulWidget {
  const CustomExpandableSearchBar({
    super.key,
    required this.hintText,
    this.onChanged,
    this.onClear,
    this.controller,
    this.height = 32,
    this.expandedWidth = 180,
    this.isPill = false,
    this.alignment = Alignment.centerRight,
    this.defaultExpanded = false,
    this.autoSearchOnChange = false,
    this.debounceDuration,
    this.onDebouncedChanged,
    this.onSubmitted,
  });

  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final TextEditingController? controller;
  final double height;
  final double expandedWidth;
  final bool isPill;
  final AlignmentGeometry alignment;
  final bool defaultExpanded;
  final bool autoSearchOnChange;
  final Duration? debounceDuration;
  final ValueChanged<String>? onDebouncedChanged;

  /// 回车 / 点右侧确认按钮时触发（立即搜索，不走 debounce）。
  /// 为 null 时不显示确认按钮，行为与以前一致。
  final ValueChanged<String>? onSubmitted;

  @override
  State<CustomExpandableSearchBar> createState() =>
      _CustomExpandableSearchBarState();
}

class _CustomExpandableSearchBarState extends State<CustomExpandableSearchBar> {
  late bool _expanded = widget.defaultExpanded;
  late final TextEditingController _c =
      widget.controller ?? TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    if (widget.controller == null) _c.dispose();
    super.dispose();
  }

  void _submit() => widget.onSubmitted?.call(_c.text);

  void _emit(String v) {
    widget.onChanged?.call(v);
    if (widget.onDebouncedChanged == null) return;
    _debounce?.cancel();
    _debounce = Timer(
      widget.debounceDuration ?? const Duration(milliseconds: 350),
      () => widget.onDebouncedChanged!(v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = widget.isPill
        ? BorderRadius.circular(widget.height / 2)
        : BorderRadius.circular(6);
    if (!_expanded) {
      return Align(
        alignment: widget.alignment,
        child: IconButton(
          icon: const Icon(Icons.search, size: 20),
          onPressed: () => setState(() => _expanded = true),
          visualDensity: VisualDensity.compact,
        ),
      );
    }
    return Align(
      alignment: widget.alignment,
      child: SizedBox(
        width: widget.expandedWidth,
        height: widget.height,
        child: TextField(
          controller: _c,
          autofocus: true,
          onChanged: _emit,
          textInputAction: TextInputAction.search,
          // 回车直接搜：以前这里没有 onSubmitted，按回车什么都不发生
          onSubmitted: (_) => _submit(),
          style: theme.textTheme.bodySmall,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hintText,
            hintStyle: theme.textTheme.bodySmall,
            prefixIcon: const Icon(Icons.search, size: 16),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 30,
              minHeight: 30,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide.none,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.onSubmitted != null)
                  IconButton(
                    tooltip: 'search'.tr,
                    icon: const Icon(Icons.arrow_forward, size: 15),
                    visualDensity: VisualDensity.compact,
                    onPressed: _submit,
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 15),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _c.clear();
                    widget.onClear?.call();
                    widget.onChanged?.call('');
                    setState(() => _expanded = false);
                  },
                ),
              ],
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 30,
              minHeight: 30,
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮放大效果容器
enum CustomHoverMenuTriggerMode {
  /// 鼠标悬停触发
  hover,

  /// 点击触发
  click,
}

/// 通用弹出菜单锚点（对齐参考项目 `modules/base/components/custom_hover_menu_anchor.dart`）。
/// 用 Material 3 的 [MenuAnchor] 实现，菜单内容由调用方给 [menuChildren]。
class CustomHoverMenuAnchor extends StatefulWidget {
  const CustomHoverMenuAnchor({
    super.key,
    required this.child,
    required this.menuChildren,
    this.alignmentOffset = const Offset(0, 6),
    this.menuRadius = 10.0,
    this.buttonRadius = 10.0,
    this.buttonPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 10,
    ),
    this.buttonMinimumHeight,
    this.triggerMode = CustomHoverMenuTriggerMode.click,
  });

  final Widget child;
  final List<Widget> menuChildren;
  final Offset alignmentOffset;
  final double menuRadius;
  final double buttonRadius;
  final EdgeInsetsGeometry buttonPadding;
  final double? buttonMinimumHeight;
  final CustomHoverMenuTriggerMode triggerMode;

  @override
  State<CustomHoverMenuAnchor> createState() => _CustomHoverMenuAnchorState();
}

class _CustomHoverMenuAnchorState extends State<CustomHoverMenuAnchor> {
  final MenuController _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final hover = widget.triggerMode == CustomHoverMenuTriggerMode.hover;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: widget.alignmentOffset,
      menuChildren: widget.menuChildren,
      builder: (context, controller, _) {
        final button = InkWell(
          borderRadius: BorderRadius.circular(widget.buttonRadius),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.buttonMinimumHeight ?? 0,
            ),
            child: Padding(padding: widget.buttonPadding, child: widget.child),
          ),
        );
        if (!hover) return button;
        return MouseRegion(
          onEnter: (_) => controller.open(),
          onExit: (_) => controller.close(),
          child: button,
        );
      },
    );
  }
}

enum CustomAlbumHeaderPosition { top, bottom }

/// 参考项目 `custom_letter_filter.dart` 的等价实现：右侧一列字母索引。
class CustomLetterFilter extends StatelessWidget {
  const CustomLetterFilter({
    super.key,
    this.letters = const <String>[
      '#',
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'I',
      'J',
      'K',
      'L',
      'M',
      'N',
      'O',
      'P',
      'Q',
      'R',
      'S',
      'T',
      'U',
      'V',
      'W',
      'X',
      'Y',
      'Z',
    ],
    this.value,
    this.initialValue,
    this.onChanged,
    this.width = 22,
    this.itemHeight = 16,
    this.borderRadius = 4,
    this.centerWhenBoundedHeight = false,
  });

  final List<String> letters;
  final String? value;
  final String? initialValue;
  final ValueChanged<String?>? onChanged;
  final double width;
  final double itemHeight;
  final double borderRadius;
  final bool centerWhenBoundedHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = (value ?? initialValue ?? '').toUpperCase();
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final l in letters)
          InkWell(
            borderRadius: BorderRadius.circular(borderRadius),
            onTap: () {
              // 再点一次同一个字母 = 取消筛选
              onChanged?.call(l == current ? null : l);
            },
            child: SizedBox(
              width: width,
              height: itemHeight,
              child: Center(
                child: Text(
                  l,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: l == current
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: l == current
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    if (!centerWhenBoundedHeight) return column;
    // 不能 return Center(...)：Center 会占满父级宽度再把字母列**水平居中**，
    // 手机端就变成「A-Z 索引浮在页面正中间」。这里要的是垂直居中 + 始终贴右。
    return Align(alignment: Alignment.centerRight, child: column);
  }
}

class CustomAlbum extends StatefulWidget {
  const CustomAlbum({
    super.key,
    required this.preview,
    this.onTap,
    this.headerLeft,
    this.headerRight,
    this.headerHeight = 55,
    this.headerPadding = const EdgeInsets.fromLTRB(10, 0, 2, 0),
    this.headerGradient,
    this.headerPosition = CustomAlbumHeaderPosition.top,
    this.overlayChildren = const [],
    this.hoverEnabled = true,
    this.hoverScale = 1.02,
    this.hoverDuration = const Duration(milliseconds: 160),
    this.hoverCurve = Curves.easeOut,
  });

  final Widget preview;
  final VoidCallback? onTap;
  final Widget? headerLeft;
  final Widget? headerRight;
  final double headerHeight;
  final EdgeInsetsGeometry headerPadding;
  final Gradient? headerGradient;
  final CustomAlbumHeaderPosition headerPosition;
  final List<Widget> overlayChildren;
  final bool hoverEnabled;
  final double hoverScale;
  final Duration hoverDuration;
  final Curve hoverCurve;

  @override
  State<CustomAlbum> createState() => _CustomAlbumState();
}

class _CustomAlbumState extends State<CustomAlbum> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    Widget stack = Stack(
      fit: StackFit.expand,
      children: [
        widget.preview,
        ...widget.overlayChildren,
        if (widget.headerLeft != null || widget.headerRight != null)
          Positioned(
            left: 0,
            right: 0,
            top: widget.headerPosition == CustomAlbumHeaderPosition.top
                ? 0
                : null,
            bottom: widget.headerPosition == CustomAlbumHeaderPosition.bottom
                ? 0
                : null,
            height: widget.headerHeight,
            child: Container(
              padding: widget.headerPadding,
              decoration: BoxDecoration(gradient: widget.headerGradient),
              child: Row(
                children: [
                  if (widget.headerLeft != null) widget.headerLeft!,
                  const Spacer(),
                  if (widget.headerRight != null) widget.headerRight!,
                ],
              ),
            ),
          ),
      ],
    );

    if (widget.hoverEnabled) {
      stack = AnimatedScale(
        scale: _hovering ? widget.hoverScale : 1.0,
        duration: widget.hoverDuration,
        curve: widget.hoverCurve,
        child: stack,
      );
    }

    return MouseRegion(
      onEnter: widget.hoverEnabled
          ? (_) => setState(() => _hovering = true)
          : null,
      onExit: widget.hoverEnabled
          ? (_) => setState(() => _hovering = false)
          : null,
      // behavior 必须显式写 opaque：GestureDetector 有 child 时默认 deferToChild，
      // 而这里的 child 链条最终落到 `Image`（RenderImage 的 hitTestSelf 恒为 false，
      // 又没有子节点），于是整块封面在 hit test 里「不存在」—— 点击直接穿透到底层，
      // onTap 永远不触发。表现就是「点专辑 / 歌手卡片没反应」。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: stack,
      ),
    );
  }
}

// ============================================================ 操作表

abstract class AppItemActionSheetEntry {
  const AppItemActionSheetEntry();
}

class AppItemActionSheetAction extends AppItemActionSheetEntry {
  const AppItemActionSheetAction({
    required this.title,
    required this.icon,
    this.onTap,
    this.color,
    this.titleColor,
  });

  final String title;
  final Widget icon;
  final VoidCallback? onTap;
  final Color? color;

  /// 标题颜色（参考项目的参数名，等价于 [color]）
  final Color? titleColor;
}

class AppItemActionSheetDivider extends AppItemActionSheetEntry {
  const AppItemActionSheetDivider();
}

class AppItemActionSheet {
  const AppItemActionSheet._();

  static Future<void> show(
    BuildContext context, {
    Widget? headerLeading,
    String? headerTitle,
    String? headerSubtitle,
    required List<AppItemActionSheetEntry> entries,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (headerTitle != null || headerLeading != null)
                ListTile(
                  leading: headerLeading,
                  title: Text(headerTitle ?? ''),
                  subtitle: headerSubtitle == null
                      ? null
                      : Text(headerSubtitle),
                ),
              const Divider(height: 1),
              for (final e in entries)
                if (e is AppItemActionSheetAction)
                  ListTile(
                    leading: e.icon,
                    title: Text(e.title, style: TextStyle(color: e.color)),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      e.onTap?.call();
                    },
                  )
                else if (e is AppItemActionSheetDivider)
                  Divider(height: 1, color: theme.dividerColor),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================ 系统文件操作

class FileApiService {
  FileApiService._();
  static final FileApiService instance = FileApiService._();

  Future<ApiResult> showInSystem(String path) async =>
      const ApiResult(success: false, message: '本端不支持在文件管理器中显示');

  Future<ApiResult> openInSystem(String path) async =>
      const ApiResult(success: false, message: '本端不支持用系统方式打开');
}

class ApiResult {
  const ApiResult({required this.success, this.message});

  final bool success;
  final String? message;
}

class PcHomeController {
  PcHomeController._();
  static final PcHomeController instance = PcHomeController._();

  /// 跳到「文件」页并定位到某个目录
  void openFolderAt(String path) {
    ToastUtil.show('文件浏览：$path');
  }
}

// ============================================================ 杂项

enum FolderViewModuleType { music, video, photo, book }

/// 文件视图页：本项目已有独立的文件模块，这里给个占位提示
class PcFolderViewPage extends StatelessWidget {
  const PcFolderViewPage({super.key, required this.moduleType});

  final FolderViewModuleType moduleType;

  @override
  Widget build(BuildContext context) {
    return const CustomNoData(text: '请到「文件」应用浏览目录');
  }
}

/// 数量徽标（筛选按钮右上角小圆点）
class VideoListBadge extends StatelessWidget {
  const VideoListBadge({super.key, required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -6,
          top: -6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
          ),
        ),
      ],
    );
  }
}

/// 目录选择对话框（本项目用系统文件选择器，这里给个说明占位）
class FolderPickerDialog extends StatelessWidget {
  const FolderPickerDialog({super.key, this.initialPath});

  final String? initialPath;

  @override
  Widget build(BuildContext context) =>
      const CustomNoData(text: '请使用「音乐来源」页添加目录');
}

/// 浏览路径工具（参考实现用于面包屑），本项目直接用 `/` 拼接
class BrowsePathUtils {
  const BrowsePathUtils._();

  static List<String> segments(String path) =>
      path.replaceAll('\\', '/').split('/').where((e) => e.isNotEmpty).toList();

  static String join(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';
}

/// 自签名证书兼容开关（参考实现有，本项目统一由 http 客户端处理）
class DioBadCertificatCompat {
  const DioBadCertificatCompat._();

  static bool get enabled => true;
}

/// 参考项目自带的下载中心控制器：本项目下载走 Transmission/PT，音乐不涉及
class DownloadController {
  /// 参考项目用 `Get.put(DownloadController())` 注册，所以要公开无名构造。
  /// 单例只在需要「全局看进度」时才用 [instance]。
  DownloadController();

  static final DownloadController instance = DownloadController();

  final ValueNotifier<int> activeCount = ValueNotifier<int>(0);

  final ValueNotifier<int> finishedCount = ValueNotifier<int>(0);

  bool _running = false;

  /// 下载一批远端路径。返回成功条数。
  ///
  /// 原生端流式写到「应用文档目录 / ColaNasDownload /」；Web 端不接管
  /// （浏览器自带下载器，调用方可用 [downloadUrlFor] 拼直链）。
  Future<int> handleDownload(
    List<String> paths, {
    List<bool?>? remoteIsDirectoryHint,
  }) async {
    if (paths.isEmpty) return 0;
    if (_running) return 0;
    _running = true;
    activeCount.value = paths.length;
    var ok = 0;
    try {
      for (final path in paths) {
        final done = await downloadRemoteFile(path);
        if (done) ok++;
        finishedCount.value = finishedCount.value + 1;
        activeCount.value = (activeCount.value - 1).clamp(0, 1 << 30);
      }
    } finally {
      activeCount.value = 0;
      _running = false;
    }
    return ok;
  }
}

/// 旧的二级菜单组件（音乐左菜单改用本项目 AppNavShell，不再使用）
class SideMenuTwoLevelGroup {
  const SideMenuTwoLevelGroup({
    required this.title,
    this.icon,
    this.expanded = false,
    this.items = const [],
  });

  final String title;
  final IconData? icon;
  final bool expanded;
  final List<TwoLevelSideMenuItem> items;
}

class TwoLevelSideMenuItem {
  const TwoLevelSideMenuItem({
    required this.title,
    required this.key,
    this.icon,
  });

  final String title;
  final String key;
  final IconData? icon;
}

/// 让 `jsonEncode` 对非 UTF-8 安全（部分平台 debug 输出用）
String safeJson(Object? v) {
  try {
    return jsonEncode(v);
  } catch (_) {
    return '$v';
  }
}

/// 复制到剪贴板（参考实现散在 utils 里）
Future<void> copyText(String text) =>
    Clipboard.setData(ClipboardData(text: text));

// ============================================================ 本地持久化的键名

/// 参考项目的本地缓存键（音乐模块会读写这些状态）。
/// 本项目不落盘（见 CacheManager），键名保持一致以免改动调用点。
class CacheKeys {
  const CacheKeys._();

  static const String musicVolume = 'music_volume';
  static const String musicVolumeBeforeMute = 'music_volume_before_mute';
  static const String musicLoopModeIndex = 'music_loop_mode_index';
  static const String musicAudioCacheEnabled = 'music_audio_cache_enabled';
  static const String musicAudioCacheMaxItems = 'music_audio_cache_max_items';
  static const String musicAudioCacheIndex = 'music_audio_cache_index';
  static const String musicDiscStyleIndex = 'music_disc_style_index';
  static const String musicFullScreenShowLyrics =
      'music_fullscreen_show_lyrics';
  static const String musicListSortByPrefix = 'music_list_sort_by_';
  static const String musicListSortOrderPrefix = 'music_list_sort_order_';
  static const String musicListSelectedPaths = 'music_list_selected_paths';
  static const String musicSubListSortBy = 'music_sub_list_sort_by';
  static const String musicSubListSortOrder = 'music_sub_list_sort_order';
}

/// 带占位符的文案：`'music_x'.trParams({'count': '3'})`
extension CompatTrParams on String {
  String trParams(Map<String, String> params) {
    var out = tr;
    params.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }
}

/// 桌面壳的窗口作用域：参考项目用它给标题栏按钮组留白。
/// 本项目窗口按钮画在自绘标题栏里，这里恒给 0。
class PcWindowScope {
  const PcWindowScope({this.titleBarControlsWidth = 0});

  final double titleBarControlsWidth;

  static PcWindowScope? of(BuildContext context) => null;
}

// ============================================================ video_player 等价层
//
// 参考项目在 Web / 桌面上用 `video_player` 播音频：`MusicPlayerVideoAdapter`
// 直接吃 `VideoPlayerController`。本项目统一走 media_kit，所以这里给一层
// 同名同语义的薄封装——`createVideoController()` 开一个 media_kit `Player`，
// 把它的 stream 汇成 `value`，`MusicPlayerVideoAdapter` 一行都不用改。

class DurationRange {
  const DurationRange(this.start, this.end);

  final Duration start;
  final Duration end;

  @override
  String toString() => 'DurationRange($start, $end)';
}

class VideoPlayerValue {
  const VideoPlayerValue({
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.buffered = const <DurationRange>[],
    this.isPlaying = false,
    this.isBuffering = false,
    this.isInitialized = false,
    this.hasError = false,
    this.errorDescription,
    this.volume = 1.0,
    this.looping = false,
  });

  final Duration duration;
  final Duration position;
  final List<DurationRange> buffered;
  final bool isPlaying;
  final bool isBuffering;
  final bool isInitialized;
  final bool hasError;
  final String? errorDescription;
  final double volume;
  final bool looping;

  VideoPlayerValue copyWith({
    Duration? duration,
    Duration? position,
    List<DurationRange>? buffered,
    bool? isPlaying,
    bool? isBuffering,
    bool? isInitialized,
    bool? hasError,
    String? errorDescription,
    double? volume,
    bool? looping,
  }) {
    return VideoPlayerValue(
      duration: duration ?? this.duration,
      position: position ?? this.position,
      buffered: buffered ?? this.buffered,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      isInitialized: isInitialized ?? this.isInitialized,
      hasError: hasError ?? this.hasError,
      errorDescription: errorDescription ?? this.errorDescription,
      volume: volume ?? this.volume,
      looping: looping ?? this.looping,
    );
  }
}

/// media_kit 驱动的 `VideoPlayerController` 等价物。语义对齐 video_player：
/// [initialize] 只负责加载取时长、不自动开播；[value] 是同步快照。
class VideoPlayerController {
  VideoPlayerController._(this.dataSource);

  /// 本地缓存文件（对齐 `VideoPlayerController.file`）。
  /// 参数用 dynamic 是为了让这份 compat 在 Web 端也能编译（那里没有 dart:io）。
  VideoPlayerController.file(dynamic file) : dataSource = '${file.path}';

  /// 网络地址（对齐 `VideoPlayerController.networkUrl`）
  VideoPlayerController.networkUrl(Uri url) : dataSource = url.toString();

  /// 播放地址（本地文件路径或 http url）
  final String dataSource;

  Player? _player;
  VideoPlayerValue _value = const VideoPlayerValue();
  final List<VoidCallback> _listeners = <VoidCallback>[];
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  VideoPlayerValue get value => _value;

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player();
    _player = p;
    _subs.add(
      p.stream.duration.listen((d) {
        _value = _value.copyWith(duration: d);
        _notify();
      }),
    );
    _subs.add(
      p.stream.position.listen((pos) {
        _value = _value.copyWith(position: pos);
        _notify();
      }),
    );
    _subs.add(
      p.stream.buffer.listen((b) {
        _value = _value.copyWith(
          buffered: <DurationRange>[DurationRange(Duration.zero, b)],
        );
        _notify();
      }),
    );
    _subs.add(
      p.stream.playing.listen((playing) {
        _value = _value.copyWith(isPlaying: playing);
        _notify();
      }),
    );
    _subs.add(
      p.stream.buffering.listen((buffering) {
        _value = _value.copyWith(isBuffering: buffering);
        _notify();
      }),
    );
    _subs.add(
      p.stream.error.listen((message) {
        _value = _value.copyWith(hasError: true, errorDescription: message);
        _notify();
      }),
    );
    return p;
  }

  Future<void> initialize() async {
    if (_disposed) return;
    final p = _ensurePlayer();
    await p.open(Media(dataSource), play: false);
    if (_disposed) return;
    _value = _value.copyWith(
      duration: p.state.duration,
      isInitialized: true,
      hasError: false,
    );
    await p.setVolume((_value.volume * 100).clamp(0.0, 100.0));
    _notify();
  }

  Future<void> play() async {
    if (_disposed) return;
    await _ensurePlayer().play();
  }

  Future<void> pause() async {
    if (_disposed) return;
    await _ensurePlayer().pause();
  }

  Future<void> seekTo(Duration position) async {
    if (_disposed) return;
    await _ensurePlayer().seek(position);
  }

  /// video_player 的 volume 是 0..1，media_kit 是 0..100
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    _value = _value.copyWith(volume: v);
    if (_disposed) return;
    await _ensurePlayer().setVolume(v * 100);
  }

  Future<void> setLooping(bool looping) async {
    _value = _value.copyWith(looping: looping);
    if (_disposed) return;
    await _ensurePlayer().setPlaylistMode(
      looping ? PlaylistMode.single : PlaylistMode.none,
    );
  }

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in List<VoidCallback>.of(_listeners)) {
      l();
    }
  }

  /// 幂等：`MusicPlayerVideoAdapter.dispose()` 会连带调一次
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _listeners.clear();
    final p = _player;
    _player = null;
    if (p != null) await p.dispose();
  }
}

/// 打开一个播放控制器（不做网络探测，交给 media_kit）
Future<VideoPlayerController> createVideoController(String url) async {
  return VideoPlayerController._(url);
}

/// 只负责回收，调用方随后还会 `controller.dispose()`（幂等，无副作用）
void disposeVideoController(VideoPlayerController controller) {
  unawaited(controller.dispose());
}

// ============================================================ 顶层工具 / 小组件
//
// 参考项目这些散在 `utils/` 与 `modules/base/components/` 里，调用处都是裸名字，
// 所以这里也导出成顶层符号，搬运过来的页面不用改一行。

/// 把「文件路径」折算成「所在目录」；本来就是目录就原样返回。
///
/// 只做字符串处理，不碰文件系统（Web 也能用），所以不需要 `path` 包。
String browseFolderPathMusic(String path) {
  final raw = path.trim();
  if (raw.isEmpty) return '';
  final normalized = raw.replaceAll('\\', '/');
  var end = normalized.length;
  while (end > 0 && normalized[end - 1] == '/') {
    end--;
  }
  final trimmed = normalized.substring(0, end);
  if (trimmed.isEmpty) return '';
  final slash = trimmed.lastIndexOf('/');
  final last = slash < 0 ? trimmed : trimmed.substring(slash + 1);
  // 带扩展名 = 文件 → 取父目录；末尾原本有斜杠 = 目录 → 原样
  if (end == normalized.length && last.contains('.')) {
    return slash <= 0 ? '' : trimmed.substring(0, slash);
  }
  return trimmed;
}

/// 选目录：统一走相册 / 影视那套「逐级浏览」的目录选择器，
/// 能返回上一层、也能一键回根。以前这里是粘贴绝对路径的文本框，
/// 压根没有目录层级可返回。allowFileSelect / sourceType 是参考实现
/// 留下的参数，统一选择器只选目录，保留签名不改 4 个调用点。
Future<List<String>?> showFolderPickerBottomSheet(
  BuildContext context, {
  bool multiSelect = false,
  bool allowFileSelect = false,
  String? sourceType,
  String? initialPath,
  String? title,
}) {
  final label = title ?? (multiSelect ? '选择目录（可多选）' : '选择目录');
  if (multiSelect) {
    return showFolderPickerMulti(
      context,
      initialPath: initialPath,
      title: label,
    );
  }
  return showFolderPicker(context, initialPath: initialPath, title: label)
      .then((picked) => picked == null ? null : <String>[picked]);
}

// ============================================================ 简易 HTTP

class HttpResult {
  const HttpResult({this.statusCode, this.json});

  final int? statusCode;
  final Map<String, dynamic>? json;

  bool get isOk =>
      statusCode != null && statusCode! >= 200 && statusCode! < 300;
}

/// 参考项目基于 dio 封的 `HttpUtil`，这里用 `http` 包给等价的两个方法。
class HttpUtil {
  const HttpUtil._();

  static Future<HttpResult> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final resp = await http.get(Uri.parse(url), headers: headers);
      Map<String, dynamic>? json;
      if (resp.body.isNotEmpty) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      }
      return HttpResult(statusCode: resp.statusCode, json: json);
    } catch (_) {
      return const HttpResult();
    }
  }

  static Future<HttpResult> post(
    String url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      );
      Map<String, dynamic>? json;
      if (resp.body.isNotEmpty) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      }
      return HttpResult(statusCode: resp.statusCode, json: json);
    } catch (_) {
      return const HttpResult();
    }
  }
}

// ============================================================ 通知权限

enum PermissionStatus {
  granted,
  denied,
  restricted,
  limited,
  permanentlyDenied,
  provisional;

  bool get isGranted => this == PermissionStatus.granted;

  bool get isPermanentlyDenied => this == PermissionStatus.permanentlyDenied;

  bool get isDenied => this == PermissionStatus.denied;

  bool get isRestricted => this == PermissionStatus.restricted;
}

/// 参考项目用 `permission_handler`。本项目只用到「通知权限」这一项，
/// 且音频走前台服务，通知权限被拒也不影响播放，所以这里恒给「已授予」，
/// 不引一个只为一次询问的原生插件。
class Permission {
  const Permission._(this.name);

  final String name;

  static const Permission notification = Permission._('notification');

  Future<PermissionStatus> get status async => PermissionStatus.granted;

  Future<PermissionStatus> request() async => PermissionStatus.granted;
}

/// 打开系统设置页（本项目没有对应原生通道，返回 false 表示没跳）
Future<bool> openAppSettings() async => false;

/// 参考项目在移动端注册 FVP 播放内核；本项目统一 media_kit，无需注册。
void registerFvp() {}

/// 断点续传下载用的 HttpClient（放行自签证书）。
/// 真正实现在 `compat/dio_lite.dart`，转一手让调用方不用带前缀。
dio_lite.Dio createDioWithBadCertificateCompat() =>
    dio_lite.createDioWithBadCertificateCompat();

// ============================================================ 二级侧边栏

/// 参考项目的二级侧边菜单（分组 + 子项 + 折叠）。
///
/// 注意：本项目正式入口走 `AppNavShell`（菜单来自 `contracts/apps.json`），
/// 这个组件只在音乐模块内部（比如独立窗口样式）用到，行为对齐参考实现即可。
class TwoLevelSideMenu extends StatelessWidget {
  const TwoLevelSideMenu({
    super.key,
    required this.currentKey,
    required this.onSelect,
    required this.groups,
    this.collapsed = false,
    this.onToggleCollapse,
    this.toggleExpandTooltip,
    this.toggleCollapseTooltip,
    this.headerTrailing,
    this.width = 208,
  });

  final String currentKey;
  final void Function(String key) onSelect;
  final List<SideMenuTwoLevelGroup> groups;
  final bool collapsed;
  final VoidCallback? onToggleCollapse;
  final String? toggleExpandTooltip;
  final String? toggleCollapseTooltip;
  final Widget? headerTrailing;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (collapsed) {
      return SizedBox(
        width: 56,
        child: Column(
          children: <Widget>[
            if (headerTrailing != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: headerTrailing,
              ),
            IconButton(
              tooltip: toggleExpandTooltip,
              onPressed: onToggleCollapse,
              icon: const Icon(Icons.chevron_right),
            ),
            const Divider(height: 1),
            for (final group in groups)
              for (final item in group.items)
                IconButton(
                  tooltip: item.title,
                  onPressed: () => onSelect(item.key),
                  icon: Icon(
                    item.icon ?? Icons.circle_outlined,
                    color: item.key == currentKey
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
          ],
        ),
      );
    }

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (headerTrailing != null) Expanded(child: headerTrailing!),
              IconButton(
                tooltip: toggleCollapseTooltip,
                onPressed: onToggleCollapse,
                icon: const Icon(Icons.chevron_left),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: <Widget>[
                for (final group in groups) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: Row(
                      children: <Widget>[
                        if (group.icon != null)
                          Icon(
                            group.icon,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        if (group.icon != null) const SizedBox(width: 6),
                        Text(
                          group.title,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final item in group.items)
                    ListTile(
                      dense: true,
                      selected: item.key == currentKey,
                      leading: Icon(
                        item.icon ?? Icons.circle_outlined,
                        size: 20,
                      ),
                      title: Text(item.title),
                      onTap: () => onSelect(item.key),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
