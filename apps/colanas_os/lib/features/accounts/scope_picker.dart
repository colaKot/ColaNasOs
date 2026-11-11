import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

/// 服务端全部 `xxx:read` / `xxx:write` 权限域。
///
/// 清单来自 `src/modules/**` 里 `secured('域:动作', …)` 的实际调用，
/// 加模块时这里要同步 —— `tool/check/scope-catalog.js` 会拿两边比对，漂了就报错。
///
/// 顺序是界面顺序：常用的放前面（文件 / 相册 / 影视 / 音乐），
/// 管理类放后面，免得新建账号时在一堆系统项里找相册。
const List<String> kScopeDomains = <String>[
  'files',
  'photo',
  'video',
  'music',
  'blog',
  'discover',
  'pt',
  'rss',
  'sync',
  'player',
  'integration',
  'system',
  'user',
  'security',
];

/// 通配权限：勾上就等于「所有域 + 以后新增的域」。
const String kScopeWildcard = '*';

String scopeRead(String domain) => '$domain:read';
String scopeWrite(String domain) => '$domain:write';

/// 域的中文名。走 i18n，缺键时回落成域名本身（至少还能认出来是哪个）。
String scopeDomainLabel(String domain) => tr('accounts.scope.domain.$domain');

/// 单个权限的中文标签：`files:read` → 「文件 · 只读」，`*` → 「全部权限」。
///
/// 用户列表 / 账号卡片 / 访问令牌列表以前把 `files:read` 原样铺出来，
/// 看着像配置文件而不是权限（用户 2026-11-11 反馈）。未知域 / 未知动作
/// 原样返回，宁可露出英文也别显示成空白。
String scopeLabel(String scope) {
  final s = scope.trim();
  if (s.isEmpty) return s;
  if (s == kScopeWildcard) return tr('accounts.scope.all');
  final idx = s.indexOf(':');
  if (idx <= 0) return s;
  final domain = s.substring(0, idx);
  final action = s.substring(idx + 1);
  final name = kScopeDomains.contains(domain)
      ? scopeDomainLabel(domain)
      : domain;
  final act = switch (action) {
    'read' => tr('accounts.scope.read'),
    'write' => tr('accounts.scope.write'),
    _ => action,
  };
  return '$name · $act';
}

/// 一组权限的中文标签，按域顺序排（`*` 直接折成一条「全部权限」）。
List<String> scopeLabels(Iterable<String> scopes) {
  final list = scopes.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (list.contains(kScopeWildcard)) return <String>[tr('accounts.scope.all')];
  final order = <String, int>{
    for (var i = 0; i < kScopeDomains.length; i++) kScopeDomains[i]: i,
  };
  // 排序键：域序号 × 10 + 动作（只读 0 / 可写 1），同域内 read 排前面
  int key(String s) {
    final parts = s.split(':');
    final d = order[parts.first] ?? 999;
    final a = parts.length > 1 && parts[1] == 'write' ? 1 : 0;
    return d * 10 + a;
  }

  list.sort((a, b) => key(a).compareTo(key(b)));
  return list.map(scopeLabel).toList();
}

/// 把任意 scope 列表归一成「界面能正确显示」的形态：
/// 去掉未知项以外的空值、给 `xxx:write` 自动补上 `xxx:read`。
///
/// 为什么要补 read：服务端写接口只校验 `xxx:write`，但列表 / 详情这些读接口
/// 校验 `xxx:read`。只给 write 的账号进页面会看到「有按钮但打不开列表」，
/// 属于常见误配，这里直接消掉这个可能性。
List<String> normalizeScopes(Iterable<String> raw) {
  final out = <String>{};
  for (final s in raw) {
    final v = s.trim();
    if (v.isEmpty) continue;
    out.add(v);
    if (v.endsWith(':write')) out.add('${v.substring(0, v.length - 6)}:read');
  }
  return out.toList(growable: false);
}

/// 权限选择器：按域列「只读 / 可写」两列勾选。
///
/// 取代原来那个「逗号分隔手填 `files:read`」的输入框 —— 那个输入框有三个问题：
/// ① 没人知道合法值有哪些；② 拼错一个字母不报错，只是那个页面 403；
/// ③ 只勾 write 不勾 read 会得到一个「能改但看不了」的账号。
class ScopePicker extends StatefulWidget {
  const ScopePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.maxHeight = 300,
  });

  final List<String> value;
  final ValueChanged<List<String>> onChanged;
  final double maxHeight;

  @override
  State<ScopePicker> createState() => _ScopePickerState();
}

class _ScopePickerState extends State<ScopePicker> {
  late Set<String> _set;

  @override
  void initState() {
    super.initState();
    _set = normalizeScopes(widget.value).toSet();
  }

  @override
  void didUpdateWidget(covariant ScopePicker old) {
    super.didUpdateWidget(old);
    // 外部换了源数据（比如编辑另一个账号）才重建，自己 emit 上来的不回灌，
    // 否则勾选顺序会被父级重排。
    if (!identical(old.value, widget.value)) {
      _set = normalizeScopes(widget.value).toSet();
    }
  }

  bool get _wildcard => _set.contains(kScopeWildcard);

  void _emit() {
    // 通配时只发 `*`：服务端按 `scopes.includes('*')` 直接放行，
    // 再叠 28 个明细只是噪音，回读界面时也难判断「到底是不是全权」。
    final list = _wildcard
        ? <String>[kScopeWildcard]
        : kScopeDomains
              .expand(
                (d) => <String>[
                  if (_set.contains(scopeRead(d))) scopeRead(d),
                  if (_set.contains(scopeWrite(d))) scopeWrite(d),
                ],
              )
              .toList(growable: false);
    widget.onChanged(list);
    setState(() {});
  }

  void _toggle(String scope, bool on) {
    final domain = scope.split(':').first;
    if (on) {
      _set.add(scope);
      // 给写权限时自动补读权限（见 normalizeScopes 的说明）
      if (scope.endsWith(':write')) _set.add(scopeRead(domain));
    } else {
      _set.remove(scope);
      // 收回读权限时写权限也一起收：没有 read 的 write 是个半残状态
      if (scope.endsWith(':read')) _set.remove(scopeWrite(domain));
    }
    _emit();
  }

  void _applyAll({required bool read, required bool write}) {
    _set = <String>{};
    if (read || write) {
      for (final d in kScopeDomains) {
        if (read) _set.add(scopeRead(d));
        if (write) {
          _set.add(scopeRead(d));
          _set.add(scopeWrite(d));
        }
      }
    }
    _emit();
  }

  void _toggleWildcard(bool on) {
    _set = on ? <String>{kScopeWildcard} : <String>{};
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedCount = _wildcard ? kScopeDomains.length * 2 : _set.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---------------------------------------------------------- 快捷操作
        Row(
          children: [
            Text(
              tr('accounts.scope.summary', {'n': '$selectedCount'}),
              style: TextStyle(
                fontSize: NasTokens.fontCaption,
                color: context.nasTextSecondary,
              ),
            ),
            const Spacer(),
            _quickAction(
              tr('accounts.scope.allRead'),
              () => _applyAll(read: true, write: false),
            ),
            _quickAction(
              tr('accounts.scope.allWrite'),
              () => _applyAll(read: true, write: true),
            ),
            _quickAction(
              tr('accounts.scope.clear'),
              () => _applyAll(read: false, write: false),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceXs),
        const Divider(height: 1),

        // ---------------------------------------------------------- 域清单
        SizedBox(
          height: widget.maxHeight,
          child: _wildcard
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NasTokens.spaceMd),
                    child: Text(
                      tr('accounts.scope.wildcardHint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                  ),
                )
              : Scrollbar(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: kScopeDomains.length,
                    itemBuilder: (context, i) {
                      final d = kScopeDomains[i];
                      final r = _set.contains(scopeRead(d));
                      final w = _set.contains(scopeWrite(d));
                      return InkWell(
                        onTap: () => _toggle(scopeRead(d), !r),
                        child: SizedBox(
                          height: 38,
                          child: Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    left: NasTokens.spaceXs,
                                  ),
                                  child: Text(
                                    scopeDomainLabel(d),
                                    style: TextStyle(
                                      fontSize: NasTokens.fontBody,
                                      color: r || w
                                          ? scheme.onSurface
                                          : context.nasTextSecondary,
                                    ),
                                  ),
                                ),
                              ),
                              _cell(
                                context,
                                label: tr('accounts.scope.read'),
                                checked: r,
                                onChanged: (v) => _toggle(scopeRead(d), v),
                              ),
                              _cell(
                                context,
                                label: tr('accounts.scope.write'),
                                checked: w,
                                onChanged: (v) => _toggle(scopeWrite(d), v),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        const Divider(height: 1),

        // ---------------------------------------------------------- 全权
        InkWell(
          onTap: () => _toggleWildcard(!_wildcard),
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                Checkbox(
                  value: _wildcard,
                  onChanged: (v) => _toggleWildcard(v == true),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('accounts.scope.all'),
                        style: TextStyle(fontSize: NasTokens.fontBody),
                      ),
                      Text(
                        tr('accounts.scope.allHint'),
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: context.nasTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _quickAction(String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(left: NasTokens.spaceXs),
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: NasTokens.fontCaption),
      ),
    ),
  );

  Widget _cell(
    BuildContext context, {
    required String label,
    required bool checked,
    required ValueChanged<bool> onChanged,
  }) => SizedBox(
    width: 74,
    child: InkWell(
      onTap: () => onChanged(!checked),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: checked,
            onChanged: (v) => onChanged(v == true),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}
