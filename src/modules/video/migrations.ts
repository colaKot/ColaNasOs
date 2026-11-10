import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

export const VIDEO_MIGRATIONS: Migration[] = [
    {
      id: '031_video',
      async up(db) {
        await sql`
          create table if not exists video_libraries (
            id text primary key,
            name text not null,
            root_path text not null unique,
            created_at integer not null,
            last_scan_at integer,
            items integer not null default 0
          )
        `.execute(db);

        await sql`
          create table if not exists video_items (
            id text primary key,
            library_id text not null,
            rel_path text not null,
            title text not null,
            duration integer,
            width integer,
            height integer,
            video_codec text,
            audio_codec text,
            container text not null default '',
            has_subtitle integer not null default 0,
            size integer not null,
            mtime integer not null,
            created_at integer not null,
            unique(library_id, rel_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_items_title
            on video_items(title, id)
        `.execute(db);
        await sql`
          create index if not exists idx_video_items_library
            on video_items(library_id, title, id)
        `.execute(db);
      },
    },
    {
      id: '035_video_series',
      async up(db) {
        // 剧集字段：能解析出季 / 集号的文件才填 series，其余按影片（全 null）
        await sql`alter table video_items add column series text`.execute(db);
        await sql`alter table video_items add column season integer`.execute(db);
        await sql`alter table video_items add column episode integer`.execute(db);
        await sql`
          create index if not exists idx_video_items_series
            on video_items(series, season, episode, title, id)
        `.execute(db);
      },
    },
    {
      id: '036_video_progress',
      async up(db) {
        // 观看进度：按用户隔离（owner_id = JWT sub），百分比 + 播放位置字符串
        await sql`
          create table if not exists video_progress (
            item_id text not null,
            owner_id text not null,
            position text not null default '',
            percent integer not null default 0,
            updated_at integer not null,
            primary key (item_id, owner_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_progress_owner
            on video_progress(owner_id, updated_at desc)
        `.execute(db);
      },
    },
    {
      id: '060_video_libtype',
      async up(db) {
        // 库类型：movie / jp_movie / tv / image / mixed（创建后不可改，类型即行为）
        await sql`alter table video_libraries add column lib_type text not null default 'movie'`.execute(
          db,
        );
        // 兼容老字段：jp_movie = 1 等价于 lib_type='jp_movie'
        await sql`alter table video_libraries add column jp_movie integer not null default 0`.execute(
          db,
        );
        await sql`alter table video_items add column media_type text not null default 'video'`.execute(
          db,
        );
        await sql`alter table video_items add column code text`.execute(db);
        await sql`alter table video_items add column uncensored integer not null default 0`.execute(
          db,
        );
        await sql`alter table video_items add column chinese_sub integer not null default 0`.execute(
          db,
        );
        await sql`
          create index if not exists idx_video_items_code on video_items(code)
        `.execute(db);

        // 图片库 / 混合库的图片索引（与 photo 库分开：影视的图片是「作品集」而不是相册）
        await sql`
          create table if not exists image_items (
            id text primary key,
            library_id text not null,
            rel_path text not null,
            title text not null,
            taken_at integer,
            size integer not null,
            mtime integer not null,
            width integer,
            height integer,
            mime text not null,
            favorite integer not null default 0,
            created_at integer not null,
            unique(library_id, rel_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_image_items_library
            on image_items(library_id, taken_at desc, id)
        `.execute(db);

        await sql`
          create table if not exists video_favorites (
            owner_id text not null,
            media_type text not null,
            item_id text not null,
            created_at integer not null,
            primary key (owner_id, media_type, item_id)
          )
        `.execute(db);

        // 日本库演员（只存名字与头像地址；档案抓取失败不影响列表）
        await sql`
          create table if not exists jp_actors (
            id text primary key,
            name text not null,
            thumb_path text,
            profile text,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists jp_actor_items (
            actor_id text not null,
            item_id text not null,
            primary key (actor_id, item_id)
          )
        `.execute(db);
      },
    },
    {
      id: '066_video_smb_source',
      async up(db) {
        // SMB 网络目录作为片源：连接参数 + 在线状态缓存。
        // 列表接口只读 online_state（离线机器 stat 会卡十几秒），探测交给 probe 接口。
        const cols = (
          (await sql`pragma table_info(video_libraries)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        const wanted: Array<[string, string]> = [
          ['conn_type', "text not null default 'local'"],
          ['host', 'text'],
          ['share', 'text'],
          ['sub_path', 'text'],
          ['unc_path', 'text'],
          ['smb_user', 'text'],
          ['smb_password_enc', 'text'],
          ['online_state', 'integer not null default 0'],
          ['online_checked_at', 'integer'],
        ];
        for (const [name, type] of wanted) {
          if (cols.includes(name)) continue;
          await sql.raw(`alter table video_libraries add column ${name} ${type}`).execute(db);
        }
      },
    },
    {
      id: '068_jp_auto_subtitle',
      async up(db) {
        // 日本片自动字幕：库开关 + 条目状态机（0待/1成功/2无番号/3站内无/4无中文/5失败）
        const libCols = (
          (await sql`pragma table_info(video_libraries)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        if (!libCols.includes('auto_subtitle')) {
          await sql`alter table video_libraries add column auto_subtitle integer not null default 0`.execute(
            db,
          );
        }
        const itemCols = (
          (await sql`pragma table_info(video_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!itemCols.includes('sub_fetch_state')) {
          await sql`alter table video_items add column sub_fetch_state integer not null default 0`.execute(
            db,
          );
        }
        if (!itemCols.includes('sub_fetch_at')) {
          await sql`alter table video_items add column sub_fetch_at integer`.execute(db);
        }
        // 演员收藏（per-user）；演员名按归一化 key 去重
        await sql`
          create table if not exists video_actor_favorite (
            uid text not null,
            actor_key text not null,
            actor_name text not null,
            created_at integer not null,
            primary key (uid, actor_key)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_actor_favorite_uid
          on video_actor_favorite (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '076_video_collections',
      async up(db) {
        // 自定义合集（每用户）：合集名 + 条目。条目按 added_at 倒序展示。
        await sql`
          create table if not exists video_collections (
            id text primary key,
            uid text not null,
            name text not null,
            kind text not null default 'custom',
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_collections_uid
          on video_collections (uid, updated_at desc)
        `.execute(db);
        await sql`
          create table if not exists video_collection_items (
            collection_id text not null,
            item_id text not null,
            added_at integer not null,
            primary key (collection_id, item_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_collection_items
          on video_collection_items (collection_id, added_at desc)
        `.execute(db);
      },
    },
    {
      id: '075_video_media_flags',
      async up(db) {
        // 影片信息卡徽章：4K / HDR10 / HDR10+ / HLG / 杜比视界 / 全景声。
        // 全部来自扫描期 ffmpeg stderr，落库后列表与详情直接读，不需要重扫库。
        const cols = (
          (await sql`pragma table_info(video_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const wanted = ['is_4k', 'hdr10', 'hdr10plus', 'hlg', 'dolby_vision', 'dolby_atmos'];
        for (const name of wanted) {
          if (cols.includes(name)) continue;
          await sql.raw(`alter table video_items add column ${name} integer not null default 0`).execute(db);
        }
      },
    },
    {
      // 剧集级收藏（每用户）：series 名 + 库，避免同名剧跨库冲突
      id: '078_video_series_favorites',
      async up(db) {
        await sql`
          create table if not exists video_series_favorites (
            owner_id text not null,
            library_id text not null default '',
            series text not null,
            created_at integer not null,
            primary key (owner_id, library_id, series)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_series_favorites_owner
          on video_series_favorites (owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      // 媒体信息层（nfo_* 一组列）。
      //
      // 为什么一次补全而不是分批：SQLite 的 add column 极便宜，分批反而要写三次迁移、
      // 三次改契约、三次重新生成 Dart 模型。列名与既有实现保持同义，
      // 便于将来对抄/迁移数据。
      id: '080_video_nfo',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(video_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (table: string, name: string, type: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table ${table} add column ${name} ${type}`).execute(db);
        };

        // —— 片名与基础信息
        await add('video_items', 'nfo_name', 'text');
        await add('video_items', 'nfo_original_name', 'text');
        await add('video_items', 'nfo_year', 'integer');
        await add('video_items', 'nfo_score', 'real');
        await add('video_items', 'nfo_overview', 'text');
        await add('video_items', 'nfo_runtime', 'integer');
        await add('video_items', 'nfo_release_date', 'text');
        await add('video_items', 'nfo_studio', 'text');

        // —— 分类与人物（JSON 数组文本；查询时用 like / json_each 兜底，不做额外关联表）
        await add('video_items', 'nfo_genres', 'text');
        await add('video_items', 'nfo_regions', 'text');
        await add('video_items', 'nfo_actors', 'text');
        await add('video_items', 'nfo_directors', 'text');

        // —— 图片（本地相对路径或远端 URL；/video/art 统一出口）
        await add('video_items', 'nfo_poster', 'text');
        await add('video_items', 'nfo_fanart', 'text');
        await add('video_items', 'nfo_thumb', 'text');

        // —— 外部 id（排重硬钥匙 + 发现页「已拥有」判定）
        await add('video_items', 'nfo_imdb_id', 'text');
        await add('video_items', 'nfo_douban_id', 'text');
        await add('video_items', 'nfo_tmdb_id', 'integer');

        // —— 刮削状态：source = nfo / tmdb / javdb / javbus / avsox / manual；
        //    match_nfo = 0 表示用户显式排除，不再参与自动刮削
        await add('video_items', 'nfo_source', 'text');
        await add('video_items', 'nfo_updated_at', 'integer');
        await add('video_items', 'match_nfo', 'integer default 1');

        // 列表默认按「刮削片名 > 文件名」展示，排序与筛选都打在这两列上
        await sql`
          create index if not exists idx_video_items_nfo_year
          on video_items(nfo_year, id)
        `.execute(db);
        await sql`
          create index if not exists idx_video_items_nfo_score
          on video_items(nfo_score, id)
        `.execute(db);
      },
    },
    {
      // 已观看（每用户）。存在即已看，不做软删除：取消标记直接删行。
      //
      // 为什么独立成表而不是复用 video_progress：进度是「看到哪」，观看标记是
      // 「看完了/不想看」的用户判断，两者会打架（看 5 分钟退出的人应该能标已看）。
      id: '081_video_watch',
      async up(db) {
        await sql`
          create table if not exists video_watch (
            owner_id text not null,
            item_id text not null,
            watched_at integer not null,
            primary key (owner_id, item_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_watch_owner
          on video_watch (owner_id, watched_at desc)
        `.execute(db);
      },
    },
    {
      // 库级设置：首页是否出现（show_in_home）、左栏排序（sort_order）、
      // 响度归一（audio_normalize，既有实现同名开关）
      id: '082_video_library_settings',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(video_libraries)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (name: string, type: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table video_libraries add column ${name} ${type}`).execute(db);
        };
        await add('show_in_home', 'integer not null default 1');
        await add('sort_order', 'integer not null default 0');
        await add('audio_normalize', 'integer not null default 0');
        await add('scrape_enabled', 'integer not null default 1');
      },
    },
    {
      // 影视收尾两件：
      //   1) 合集自己的封面 / 简介 / 手排顺序（此前只有名字，列表只能按更新时间排）；
      //   2) 「入库即刮」开关 auto_scrape —— **不复用 scrape_enabled**：
      //      那是"允许刮削"（手动点也受它约束），默认 1；拿它当自动开关等于
      //      替所有存量库打开了联网刮削，用户只会觉得"NAS 自己在跑流量"。
      id: '085_video_collection_meta',
      async up(db) {
        const ccols = (
          (await sql`pragma table_info(video_collections)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const addCol = async (name: string, type: string) => {
          if (ccols.includes(name)) return;
          await sql.raw(`alter table video_collections add column ${name} ${type}`).execute(db);
        };
        await addCol('description', 'text');
        await addCol('cover_item_id', 'text');
        await addCol('sort_order', 'integer not null default 0');

        const lcols = (
          (await sql`pragma table_info(video_libraries)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!lcols.includes('auto_scrape')) {
          await sql`alter table video_libraries add column auto_scrape integer not null default 0`.execute(
            db,
          );
        }
      },
    },
    {
      id: '088_video_query_indexes',
      async up(db) {
        // 列表排序全部走表达式，原有 (title,id) 与 (library_id,title,id) 一条都吃不到：
        //   name      → coalesce(nullif(nfo_name,''), title)   「刮削名优先」
        //   takenTime → cast(mtime/1000 as integer)
        // 数万部片时每次翻页都退化成全表扫 + 临时 B 树排序。
        //
        // 用**表达式索引**而不是加一列冗余 display_title：后者要在扫描 / 刮削 / 改名
        // 三处写入点同步维护，漏一处就会静默错位；SQLite 3.9+ 的表达式索引由优化器
        // 按表达式树匹配，查询那边一个字都不用改。
        await sql`
          create index if not exists idx_video_items_display_title
            on video_items(coalesce(nullif(nfo_name, ''), title), id)
        `.execute(db);
        await sql`
          create index if not exists idx_video_items_library_display_title
            on video_items(library_id, coalesce(nullif(nfo_name, ''), title), id)
        `.execute(db);
        // takenTime 侧：把查询里的 cast(mtime/1000 as integer) 改成裸 mtime（除以 1000
        // 不改变单调性），这样能直接命中下面两条。
        await sql`
          create index if not exists idx_video_items_mtime
            on video_items(mtime desc, id)
        `.execute(db);
        await sql`
          create index if not exists idx_video_items_library_mtime
            on video_items(library_id, mtime desc, id)
        `.execute(db);
      },
    },
    {
      id: '091_drop_image_favorite',
      async up(db) {
        // `image_items.favorite` 是个纯死列：031 建表时就有，但扫描从不写它，
        // 查询里也没有人读（收藏实际存在 video_favorites(owner_id, media_type, item_id)，
        // 按用户隔离）。留着只会让下一个读代码的人以为「图片库支持收藏」。
        const cols = (
          (await sql`pragma table_info(image_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (cols.includes('favorite')) {
          await sql`alter table image_items drop column favorite`.execute(db);
        }
      },
    },
    {
      // 一个库多个来源。
      //
      // 旧模型 `video_libraries.root_path` 是单值 + UNIQUE，导致「同一类片子分散在几个盘」
      // 只能建好几个同名库。改成来源表后，库 = 一类片子，来源 = 它扫哪几个目录。
      //
      // `video_libraries.root_path` 继续保留（写第一个来源），不动约束：
      // 已有的读取点（SMB 探测缓存、监控兜底、老客户端）还在用它，
      // 拆掉重建表的代价远大于保留一列冗余。
      id: '092_video_library_sources',
      async up(db) {
        await sql`
          create table if not exists video_library_sources (
            id text primary key,
            library_id text not null,
            root_path text not null,
            conn_type text not null default 'local',
            host text,
            share text,
            sub_path text,
            unc_path text,
            smb_user text,
            smb_password_enc text,
            online_state integer not null default 0,
            online_checked_at integer,
            sort_order integer not null default 0,
            items integer not null default 0,
            last_scan_at integer,
            created_at integer not null,
            unique(library_id, root_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_video_sources_lib
            on video_library_sources(library_id, sort_order, id)
        `.execute(db);

        // 回填：每个现存库的 root_path 就是它的第一个来源。
        // 用 insert or ignore 兜住「重跑迁移」的情况（unique 冲突即已回填过）。
        const libs = (
          await sql<{
            id: string;
            root_path: string;
            created_at: number;
            last_scan_at: number | null;
            items: number;
            conn_type: string | null;
            host: string | null;
            share: string | null;
            sub_path: string | null;
            unc_path: string | null;
            smb_user: string | null;
            smb_password_enc: string | null;
            online_state: number | null;
            online_checked_at: number | null;
          }>`select * from video_libraries`.execute(db)
        ).rows;
        for (const lib of libs) {
          if (!lib.root_path) continue;
          await sql`
            insert or ignore into video_library_sources
              (id, library_id, root_path, conn_type, host, share, sub_path, unc_path,
               smb_user, smb_password_enc, online_state, online_checked_at,
               sort_order, items, last_scan_at, created_at)
            values (${`src_${lib.id}_0`}, ${lib.id}, ${lib.root_path},
                    ${lib.conn_type || 'local'}, ${lib.host ?? null}, ${lib.share ?? null},
                    ${lib.sub_path ?? null}, ${lib.unc_path ?? null}, ${lib.smb_user ?? null},
                    ${lib.smb_password_enc ?? null}, ${Number(lib.online_state) || 0},
                    ${lib.online_checked_at ?? null}, ${0}, ${Number(lib.items) || 0},
                    ${lib.last_scan_at ?? null}, ${Number(lib.created_at) || 0})
          `.execute(db);
        }
      },
    },
    {
      // 日本片的「热度」两列（jp_hot_votes / jp_hot_score）。
      //
      // 为什么非要有：日系演员列表与「她的作品」两处的综合排序都以
      // 「JavDB 评价人数」为首要档位（评论多的排前面），没有这两列时
      // 排序会一路退化到「名字」，看起来就像随机顺序。
      // 抓不到就保持 0，排序自然降级，不编造数据。
      id: '093_video_jp_hot',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(video_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('jp_hot_votes')) {
          await sql`alter table video_items add column jp_hot_votes integer not null default 0`.execute(
            db,
          );
        }
        if (!cols.includes('jp_hot_score')) {
          await sql`alter table video_items add column jp_hot_score real not null default 0`.execute(
            db,
          );
        }
      },
    },
    {
      // 图片库 / 混合库的排序与首字母检索列（image_index）。
      // natural_name：数字补零后的名字，img2 < img10；filename_fl：A-Z / #。
      id: '094_video_image_search',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(image_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        for (const [name, type] of [
          ['natural_name', 'text'],
          ['filename_fl', 'text'],
          ['view_at', 'integer not null default 0'],
        ] as const) {
          if (!cols.includes(name)) {
            await sql.raw(`alter table image_items add column ${name} ${type}`).execute(db);
          }
        }
        const rows = (
          await sql<{ id: string; title: string }>`select id, title from image_items`.execute(db)
        ).rows;
        const natural = (s: string) =>
          String(s || '')
            .toLowerCase()
            .replace(/\d+/g, (m) => m.padStart(6, '0'));
        const fl = (s: string) => {
          const first = String(s || '').trim().charAt(0).toUpperCase();
          return /^[A-Z]$/.test(first) ? first : '#';
        };
        for (let i = 0; i < rows.length; i += 500) {
          const chunk = rows.slice(i, i + 500);
          await db.transaction().execute(async (trx: any) => {
            for (const r of chunk) {
              await sql`
                update image_items
                   set natural_name = ${natural(r.title)}, filename_fl = ${fl(r.title)}
                 where id = ${r.id}
              `.execute(trx);
            }
          });
        }
      },
    },
    {
      // 每日刮削进度快照（2026-11-04）。
      //
      // 为什么单独一张表而不是只留在 tasks 里：任务是「一次性执行记录」，
      // 面板只保留最近 50 条，翻不到上周的数字；用户要的是「还剩多少要刮、
      // 已经刮了多少」这种可对比的曲线，所以按天落一条，一天一行、当天覆盖。
      id: '106_video_scrape_stats',
      async up(db) {
        await sql`
          create table if not exists video_scrape_stats (
            day text primary key,
            total integer not null default 0,
            scraped integer not null default 0,
            unscraped integer not null default 0,
            with_c integer not null default 0,
            with_sub integer not null default 0,
            no_c_no_sub integer not null default 0,
            detail text,
            created_at integer not null
          )
        `.execute(db);
      },
    },
    {
      // 全文索引（FTS5 trigram）：只覆盖原来 `like '%kw%'` 扫的列。
      // trigram 支持中文子串，但要求查询 ≥3 个字符；1-2 字由查询侧回退 LIKE。
      id: '130_video_fts',
      async up(db) {
        await sql`
          create virtual table if not exists video_items_fts using fts5(
            title, rel_path, nfo_name, nfo_original_name, code, nfo_actors, nfo_directors,
            content='video_items',
            content_rowid='rowid',
            tokenize='trigram'
          )
        `.execute(db);

        await sql`
          create trigger if not exists video_items_fts_ai after insert on video_items begin
            insert into video_items_fts
              (rowid, title, rel_path, nfo_name, nfo_original_name, code, nfo_actors, nfo_directors)
            values
              (new.rowid, new.title, new.rel_path, new.nfo_name, new.nfo_original_name,
               new.code, new.nfo_actors, new.nfo_directors);
          end
        `.execute(db);
        await sql`
          create trigger if not exists video_items_fts_ad after delete on video_items begin
            insert into video_items_fts
              (video_items_fts, rowid, title, rel_path, nfo_name, nfo_original_name,
               code, nfo_actors, nfo_directors)
            values
              ('delete', old.rowid, old.title, old.rel_path, old.nfo_name, old.nfo_original_name,
               old.code, old.nfo_actors, old.nfo_directors);
          end
        `.execute(db);
        await sql`
          create trigger if not exists video_items_fts_au after update on video_items begin
            insert into video_items_fts
              (video_items_fts, rowid, title, rel_path, nfo_name, nfo_original_name,
               code, nfo_actors, nfo_directors)
            values
              ('delete', old.rowid, old.title, old.rel_path, old.nfo_name, old.nfo_original_name,
               old.code, old.nfo_actors, old.nfo_directors);
            insert into video_items_fts
              (rowid, title, rel_path, nfo_name, nfo_original_name, code, nfo_actors, nfo_directors)
            values
              (new.rowid, new.title, new.rel_path, new.nfo_name, new.nfo_original_name,
               new.code, new.nfo_actors, new.nfo_directors);
          end
        `.execute(db);

        // 已有数据一次性回填（8k 级只在这一刻花一次；之后由触发器增量维护）
        await sql`insert into video_items_fts(video_items_fts) values('rebuild')`.execute(db);
      },
    },
    {
      // HDR / DV 标记的「解析口径版本」。
      //
      // 早期 `probeVideo` 只保留含 `Stream #` / `Side data:` 的行，而真正的内容写
      // 在这两行下面的缩进子行里（`DOVI configuration record: ... profile: 5`、
      // `Mastering display metadata: ...`），于是整块 Side data 被丢掉 —— 所有
      // DV / HDR10 片源都落库成 0。后果不只是徽章缺失：播放时 `hdrToSdr=false`，
      // HDR→SDR 链路整条不启用，DV P5 的 IPTPQc2 当普通 BT.2020 直出，画面偏绿偏紫。
      //
      // 解析已修（见 ffmpeg.ts），但老行因为 size/mtime 没变会被增量扫描直接跳过，
      // 永远带着错值。留一个版本列做「一次性重探」的口子：扫描时发现
      // `hdr_meta_v != HDR_META_VERSION` 就重新 ffprobe 一次并写回。
      id: '134_video_hdr_meta_version',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(video_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('hdr_meta_v')) {
          // 默认 0 = 从没按新口径探过；扫描写回时置为 1
          await sql
            .raw('alter table video_items add column hdr_meta_v integer not null default 0')
            .execute(db);
        }
      },
    },
    {
      // 与 `163_music_library_owner` 同一件事：三张 *libraries 表里只有
      // `photo_libraries` 有 `owner_id`，视频/音乐库缺列。
      //
      // ⚠️ 同样只补列、不回填、不加 NOT NULL —— NULL 表示「所有人可见」，
      // 保持影视库在家庭内共享的现状。要私有化时填值并加
      // `and (owner_id is null or owner_id = ?)` 即可。
      id: '164_video_library_owner',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(video_libraries)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('owner_id')) {
          await sql`alter table video_libraries add column owner_id text`.execute(db);
        }
        await sql`
          create index if not exists idx_video_libraries_owner
            on video_libraries (owner_id)
        `.execute(db);
      },
    },
    {
      // FTS 增量同步触发器收紧触发范围。
      //
      // 原来的 `after update on video_items` 是**无条件**的：只要这行被 UPDATE，
      // 就把 7 个被索引字段的 trigram 条目删掉重建一遍。可这张表上大量更新跟搜索无关
      // （`sub_fetch_state`/`sub_fetch_at`/`jp_hot_votes`/`match_nfo`/`hdr_meta_v`…），
      // 于是「改一个整数」变成「重算 1.3KB 文本的 trigram」。
      //
      // 真库实测（200 行 × 5 轮取平均）：
      //   · 改非 FTS 字段（原触发器）      1,169 µs/条
      //   · 同上，删掉触发器                 36 µs/条   ← 触发器占了 97%
      //   · 同上，触发器加 `update of`       35 µs/条   ← 省回 97%
      //   · 改 title（真需要重建）          762 µs/条   ← 这笔开销是应该付的
      // 折算到 2,162 部片子扫一遍字幕：2,338ms → 70ms。
      //
      // `after update of <列>` 只在 SET 子句**提到**这些列时才触发；UPDATE 不可能
      // 改动没提到的列，所以不会漏同步。插入 / 删除两个触发器不动（必须每次都同步）。
      id: '167_video_fts_update_scope',
      async up(db) {
        await sql`drop trigger if exists ${sql.table('video_items_fts_au')}`.execute(db);
        await sql`
          create trigger video_items_fts_au
          after update of
            title, rel_path, nfo_name, nfo_original_name, code, nfo_actors, nfo_directors
          on video_items begin
            insert into video_items_fts
              (video_items_fts, rowid, title, rel_path, nfo_name, nfo_original_name,
               code, nfo_actors, nfo_directors)
            values
              ('delete', old.rowid, old.title, old.rel_path, old.nfo_name, old.nfo_original_name,
               old.code, old.nfo_actors, old.nfo_directors);
            insert into video_items_fts
              (rowid, title, rel_path, nfo_name, nfo_original_name, code, nfo_actors, nfo_directors)
            values
              (new.rowid, new.title, new.rel_path, new.nfo_name, new.nfo_original_name,
               new.code, new.nfo_actors, new.nfo_directors);
          end
        `.execute(db);
      },
    },
];
