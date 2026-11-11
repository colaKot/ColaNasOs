#!/usr/bin/env node
/**
 * 本地一键门禁（与 CI 同款）：编译 → lint → 单测 → 契约一致性 → 全部冒烟。
 * 跨平台（不依赖 npm-run-all / shell 的 &&）。
 *
 * 用法：
 *   node tool/verify.js             全量（默认，等价于 npm run verify）
 *   node tool/verify.js --fast      按改动范围选步（本地日常，目标 < 60s）
 *   node tool/verify.js --changed   同 --fast
 *   node tool/verify.js --full      全量 + 500 张缩略图基准
 *   node tool/verify.js --only=smoke:video,test   只跑指定步骤（调试用）
 *   node tool/verify.js --jobs=2    限制并发（默认 min(6, cpus-2)）
 *   node tool/verify.js --fail-fast 首个失败即停止派发
 *
 * 与旧版的差别（2026-11 性能改造，见 AGENTS.md §4）：
 *   1. 直接执行 package.json 里的命令，不再套一层 `npm run`（省 ~0.4s/步）；
 *   2. 构建之后并行执行，长任务先派发（LPT），每步独立 dataDir + port:0；
 *   3. 打印每步耗时并把结果写 `dist/verify-report.json`；
 *   4. `--fast` / `--changed` 用 git 改动映射到受影响步骤，不再「每次都全量」。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf-8'));
const commands = pkg.scripts || {};

/** `npm run` 会把 node_modules/.bin 放进 PATH，直连命令时要自己补。 */
const childEnv = Object.assign({}, process.env, {
  PATH: `${path.join(root, 'node_modules', '.bin')}${path.delimiter}${process.env.PATH || ''}`,
});
// 门禁里不需要每条启动日志（pino info 的 JSON 输出约占每步 1~2s 的 I/O）；
// 失败时仍保留 warn/error，`--verbose` 可恢复完整日志。

// ---------------------------------------------------------------- 参数

const argv = process.argv.slice(2);
const option = (name) => {
  const hit = argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : undefined;
};
const has = (name) => argv.includes(`--${name}`);

if (!has('verbose') && !process.env.LOG_LEVEL) childEnv.LOG_LEVEL = 'warn';

const mode = has('full') ? 'full' : has('fast') || has('changed') ? 'changed' : 'default';
const only = (option('only') || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const failFast = has('fail-fast');
const retry = Number(option('retry') || 0);
const jobs = Math.max(
  1,
  Number(option('jobs')) || Math.min(6, Math.max(2, os.cpus().length - 2)),
);
const base = option('base') || 'HEAD';

// ---------------------------------------------------------------- 步骤表

/**
 * est：本机实测耗时（ms，2026-11 基线 569.9s），用于「长任务先派发」排序。
 * 不追求精确，只保证长尾（behavior / dart-pkgs / media / video）先占坑。
 */
const STEPS = [
  { script: 'build', label: '编译 TypeScript', est: 2500, layer: 'build' },
  { script: 'lint', label: 'ESLint', est: 6700 },
  { script: 'errors.check', label: '错误码一致性（Err 常量 / 契约登记）', est: 470 },
  { script: 'test', label: 'node:test 单测', est: 21700 },
  { script: 'gen.check', label: 'OpenAPI 与代码一致', est: 11100 },
  { script: 'gen:errors.check', label: '错误码表与契约一致', est: 520 },
  { script: 'gen:play-quality.check', label: '画质档位与 sidecar / 服务端一致', est: 470 },
  { script: 'gen:client.check', label: 'Dart client/models 一致', est: 490 },
  { script: 'gen:apps.check', label: 'AppRegistry 一致', est: 550 },
  { script: 'app-nav.check', label: '菜单契约 ↔ 页面实现', est: 300 },
  { script: 'gen:caps.check', label: '端能力矩阵生成物一致', est: 520 },
  { script: 'version:check', label: '版本单一真源（package / pubspec / 鸿蒙）', est: 420 },
  { script: 'gen:locales.check', label: '语言开关（覆盖率派生 enabled）', est: 460 },
  { script: 'gen:i18n.check', label: 'i18n 骨架一致', est: 420 },
  { script: 'api:doc.check', label: 'API 文档与契约一致', est: 400 },
  { script: 'verify:contract', label: '破坏性变更检测', est: 590 },
  { script: 'sbom.check', label: 'SBOM 与依赖一致', est: 530 },
  { script: 'i18n.glossary', label: 'i18n 占位符 / 术语', est: 520 },
  { script: 'i18n.keys.check', label: 'i18n 键存在（tr 不留裸键名）', est: 480 },
  { script: 'compat.i18n.check', label: 'compat 中文表缺键（不留英文键名）', est: 300 },
  { script: 'scope.catalog.check', label: '权限域清单（服务端 secured ↔ 客户端勾选项）', est: 260 },
  { script: 'smoke:abi', label: '原生模块 ABI', est: 570 },
  { script: 'smoke:db', label: 'DB / 迁移 / 队列', est: 720 },
  { script: 'smoke:task', label: '任务队列（执行 / 重试 / 去重 / 取消 / 恢复）', est: 4470 },
  { script: 'smoke:api', label: '鉴权 / 越权 / 越界', est: 4160 },
  { script: 'smoke:upload', label: '分片上传', est: 4640 },
  { script: 'smoke:download', label: 'Range 下载', est: 4190 },
  { script: 'smoke:thumb', label: '缩略图（sidecar / 缓存 / 越界）', est: 5210 },
  { script: 'smoke:dart', label: '契约 ↔ Dart 生成物', est: 630 },
  { script: 'smoke:i18n', label: 'i18n / AppRegistry', est: 640 },
  { script: 'caps.check', label: '端能力矩阵（契约 / 文档 / 接线）', est: 570 },
  { script: 'ohos.check', label: '鸿蒙端工程（bundleName / 版本 / 入口）', est: 2070 },
  { script: 'smoke:sidecar', label: 'Sidecar 守护（启动/心跳/重启）', est: 1350 },
  { script: 'smoke:indexer', label: '索引批量写（批大小/事务/续传）', est: 6790 },
  { script: 'smoke:files-index', label: 'files 索引器接入（入队 / 落库 / 搜索 / 幂等 / 权限）', est: 4660 },
  { script: 'smoke:files-op', label: 'files 写操作（新建 / 改名 / 移动 / 回收站 / 越界拦截）', est: 3000 },
  { script: 'smoke:cache', label: '缓存命中统计（埋点 / 只读接口 / 权限）', est: 4270 },
  { script: 'smoke:bootstrap', label: '首次安装引导 / 开发令牌默认关闭', est: 4390 },
  { script: 'smoke:auth-secret', label: 'JWT 密钥持久化（重启不踢客户端）', est: 400 },
  { script: 'smoke:ai', label: 'AI 推理（会话串行 / EP 白名单）', est: 1450 },
  { script: 'smoke:media', label: '缩略图 / 转码会话复用', est: 49400 },
  { script: 'smoke:updater', label: '版本目录 / 签名 / 防降级', est: 600 },
  { script: 'smoke:dart-pkgs', label: 'Dart 包 analyze / test', est: 86000 },
  { script: 'smoke:system', label: '系统监控 / 进程', est: 6150 },
  { script: 'smoke:https', label: 'HTTPS 入口（用户上传证书）', est: 8000 },
  { script: 'smoke:terminal', label: '交互式终端（PTY / 鉴权 / 会话回收）', est: 11980 },
  { script: 'smoke:rss', label: 'RSS 订阅 / 解析', est: 4090 },
  { script: 'smoke:discover-shell', label: '影视发现移植（评分体系 / 站点测试 / 规则 / 订阅）', est: 4500 },
  { script: 'smoke:catalog', label: '榜单快照（TMDB / 日系共用落库 + 清理）', est: 5200 },
  { script: 'smoke:catalog-live', label: '榜单链路（假上游：抓取 → 落库 → 降级 / 回退）', est: 6500 },
  { script: 'smoke:sync', label: '同步 / 冲突策略', est: 4170 },
  { script: 'smoke:auth', label: '登录 / 2FA / IP 黑名单', est: 4530 },
  { script: 'smoke:webhook', label: 'Webhook 签名 / 重试', est: 4620 },
  { script: 'smoke:photo', label: '相册库 / 时间轴 / 相册', est: 4540 },
  { script: 'smoke:photo-media', label: '动态照片 / 视频元数据与 Range', est: 2100 },
  { script: 'smoke:photo-backup-dedup', label: '备份内容去重 / 原始指纹 / GPS 改写不重传', est: 2200 },
  { script: 'smoke:watch', label: '文件监控（自动增量入库 / 忽略规则 / 不误删）', est: 6780 },
  { script: 'smoke:video-duplicates', label: '影视查重（四钥匙分组 / 角标 / 删除进回收站）', est: 3000 },
  { script: 'smoke:video-image', label: '图片库 / 混合库（排序 / 文件夹 / 首页 / 删除）', est: 5000 },
  { script: 'smoke:video', label: '影视库 / 探测 / 海报', est: 26050 },
  { script: 'smoke:video-series', label: '剧集识别 / 季集列表', est: 4630 },
  { script: 'smoke:video-progress', label: '观看进度（隔离 / 排序）', est: 4420 },
  { script: 'smoke:subtitles', label: '外挂字幕（发现 / srt·ass·vtt / WebVTT）', est: 4440 },
  { script: 'smoke:music', label: '音乐库 / tags / 封面 / 歌单', est: 5740 },
  { script: 'smoke:music-compat', label: '音乐兼容层（既有实现 形状 / int id / 偏移分页）', est: 3200 },
  { script: 'smoke:music-detail', label: '专辑/歌手详情 + Last.fm（热度 / 绑定 / Scrobble 签名）', est: 5200 },
  { script: 'smoke:lyrics', label: '歌词（LRC / ID3 / Vorbis / MP4）', est: 5650 },
  { script: 'smoke:blog', label: 'AI 播客（设置 / 文案 / 试听缓存降级）', est: 4200 },
  { script: 'smoke:player', label: 'HLS 转码会话 / 字幕烧录 / 分片访问', est: 6300 },
  { script: 'smoke:state', label: '书籍全文检索（FTS5）/ 音乐收藏与历史', est: 5150 },
  { script: 'smoke:extras', label: '离线刮削 / 加密空间导出 / 受限命令', est: 5630 },
  { script: 'smoke:photo-ai', label: '照片智能（人脸 / 场景 / 以图搜图）', est: 8890 },
  { script: 'smoke:photo-retrieval', label: '相册检索链路（联想 / 关系图 / 预演撤销 / 重扫 / 分项重识别）', est: 5110 },
  { script: 'smoke:pt', label: 'PT 站点 / 搜索 / 择种 / transmission / 留痕', est: 4660 },
  { script: 'fonts:check', label: 'Web 中文字体本地镜像', est: 520 },
  { script: 'migrate:verify', label: '迁移顺序清单（未登记即失败）', est: 950 },
  { script: 'sdk.check', label: 'SDK（TypeScript / Python）与契约一致', est: 520 },
  { script: 'smoke:mcp', label: 'MCP server（stdio JSON-RPC 只读工具）', est: 5210 },
  { script: 'behavior', label: '行为用例（DSL：四角色 / 越权 / 业务链路）', est: 148000 },
  { script: 'behavior:matrix.check', label: '行为用例覆盖矩阵（域 × 四角色）未过期', est: 760 },
];

// ---------------------------------------------------------------- 改动 → 步骤

/**
 * `--fast`：只跑受影响的域。规则保守——命中不了就退回全量，
 * 宁可多跑也不把真实回归漏掉。
 */
const MODULE_RULES = [
  { dir: 'auth', steps: ['smoke:api', 'smoke:auth', 'smoke:bootstrap', 'smoke:auth-secret'], domains: ['auth'] },
  { dir: 'blog', steps: ['smoke:blog'], domains: [] },
  { dir: 'discover', steps: ['smoke:pt', 'smoke:catalog', 'smoke:catalog-live', 'smoke:discover-shell'], domains: [] },
  { dir: 'files', steps: ['smoke:upload', 'smoke:download', 'smoke:thumb', 'smoke:indexer', 'smoke:files-index', 'smoke:files-op', 'smoke:watch'], domains: [] },
  { dir: 'integrations', steps: ['smoke:webhook'], domains: ['webhook'] },
  { dir: 'media', steps: ['smoke:media', 'smoke:thumb'], domains: [] },
  { dir: 'music', steps: ['smoke:music', 'smoke:music-compat', 'smoke:music-detail', 'smoke:lyrics'], domains: ['music'] },
  { dir: 'photo', steps: ['smoke:photo', 'smoke:photo-ai', 'smoke:photo-media', 'smoke:photo-retrieval', 'smoke:photo-backup-dedup'], domains: ['photo'] },
  { dir: 'pt', steps: ['smoke:pt', 'smoke:discover-shell'], domains: [] },
  { dir: 'rss', steps: ['smoke:rss'], domains: ['rss'] },
  { dir: 'sync', steps: ['smoke:sync'], domains: ['sync'] },
  { dir: 'system', steps: ['smoke:system', 'smoke:https', 'smoke:terminal'], domains: ['system'] },
  { dir: 'video', steps: ['smoke:video-duplicates', 'smoke:video-image', 'smoke:video', 'smoke:video-series', 'smoke:video-progress', 'smoke:subtitles', 'smoke:player'], domains: ['video'] },
  { dir: 'videoPlayer', steps: ['smoke:player'], domains: ['video'] },
  { dir: 'transfer', steps: ['smoke:transfer', 'smoke:upload', 'smoke:download'], domains: [] },
];

const FULL_TRIGGERS = [
  /^kernel\//,
  /^tool\//,
  /^electron\//,
  /^package(-lock)?\.json$/,
  /^tsconfig\.json$/,
  /^eslint\.config\.mjs$/,
];

const CONTRACT_STEPS = [
  'errors.check',
  'gen.check',
  'gen:errors.check',
  'gen:play-quality.check',
  'gen:client.check',
  'gen:apps.check',
  'app-nav.check',
  'gen:caps.check',
  'gen:locales.check',
  'gen:i18n.check',
  'api:doc.check',
  'verify:contract',
  'sbom.check',
  'i18n.glossary',
  'i18n.keys.check',
  'compat.i18n.check',
  'scope.catalog.check',
  'version:check',
  'caps.check',
  'migrate:verify',
  'sdk.check',
  'smoke:dart',
  'smoke:i18n',
];

function changedFiles() {
  // 关掉 quotepath：中文路径否则会变成 `"docs/\350\227..."` 这种带引号的
  // 转义串，路径规则全部匹配不到，保守逻辑直接把 --fast 推成全量。
  const run = (args) =>
    spawnSync('git', ['-c', 'core.quotepath=false', ...args], {
      cwd: root,
      encoding: 'utf-8',
    }).stdout || '';
  const out = new Set();
  for (const line of run(['diff', '--name-only', '--diff-filter=ACMRTUXB', base]).split('\n')) {
    if (line.trim()) out.add(line.trim());
  }
  for (const line of run(['ls-files', '--others', '--exclude-standard']).split('\n')) {
    const p = line.trim().replace(/\\/g, '/');
    if (!p) continue;
    // 只把工程源码目录下的新文件算成改动。工作区里常有旁支草稿
    // （AI 播客脚本、音频、临时稿），它们不会被任何门禁步骤消费，
    // 却会因为落在 `tool/` 下命中 FULL_TRIGGERS，把 --fast 推成 80 步全量。
    if (
      !/^(src|contracts|apps|packages|sdk|test|sidecars|web|resources|electron|kernel|tool\/check|tool\/smoke|tool\/gen)/.test(
        p,
      )
    )
      continue;
    out.add(p);
  }
  return [...out];
}

function selectSteps(files) {
  const pick = new Set(['build', 'lint', 'test']);
  const domains = new Set();
  let full = false;
  // 退全量时把「是谁触发的」记下来：以前只打印一句「改动超出已知域」，
  // 工作区堆了几十个未提交文件时根本看不出该提交哪个 / 该用 --base 跳过哪个。
  const fullTriggers = [];
  const markFull = (why) => {
    full = true;
    fullTriggers.push(why);
  };

  if (files.length === 0) {
    CONTRACT_STEPS.forEach((s) => pick.add(s));
    return { steps: STEPS.filter((s) => pick.has(s.script)), domains: [], reason: '工作区无改动，只跑静态层与单测' };
  }

  for (const f of files) {
    const p = f.replace(/\\/g, '/');
    if (/^(docs\/|mypic\/|\.arts\/|\.codegraph\/|\.workbuddy\/)/.test(p)) continue;
    if (/^(\.tmp-|\.merkle-snapshot\.json$|vr9\.txt$)/.test(p)) continue;
    // 纯仓库元文件不被任何门禁步骤消费（`.gitignore` 加一行 tool/tmp/ 也
    // 不该把 --fast 推成 80 步）。2026-11-07 实测踩过。
    if (/^\.(gitignore|gitattributes|editorconfig|npmrc|prettierrc)(\.json)?$/.test(p)) continue;
    // kernel 里的「纯类型 / sidecar 桥 / 迁移清单」不写业务逻辑：
    // 编译 + lint + 全量单测 + 契约层 + 相关 smoke 已经覆盖，不必退全量。
    // 这条必须排在 FULL_TRIGGERS（含 /^kernel\//）之前，否则永远轮不到。
    // 真正的内核实现（kernel/index.ts、kernel/route.ts …）仍旧保守全量。
    if (/^kernel\/(types\.ts|sidecar\/media-bridge\.ts|migrations\/manifest\.ts)$/.test(p)) {
      CONTRACT_STEPS.forEach((s) => pick.add(s));
      ['smoke:player', 'smoke:media', 'smoke:db', 'behavior'].forEach((s) => pick.add(s));
      domains.add('video');
      continue;
    }
    // 改「门禁 / 冒烟脚本本身」不该把整条门禁推成全量：用 package.json 的命令
    // 反查哪些步骤真的会执行这个文件，只跑那几步 + 基础层。
    // 以前 /^tool\// 无条件 full，改一个 player-smoke.js 就跑满 80 步；
    // 上次只挡住了落在 tool/ 下的未跟踪草稿，已跟踪的 check 脚本仍会误伤。
    // 反查不到任何已登记步骤（例如改了脚本却没有对应门禁）仍保守退全量。
    if (/^tool\//.test(p)) {
      const rel = p.replace(/\\/g, '/');
      // 改的是编排器自己：只影响「选哪些步」，不影响产物。
      // 反查 package.json 只会命中 verify / verify:fast / verify:full，
      // 它们都不在 STEPS 里 → 会被判成「反查不到」而退全量，等于改一次
      // 脚本就把之后的 --fast 全废掉。这里显式放行到基础层 + 契约层。
      if (rel === 'tool/verify.js') {
        CONTRACT_STEPS.forEach((s) => pick.add(s));
        continue;
      }
      const known = new Set(STEPS.map((s) => s.script));
      const hits = Object.entries(commands)
        .filter(([, cmd]) => typeof cmd === 'string' && cmd.includes(rel))
        .map(([name]) => name)
        .filter((name) => known.has(name));
      if (hits.length === 0) {
        markFull(`${p} → tool/ 反查不到对应门禁步骤`);
        continue;
      }
      hits.forEach((s) => pick.add(s));
      continue;
    }
    if (FULL_TRIGGERS.some((re) => re.test(p))) {
      markFull(`${p} → FULL_TRIGGERS（内核实现 / 脚本注册表，按设计全量）`);
      continue;
    }
    // `test/` 下的单测由基础 `test` 步骤（`node --test test/*.test.ts`）全量执行，
    // 新增 / 改一个单测不该让整条门禁退回全量。以前没这条规则，
    // 加一个 test/video-xxx.test.ts 就会触发「未识别路径 → full」跑满 80 步。
    if (/^test\//.test(p)) continue;
    const mod = /^src\/modules\/([^/]+)\//.exec(p);
    if (mod) {
      const rule = MODULE_RULES.find((r) => r.dir === mod[1]);
      if (!rule) {
        markFull(`${p} → MODULE_RULES 未登记模块 ${mod[1]}`);
        continue;
      }
      rule.steps.forEach((s) => pick.add(s));
      rule.domains.forEach((d) => domains.add(d));
      continue;
    }
    if (/^contracts\//.test(p)) {
      CONTRACT_STEPS.forEach((s) => pick.add(s));
      continue;
    }
    if (/^(apps|packages|sdk)\//.test(p)) {
      pick.add('smoke:dart-pkgs');
      pick.add('smoke:dart');
      pick.add('app-nav.check');
      continue;
    }
    if (/^docs\/api\//.test(p)) {
      pick.add('api:doc.check');
      continue;
    }
    if (/^(web\/|resources\/)/.test(p)) {
      pick.add('fonts:check');
      continue;
    }
    if (/^(docs\/|mypic\/)/.test(p)) continue;
    // media sidecar 只影响转码 / 缩略图链路，改它不需要把全网 smoke 跑一遍。
    if (/^sidecars\/media\//.test(p)) {
      ['smoke:media', 'smoke:thumb', 'smoke:player', 'smoke:video'].forEach((s) => pick.add(s));
      domains.add('video');
      continue;
    }
    // photo-ai sidecar 之前没映射，落进 `^sidecars/` 的保守分支 → 改一个
    // OCR 脚本就退全量。它只影响 AI 识别链路，跑 photo 域即可。
    if (/^sidecars\/photo-ai\//.test(p)) {
      ['smoke:photo-ai', 'smoke:photo'].forEach((s) => pick.add(s));
      domains.add('photo');
      continue;
    }
    if (/^src\//.test(p) || /^sidecars\//.test(p)) {
      markFull(`${p} → src/sidecars 未识别路径`);
      continue;
    }
    // 未识别路径：保守全量
    markFull(`${p} → 未识别路径`);
  }

  if (full) {
    const shown = fullTriggers.slice(0, 6).join('；');
    const more = fullTriggers.length > 6 ? `；…另 ${fullTriggers.length - 6} 个` : '';
    return {
      steps: STEPS.slice(),
      domains: null,
      reason: `改动超出已知域，退回全量（触发：${shown}${more}）`,
    };
  }
  // src / contracts 改动都要校验契约层
  if (files.some((f) => /^(src|contracts)\//.test(f.replace(/\\/g, '/')))) {
    CONTRACT_STEPS.forEach((s) => pick.add(s));
  }
  // 有域命中时，behavior 只跑这些域（省掉其余 100+ 例）
  if (domains.size > 0) pick.add('behavior');
  const steps = STEPS.filter((s) => pick.has(s.script));
  return {
    steps,
    domains: [...domains],
    reason: `按改动选择 ${steps.length} 步（域：${[...domains].join(',') || '无'}）`,
  };
}

// ---------------------------------------------------------------- 执行

function resolveCommand(step) {
  if (step.command) return step.command;
  const baseCmd = commands[step.script];
  if (!baseCmd) throw new Error(`package.json 缺少 script: ${step.script}`);
  if (!step.args || step.args.length === 0) return baseCmd;
  return `${baseCmd} ${step.args.join(' ')}`;
}

function runStep(step) {
  return new Promise((resolve) => {
    let cmd;
    try {
      cmd = resolveCommand(step);
    } catch (err) {
      resolve({ ok: false, ms: 0, output: String(err) });
      return;
    }
    const t0 = Date.now();
    let output = '';
    let child;
    try {
      child = spawn(cmd, { cwd: root, shell: true, windowsHide: true, env: childEnv });
    } catch (err) {
      resolve({ ok: false, ms: Date.now() - t0, output: String(err) });
      return;
    }
    child.stdout.on('data', (d) => (output += d));
    child.stderr.on('data', (d) => (output += d));
    child.on('error', (err) => {
      output += String(err);
    });
    child.on('close', (code) => resolve({ ok: code === 0, ms: Date.now() - t0, output }));
  });
}

async function pool(items, limit, worker, onDone) {
  const results = new Array(items.length);
  let cursor = 0;
  let active = 0;
  let stopped = false;

  return new Promise((resolve) => {
    const pump = () => {
      if (stopped) {
        if (active === 0) resolve(results);
        return;
      }
      while (active < limit && cursor < items.length) {
        const index = cursor;
        const item = items[cursor++];
        active++;
        worker(item, index).then((r) => {
          results[index] = r;
          active--;
          if (onDone) {
            const stop = onDone(item, r);
            if (stop) stopped = true;
          }
          pump();
        });
      }
      if (active === 0 && cursor >= items.length) resolve(results);
    };
    pump();
  });
}

async function main() {
  const started = Date.now();
  const fakeFiles = option('files');
  const files =
    mode === 'changed' ? (fakeFiles ? fakeFiles.split(',').map((s) => s.trim()).filter(Boolean) : changedFiles()) : [];
  const selection = mode === 'changed' ? selectSteps(files) : { steps: STEPS.slice(), domains: null };

  let steps = selection.steps.map((s) => ({ ...s }));
  if (mode === 'full') {
    const media = steps.find((s) => s.script === 'smoke:media');
    if (media) media.args = ['--count=500'];
  } else {
    const media = steps.find((s) => s.script === 'smoke:media');
    // 日常门禁只跑采样；500 张基准留给 --full / npm run bench:media
    if (media) media.args = ['--count=50'];
  }
  if (selection.domains && selection.domains.length > 0) {
    const behavior = steps.find((s) => s.script === 'behavior');
    if (behavior) behavior.args = [`--domains=${selection.domains.join(',')}`, `--jobs=${jobs}`];
  } else if (steps.some((s) => s.script === 'behavior')) {
    const behavior = steps.find((s) => s.script === 'behavior');
    if (behavior) behavior.args = [`--jobs=${jobs}`];
  }
  if (selection.domains && selection.domains.length === 0) {
    steps = steps.filter((s) => s.script !== 'behavior');
  }
  if (only.length > 0) {
    steps = STEPS.filter((s) => only.includes(s.script)).map((s) => ({ ...s }));
  }
  const pkg = steps.find((s) => s.script === 'smoke:dart-pkgs');
  if (pkg) pkg.args = [`--jobs=${jobs}`];

  if (has('dry-run')) {
    if (mode === 'changed') console.log(`[verify] ${selection.reason}（${files.length} 个改动文件）`);
    console.log(`[verify] dry-run: ${steps.map((s) => s.script).join(', ')}`);
    process.exit(0);
  }

  console.log(
    `[verify] mode=${mode}${only.length ? ` only=${only.join(',')}` : ''} jobs=${jobs}` +
      `${mode === 'changed' ? ` base=${base}` : ''}`,
  );
  if (mode === 'changed') {
    console.log(`[verify] ${selection.reason}（${files.length} 个改动文件）`);
    if (files.length && files.length <= 12) console.log(`[verify] ${files.join(', ')}`);
  }

  const build = steps.filter((s) => s.layer === 'build');
  const rest = steps.filter((s) => s.layer !== 'build');

  const results = [];
  for (const step of build) {
    const r = await runStep(step);
    results.push({ step, ...r });
    console.log(
      `${r.ok ? '[OK]  ' : '[FAIL]'} ${step.script.padEnd(22)} ${step.label}  ${(r.ms / 1000).toFixed(1)}s`,
    );
    if (!r.ok) {
      console.error(r.output.split('\n').slice(-25).join('\n'));
      break;
    }
  }
  if (results.some((r) => !r.ok && r.step.layer === 'build')) {
    return finish(results, started, steps.length);
  }

  // 预生成「已跑完迁移」的空库模板：命中缓存时不到 1s，可省掉每个 smoke 重复迁移的 2~3s。
  // 生成失败不回退门禁本身（各步会自己跑迁移，只是慢一点）。
  const tpl = await runStep({ script: 'template', command: 'node tool/gen-kernel-template.js' });
  if (tpl.ok) {
    const dir = (tpl.output || '').trim().split('\n').filter(Boolean).pop();
    if (dir && fs.existsSync(path.join(dir, 'colanas.sqlite'))) {
      childEnv.COLANAS_KERNEL_TEMPLATE = dir;
      console.log(`[OK]   template               内核迁移模板（复用）  ${(tpl.ms / 1000).toFixed(1)}s`);
    }
  } else {
    console.warn(`[warn] 内核迁移模板生成失败，回退逐次迁移：${(tpl.output || '').split('\n').slice(-3).join(' ')}`);
  }

  // 长任务先派发，缩短总跨度
  const order = rest.slice().sort((a, b) => (b.est || 0) - (a.est || 0));
  await pool(
    order,
    jobs,
    async (step) => {
      let r = await runStep(step);
      for (let i = 0; i < retry && !r.ok; i++) r = await runStep(step);
      return r;
    },
    (step, r) => {
      results.push({ step, ...r });
      console.log(
        `${r.ok ? '[OK]  ' : '[FAIL]'} ${step.script.padEnd(22)} ${step.label}  ${(r.ms / 1000).toFixed(1)}s`,
      );
      if (!r.ok) {
        console.error(`\n--- ${step.script} ---`);
        console.error(r.output.split('\n').slice(-25).join('\n'));
      }
      return failFast && !r.ok;
    },
  );

  return finish(results, started, steps.length);
}

function finish(results, started, planned) {
  const failed = results.filter((r) => !r.ok);
  const total = Date.now() - started;
  const slow = results
    .slice()
    .sort((a, b) => b.ms - a.ms)
    .slice(0, 8)
    .map((r) => `${r.step.script}=${(r.ms / 1000).toFixed(1)}s`)
    .join('  ');

  console.log(
    `\n[verify] ${results.length - failed.length}/${planned} passed, ` +
      `${(total / 1000).toFixed(1)}s（串行基线 569.9s）`,
  );
  console.log(`[verify] 慢步 Top8: ${slow}`);

  try {
    const dir = path.join(root, 'dist');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'verify-report.json'),
      JSON.stringify(
        {
          generatedAt: new Date().toISOString(),
          mode,
          totalMs: total,
          planned,
          passed: results.length - failed.length,
          failed: failed.length,
          steps: results
            .slice()
            .sort((a, b) => b.ms - a.ms)
            .map((r) => ({ script: r.step.script, label: r.step.label, ok: r.ok, ms: r.ms })),
        },
        null,
        2,
      ),
      'utf-8',
    );
  } catch {
    /* 报告写失败不影响门禁结果 */
  }

  process.exit(failed.length ? 1 : 0);
}

main().catch((err) => {
  console.error('[verify] FATAL', err);
  process.exit(2);
});