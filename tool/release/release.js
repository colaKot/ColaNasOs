#!/usr/bin/env node
'use strict';
/**
 * 一次发版的全部产物：版本目录 + 版本清单 + 增量包 + update.json。
 *
 *   node tool/release/release.js --out=dist_release --tag=v1.3.14 \
 *        --from=dist_release/D10313 \
 *        --url-base=https://gitcode.com/colaKot/ColaNasOs/releases/download/v1.3.14,\
https://github.com/colaKot/ColaNasOs/releases/download/v1.3.14 \
 *        --pc-setup=dist_installer/ColaNasOs-Client-1.3.14-Setup.exe \
 *        --apk=dist_installer/ColaNasOs-Client-1.3.14-android-arm64.apk \
 *        --notes-zh="修复…"
 *
 * 产物（全部可以原样上传到 Release，**扁平**资产名）：
 *   dist_release/update.json / update.json.sig
 *   dist_release/D10314/            完整版本目录（内含 manifest.json / .sig）
 *   dist_release/assets/            增量资产：*.br、smallfiles-*.brb、manifest-D10314.json
 *
 * 铁律：**清单最后上传**（方案 §10.1）。本工具只负责生成；上传由 publish.js 收尾。
 *
 * 发行方式（2026-11-21 定）：**服务端一律发增量**。
 *   - 增量是默认行为，不是可选项：`--from` 没给就自动取输出目录里上一版作基线；
 *     连基线都找不到直接失败，绝不静默退化成「只发全量」。
 *   - 全量包**始终一起发**，它是「首次安装」和「跨版本跳级」的兜底，不能撤。
 *   - 真要只发全量，必须显式 `--no-delta`，并在提交信息里写明原因。
 *   - 补发场景（发完才发现漏了增量）用 `--reuse-version-dir`：复用已发布的
 *     版本目录，不从当前 `dist/` 重建，避免把发版之后的在途改动混进那一版。
 */
const fs = require('node:fs');
const path = require('node:path');
const L = require('./lib');

const SMALL_FILE_LIMIT = 256 * 1024;

function main() {
  // 补发场景：Release 上已经发出去的那一版未必等于 package.json 的当前值
  // （发版成功后惯例会把版本 bump 到下一版）。显式 `--semver` 以它为准。
  const product = productOverride() ?? L.productVersion();
  const out = path.resolve(L.root, String(L.arg('out', 'dist_release')));
  const tag = String(L.arg('tag', `v${product.semver}`));
  const pre = L.arg('pre') !== undefined;
  const channels = String(L.arg('channel', pre ? 'pre' : 'stable'));
  const fromDirs = resolveBaselines(out, product.version);
  /**
   * 下载源：`<url>[#<资产名后缀>]`，逗号分隔，**顺序即优先级**。
   *
   * 加 `#-v2` 的原因是 GitCode 上的附件可能被平台改过名（同名重传失败后人工加的），
   * 而 GitHub 上是原名。清单里的 urls 是逐条的，所以两边各写各的即可。
   */
  const urlBases = String(L.arg('url-base', ''))
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((spec) => {
      const hash = spec.indexOf('#');
      const url = (hash === -1 ? spec : spec.slice(0, hash)).replace(/\/+$/, '');
      const suffix = hash === -1 ? '' : spec.slice(hash + 1);
      return { url, suffix };
    });

  const id = L.versionId(product.version);
  /** 需要上传的「扁平资产名 → 本地文件」，最后写成 upload.json 给 publish.js */
  const uploads = [];

  console.log(`[release] ${product.semver} → ${id}，输出 ${path.relative(L.root, out)}`);

  // ---- 1. 版本目录 -------------------------------------------------------
  const versionDir = path.join(out, id);
  const reuseVersionDir = L.arg('reuse-version-dir') !== undefined;
  let copied = 0;
  if (reuseVersionDir) {
    // 补发场景：**绝不能**从当前 `dist/` 重建。发版之后往 dist/ 里编译的改动
    // （比如刚修的一个 bug）不属于「已发布的那一版」，混进来会让增量装出来的
    // 内容和 Release 上那个全量包装出来的内容不一致 —— 同一个版本号两种内容。
    if (!fs.existsSync(path.join(versionDir, 'manifest.json'))) {
      L.fail(
        `--reuse-version-dir 需要 ${path.relative(L.root, versionDir)} 已存在且带 manifest.json`,
      );
    }
    console.log(`[release] 复用已有版本目录 ${id}（不重建，保持与已发布内容一致）`);
  } else {
    fs.rmSync(versionDir, { recursive: true, force: true });
    copied = buildVersionDir(versionDir, product);
    L.writeJson(path.join(versionDir, 'version.json'), {
      semver: product.semver,
      version: product.version,
      buildNumber: product.version % 100,
      versionCode: product.version,
    });
  }

  // ---- 2. 版本清单（整体签名）--------------------------------------------
  const { pem } = L.loadPrivateKey();
  const manifest = L.writeManifest(versionDir, product.version, pem);
  const fileCount = Object.keys(manifest.files).length;
  const versionBytes = L.dirBytes(versionDir);
  console.log(`[release] 版本目录 ${fileCount} 个文件 / ${(versionBytes / 1048576).toFixed(1)} MB`);

  // ---- 3. 增量包 ---------------------------------------------------------
  const assetsDir = path.join(out, 'assets');
  fs.rmSync(assetsDir, { recursive: true, force: true });
  L.ensureDir(assetsDir);

  // 清单资产（扁平名），客户端按 urls 直接取
  //
  // 签名文件一律挂 `.sig.json` 后缀（内容 `{keyId, sig}`）。GitCode 的 raw 直链
  // 会拒绝「预览」未知扩展名：`.sig` 直接返 403「暂不支持预览」，只有 `.json`
  // 能直出真文件。`<x>.sig` 仍额外写一份，供离线包与只认老格式的源使用。
  const keyId = String(L.arg('key-id', 'k2026a'));
  // 清单资产名同样跟着内容走（`manifest-D10315-<sha12>.json`）。清单每次重算
  // 都可能变（哪怕只差签名字节），固定名字在 GitCode 上就永远覆盖不掉。
  const manifestDigest = L.sha256FileHex(path.join(versionDir, 'manifest.json')).slice(0, 12);
  const manifestName = `manifest-${id}-${manifestDigest}.json`;
  const manifestSigName = `${manifestName}.sig.json`;
  fs.copyFileSync(path.join(versionDir, 'manifest.json'), path.join(assetsDir, manifestName));
  L.writeJson(path.join(assetsDir, manifestSigName), {
    keyId,
    sig: fs.readFileSync(path.join(versionDir, 'manifest.json.sig'), 'utf8').trim(),
  });
  // 老格式再留一份（88 字节）：离线目录与只认 `.sig` 的源还在用它
  fs.copyFileSync(
    path.join(versionDir, 'manifest.json.sig'),
    path.join(assetsDir, `${manifestName}.sig`),
  );

  let delta = null;
  if (fromDirs.length > 0) {
    delta = buildDelta({
      versionDir,
      assetsDir,
      manifest,
      baselines: fromDirs,
      urlBases,
      manifestName,
    });
  } else if (L.arg('no-delta') !== undefined) {
    console.log('[release] --no-delta：本次只发全量 / 清单（这一版的服务端无法增量升级）');
  } else {
    L.fail(
      `找不到增量基线：${path.relative(L.root, out)} 下没有更旧的 D<NNN> 版本目录。\n` +
        '  增量是服务端的默认发行方式，不允许静默退化成只发全量。\n' +
        '  · 有旧版本目录 → 用 --from=<目录> 指定基线（可重复传多个）\n' +
        '  · 确实做不出可用增量 → 显式加 --no-delta，并在提交信息里写明原因',
    );
  }

  // ---- 4. update.json ----------------------------------------------------
  const serverFull = packageAsset('setup');
  const update = {
    schema: 1,
    channel: channels,
    releasedAt: new Date().toISOString(),
    keyId,
    ...(L.arg('min-shell') ? { minShell: String(L.arg('min-shell')) } : {}),
    notes: notes(),
    components: {
      server: {
        semver: product.semver,
        version: product.version,
        ...(delta ? { delta } : {}),
        ...(serverFull ? { full: serverFull } : {}),
      },
    },
  };
  const pc = clientComponent('client_pc');
  if (pc) update.components.client_pc = pc;
  const android = clientComponent('client_android');
  if (android) update.components.client_android = android;

  // 通道决定清单文件名：正式版 `update.json`，预发布 `update-pre.json`。
  // 两份都是完整清单（各自签名），客户端按设置里的通道选一个读。
  const updateName = channels === 'pre' ? 'update-pre.json' : 'update.json';
  const updatePath = path.join(out, updateName);
  const text = `${JSON.stringify(update, null, 2)}\n`;
  fs.writeFileSync(updatePath, text, 'utf8');
  const sig = require('node:crypto').sign(null, Buffer.from(text, 'utf8'), pem).toString('base64');
  fs.writeFileSync(`${updatePath}.sig`, sig, 'utf8');
  L.writeJson(`${updatePath}.sig.json`, { keyId, sig });

  // 清单要发布到**仓库里的 release/ 目录**（raw 直链，地址稳定）：
  // GitCode 的 releases/latest/download 返回 HTML，Release 资产没法当稳定清单源
  const manifestOut = L.arg('manifest-out');
  if (manifestOut) {
    const dir = path.resolve(L.root, String(manifestOut));
    L.ensureDir(dir);
    fs.copyFileSync(updatePath, path.join(dir, updateName));
    fs.copyFileSync(`${updatePath}.sig`, path.join(dir, `${updateName}.sig`));
    fs.copyFileSync(`${updatePath}.sig.json`, path.join(dir, `${updateName}.sig.json`));
    console.log(
      `[release] 清单 ${updateName} 已复制到 ${path.relative(L.root, dir)}/（提交并 push 即发布；` +
        'raw 直链地址不随版本变化）',
    );
  }

  for (const name of fs.readdirSync(assetsDir)) {
    uploads.push({ name, file: path.join(assetsDir, name) });
  }
  uploads.push({ name: updateName, file: updatePath });
  uploads.push({ name: `${updateName}.sig`, file: `${updatePath}.sig` });
  uploads.push({ name: `${updateName}.sig.json`, file: `${updatePath}.sig.json` });
  flushUploads();

  // ---- 5. 汇总 -----------------------------------------------------------
  const assetFiles = fs.readdirSync(assetsDir);
  const assetBytes = assetFiles.reduce((s, n) => s + fs.statSync(path.join(assetsDir, n)).size, 0);
  console.log(
    `[release] 增量资产 ${assetFiles.length} 个 / ${(assetBytes / 1048576).toFixed(2)} MB` +
      (delta ? `（基线 ${delta.from.join(', ')}）` : ''),
  );
  console.log(`[release] 清单 ${updatePath}（${(fs.statSync(updatePath).size / 1024).toFixed(1)} KB）+ .sig`);
  if (!urlBases.length) {
    console.log('[release] ⚠ 未给 --url-base，update.json 里的 URL 是相对占位，上传前必须补');
  }
  console.log(`[release] 下一步：node tool/release/publish.js --dir=${path.relative(L.root, out)} --tag=${tag}`);
  console.log(`[release] 本次共处理 ${copied} 个源文件`);

  function notes() {
    const zh = String(L.arg('notes-zh', L.arg('notes', '')));
    const en = String(L.arg('notes-en', ''));
    const out = {};
    if (zh) out.zh = zh;
    if (en) out.en = en;
    return out;
  }

  /** 整包资产（安装包 / APK）：给了路径就带上，同时登记到 upload.json */
  function packageAsset(flag) {
    const p = L.arg(flag);
    if (!p) return null;
    const file = path.resolve(L.root, String(p));
    if (!fs.existsSync(file)) L.fail(`找不到 --${flag}: ${p}`);
    const name = path.basename(file);
    uploads.push({ name, file });
    return {
      size: fs.statSync(file).size,
      sha256: L.sha256FileHex(file),
      urls: urlBases.map((b) => assetUrl(b, name)),
    };
  }

  function clientComponent(id) {
    const map = {
      client_pc: [
        ['setup', 'pc-setup'],
        ['portable', 'pc-portable'],
      ],
      client_android: [
        ['apk', 'apk'],
        ['apk_tv', 'apk-tv'],
        // 相册独立端（com.colanas.photo）：与主客户端版本号一致，但包身份不同
        ['apk_photo', 'apk-photo'],
      ],
    }[id];
    const assets = {};
    for (const [kind, flag] of map) {
      const asset = packageAsset(flag);
      if (asset) assets[kind] = asset;
    }
    if (Object.keys(assets).length === 0) return null;
    return {
      semver: product.semver,
      version: product.version,
      versionCode: buildNumber(),
      assets,
    };
  }

  /** 安卓 versionCode = pubspec 的 `+B`（Flutter 打包时直接用这个） */
  function buildNumber() {
    const explicit = L.arg('version-code');
    if (explicit) return Number(explicit);
    try {
      const pub = fs.readFileSync(
        path.join(L.root, 'apps', 'colanas_os', 'pubspec.yaml'),
        'utf8',
      );
      const m = /^version:\s*\d+\.\d+\.\d+\+(\d+)/m.exec(pub);
      if (m) return Number(m[1]);
    } catch {
      /* 兜底用 patch */
    }
    return product.version % 100;
  }

  function flushUploads() {
    // 上传清单：让 publish.js 知道「哪些名字对应哪个本地文件」，
    // 551 MB 的整包不用在 dist_release 里再复制一份
    L.writeJson(path.join(out, 'upload.json'), { tag, entries: uploads });
  }
}

/**
 * `--semver=` 覆盖：只用于补发已经上线的版本，不改 package.json。
 * 日常发版不传，版本号仍以 package.json 为唯一真源。
 */
function productOverride() {
  const raw = L.arg('semver');
  if (!raw) return null;
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(raw));
  if (!m) L.fail(`--semver 不合法: ${raw}`);
  const [major, minor, patch] = [Number(m[1]), Number(m[2]), Number(m[3])];
  return { semver: String(raw), version: major * 10000 + minor * 100 + patch };
}

/**
 * 增量基线：显式 `--from` 优先，否则自动取输出目录里「比当前旧的最新一版」。
 *
 * 为什么默认自动找：漏传 `--from` 的代价是完全静默的 —— 清单里没有 `delta`，
 * 所有用户都只能下几百 MB 全量包，而发版的人看不出任何异常（1.3.14 / 1.3.15
 * 两次都是这么发出去的）。
 *
 * 只取**最新一版**而不取全部旧版：清单里 `from` 是变化文件的**并集**，基线越多
 * 增量包越大。跳级用户（比如 1.3.12 直升）会落到全量兜底，这是可接受的；
 * 要覆盖更多版本就显式多传几个 `--from`。
 */
function resolveBaselines(out, currentVersion) {
  const explicit = L.args('from').map((p) => path.resolve(L.root, p));
  if (explicit.length > 0) return explicit;
  if (L.arg('no-delta') !== undefined) return [];
  const candidates = [];
  for (const name of fs.existsSync(out) ? fs.readdirSync(out) : []) {
    if (!/^D\d{5}$/.test(name)) continue;
    const dir = path.join(out, name);
    if (!fs.existsSync(path.join(dir, 'manifest.json'))) continue;
    let v;
    try {
      v = Number(L.readJson(path.join(dir, 'version.json')).version) || 0;
    } catch {
      continue;
    }
    if (v > 0 && v < currentVersion) candidates.push({ dir, v });
  }
  if (candidates.length === 0) return [];
  candidates.sort((a, b) => b.v - a.v);
  console.log(`[release] 自动基线：${path.relative(L.root, candidates[0].dir)}`);
  return [candidates[0].dir];
}

/**
 * 按源拼资产 URL：后缀插在扩展名之前（`x-Setup.exe` + `-v2` → `x-Setup-v2.exe`）。
 *
 * 放在模块级：`buildDelta` 也要用（增量资产同样要按源改名）。
 */
function assetUrl(base, fileName) {
  const dot = fileName.lastIndexOf('.');
  const name =
    base.suffix && dot > 0
      ? `${fileName.slice(0, dot)}${base.suffix}${fileName.slice(dot)}`
      : `${fileName}${base.suffix}`;
  return `${base.url}/${encodeURIComponent(name)}`;
}

function buildVersionDir(versionDir, product) {
  const skip = (p) => !p.endsWith('.map') && !p.endsWith('.br');
  let n = 0;
  n += L.copyTree(path.join(L.root, 'dist', 'kernel'), path.join(versionDir, 'kernel'), skip);
  // 内核的模块实现：`dist/kernel/modules.js` 里是 `require("../src/modules/…")`，
  // 少了这一份，版本目录里的内核一启动就 MODULE_NOT_FOUND（2026-11-21 复查发现）
  const srcDir = path.join(L.root, 'dist', 'src');
  if (!fs.existsSync(path.join(srcDir, 'modules', 'system', 'index.js'))) {
    L.fail('缺少 dist/src（先 npm run build）——版本目录必须带 src/，否则内核起不来');
  }
  n += L.copyTree(srcDir, path.join(versionDir, 'src'), skip);
  // electron 内核宿主：单个文件
  const host = path.join(L.root, 'dist', 'electron', 'kernel-host.js');
  if (!fs.existsSync(host)) L.fail('缺少 dist/electron/kernel-host.js（先 npm run build）');
  L.ensureDir(path.join(versionDir, 'electron'));
  fs.copyFileSync(host, path.join(versionDir, 'electron', 'kernel-host.js'));
  n += 1;

  const web = path.join(L.root, 'apps', 'colanas_os', 'build', 'web');
  if (!fs.existsSync(path.join(web, 'index.html'))) {
    L.fail('缺少 Web 产物（先 build-web.bat）');
  }
  n += L.copyTree(web, path.join(versionDir, 'web'), skip);

  /**
   * 契约：**只放安装包里真正随包的那几个**（见 electron-builder.js 的
   * `extraResources` 里 `contracts` 那条的 filter）。
   *
   * 为什么不能整目录拷：安装包只把 `resources/contracts/locales.json` 解出来，
   * 装机后播种出来的版本目录里也就只有这一个文件。清单里多列 `apps.json` /
   * `errors.json` 这些「本机根本没有」的文件，增量装配时会去当前目录硬链接它们
   * → 缺文件 → 校验失败 → **每次增量都退化成 550 MB 全量**（2026-11-22 实测）。
   * 内核运行时也只读 locales.json（`kernel/index.ts` 唯一一处 resolveContractFile）。
   */
  const shippedContracts = new Set(['locales.json']);
  const contracts = path.join(L.root, 'contracts');
  L.ensureDir(path.join(versionDir, 'contracts'));
  for (const name of fs.readdirSync(contracts)) {
    if (!shippedContracts.has(name)) continue;
    fs.copyFileSync(path.join(contracts, name), path.join(versionDir, 'contracts', name));
    n += 1;
  }

  n += L.copyTree(path.join(L.root, 'sidecars'), path.join(versionDir, 'sidecars'), skip);
  void product;
  return n;
}

/**
 * 增量：所有基线**变化文件的并集**。
 *
 * 为什么是并集：清单里 `from: [1.3.12, 1.3.13]` 只有一份文件列表。若某文件
 * 相对 1.3.12 变了、相对 1.3.13 没变，它仍然必须出现在列表里 —— 否则从 1.3.12
 * 升上来的用户会漏文件。对 1.3.13 的用户多下一份同样的文件，只是浪费几 KB。
 */
function buildDelta({ versionDir, assetsDir, manifest, baselines, urlBases, manifestName }) {
  const baseMaps = baselines.map((dir) => {
    const mf = path.join(dir, 'manifest.json');
    if (!fs.existsSync(mf)) {
      L.fail(`基线目录缺 manifest.json: ${path.relative(L.root, dir)}`);
    }
    return L.readJson(mf).files || {};
  });
  const baseNames = baselines.map((dir) => {
    const vj = path.join(dir, 'version.json');
    if (fs.existsSync(vj)) return L.readJson(vj).semver;
    return path.basename(dir);
  });

  const changed = [];
  for (const [rel, digest] of Object.entries(manifest.files)) {
    const differs = baseMaps.some((files) => files[rel] !== digest);
    if (differs) changed.push(rel);
  }

  const files = [];
  const small = [];
  let seq = 0;
  for (const rel of changed) {
    const abs = path.join(versionDir, rel);
    const size = fs.statSync(abs).size;
    if (size < SMALL_FILE_LIMIT) {
      small.push({ path: rel, data: fs.readFileSync(abs) });
      continue;
    }
    const raw = fs.readFileSync(abs);
    const br = L.brotli(raw);
    const rawSha = L.sha256Hex(raw);
    // 资产名带内容摘要：GitCode 不接受同名覆盖附件（同名非空一律跳过），
    // 名字不跟内容走就会出现「本地已更新、线上还是上一版」——
    // 而且这种错最难查，因为上传日志全都显示成功 / 跳过。
    const assetName = `${seq++}-${rawSha.slice(0, 12)}-${path.basename(rel)}.br`;
    fs.writeFileSync(path.join(assetsDir, assetName), br);
    files.push({
      path: rel,
      size: raw.length,
      sha256: rawSha,
      br: { size: br.length, sha256: L.sha256Hex(br) },
      urls: urlBases.map((b) => assetUrl(b, assetName)),
    });
  }

  const bundles = [];
  if (small.length > 0) {
    const packed = L.packBundle(small);
    const bundleName = `smallfiles-${L.sha256Hex(packed).slice(0, 12)}.brb`;
    fs.writeFileSync(path.join(assetsDir, bundleName), packed);
    bundles.push({
      name: bundleName,
      size: packed.length,
      sha256: L.sha256Hex(packed),
      members: small.map((s) => s.path),
      urls: urlBases.map((b) => assetUrl(b, bundleName)),
    });
  }

  const manifestAsset = {
    size: fs.statSync(path.join(assetsDir, manifestName)).size,
    sha256: L.sha256FileHex(path.join(assetsDir, manifestName)),
    urls: urlBases.map((b) => assetUrl(b, manifestName)),
  };

  console.log(
    `[release] 增量：变 ${changed.length} 个（大文件 ${files.length} / 小文件包 ${small.length}）`,
  );
  return {
    from: [...baseNames],
    files,
    bundles,
    urlBase: urlBases.map((b) => b.url),
    manifest: manifestAsset,
  };
}

main();
