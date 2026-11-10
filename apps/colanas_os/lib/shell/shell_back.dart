import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 「返回上一层」的注册表（桌面右上角 / 手机左上角共用一个通道）。
///
/// 三级 / 四级页面有两种形态：`Navigator.push` 出来的整页自带 AppBar（顶栏被遮住），
/// 而「在模块内下钻」的页面（如相册·人脸点进某个簇）仍留在三栏外壳里，没有自己的返回入口。
///
/// 2026-11-06 升级：从「一个 appId 一个 handler」改成**按 appId 的栈**。
/// 以前只有人脸页注册，且外壳自己想给「那年今日」这类页面内跳转加返回时会互相覆盖；
/// 现在外壳层（隐藏菜单项）和页面层（State 内下钻）可以叠加，返回一次退一层。
class ShellBack {
  ShellBack._();

  static final Map<String, List<_Entry>> _stacks = <String, List<_Entry>>{};

  /// 顶栏监听它重建：注册 / 注销后返回按钮的显隐立即生效。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知顶栏重建。
  ///
  /// 不能在帧内直接改：`SubPageScope.dispose` 发生在 `finalizeTree`（树锁定期），
  /// 同步 `revision.value++` 会让顶栏的 ValueListenableBuilder 立刻 `setState`，
  /// 直接报 "setState() or markNeedsBuild() called when widget tree was locked"。
  /// 推到帧后再通知，多一帧延迟但不会炸。
  static void _bump() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.postFrameCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        revision.value += 1;
      });
      return;
    }
    revision.value += 1;
  }

  /// 压一层，返回 token 供 [remove] 精确注销（旧闭包不会误删新注册）。
  static Object push(String appId, VoidCallback onBack) {
    final token = Object();
    _stacks.putIfAbsent(appId, () => <_Entry>[]).add(_Entry(token, onBack));
    _bump();
    return token;
  }

  static void remove(String appId, Object token) {
    final list = _stacks[appId];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((e) => identical(e.token, token));
    if (list.length == before) return;
    if (list.isEmpty) _stacks.remove(appId);
    _bump();
  }

  /// 换二级菜单时清空该模块的所有层级，避免旧页面留下的返回按钮串到新页面。
  static void clear(String appId) {
    if (_stacks.remove(appId) != null) _bump();
  }

  /// 栈顶 = 当前最里层的返回动作。
  static VoidCallback? handlerFor(String appId) {
    final list = _stacks[appId];
    return list == null || list.isEmpty ? null : list.last.onBack;
  }

  static int depth(String appId) => _stacks[appId]?.length ?? 0;
}

class _Entry {
  const _Entry(this.token, this.onBack);

  final Object token;
  final VoidCallback onBack;
}

/// 由 [AppNavShell] 提供 appId，页面不用再硬编码 `'photo'` / `'video'`。
class ShellBackScope extends InheritedWidget {
  const ShellBackScope({super.key, required this.appId, required super.child});

  final String appId;

  static String? appIdOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellBackScope>()?.appId;

  @override
  bool updateShouldNotify(ShellBackScope oldWidget) => oldWidget.appId != appId;
}

/// 页面内下钻时只需包一层：
///
/// ```dart
/// SubPageScope(
///   active: _title != null,
///   onBack: _backToGrid,
///   child: body,
/// )
/// ```
///
/// `active` 变 true 就注册、变 false 或页面销毁就注销，不漏 unregister。
/// 注册的是绑定方法 [_fire]（闭包固定），`widget.onBack` 每次读最新的，
/// 所以页面 rebuild 不会反复 push 导致 revision 抖动。
class SubPageScope extends StatefulWidget {
  const SubPageScope({
    super.key,
    required this.active,
    required this.onBack,
    required this.child,
  });

  final bool active;
  final VoidCallback onBack;
  final Widget child;

  @override
  State<SubPageScope> createState() => _SubPageScopeState();
}

class _SubPageScopeState extends State<SubPageScope> {
  String? _appId;
  Object? _token;

  void _fire() => widget.onBack();

  void _detach([String? ofAppId]) {
    final appId = ofAppId ?? _appId;
    final token = _token;
    _token = null;
    if (appId != null && token != null) ShellBack.remove(appId, token);
  }

  void _sync() {
    final appId = _appId;
    if (appId == null) return;
    // didChangeDependencies / didUpdateWidget 都在 build 阶段，直接改 revision 会让
    // 顶栏的 ValueListenableBuilder 在 build 中 setState。统一推到帧后执行；
    // dispose 走同步 _detach，避免页面没了还留着返回按钮。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _appId != appId) return;
      if (!widget.active) {
        _detach(appId);
        return;
      }
      _token ??= ShellBack.push(appId, _fire);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appId = ShellBackScope.appIdOf(context);
    if (appId != _appId) {
      _detach();
      _appId = appId;
      _sync();
    }
  }

  @override
  void didUpdateWidget(SubPageScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
