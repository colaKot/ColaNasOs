import fs from 'node:fs';
import path from 'node:path';

/**
 * 契约文件定位（安装包形态修复，SP4-03）。
 *
 * 开发态契约在仓库根 `contracts/`；安装包里它在 `resources/contracts/`。
 * 旧实现只认 `process.cwd()/contracts` —— 打包后 cwd 是 exe 所在目录，
 * 内核启动即 `ENOENT`（安装包完全起不来，只有跑过运行冒烟才能发现）。
 *
 * 查找顺序：
 *   1. `COLANAS_CONTRACTS_DIR`（外壳在打包态注入 `resources/contracts`）
 *   2. `<cwd>/contracts`（开发态：仓库根启动）
 *   3. `<__dirname>/../../contracts`（dist/kernel → 仓库根，兜底）
 */
export function resolveContractFile(name: string): string {
  const candidates = [
    process.env.COLANAS_CONTRACTS_DIR,
    path.join(process.cwd(), 'contracts'),
    path.resolve(__dirname, '..', '..', 'contracts'),
  ].filter((p): p is string => Boolean(p));

  for (const dir of candidates) {
    const file = path.join(dir, name);
    if (fs.existsSync(file)) return file;
  }

  throw new Error(
    `契约文件 ${name} 不存在（已查找：${candidates.join(' | ')}）；` +
      '安装包请确认 resources/contracts 随包分发，或用 COLANAS_CONTRACTS_DIR 指定目录',
  );
}