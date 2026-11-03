import type { FastifyInstance } from 'fastify';
import type { KernelApi, ServerModule } from './types';
import type { Migrator } from './migrator';

export interface ResolveResult {
  /** 拓扑排序后的模块 */
  order: ServerModule[];
  /** 缺失的依赖（module -> dep） */
  missing: Array<{ module: string; dep: string }>;
  /** 参与环的模块 id */
  cycle: string[];
}

export interface MountResult {
  loaded: string[];
  /** 注册抛错的模块 */
  degraded: string[];
  /** 因上游失败而跳过的模块 */
  skipped: string[];
  /** 本次执行的迁移 id */
  applied: string[];
}

/**
 * 模块注册器：
 * - 显式注册（不扫描目录）
 * - `dependsOn` 拓扑排序 + 缺失/环形依赖在启动期直接报错
 * - 单模块失败只降级该模块及其下游，不影响其他模块
 */
export class ModuleRegistry {
  private modules = new Map<string, ServerModule>();

  add(m: ServerModule): this {
    if (this.modules.has(m.id)) {
      throw new Error(`duplicate module id: ${m.id}`);
    }
    this.modules.set(m.id, m);
    return this;
  }

  ids(): string[] {
    return [...this.modules.keys()];
  }

  resolve(): ResolveResult {
    const missing: Array<{ module: string; dep: string }> = [];
    for (const m of this.modules.values()) {
      for (const dep of m.dependsOn ?? []) {
        if (!this.modules.has(dep)) missing.push({ module: m.id, dep });
      }
    }

    // Kahn 拓扑排序
    const indeg = new Map<string, number>();
    const adj = new Map<string, string[]>();
    for (const id of this.modules.keys()) {
      indeg.set(id, 0);
      adj.set(id, []);
    }
    for (const m of this.modules.values()) {
      for (const dep of m.dependsOn ?? []) {
        if (!this.modules.has(dep)) continue;
        adj.get(dep)!.push(m.id);
        indeg.set(m.id, (indeg.get(m.id) ?? 0) + 1);
      }
    }

    const queue = [...this.modules.keys()].filter((id) => (indeg.get(id) ?? 0) === 0).sort();
    const order: ServerModule[] = [];

    while (queue.length > 0) {
      const id = queue.shift()!;
      order.push(this.modules.get(id)!);
      for (const next of [...(adj.get(id) ?? [])].sort()) {
        const left = (indeg.get(next) ?? 1) - 1;
        indeg.set(next, left);
        if (left === 0) queue.push(next);
      }
      queue.sort();
    }

    const ordered = new Set(order.map((m) => m.id));
    const cycle = [...this.modules.keys()].filter((id) => !ordered.has(id));

    return { order, missing, cycle };
  }

  async mount(
    app: FastifyInstance,
    k: KernelApi,
    migrator?: Migrator,
    migrationOrder?: readonly string[],
  ): Promise<MountResult> {
    const { order, missing, cycle } = this.resolve();

    if (missing.length > 0) {
      throw new Error(
        'missing module dependencies: ' + missing.map((x) => `${x.module}->${x.dep}`).join(', '),
      );
    }
    if (cycle.length > 0) {
      throw new Error('circular module dependencies: ' + cycle.join(', '));
    }

    let applied: string[] = [];
    if (migrator) {
      const all = order.flatMap((m) => m.migrations ?? []);
      if (all.length > 0) applied = await migrator.run(all, migrationOrder);
    }

    const loaded: string[] = [];
    const degraded: string[] = [];
    const skipped: string[] = [];
    const bad = new Set<string>();

    for (const m of order) {
      const upstreamBad = (m.dependsOn ?? []).some((d) => bad.has(d));
      if (upstreamBad) {
        skipped.push(m.id);
        bad.add(m.id);
        continue;
      }
      try {
        await m.register(app, k);
        loaded.push(m.id);
      } catch (err) {
        k.log.error({ module: m.id, err: String(err) }, 'module register failed');
        degraded.push(m.id);
        bad.add(m.id);
      }
    }

    return { loaded, degraded, skipped, applied };
  }
}
