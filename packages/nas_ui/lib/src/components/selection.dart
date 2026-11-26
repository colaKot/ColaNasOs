/// 全站统一的多选（选择态）基座 —— 以「电视剧列表」的口径为准。
///
/// 统一的三件事，任何页面都不再各写一份：
/// 1. **进入 / 退出**：工具栏 checklist 按钮（[NasSelectionToggleButton]）
///    或菜单项调用 [NasSelectionController.enter]；退出走操作条右侧 X
///    （或在同一按钮上再点一次），退出即清空选中。
/// 2. **卡片选中视觉**：封面左上角 20px 圆形勾选标记（[NasSelectChip]），
///    选中态封面加一圈主色描边 + 主色薄蒙层（[NasSelectionCover]）。
/// 3. **操作条**：全站统一用浮层条 [NasSelectionFloatingBar] —— 悬浮在内容
///    右下角的面板色胶囊，左侧「已选 N」，随后「全选 / 取消全选」+ 业务动作
///    + 关闭。用 [NasSelectionOverlay] 把它叠在列表 / 网格之上即可。
///
/// 特殊形态（相似清理的逐组勾选、文件的拖拽、音乐框选）只复用
/// [NasSelectChip] 做视觉标记，不强行套用整条操作条 —— 见各页说明。
library;

import 'dart:collection';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../style.dart';
import '../tokens.dart';

/// 选择态状态机：页面只持有一个实例，不要各自维护 `bool + Set`。
class NasSelectionController extends ChangeNotifier {
  NasSelectionController({Set<String>? initialIds}) : _ids = {...?initialIds};

  bool _active = false;
  final Set<String> _ids;

  /// 是否处于选择态（true 时卡片点击 = 切换选中，而不是打开详情）
  bool get active => _active;

  /// 已选 id 的只读视图；改选中一律走本类的方法
  Set<String> get ids => UnmodifiableSetView(_ids);

  int get count => _ids.length;

  bool get isEmpty => _ids.isEmpty;

  bool get isNotEmpty => _ids.isNotEmpty;

  bool contains(String id) => _ids.contains(id);

  /// 进入选择态。`initialId` 用于「长按 / 右键某张卡直接进多选」的场景。
  void enter({String? initialId}) {
    _active = true;
    if (initialId != null) _ids.add(initialId);
    notifyListeners();
  }

  /// 退出并清空（全站统一：退出选择态不保留上次选中）
  void exit() {
    if (!_active && _ids.isEmpty) return;
    _active = false;
    _ids.clear();
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    notifyListeners();
  }

  void toggle(String id) {
    if (!_ids.remove(id)) _ids.add(id);
    notifyListeners();
  }

  void setSelected(String id, bool selected) {
    final changed = selected ? _ids.add(id) : _ids.remove(id);
    if (changed) notifyListeners();
  }

  /// 全选当前列表
  void selectAll(Iterable<String> all) {
    _ids
      ..clear()
      ..addAll(all);
    notifyListeners();
  }

  /// 当前列表是否「全部已选」（空列表不算全选，避免按钮语义反过来）
  bool allSelected(Iterable<String> all) {
    final list = all.toList();
    return list.isNotEmpty && list.every(_ids.contains);
  }

  /// 全选 / 取消全选：全站统一由操作条上的同一个按钮触发
  void toggleAll(Iterable<String> all) {
    final list = all.toList();
    if (allSelected(list)) {
      _ids.clear();
    } else {
      _ids
        ..clear()
        ..addAll(list);
    }
    notifyListeners();
  }
}

/// 封面左上角的圆形勾选标记。
///
/// 未选中 = 半透明黑底 + 白描边；选中 = 主色实心 + 白勾。
/// [size] 默认 20，剧集小格可用 12 这种更小的档位。
class NasSelectChip extends StatelessWidget {
  const NasSelectChip({super.key, required this.selected, this.size = 20});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: size < 16 ? 1 : 1.4,
        ),
      ),
      child: selected
          ? Icon(Icons.check, size: size * 0.65, color: Colors.white)
          : null,
    );
  }
}

/// 封面类卡片的选择态标记：左上角圆勾。
///
/// 刻意**不**给整张卡压黑 / 加大勾 —— 电视剧列表的口径是「封面保持原样，
/// 只用左上角勾选标记表达选中」，页面照着用即可。
class NasSelectionCover extends StatelessWidget {
  const NasSelectionCover({
    super.key,
    required this.selected,
    required this.child,
    this.inset = 6,
    this.chipSize = 20,
  });

  final bool selected;
  final Widget child;
  final double inset;
  final double chipSize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // 只是视觉标记，不能吃掉点击（再点一下要能取消选中）
        Positioned(
          top: inset,
          left: inset,
          child: IgnorePointer(
            child: NasSelectChip(selected: selected, size: chipSize),
          ),
        ),
      ],
    );
  }
}

/// 操作条上的一项业务动作（图标同时用于窄屏收折模式）
class NasSelectionAction {
  const NasSelectionAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.danger = false,
  });

  /// 宽屏显示的文字 / 窄屏与底部工具条的 tooltip
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool enabled;

  /// 删除类动作用错误色
  final bool danger;
}

/// 全站统一的多选浮层操作条（悬浮在内容右下角）。
///
/// 口径来自「本地博客目录」：面板色胶囊 + 已选计数 + 全选 / 取消全选 +
/// 业务动作（普通动作 tonal、删除类动作错误色）+ 可选关闭。
/// 窄屏不做图标收折 —— 用 [Wrap] 自然换行，保证按钮文字始终可读。
class NasSelectionFloatingBar extends StatelessWidget {
  const NasSelectionFloatingBar({
    super.key,
    required this.title,
    this.actions = const <NasSelectionAction>[],
    this.onToggleAll,
    this.allSelected = false,
    this.onClose,
    this.margin = const EdgeInsets.all(NasTokens.spaceLg),
  });

  /// 左侧计数文案（各域沿用已有的「已选 N」文案键）
  final String title;
  final List<NasSelectionAction> actions;

  /// 全选 / 取消全选。传 null 则该按钮不显示
  final VoidCallback? onToggleAll;
  final bool allSelected;
  final VoidCallback? onClose;

  /// 浮层与容器右下角的间距
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = context.nasStyle;
    return Material(
      color: style.panelColor,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NasTokens.radiusLg),
        side: BorderSide(color: style.panelBorderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NasTokens.spaceMd,
          vertical: NasTokens.spaceSm,
        ),
        child: Wrap(
          spacing: NasTokens.spaceSm,
          runSpacing: NasTokens.spaceXs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (onToggleAll != null)
              TextButton(
                onPressed: onToggleAll,
                child: Text(
                  allSelected
                      ? tr('ui.selection.none')
                      : tr('ui.selection.all'),
                ),
              ),
            for (final a in actions)
              a.danger
                  ? FilledButton.icon(
                      onPressed: a.enabled ? a.onPressed : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      ),
                      icon: Icon(a.icon, size: 18),
                      label: Text(a.label),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: a.enabled ? a.onPressed : null,
                      icon: Icon(a.icon, size: 18),
                      label: Text(a.label),
                    ),
            if (onClose != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: tr('common.cancel'),
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
              ),
          ],
        ),
      ),
    );
  }
}

/// 把 [NasSelectionFloatingBar] 叠在内容右下角的容器。
///
/// 内容是普通 widget（滚动列表 / 网格都可以），操作条 `null` 时不占位。
class NasSelectionOverlay extends StatelessWidget {
  const NasSelectionOverlay({
    super.key,
    required this.child,
    this.bar,
    this.margin = const EdgeInsets.all(NasTokens.spaceLg),
  });

  final Widget child;
  final Widget? bar;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final current = bar;
    if (current == null) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(padding: margin, child: current),
        ),
      ],
    );
  }
}


/// 工具栏上的「多选」入口：非选择态显示 checklist，选择态变成关闭。
class NasSelectionToggleButton extends StatelessWidget {
  const NasSelectionToggleButton({
    super.key,
    required this.active,
    required this.onPressed,
    this.enterTooltip,
  });

  final bool active;
  final VoidCallback onPressed;

  /// 进入多选的提示文案；默认「多选」
  final String? enterTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: active
          ? tr('common.cancel')
          : (enterTooltip ?? tr('ui.selection.enter')),
      onPressed: onPressed,
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      style: active
          ? IconButton.styleFrom(
              backgroundColor: scheme.primary.withValues(alpha: 0.14),
            )
          : null,
      icon: Icon(
        active ? Icons.close : Icons.checklist,
        color: active ? scheme.primary : null,
      ),
    );
  }
}
