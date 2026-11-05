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
      async up(db) {
        // 集合：把照片聚成一组（介于「相册」和「临时挑选」之间），按用户隔离
        await sql`
          create table if not exists photo_collections (
            id text primary key,
            name text not null,
            owner_id text not null default '',
            created_at integer not null,
            updated_at integer not null
          )
        `.execute(db);
        await sql`
          create index if not exists idx_photo_collections_owner
            on photo_collections(owner_id, created_at)
        `.execute(db);
        await sql`
          create table if not exists photo_collection_items (
            collection_id text not null,
            item_id text not null,
            added_at integer not null,
            primary key (collection_id, item_id)
          )
        `.execute(db);
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
];
