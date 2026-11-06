import type { ServerModule } from './types';
import { ModuleRegistry } from './registry';
import { files } from '../src/modules/files';
import { share } from '../src/modules/share';
import { safety } from '../src/modules/safety';
import { system } from '../src/modules/system';
import { rss } from '../src/modules/rss';
import { sync } from '../src/modules/sync';
import { accounts } from '../src/modules/auth';
import { integrations } from '../src/modules/integrations';
import { messages } from '../src/modules/messages';
import { notes } from '../src/modules/notes';
import { photo } from '../src/modules/photo';
import { video } from '../src/modules/video';
import { music } from '../src/modules/music';
import { book } from '../src/modules/book';
import { blog } from '../src/modules/blog';
import { mount } from '../src/modules/mount';
import { mediaTool } from '../src/modules/mediaTool';
import { videoPlayer } from '../src/modules/videoPlayer';
import { discover } from '../src/modules/discover';
import { pt } from '../src/modules/pt';

/**
 * 域模块的**唯一装配清单**。
 *
 * 内核启动与 `tool/migrate.js` 都从这里取，避免「工具看到的迁移集合」和「真实启动的迁移集合」不一致。
 * 新增模块必须在此登记（显式注册，不扫描目录）。
 */
export function moduleList(): ServerModule[] {
  return [
    files,
    share,
    safety,
    system,
    rss,
    sync,
    accounts,
    integrations,
    messages,
    notes,
    photo,
    video,
    music,
    book,
    blog,
    mount,
    mediaTool,
    videoPlayer,
    discover,
    pt,
  ];
}

export function createRegistry(): ModuleRegistry {
  const registry = new ModuleRegistry();
  for (const m of moduleList()) registry.add(m);
  return registry;
}
