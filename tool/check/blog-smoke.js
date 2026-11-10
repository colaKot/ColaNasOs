#!/usr/bin/env node
/**
 * blog（AI 新闻 / 播客）验收。
 *
 *   匿名 401 → 设置默认值 → 3 个内置音色 → 保存与回读（含明文 Key、越界值收敛）
 *   → 空列表 → 不存在的音频 404 → 删不存在的期 ok
 *   → 文稿与引用链接（新数据带 link / 老数据 headlines 兜底 / 404 / 匿名 401）
 *   → TTS 不可用时试听 / 生成必须 503（不能假装成功）
 *
 * **默认不真的合成语音**：一次试听首次要加载 1.4GB 模型（首次约 30 秒，含着色器编译），
 * 放进门禁会把 verify 拖死。要跑完整链路（合成 + 生成一期）用：
 *   COLANAS_BLOG_SMOKE_TTS=1 node tool/check/blog-smoke.js
 *
 * 需 Electron 运行时（better-sqlite3 为 Electron ABI），脚本自动自举。
 * 用法：node tool/check/blog-smoke.js
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

process.chdir(root);
process.env.COLANAS_LOG_FILE = '0';
process.env.COLANAS_DEV_TOKEN = '1';
process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';

const WITH_TTS = process.env.COLANAS_BLOG_SMOKE_TTS === '1';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-blog-'));
  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;

  const results = [];
  const check = (name, ok, detail) => {
    results.push({ name, ok, detail: detail || '' });
    console.log(`${ok ? '[ok]  ' : '[FAIL]'} ${name}${detail ? ' — ' + detail : ''}`);
  };

  const tokenRes = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/dev-token',
    payload: { sub: 'u1', scopes: ['blog:read', 'blog:write'] },
  });
  const bearer = { authorization: 'Bearer ' + tokenRes.json().token };

  let r = await app.inject({ method: 'GET', url: '/api/v1/blog/settings' });
  check('anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/blog/settings', headers: bearer });
  const s = r.json();
  check(
    'settings_defaults',
    r.statusCode === 200 &&
      s.voice === 'default' &&
      s.speed === 1 &&
      s.planHour === 4 &&
      s.planMinute === 0 &&
      s.planEnabled === true &&
      s.apiKey === '' &&
      s.counts.domesticGeneral === 2,
    JSON.stringify({ voice: s.voice, hour: s.planHour, tts: s.ttsAvailable }),
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/blog/voices', headers: bearer });
  const voices = r.json();
  check(
    'voices_3',
    voices.items.length >= 3 &&
      voices.defaultVoice === 'default' &&
      voices.items.some((v) => v.id === 'default' && v.builtin === true),
    voices.items.map((v) => v.id).join(','),
  );

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/settings',
    headers: bearer,
    payload: {
      voice: 'deep',
      speed: 1.5,
      counts: {
        // counts 是整体替换（8 个类别一起提交），页面也是这样发的
        domesticGeneral: 2,
        worldGeneral: 2,
        domesticTech: 1,
        worldTech: 1,
        domesticAi: 3,
        worldAi: 1,
        domesticFinance: 1,
        worldFinance: 10,
      },
      planHour: 23,
      planMinute: 55,
      planEnabled: false,
      apiProvider: 'openai',
      apiKey: 'sk-plain-text',
      apiBase: 'https://api.openai.com/v1',
      apiModel: 'gpt-4o-mini',
    },
  });
  const saved = r.json();
  check(
    'settings_save',
    r.statusCode === 200 &&
      saved.voice === 'deep' &&
      saved.speed === 1.5 &&
      saved.counts.domesticAi === 3 &&
      saved.counts.worldFinance === 10 &&
      saved.counts.worldGeneral === 2 &&
      saved.planHour === 23 &&
      saved.planMinute === 55 &&
      saved.planEnabled === false &&
      saved.apiKey === 'sk-plain-text' &&
      saved.apiProvider === 'openai',
    JSON.stringify({ speed: saved.speed, wf: saved.counts?.worldFinance, wg: saved.counts?.worldGeneral }),
  );

  // 越界值由契约挡住（400），而不是"悄悄改成边界值"
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/settings',
    headers: bearer,
    payload: { speed: 9 },
  });
  check('settings_speed_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/settings',
    headers: bearer,
    payload: { counts: { domesticAi: 3 } },
  });
  check('settings_counts_partial_400', r.statusCode === 400, 'status=' + r.statusCode);

  r = await app.inject({ method: 'GET', url: '/api/v1/blog/episodes', headers: bearer });
  check('episodes_empty', r.statusCode === 200 && r.json().items.length === 0);

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/blog/audio-url?id=nope',
    headers: bearer,
  });
  check('audio_url_404', r.statusCode === 404, 'status=' + r.statusCode);

  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/remove',
    headers: bearer,
    payload: { id: 'nope' },
  });
  check('remove_missing_ok', r.statusCode === 200);

  // 一键下载：状态是实时探测磁盘，取消必须立刻把 downloading 归零。
  // 这里**故意不调 /download**（会真的拉 1.4GB），下载状态机由独立脚本验证。
  r = await app.inject({ method: 'GET', url: '/api/v1/blog/tts/model', headers: bearer });
  const model = r.json();
  check(
    'tts_model_status',
    r.statusCode === 200 &&
      typeof model.installed === 'boolean' &&
      typeof model.percent === 'number' &&
      typeof model.task === 'string' &&
      model.installed === (model.binReady && model.modelReady),
    `installed=${model.installed} bin=${model.binReady} models=${model.modelReady} task=${model.task}`,
  );
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/tts/model/cancel',
    headers: bearer,
  });
  check(
    'tts_model_cancel',
    r.statusCode === 200 && r.json().downloading === false,
    `status=${r.statusCode} downloading=${r.json().downloading}`,
  );

  // TTS 关闭时必须明确 503，而不是"接受了但永远 pending"
  process.env.COLANAS_TTS_DISABLED = '1';
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/preview',
    headers: bearer,
    payload: { voice: 'default' },
  });
  check('preview_503_when_tts_off', r.statusCode === 503, 'status=' + r.statusCode);
  r = await app.inject({ method: 'POST', url: '/api/v1/blog/generate', headers: bearer, payload: {} });
  check('generate_503_when_tts_off', r.statusCode === 503, 'status=' + r.statusCode);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/resynth',
    headers: bearer,
    payload: { id: 'missing' },
  });
  check('resynth_503_when_tts_off', r.statusCode === 503, 'status=' + r.statusCode);
  delete process.env.COLANAS_TTS_DISABLED;

  // 只测错误分支：成功路径会真跑 20 分钟 TTS，不能放进冒烟
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/resynth',
    headers: bearer,
    payload: { id: 'missing' },
  });
  check('resynth_missing_404', r.statusCode === 404, 'status=' + r.statusCode);
  r = await app.inject({
    method: 'POST',
    url: '/api/v1/blog/resynth',
    headers: bearer,
    payload: {},
  });
  check('resynth_no_id_400', r.statusCode === 400, 'status=' + r.statusCode);

  if (WITH_TTS) {
    const t0 = Date.now();
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/blog/preview',
      headers: bearer,
      payload: { voice: 'default' },
    });
    const pv = r.json();
    check('preview_200', r.statusCode === 200 && typeof pv.url === 'string', `status=${r.statusCode}`);
    if (pv.url) {
      const audio = await app.inject({ method: 'GET', url: pv.url });
      check(
        'preview_audio_mp3',
        audio.statusCode === 200 &&
          String(audio.headers['content-type']).includes('audio') &&
          audio.rawPayload.length > 20000,
        `${audio.headers['content-type']} ${audio.rawPayload.length}B (${((Date.now() - t0) / 1000).toFixed(1)}s)`,
      );
    }
    r = await app.inject({
      method: 'POST',
      url: '/api/v1/blog/generate',
      headers: bearer,
      payload: {
        counts: {
          domesticGeneral: 0,
          worldGeneral: 0,
          domesticTech: 1,
          worldTech: 0,
          domesticAi: 0,
          worldAi: 0,
          domesticFinance: 0,
          worldFinance: 0,
        },
        voice: 'default',
        speed: 1,
      },
    });
    const gen = r.json();
    check('generate_accepted', r.statusCode === 200 && Boolean(gen.id), `status=${r.statusCode}`);
    if (gen.id) {
      let st = null;
      for (let i = 0; i < 90; i++) {
        await sleep(2000);
        st = (await app.inject({ method: 'GET', url: `/api/v1/blog/status?id=${gen.id}`, headers: bearer })).json();
        if (st.status === 'done' || st.status === 'failed') break;
      }
      check('generate_done', st && st.status === 'done', JSON.stringify(st));
      const list = (await app.inject({ method: 'GET', url: '/api/v1/blog/episodes', headers: bearer })).json();
      const ep = list.items[0];
      check('episode_listed', Boolean(ep && ep.id === gen.id && ep.durationSec > 3), ep ? `${ep.durationSec}s ${ep.sizeBytes}B` : 'none');
    }
  } else {
    console.log('[skip] 语音合成链路（设 COLANAS_BLOG_SMOKE_TTS=1 开启）');
  }

  // 文稿弹窗的数据源：新期次落 news_json（带原文链接），迁移前的老期次
  // 只有 headlines，接口要退化成「有标题、没有链接」的引用，不能直接 500。
  const { sql: ksql } = require('kysely');
  await ksql`
    insert into blog_episodes
      (id, title, voice, speed, status, script, headlines_json, news_json, created_at)
    values ('smoke-script', '文稿测试期', 'default', 1, 'done', '第一段播报稿。', '[]',
            ${JSON.stringify([
              {
                category: '国内综合新闻',
                title: '示例新闻',
                link: 'https://example.com/a',
                source: '示例源',
              },
            ])}, 1)
  `.execute(k.db);
  await ksql`
    insert into blog_episodes
      (id, title, voice, speed, status, script, headlines_json, created_at)
    values ('smoke-script-old', '老期次', 'default', 1, 'done', '老稿。', '["老标题"]', 2)
  `.execute(k.db);

  // 服务端真分页：total 是全部条数，offset/limit 只切当前页（前端不再一次拉 200 条切片）
  const epP1 = (
    await app.inject({ method: 'GET', url: '/api/v1/blog/episodes?limit=1', headers: bearer })
  ).json();
  const epP2 = (
    await app.inject({ method: 'GET', url: '/api/v1/blog/episodes?limit=1&offset=1', headers: bearer })
  ).json();
  check(
    'episodes_server_paging',
    epP1.items.length === 1 &&
      epP1.total >= 2 &&
      epP1.limit === 1 &&
      epP1.offset === 0 &&
      epP2.items.length === 1 &&
      epP2.offset === 1 &&
      epP2.items[0].id !== epP1.items[0].id,
    `total=${epP1.total} p1=${epP1.items[0]?.id} p2=${epP2.items[0]?.id}`,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/blog/script?id=smoke-script',
    headers: bearer,
  });
  const sc = r.json();
  check(
    'script_with_links',
    r.statusCode === 200 &&
      sc.script === '第一段播报稿。' &&
      sc.items.length === 1 &&
      sc.items[0].link === 'https://example.com/a' &&
      sc.items[0].source === '示例源',
    'status=' + r.statusCode,
  );

  r = await app.inject({
    method: 'GET',
    url: '/api/v1/blog/script?id=smoke-script-old',
    headers: bearer,
  });
  const legacy = r.json();
  check(
    'script_legacy_headlines_fallback',
    r.statusCode === 200 &&
      legacy.items.length === 1 &&
      legacy.items[0].title === '老标题' &&
      legacy.items[0].link === '',
    'status=' + r.statusCode,
  );

  r = await app.inject({ method: 'GET', url: '/api/v1/blog/script?id=nope', headers: bearer });
  check('script_404', r.statusCode === 404, 'status=' + r.statusCode);
  r = await app.inject({ method: 'GET', url: '/api/v1/blog/script?id=smoke-script' });
  check('script_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);

  // ---------------------------------------------------------------- 语音合成切块
  // `llama-tts` 不给 `-n` 时只生成 **512 帧**（12Hz → 42.67s ≈ 200 字），
  // 超出的文字**静默丢弃**：不报错、退出码 0，只听得出「念到一半没了」。
  // 这两条不变量必须守住：切块不丢字、每块按字数给足上限。
  const tts = require('../../dist/kernel/tts/engine.js');
  const longText =
    '沪武高速安徽潜山段11月7日下午发生一起多车追尾事故。记者从消防、公安等多部门了解到，' +
    '事发路段位于岳西往桐城南方向。一辆载有电池的货车发生自燃，后方多车随即追尾。' +
    '目前事故伤亡情况仍在进一步了解中，当地有关部门表示，已有人被送往医院接受治疗。' +
    '事故发生后，消防、公安等救援力量赶赴现场处置。高速公路货车自燃并引发连环追尾，' +
    '往往造成长时间拥堵和二次事故风险。这也提醒运输企业和驾驶人，加强对电池等特殊货物的装载检查，' +
    '遇到突发情况及时预警后方车辆。';
  const pieces = tts.splitText(longText, 300);
  check(
    'tts_split_keeps_all_text',
    pieces.join('').replace(/\s/g, '') === longText.replace(/\s/g, ''),
    `块数=${pieces.length} 字=${longText.length}`,
  );
  // 512 帧是 200 字左右；300 字的块必须拿到明显更大的上限，否则一定被截
  check(
    'tts_predict_covers_512_frame_default',
    tts.predictFrames('字'.repeat(300)) > 512 && tts.predictFrames('字'.repeat(300)) <= 8192,
    'n=' + tts.predictFrames('字'.repeat(300)),
  );
  const half = tts.halveForRetry(longText);
  check(
    'tts_halve_keeps_all_text',
    !!half && (half[0] + half[1]).replace(/\s/g, '') === longText.replace(/\s/g, ''),
    half ? `${half[0].length}+${half[1].length}` : 'null',
  );

  // ---------------------------------------------------------------- 播报头（序号 + 一句话总结）
  // 以前整篇只有「下面是国内科技。」分段，同一分类下连着好几条，听众分不清
  // 什么时候换了一条新闻。现在每条前面必须报序号 + 一句总结，再进正文。
  const blogScript = require('../../dist/src/modules/blog/script.js');
  const rendered = blogScript.renderScript(
    [
      {
        key: 'a',
        spoken: '国内科技',
        articles: [
          { summary: '甲总结。', text: '甲正文。' },
          { summary: '乙总结', text: '乙正文' },
        ],
      },
      { key: 'b', spoken: '国内AI', articles: [{ summary: '丙总结；', text: '丙正文' }] },
    ],
    null,
    '2026年11月8日',
  );
  check(
    'script_numbered_with_summary',
    rendered.includes('第一，甲总结。') &&
      rendered.includes('第二，乙总结。') &&
      // 序号必须**跨分类连续**，不是每类从「第一」重来
      rendered.includes('第三，丙总结。'),
    rendered.slice(0, 90).replace(/\n/g, ' / '),
  );

  await k.close?.();
  try {
    fs.rmSync(dataDir, { recursive: true, force: true });
  } catch {
    /* Windows 上 sqlite 句柄可能还没释放 */
  }

  const failed = results.filter((x) => !x.ok);
  console.log(`\n[blog-smoke] ${results.length - failed.length}/${results.length} 通过`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
