import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

export const PHOTO_MIGRATIONS: Migration[] = [
    {
      id: '030_photo',
      async up(db) {
        await sql`
          create table if not exists photo_libraries (
            id text primary key,
            name text not null,
            root_path text not null unique,
            created_at integer not null,
            last_scan_at integer,
            items integer not null default 0
          )
        `.execute(db);

        await sql`
          create table if not exists photo_items (
            id text primary key,
            library_id text not null,
            rel_path text not null,
            taken_at integer not null,
            size integer not null,
            mtime integer not null,
            width integer,
            height integer,
            mime text not null,
            created_at integer not null,
            unique(library_id, rel_path)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_items_timeline
            on photo_items(taken_at desc, id)
        `.execute(db);
        await sql`
          create index if not exists idx_photo_items_library
            on photo_items(library_id, taken_at desc, id)
        `.execute(db);

        await sql`
          create table if not exists photo_albums (
            id text primary key,
            name text not null,
            owner_id text not null,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_albums_owner
            on photo_albums(owner_id, created_at desc)
        `.execute(db);

        await sql`
          create table if not exists photo_album_items (
            album_id text not null,
            item_id text not null,
            added_at integer not null,
            primary key (album_id, item_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_album_items_item
            on photo_album_items(item_id)
        `.execute(db);
      },
    },
    {
      id: '045_photo_ai',
      async up(db) {
        await sql`
          create table if not exists photo_faces (
            id text primary key,
            photo_id text not null,
            emb blob not null,
            cluster_id text,
            score real not null default 1,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_faces_cluster on photo_faces(cluster_id)
        `.execute(db);
        await sql`
          create table if not exists photo_scenes (
            photo_id text primary key,
            label text not null,
            score real not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_scenes_label on photo_scenes(label)
        `.execute(db);
        await sql`
          create table if not exists photo_embeddings (
            photo_id text primary key,
            dim integer not null,
            vec blob not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create table if not exists photo_face_clusters (
            id text primary key,
            name text,
            size integer not null default 0,
            cover_photo_id text,
            centroid blob not null,
            created_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '050_photo_geo',
      async up(db) {
        // 地理：扫描时从 EXIF GPS 写入；geohash2..7 是「按精度直接等值匹配」的物化前缀，
        // 避免运行时对每条记录算 substr，也让覆盖格查询能吃到索引。
        await sql`alter table photo_items add column latitude real`.execute(db);
        await sql`alter table photo_items add column longitude real`.execute(db);
        await sql`alter table photo_items add column geohash text`.execute(db);
        await sql`alter table photo_items add column geohash2 text`.execute(db);
        await sql`alter table photo_items add column geohash3 text`.execute(db);
        await sql`alter table photo_items add column geohash4 text`.execute(db);
        await sql`alter table photo_items add column geohash5 text`.execute(db);
        await sql`alter table photo_items add column geohash6 text`.execute(db);
        await sql`alter table photo_items add column geohash7 text`.execute(db);
        await sql`alter table photo_items add column camera text`.execute(db);
        await sql`alter table photo_items add column content_md5 text`.execute(db);
        await sql`alter table photo_items add column favorite integer not null default 0`.execute(db);
        await sql`alter table photo_items add column in_trash integer not null default 0`.execute(db);
        await sql`alter table photo_items add column deleted_at integer`.execute(db);
        for (const p of [2, 3, 4, 5, 6, 7]) {
          await sql`
            create index if not exists ${sql.raw(`idx_photo_items_geohash${p}`)}
              on photo_items(${sql.raw(`geohash${p}`)})
          `.execute(db);
        }
        await sql`
          create index if not exists idx_photo_items_md5 on photo_items(content_md5)
        `.execute(db);
        await sql`
          create index if not exists idx_photo_items_trash on photo_items(in_trash, taken_at desc)
        `.execute(db);

        // 活动标签（SigLIP2 多标签），与 photo_scenes 的「单一场景」互补
        await sql`
          create table if not exists photo_activities (
            photo_id text not null,
            label text not null,
            score real not null,
            updated_at integer not null,
            primary key (photo_id, label)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_activities_label
            on photo_activities(label, score desc)
        `.execute(db);

        // OCR 文本：票夹 / 语义搜索的原料（懒解析，缺失时相关接口降级）
        await sql`
          create table if not exists photo_ocr (
            photo_id text primary key,
            text text not null,
            updated_at integer not null
          )
        `.execute(db);
      },
    },
    {
      id: '051_photo_cleanup',
      async up(db) {
        // 清理批次：预演 → 执行 → 可撤销。撤销只按 batch 回滚，不做全局回滚。
        await sql`
          create table if not exists photo_cleanup_batches (
            id text primary key,
            kind text not null,
            owner_id text not null default '',
            created_at integer not null,
            undone_at integer,
            summary text not null default '{}'
          )
        `.execute(db);
        await sql`
          create table if not exists photo_cleanup_items (
            batch_id text not null,
            item_id text not null,
            action text not null,
            keep_id text,
            prev_trash integer not null default 0,
            prev_deleted_at integer,
            primary key (batch_id, item_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_cleanup_items_batch
            on photo_cleanup_items(batch_id)
        `.execute(db);

        // 用户确认过的记忆（避免 AI 自己编回忆：候选算出来，记忆必须由用户落库）
        await sql`
          create table if not exists photo_memories (
            id text primary key,
            owner_id text not null,
            title text not null,
            cover_photo_id text,
            start_at integer not null,
            end_at integer not null,
            place text,
            tags text,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_memories_owner
            on photo_memories(owner_id, start_at desc)
        `.execute(db);
        await sql`
          create table if not exists photo_memory_excludes (
            owner_id text not null,
            memory_key text not null,
            photo_id text not null,
            primary key (owner_id, memory_key, photo_id)
          )
        `.execute(db);
      },
    },
    {
      id: '052_photo_faces',
      async up(db) {
        // 人脸簇：记录更新时间，便于「重建 / 回滚」对账
        await sql`alter table photo_face_clusters add column updated_at integer`.execute(db);
        // 重建快照：一次重建一份，rollback 直接换回来
        await sql`
          create table if not exists photo_face_clusters_prev (
            run_id text not null,
            id text not null,
            name text,
            size integer not null default 0,
            cover_photo_id text,
            centroid blob not null,
            created_at integer not null,
            primary key (run_id, id)
          )
        `.execute(db);
        await sql`
          create table if not exists photo_face_rebuild_runs (
            id text primary key,
            owner_id text not null default '',
            created_at integer not null,
            finished_at integer,
            faces integer not null default 0,
            clusters integer not null default 0,
            rolled_back_at integer
          )
        `.execute(db);
      },
    },
    {
      id: '053_photo_faces_map',
      async up(db) {
        // 重建前的「人脸 → 簇」映射，回滚时按 face 精确还原
        await sql`
          create table if not exists photo_face_prev_map (
            run_id text not null,
            face_id text not null,
            cluster_id text,
            primary key (run_id, face_id)
          )
        `.execute(db);
      },
    },
    {
      id: '054_photo_backup',
      async up(db) {
        // 手机备份只记录「这次传了多少、跳过多少」，不做断点续传状态机
        //（断点由 files 的分片上传自己维护）
        await sql`
          create table if not exists photo_backup_jobs (
            id text primary key,
            owner_id text not null default '',
            source text not null default '',
            created_at integer not null,
            finished_at integer,
            total integer not null default 0,
            uploaded integer not null default 0,
            skipped integer not null default 0,
            bytes integer not null default 0
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_backup_jobs_owner
            on photo_backup_jobs(owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '063_photo_scene_tags',
      async up(db) {
        // 场景 v2：多标签 + 开放集门控出口（confident / ambiguous / unknown）。
        // top-1 仍写 photo_scenes，兼容既有统计与语义搜索；这张表用于「多标签 + 出口」。
        await sql`
          create table if not exists photo_scene_tags (
            photo_id text not null,
            label text not null,
            score real not null default 0,
            gate text not null default 'confident',
            updated_at integer not null,
            primary key (photo_id, label)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_scene_tags_label
          on photo_scene_tags (label, score desc)
        `.execute(db);
      },
    },
  {
      id: '062_photo_operation_log',
      async up(db) {
        // 通用「可撤销操作」日志：预演 → 执行 → 留痕 → 撤销。
        // 只回滚一次操作自身的快照（不做全局回滚），重复撤销由 undone_at 拦成 409。
        await sql`
          create table if not exists photo_operation_log (
            id text primary key,
            uid text not null default '',
            kind text not null,
            item_ids text not null default '[]',
            prev_json text not null default '[]',
            created_at integer not null,
            undone_at integer
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_operation_log_uid
          on photo_operation_log (uid, created_at desc)
        `.execute(db);
      },
    },
    {
      id: '067_photo_library_owner',
      async up(db) {
        // 相册库归属：每个用户只看自己的库（历史库 owner_id='' 视为共享，向后兼容）。
        // 读严格隔离；写操作保留超管越权（运维需要）。
        const cols = (
          (await sql`pragma table_info(photo_libraries)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('owner_id')) {
          await sql`alter table photo_libraries add column owner_id text not null default ''`.execute(
            db,
          );
        }
        await sql`
          create index if not exists idx_photo_libraries_owner
          on photo_libraries (owner_id, created_at)
        `.execute(db);
      },
    },
    {
      id: '064_face_cluster_v2_meta',
      async up(db) {
        // 重建运行元信息：算法版本 / 模型 / 预处理 / 参数 / 覆盖率，
        // 保证「同一输入 + 同一组参数」可复现、可审计。
        const cols = (
          (await sql`pragma table_info(photo_face_rebuild_runs)`.execute(db)).rows as Array<{
            name: string;
          }>
        ).map((r) => r.name);
        const wanted: Array<[string, string]> = [
          ['algo_version', 'text'],
          ['embedding_model', 'text'],
          ['preprocess_version', 'text'],
          ['params_json', 'text'],
          ['sample_count', 'integer'],
          ['singleton_count', 'integer'],
          ['coverage', 'real'],
          ['elapsed_ms', 'integer'],
        ];
        for (const [name, type] of wanted) {
          if (cols.includes(name)) continue;
          await sql.raw(`alter table photo_face_rebuild_runs add column ${name} ${type}`).execute(db);
        }
      },
    },
    {
      id: '071_photo_collections',
      async up() {
        // 空操作（同 072_photo_memories 的处置方式）。
        //
        // 集合已经并入相册，建表语句移到 `169_photo_album_rules` 里负责删除。
        // 这里必须留一个空壳而不是直接删条目：
        //   · 老库 `_migrations` 里已有这条记录，删条目会让 checkMigrationOrder 报孤儿；
        //   · 更重要的是**不能靠「169 删掉 071 的记录」来达成清理** —— 迁移器按 id
        //     字典序执行、`done` 快照在循环前取，071 的记录一旦没了，下一轮启动
        //     就会重新把集合表建回来（实测 071 比 169 晚了 0.3s 落地）。
        // 建表逻辑留在这里只对「从未升级过的全新库」有意义，而那种库跑完 071
        // 紧接着就会被 169 删掉，纯属白做一次 DDL，不如干脆不建。
      },
    },
    {
      id: '072_photo_memories',
      async up() {
        // 空操作。保留 id 不删：老库 _migrations 里已有这条记录，删条目会让
        // 「迁移清单」与「实际历史」对不上。
        //
        // 这条迁移从未生效过：045_photo_ai 已建过同名表 photo_memories
        // （字段 owner_id / start_at / end_at，存 AI 记忆），而这里写的是
        // `create table if not exists` + 另一套字段（date / status / note），
        // 表已存在 ⇒ 整条 DDL 被跳过；紧随的 `create index if not exists
        // idx_photo_memories_owner` 也因 045 已建同名索引而跳过。
        //
        // 真正落地的是 073_photo_memory_marks（photo_memory_marks 表）。
        // 谁若按这里的字段去查 photo_memories.date 会直接报「no such column」，
        // 所以显式置空 —— 让「这条迁移什么都不做」成为可读的事实，
        // 而不是依赖 `if not exists` 的巧合。
      },
    },
    {
      id: '073_photo_memory_marks',
      async up(db) {
        // 记忆确认标记：只存「某一天的确认 / 忽略 / 备注」，内容按照片实时生成。
        // 不能复用 045 里的 photo_memories（那是以 start_at 存的 AI 记忆）。
        await sql`
          create table if not exists photo_memory_marks (
            id text primary key,
            owner_id text not null,
            day text not null,
            status text not null default 'saved',
            note text not null default '',
            created_at integer not null,
            updated_at integer not null,
            unique(owner_id, day)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_memory_marks_owner
            on photo_memory_marks(owner_id, day desc)
        `.execute(db);
      },
    },
    {
      id: '074_photo_phash_gps',
      async up(db) {
        const cols = ((await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{
          name: string;
        }>).map((r) => r.name);
        if (!cols.includes('phash')) {
          await sql`alter table photo_items add column phash text`.execute(db);
        }
        if (!cols.includes('phash_state')) {
          await sql`alter table photo_items add column phash_state integer not null default 0`.execute(db);
        }
        await sql`
          create index if not exists idx_photo_items_phash
            on photo_items(phash)
        `.execute(db);

        // 感知哈希相似组（两阶段：先算 phash，再按前缀分桶比对）
        await sql`
          create table if not exists photo_phash_groups (
            id text primary key,
            owner_id text not null,
            leader_id text not null,
            member_ids text not null,
            distance integer not null default 0,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_phash_groups_owner
            on photo_phash_groups(owner_id, created_at desc)
        `.execute(db);

        // GPS 视觉候选：用已有 CLIP 向量给缺 GPS 的照片找「有人拍过同场景」的锚点
        await sql`
          create table if not exists photo_gps_candidates (
            id text primary key,
            owner_id text not null,
            photo_id text not null,
            anchor_id text not null,
            latitude real not null,
            longitude real not null,
            similarity real not null,
            status text not null default 'pending',
            created_at integer not null,
            unique(owner_id, photo_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_gps_candidates_owner
            on photo_gps_candidates(owner_id, status, similarity desc)
        `.execute(db);
      },
    },
    {
      id: '079_photo_smart_rules',
      async up(db) {
        // 智能相册规则：用户自定义条件组合（场景 / 人物 / 地点 / 时间 / 收藏），
        // 只存条件 JSON，条目与计数在查询时按同一份条件实时算。
        await sql`
          create table if not exists photo_smart_rules (
            id text primary key,
            owner_id text not null,
            name text not null,
            conditions text not null,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_smart_rules_owner
            on photo_smart_rules(owner_id, created_at desc)
        `.execute(db);
      },
    },
    {
      // 人脸位置（bbox）：没有它就没有人脸头像，用户永远认不出"这是谁"。
      // is_cover 标记该簇的主头像（挑面积最大、位置最正的那张）。
      id: '083_photo_face_bbox',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_faces)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (name: string, type: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table photo_faces add column ${name} ${type}`).execute(db);
        };
        await add('box_left', 'integer');
        await add('box_top', 'integer');
        await add('box_width', 'integer');
        await add('box_height', 'integer');
        await add('img_width', 'integer');
        await add('img_height', 'integer');
        // 簇主头像：photo_face_clusters 上记 face id，避免每次列表都去算
        const ccols = (
          (await sql`pragma table_info(photo_face_clusters)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!ccols.includes('cover_face_id')) {
          await sql`alter table photo_face_clusters add column cover_face_id text`.execute(db);
        }
      },
    },
    {
      // P2 体验纵深三件：
      //   1) 相册有了「自己挑的封面 / 一句简介 / 手排顺序」，此前封面是查询时现算最早的成员；
      //   2) 删除批次：一次删除 = 一个批次，回收站按批次分组、整批还原（此前回收站是平铺的，
      //      删了三批照片后用户无法判断哪些是一起删的）；
      //   3) 人脸合并审计：跨照片二次合并要能回滚，记下被并入方的簇与质心，撤消时原样重建。
      id: '084_photo_p2',
      async up(db) {
        const acols = (
          (await sql`pragma table_info(photo_albums)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const addAlbum = async (name: string, type: string) => {
          if (acols.includes(name)) return;
          await sql.raw(`alter table photo_albums add column ${name} ${type}`).execute(db);
        };
        await addAlbum('description', 'text');
        await addAlbum('cover_item_id', 'text');
        await addAlbum('sort_order', 'integer not null default 0');

        // 删除批次：kind=delete 是用户主动删，kind=cleanup 留给清理链路对齐口径
        await sql`
          create table if not exists photo_delete_batches (
            id text primary key,
            owner_id text not null,
            kind text not null default 'delete',
            item_count integer not null default 0,
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_delete_batches_owner
            on photo_delete_batches(owner_id, created_at desc)
        `.execute(db);

        const icols = (
          (await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!icols.includes('delete_batch_id')) {
          await sql`alter table photo_items add column delete_batch_id text`.execute(db);
        }
        await sql`
          create index if not exists idx_photo_items_delete_batch
            on photo_items(delete_batch_id)
        `.execute(db);

        // 人脸合并审计（可回滚）：from 是被并掉的一方，删除簇后靠这里的质心重建
        await sql`
          create table if not exists photo_face_merge_log (
            id text primary key,
            owner_id text,
            from_id text not null,
            to_id text not null,
            from_name text,
            from_cover_face_id text,
            from_centroid blob,
            faces integer not null default 0,
            face_ids text,
            created_at integer not null,
            undone_at integer
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_face_merge_log_created
            on photo_face_merge_log(created_at desc)
        `.execute(db);
      },
    },
    {
      id: '087_photo_faces_photo_idx',
      async up(db) {
        // 人脸此前只有 (cluster_id) 一条索引，而按 photo_id 的读写到处都是：
        // 永久删除连带清人脸（delete.ts）、回忆页 `photo_id in (...)` 连簇
        // （memories.ts）、人脸回填。10 万张 × 2 张脸 = 20 万行，
        // 每次都是整表扫描。带上 cluster_id 让它同时覆盖「按照片取簇」。
        await sql`
          create index if not exists idx_photo_faces_photo
            on photo_faces(photo_id, cluster_id)
        `.execute(db);
      },
    },
    {
      id: '089_photo_album_added_idx',
      async up(db) {
        // 相册列表每个相册都要算封面：`order by m.added_at, i.id limit 1`。
        // 主键是 (album_id, item_id)、另有一条 (item_id)，两种顺序都不含 added_at，
        // 于是一个 1 万张的相册要被整个读出来再排序；200 个相册就是百万级行。
        await sql`
          create index if not exists idx_photo_album_items_added
            on photo_album_items(album_id, added_at, item_id)
        `.execute(db);
      },
    },
    {
      // OCR 全文索引：语义搜索 / 相册联想里的 `text like '%kw%'` 以前是整表扫。
      // trigram 要求 ≥3 字符；1-2 字由查询侧回退 LIKE。
      id: '131_photo_fts',
      async up(db) {
        await sql`
          create virtual table if not exists photo_ocr_fts using fts5(
            text,
            content='photo_ocr',
            content_rowid='rowid',
            tokenize='trigram'
          )
        `.execute(db);
        await sql`
          create trigger if not exists photo_ocr_fts_ai after insert on photo_ocr begin
            insert into photo_ocr_fts(rowid, text) values (new.rowid, new.text);
          end
        `.execute(db);
        await sql`
          create trigger if not exists photo_ocr_fts_ad after delete on photo_ocr begin
            insert into photo_ocr_fts(photo_ocr_fts, rowid, text)
            values ('delete', old.rowid, old.text);
          end
        `.execute(db);
        await sql`
          create trigger if not exists photo_ocr_fts_au after update on photo_ocr begin
            insert into photo_ocr_fts(photo_ocr_fts, rowid, text)
            values ('delete', old.rowid, old.text);
            insert into photo_ocr_fts(rowid, text) values (new.rowid, new.text);
          end
        `.execute(db);
        await sql`insert into photo_ocr_fts(photo_ocr_fts) values('rebuild')`.execute(db);
      },
    },
    {
      // 识别失败记账。挑片条件是「没有 embedding 就做」，而损坏 / 解不了的
      // 图片永远产不出 embedding —— 一张坏图就能让 photo.ai.scan 每轮都重新
      // 挑中它，变成 0.2 秒一轮的热循环（实测 HEIC 解码失败刷满日志）。
      // 失败时记时间与原因，后续批次跳过；用户点「重新识别」(force) 时清零重试。
      id: '133_photo_ai_skip',
      async up(db) {
        await sql`alter table photo_items add column ai_skip_at integer not null default 0`.execute(
          db,
        );
        await sql`alter table photo_items add column ai_skip_reason text`.execute(db);
        await sql`
          create index if not exists idx_photo_items_ai_pending
            on photo_items(ai_skip_at)
        `.execute(db);
      },
    },
    {
      // 「这张照片做过哪些识别」的位标记：1=基础（人脸/场景/embedding）、2=OCR、4=活动。
      //
      // 以前只用「有没有 embedding」当待办，于是 2026-11-04 在 OCR/活动开关关闭时
      // 跑完的那批照片，后来开关打开也永远不会被补做；而面板按「有结果的照片数」
      // 算进度，OCR / 活动永远到不了 100%，看起来就像「任务没启动」。
      // 有结果不等于没跑过、没结果也不等于跑过，所以必须单独记账。
      //
      // 老库回填只认「已有结果」：有 embedding ⇒ 基础做过，有 OCR/活动记录 ⇒ 对应项做过。
      // 没结果的照片会在下次 scan 里补做一次（且只补缺失项，不重算基础）。
      id: '146_photo_ai_done_mask',
      async up(db) {
        await sql`
          alter table photo_items add column ai_done_mask integer not null default 0
        `.execute(db);
        await sql`
          update photo_items set ai_done_mask =
            (case when exists (
              select 1 from photo_embeddings e where e.photo_id = photo_items.id
            ) then 1 else 0 end)
            | (case when exists (
                select 1 from photo_ocr o where o.photo_id = photo_items.id
              ) then 2 else 0 end)
            | (case when exists (
                select 1 from photo_activities a where a.photo_id = photo_items.id
              ) then 4 else 0 end)
        `.execute(db);
        await sql`
          create index if not exists idx_photo_items_ai_mask
            on photo_items(ai_done_mask)
        `.execute(db);
      },
    },
    {
      // 人脸「认领护栏」需要的元数据。
      //
      // 以前 photo_faces 只有一个 score（检测置信度 0..1），没有质量分也没有姿态，
      // 结果侧脸 / 低分脸和正脸一样参与 KNN 投票，滚出几百张的假人物组。
      // - quality：0..100，= 检测置信度 × 100。老行按 score 回填；
      //   sidecar 早已按 0.55 过滤，所以 55 以下都是历史遗留，重建时会踢出分组。
      // - pose_*：从 faceLandMark 的 5 点 kpss 算的姿态代理量。老数据没有关键点，
      //   留空即「放行」（与既有实现 `yaw 缺失时不判姿态门` 同一口径），不重跑模型。
      id: '147_photo_faces_claim_guard',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_faces)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (name: string, type: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table photo_faces add column ${name} ${type}`).execute(db);
        };
        await add('quality', 'real');
        await add('pose_yaw', 'real');
        await add('pose_roll', 'real');
        await add('pose_iod', 'real');
        await sql`
          update photo_faces
             set quality = round(coalesce(score, 0) * 100)
           where quality is null
        `.execute(db);
        await sql`
          create index if not exists idx_photo_faces_quality on photo_faces(quality)
        `.execute(db);
      },
    },
    {
      // 相册从「只收图片」扩到「图片 + 视频」，并记录动态照片（Motion Photo /
      // Live Photo）里那段视频的位置。三件事共用一次迁移，避免反复改这张大表。
      //
      // media_kind:
      //   image  —— 普通静态图（默认值，老数据不用回填）
      //   video  —— 相册里直接放的视频文件
      // live_kind:
      //   ''     —— 不是动态照片
      //   motion —— JPEG/HEIC 壳 + 尾部 mp4（Google Container 新格式，
      //             荣耀/Pixel/三星；XMP 里 GCamera:MotionPhoto=1）
      //   apple  —— Live Photo：同名 .mov 配一个静态图
      // live_size: motion 类型时，尾部那段视频的字节数（从文件末尾倒数）
      // live_ms:   那段视频的时长，面板显示用
      id: '148_photo_media_kind',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (name: string, ddl: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table photo_items add column ${name} ${ddl}`).execute(db);
        };
        await add('media_kind', `text not null default 'image'`);
        await add('duration_ms', 'integer');
        await add('live_kind', `text not null default ''`);
        await add('live_size', 'integer');
        await add('live_ms', 'integer');
        // 时间线要按「图片 / 视频」切换 tab，走这个组合索引
        await sql`
          create index if not exists idx_photo_items_media
            on photo_items(library_id, media_kind, taken_at desc)
        `.execute(db);
      },
    },
    {
      // 增量扫描靠 size/mtime 跳过没变的文件，但老行（本次升级前入的）里
      // live_kind/live_size 一定是空的，跟「确实是普通图片」无法区分。
      // media_ver 是「这行是按第几版媒体解析逻辑扫的」：
      // 扫描时写入 MEDIA_VER，跳过条件要求 prev.media_ver >= MEDIA_VER，
      // 于是升级后第一次扫描会自动把这些老行重读一遍（只读 256KB 文件头，不慢）。
      id: '149_photo_media_ver',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('media_ver')) {
          await sql.raw(`alter table photo_items add column media_ver integer not null default 0`).execute(
            db,
          );
        }
      },
    },
    {
      // 动态照片识别扩到多品牌后，视频不一定贴在文件末尾，配对视频也不再靠运行时探测：
      // live_offset —— 内嵌视频在原文件里的起点（老行留空，读取时回落到 size - live_size）
      // live_vendor —— 识别来源（google/samsung/huawei/heic/generic），无视频时为 ''
      // live_path   —— 双文件配对时视频的绝对路径，无配对时留空
      // 三列都允许旧库缺列，故用 pragma 判存在再 add。
      id: '150_photo_live_span',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        const add = async (name: string, ddl: string) => {
          if (cols.includes(name)) return;
          await sql.raw(`alter table photo_items add column ${name} ${ddl}`).execute(db);
        };
        await add('live_offset', 'integer');
        await add('live_vendor', `text not null default ''`);
        await add('live_path', `text not null default ''`);
      },
    },
    {
      // 手机备份判重要用「原始字节数」：NAS 上的照片之后可能被补充 GPS /
      // 旋转 / 重编码，文件真实 size 会变，但手机手里仍是原图 size。
      // orig_size 记的是首次入库（或首次发现文件被改写）时的字节数，
      // 一旦写入永不覆盖；0 表示「没被改写过」，判重时回落用 size。
      id: '151_photo_orig_size',
      async up(db) {
        const cols = (
          (await sql`pragma table_info(photo_items)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('orig_size')) {
          await sql.raw(
            'alter table photo_items add column orig_size integer not null default 0',
          ).execute(db);
        }
        await sql`
          create index if not exists idx_photo_items_orig_size
            on photo_items(orig_size, size)
        `.execute(db);
      },
    },
    {
      id: '152_photo_deleted_fp',
      async up(db) {
        // 「删过的照片」墓碑：用户在 NAS 上删掉的照片，手机备份以后不能再传一遍。
        //
        // 为什么不能只靠 photo_items.in_trash：回收站里的行还在，判重能命中；
        // 但「清空回收站」是 `delete from photo_items`，行一没，判重就彻底失去依据，
        // 用户下次备份手机又会把那些照片重新传上来 —— 这正是要避免的。
        // 所以删除动作发生时，把内容指纹单独记一份，且只增不删。
        await sql`
          create table if not exists photo_deleted_fp (
            id integer primary key autoincrement,
            owner_id text not null,
            size integer not null,
            orig_size integer not null default 0,
            content_md5 text not null default '',
            created_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_deleted_fp_size
            on photo_deleted_fp(owner_id, size)
        `.execute(db);
        // 同一张照片删两次不能堆重复行：写入侧统一用 `insert or ignore`。
        await sql`
          create unique index if not exists idx_photo_deleted_fp_uq
            on photo_deleted_fp(owner_id, size, content_md5)
        `.execute(db);
      },
    },
    {
      // 人脸「重建前快照」这套表是在 052 / 053 建起来的，本意是让重建可回滚。
      // 回滚功能后来没做（`photo_face_rebuild_runs.rolled_back_at` 永远是 null），
      // 但建表语句留了下来 —— 结果每次重建都往里灌一份全量快照，谁也不清理：
      // 真库里 `photo_face_prev_map` 涨到 175,493 行、`photo_face_clusters_prev`
      // 涨到 10,239 行，而全仓库 grep 只有建表处，**没有任何读写方**。
      //
      // 保留的只有 `photo_face_rebuild_runs`（`ai/settings.ts` 还在读它算覆盖率）。
      id: '161_drop_dead_face_snapshot',
      async up(db) {
        await sql`drop table if exists ${sql.table('photo_face_prev_map')}`.execute(db);
        await sql`drop table if exists ${sql.table('photo_face_clusters_prev')}`.execute(db);
      },
    },
    {
      // 裁掉三个「建了但查询计划永远用不上」的索引。
      //
      // 判断依据不是拍脑袋，是对真库跑 `explain query plan` 逐条验的：
      //   · idx_photo_items_ai_mask（ai_done_mask）
      //     全部查询都是位运算 `(ai_done_mask & X) <> X`，B-tree 索引对位运算无效，
      //     计划恒为 `SCAN photo_items`。
      //   · idx_photo_items_ai_pending（ai_skip_at）
      //     `ai_skip_at = 0` 覆盖几乎全表，选择性为零；带 owner 子查询的待办查询
      //     同样走 `SCAN`。
      //   · idx_photo_items_orig_size（orig_size, size）
      //     唯一用途是备份去重的 `(size in (...) or orig_size in (...))`，而 OR 优化
      //     要求每个分支都可索引 —— `size` 单列没有索引，所以整条 OR 退化，
      //     计划用 `idx_photo_items_library`。
      //
      // 这三条都是「纯写放大」：每次照片入库都要多维护三棵 B-tree。
      // 保留的 13 个索引全部在计划里被真实命中（timeline / library / media /
      // trash / md5 / phash / delete_batch / geohash2~7）。
      id: '166_photo_items_drop_unused_indexes',
      async up(db) {
        for (const name of [
          'idx_photo_items_ai_mask',
          'idx_photo_items_ai_pending',
          'idx_photo_items_orig_size',
        ]) {
          await sql`drop index if exists ${sql.table(name)}`.execute(db);
        }
      },
    },
    {
      // 「集合」并入「相册」。
      //
      // photo_collections 和 photo_albums 是同一件事的两套实现：都是「把照片挑成一组、
      // 按用户隔离」，差别只有集合少一个封面字段、也没有简介和排序。用户面对两个并列的
      // 入口无从选择 —— 真库两张表都是 0 行，说明确实没人用。
      //
      // 同一次迁移把相册升级成「规则相册」：rules_json 里存命中条件
      // （头像 / 场景 / 日期区间），命中即自动归入，后续新照片也自动收。
      //
      // ⚠️ 这里**不能**清 `071_photo_collections` 的执行记录。
      // 071 的迁移定义和 manifest 登记都还在（空操作），一旦记录被删，下次启动
      // 迁移器按 id 排序会重新执行它 —— 表现就是「表删了，重启又回来了」。
      // 160 / 168 之所以能清记录，是因为那批 id 连同迁移定义一起从清单里移除了。
      id: '169_photo_album_rules',
      async up(db) {
        await sql`drop table if exists ${sql.table('photo_collection_items')}`.execute(db);
        await sql`drop table if exists ${sql.table('photo_collections')}`.execute(db);

        const cols = (
          (await sql`pragma table_info(photo_albums)`.execute(db)).rows as Array<{ name: string }>
        ).map((r) => r.name);
        if (!cols.includes('rules_json')) {
          await sql.raw(`alter table photo_albums add column rules_json text not null default '[]'`).execute(
            db,
          );
        }
      },
    },
    {
      // 成长轨迹：服务端预计算出「阶段」（Stage）并落库，前端只做展示。
      //
      // 层级 Asset → Event → Stage → Track 里，Event 只在分段过程中隐式存在
      // （同一天/相邻 burst 的照片），不单独建表；Track = 某 person 的全部
      // Stage 有序序列，用 (owner_id, person_id, granularity) 索引表示。
      // stage_assets 只存每段的候选封面池（Top 12），不是阶段全量照片 ——
      // 全量照片由二级页按 (person, 时间窗) 现查，20 万张库不能全量冗余。
      id: '176_photo_growth',
      async up(db) {
        await sql`
          create table if not exists photo_growth_stages (
            id text primary key,
            owner_id text not null,
            person_id text not null,
            granularity text not null,
            seq integer not null,
            start_at integer not null,
            end_at integer not null,
            place_key text not null default '',
            place_name text not null default '',
            span_kind text not null default 'auto',
            title text not null default '',
            subtitle text not null default '',
            cover_asset_id text,
            cover_path text not null default '',
            secondary_path text not null default '',
            cover_score real not null default 0,
            reason_json text not null default '{}',
            photo_count integer not null default 0,
            milestone text not null default '',
            hint text not null default '',
            locked integer not null default 0,
            hidden integer not null default 0,
            version integer not null default 1,
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_growth_stages_track
            on photo_growth_stages(owner_id, person_id, granularity, start_at, seq)
        `.execute(db);
        await sql`
          create table if not exists photo_growth_stage_assets (
            stage_id text not null,
            asset_id text not null,
            rank integer not null,
            score real not null default 0,
            reason_json text not null default '{}',
            primary key (stage_id, asset_id)
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_growth_stage_assets_rank
            on photo_growth_stage_assets(stage_id, rank)
        `.execute(db);
        // 增量凭据：该 person 的照片数 / 最新拍摄时间没变就不重算。
        await sql`
          create table if not exists photo_growth_track_state (
            owner_id text not null,
            person_id text not null,
            granularity text not null,
            asset_count integer not null default 0,
            last_asset_at integer not null default 0,
            version integer not null default 0,
            built_at integer not null default 0,
            primary key (owner_id, person_id, granularity)
          )
        `.execute(db);
      },
    },
];
