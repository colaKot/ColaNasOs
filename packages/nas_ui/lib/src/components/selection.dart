/// 全站统一的多选（选择态）基座 —— 以「电视剧列表」的口径为准。
///
/// 统一的三件事，任何页面都不再各写一份：
/// 1. **进入 / 退出**：工具栏 checklist 按钮（[NasSelectionToggleButton]）
///    或菜单项调用 [NasSelectionController.enter]；退出走操作条右侧 X
///    （或在同一按钮上再点一次），退出即清空选中。
/// 2. **卡片选中视觉**：封面左上角 20px 圆形勾选标记（[NasSelectChip]），
///    选中态封面加一圈主色描边 + 主色薄蒙层（[NasSelectionCover]）。
/// 3. **操作条**：主色 8% 底色的内联条（[NasSelectionBar]），左侧「已选 N」，
///    右侧「全选 / 取消全选」+ 业务动作 + 关闭；窄屏 / 底部工具条自动收成图标。
///
/// 特殊形态（相似清理的逐组勾选、文件的拖拽、音乐框选）只复用
/// [NasSelectChip] 做视觉标记，不强行套用整条操作条 —— 见各页说明。
library;

import 'dart:collection';

import 'package:flutter/material.dart';

import '../i18n.dart';
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

/// 统一的多选操作条（内联在列表上方，或放进底部工具条容器）。
///
/// - 左侧：选中计数（各域名沿用已有的「已选 N」文案键）
/// - 右侧：全选 / 取消全选 + 业务动作 + 关闭
/// - 宽度 < 560 或 [dense] 时动作收成图标（tooltip 保留），避免手机端溢出
class NasSelectionBar extends StatelessWidget {
  const NasSelectionBar({
    super.key,
    required this.title,
    required this.actions,
    this.onClose,
    this.onToggleAll,
    this.allSelected = false,
    this.dense = false,
    this.padding,
  });

  final String title;
  final List<NasSelectionAction> actions;
  final VoidCallback? onClose;

  /// 全选 / 取消全选。传 null 则该按钮不显示（如相似清理的逐组勾选）。
  final VoidCallback? onToggleAll;
  final bool allSelected;
  final bool dense;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final iconsOnly = dense || constraints.maxWidth < 560;
        final allLabel = allSelected
            ? tr('ui.selection.none')
            : tr('ui.selection.all');
        return Container(
          color: scheme.primary.withValues(alpha: 0.08),
          padding:
              padding ??
              const EdgeInsets.symmetric(
                horizontal: NasTokens.spaceMd,
                vertical: 4,
              ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: NasTokens.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onToggleAll != null)
                iconsOnly
                    ? _BarIcon(
                        icon: allSelected
                            ? Icons.deselect
                            : Icons.select_all,
                        tooltip: allLabel,
                        onPressed: onToggleAll,
                      )
                    : TextButton(
                        onPressed: onToggleAll,
                        child: Text(allLabel),
                      ),
              for (final a in actions)
                iconsOnly
                    ? _BarIcon(
                        icon: a.icon,
                        tooltip: a.label,
                        onPressed: a.enabled ? a.onPressed : null,
                        danger: a.danger,
                      )
                    : TextButton(
                        onPressed: a.enabled ? a.onPressed : null,
                        style: a.danger
                            ? TextButton.styleFrom(
                                foregroundColor: scheme.error,
                              )
                            : null,
                        child: Text(a.label),
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
        );
      },
    );
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 20,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 19,
            color: onPressed == null
                ? scheme.onSurface.withValues(alpha: 0.38)
                : (danger ? scheme.error : null),
          ),
        ),
      ),
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
