#!/usr/bin/env node
/**
 * 把 docs/wiki/*.md 同步到 GitHub + GitCode 两个 Wiki 仓库。
 *
 * 用法：
 *   node tool/sync-wiki.js              # 同步并推送到两个平台
 *   node tool/sync-wiki.js --dry-run    # 只看会推什么
 *   node tool/sync-wiki.js --only=github|gitcode   # 只推某一个平台
 *
 * 约定：
 *   - 源文件在 docs/wiki/，文件名即 wiki 页面名（_Sidebar / _Footer 是 GitHub 的特殊页）。
 *   - 目标仓库：
 *       GitHub  https://github.com/<owner>/<repo>.wiki.git   （HTTPS + 系统 git credential）
 *       GitCode git@gitcode.com:<owner>/<repo>.wiki.git       （SSH key；密码认证已被 GitCode 禁用）
 *   - 认证不落盘明文：GitHub 走 Git Credential Manager，GitCode 走 ~/.ssh 私钥。
 *
 * ⚠️ wiki 仓库在仓库创建后的第一次推送时才会被平台建出来。克隆报
 * 「Repository not found」时，先用平台 API 建一个页面，之后本脚本就能正常克隆。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const srcDir = path.join(root, 'docs', 'wiki');
const dryRun = process.argv.includes('--dry-run');
const onlyArg = process.argv.find((a) => a.startsWith('--only='));
const only = onlyArg ? onlyArg.slice('--only='.length) : null;

const targets = [
  {
    key: 'github',
    label: 'GitHub',
    remote: `https://github.com/${process.env.WIKI_OWNER || 'colaKot'}/${process.env.WIKI_REPO || 'ColaNasOs'}.wiki.git`,
    env: {},
  },
  {
    key: 'gitcode',
    label: 'GitCode',
    remote: `git@gitcode.com:${process.env.WIKI_GITCODE_OWNER || 'cocacola23'}/${process.env.WIKI_GITCODE_REPO || 'ColaNasOs'}.wiki.git`,
    // GitCode 已移除密码认证；强制 BatchMode 用 SSH key，避免卡在交互输入
    env: { GIT_SSH_COMMAND: 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new' },
  },
].filter((t) => !only || t.key === only);

if (only && targets.length === 0) fail(`--only 只能是 github / gitcode，收到：${only}`);

function git(args, cwd, extraEnv = {}) {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, ...extraEnv },
  });
}

function fail(msg) {
  console.error(`[sync-wiki] ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(srcDir)) fail(`找不到源目录：${srcDir}`);
// README.md 是仓库内的维护说明，不发布成 wiki 页面
const files = fs
  .readdirSync(srcDir)
  .filter((f) => f.endsWith('.md') && f !== 'README.md');
if (files.length === 0) fail(`${srcDir} 里没有 .md 文件`);

const src = Object.fromEntries(files.map((f) => [f, fs.readFileSync(path.join(srcDir, f), 'utf8')]));

for (const target of targets) {
  const work = path.join(os.tmpdir(), `colanas-wiki-${target.key}-${process.pid}`);
  fs.rmSync(work, { recursive: true, force: true });
  console.log(`[sync-wiki/${target.key}] 目标：${target.remote}`);

  try {
    try {
      git(['clone', target.remote, work], process.cwd(), target.env);
    } catch (e) {
      const msg = String(e.stderr || e.message || '');
      if (/Repository not found|not found/i.test(msg)) {
        console.error(
          `[sync-wiki/${target.key}] wiki 仓库还不存在（${target.remote}）。\n` +
            '  先用平台 API 建一个首页，让 wiki 仓库初始化出来，再跑本脚本。'
        );
        process.exitCode = 1;
        continue;
      }
      console.error(`[sync-wiki/${target.key}] 克隆失败：${msg.trim()}`);
      process.exitCode = 1;
      continue;
    }

    // 让 git 用固定的提交身份（wiki 仓库未必配置 user.name/email）
    git(['config', 'user.name', 'ColaNasOs Bot'], work, target.env);
    git(['config', 'user.email', 'bot@colanas.local'], work, target.env);

    // 拷贝页面文件
    let changed = 0;
    for (const f of files) {
      const dst = path.join(work, f);
      const before = fs.existsSync(dst) ? fs.readFileSync(dst, 'utf8') : null;
      if (before !== src[f]) {
        fs.writeFileSync(dst, src[f], 'utf8');
        changed += 1;
      }
    }

    // 删掉源目录里已经没有的非 .md 文件（保留 .git 和所有 .md 页面）
    // 不删 .md：避免误删平台上手动建的页面
    for (const f of fs.readdirSync(work)) {
      if (f === '.git' || f.endsWith('.md')) continue;
      fs.rmSync(path.join(work, f), { recursive: true, force: true });
      changed += 1;
    }

    console.log(`[sync-wiki/${target.key}] 页面 ${files.length} 个，变更 ${changed} 个`);
    if (changed === 0) {
      console.log(`[sync-wiki/${target.key}] 没有变化，跳过推送`);
      continue;
    }
    if (dryRun) {
      console.log(`[sync-wiki/${target.key}] --dry-run：不提交不推送`);
      continue;
    }

    git(['add', '-A'], work, target.env);
    git(['commit', '-m', `docs(wiki): 同步 ${changed} 个页面（${new Date().toISOString().slice(0, 10)}）`], work, target.env);
    git(['push', 'origin', 'HEAD'], work, target.env);
    console.log(`[sync-wiki/${target.key}] 已推送 → ${target.remote}`);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}
