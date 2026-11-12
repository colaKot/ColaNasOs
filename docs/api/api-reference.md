# API 参考

> 由 `tool/gen-api-doc.js` 从 `contracts/openapi.json` 生成，**请勿手改**；改契约后执行 `npm run api:doc`。
> 当前：**402 个路径 / 428 个操作 / 18 个域**。鉴权统一为 `Authorization: Bearer <jwt>`，媒体直链另支持 `?token=`（5 分钟）。

## 域索引

- **子账号与权限**（`accounts`）· 21 个操作 · [跳转](#accounts)
- **认证与账号**（`auth`）· 1 个操作 · [跳转](#auth)
- **blog**（`blog`）· 23 个操作 · [跳转](#blog)
- **discover**（`discover`）· 23 个操作 · [跳转](#discover)
- **events**（`events`）· 1 个操作 · [跳转](#events)
- **文件**（`files`）· 18 个操作 · [跳转](#files)
- **开放集成（Webhook / deliveries）**（`integration`）· 6 个操作 · [跳转](#integration)
- **音乐**（`music`）· 35 个操作 · [跳转](#music)
- **其他**（`other`）· 2 个操作 · [跳转](#other)
- **相册**（`photo`）· 131 个操作 · [跳转](#photo)
- **player**（`player`）· 2 个操作 · [跳转](#player)
- **pt**（`pt`）· 26 个操作 · [跳转](#pt)
- **RSS 订阅**（`rss`）· 15 个操作 · [跳转](#rss)
- **同步**（`sync`）· 17 个操作 · [跳转](#sync)
- **系统监控**（`system`）· 20 个操作 · [跳转](#system)
- **tasks**（`tasks`）· 5 个操作 · [跳转](#tasks)
- **transfer**（`transfer`）· 8 个操作 · [跳转](#transfer)
- **影视**（`video`）· 74 个操作 · [跳转](#video)

## accounts

### 子账号与权限

#### `GET /api/v1/accounts/tokens`

当前用户的长期访问令牌（不含明文） · `apiTokenList`

- 参数：`uid` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/accounts/tokens`

创建长期访问令牌（明文只返回一次） · `apiTokenCreate`

- 请求体：`uid` string · 可选<br>`name` string · **必填**<br>`scopes` array<string> · **必填**<br>`expiresInDays` integer · 可选
- 响应：200 object · 错误 400

#### `POST /api/v1/accounts/tokens/revoke`

撤销长期访问令牌 · `apiTokenRevoke`

- 请求体：`id` string · **必填**<br>`uid` string · 可选
- 响应：200 object · 错误 404

#### `GET /api/v1/accounts/users`

账号列表 · `userList`

- 响应：200 object

#### `POST /api/v1/accounts/users/2fa/disable`

关闭 2FA · `userTotpDisable`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/accounts/users/2fa/enable`

用一次验证码启用 2FA · `userTotpEnable`

- 请求体：`id` string · **必填**<br>`code` string · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/accounts/users/2fa/setup`

生成 TOTP secret（未启用） · `userTotpSetup`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

#### `GET /api/v1/accounts/users/audit-logs`

账号操作审计（创建 / 编辑 / 删除 / 2FA / 权限） · `userAuditLogs`

- 参数：`uid` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/accounts/users/create`

创建子账号 · `userCreate`

- 请求体：`username` string · **必填**<br>`password` string · **必填**<br>`scopes` array<string> · 可选<br>`phone` string · 可选<br>`remark` string · 可选
- 响应：200 object · 错误 400

#### `POST /api/v1/accounts/users/delete`

删除账号（禁止删除自己与最后一个管理员） · `userDelete`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/accounts/users/disable`

启用 / 禁用账号 · `userDisable`

- 请求体：`id` string · **必填**<br>`disabled` boolean · **必填**
- 响应：200 object · 错误 404

#### `GET /api/v1/accounts/users/login-records`

登录记录（成功 / 失败，按用户与时间倒序） · `userLoginRecords`

- 参数：`uid` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选
- 响应：200 object

#### `GET /api/v1/accounts/users/policy`

读取子账号的应用白名单与路径 ACL · `userPolicyGet`

- 参数：`uid` · 查询 · string · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/accounts/users/policy`

设置子账号的应用白名单与路径 ACL（未传字段保持不变） · `userPolicySet`

- 请求体：`uid` string · **必填**<br>`allowedApps` array<string> · 可选<br>`paths` array<object> · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/accounts/users/update`

编辑账号（用户名 / 密码 / 手机 / 备注） · `userUpdate`

- 请求体：`id` string · **必填**<br>`username` string · 可选<br>`password` string · 可选<br>`phone` string · 可选<br>`remark` string · 可选<br>`scopes` array<string> · 可选
- 响应：200 object · 错误 400 / 404

#### `GET /api/v1/auth/bootstrap`

首次安装状态（库里是否还没有任何账号） · `authBootstrapStatus`

- 响应：200 object

#### `POST /api/v1/auth/bootstrap`

首次安装：创建第一个管理员（仅在无任何账号时可用） · `authBootstrap`

- 请求体：`username` string · **必填**<br>`password` string · **必填**
- 响应：200 object · 错误 400 / 409

#### `POST /api/v1/auth/login`

账号密码登录（可选 TOTP） · `authLogin`

- 请求体：`username` string · **必填**<br>`password` string · **必填**<br>`totp` string · 可选
- 响应：200 object · 错误 401

#### `POST /api/v1/security/ip/add`

加入 IP 黑名单（IP 或 CIDR） · `securityIpAdd`

- 请求体：`rule` string · **必填**
- 响应：200 object · 错误 400

#### `GET /api/v1/security/ip/list`

IP 黑名单 · `securityIpList`

- 响应：200 object

#### `POST /api/v1/security/ip/remove`

移出 IP 黑名单 · `securityIpRemove`

- 请求体：`rule` string · **必填**
- 响应：200 object

## auth

### 认证与账号

#### `POST /api/v1/auth/dev-token`

开发用临时令牌（仅当 COLANAS_DEV_TOKEN=1 且非 production 时可用） · `authDevToken`

- 响应：200 -

## blog

### blog

#### `GET /api/v1/blog/audio`

播放 / 下载（mp3，退化时给 wav；支持 Range） · `blogAudio`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 - · 错误 404

#### `GET /api/v1/blog/audio-url`

带短期令牌的播放地址 · `blogAudioUrl`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `BlogAudioUrlResponse` · 错误 404

#### `GET /api/v1/blog/episodes`

已生成的节目（新的在前） · `blogEpisodes`

- 参数：`limit` · 查询 · integer · 可选<br>`offset` · 查询 · integer · 可选
- 响应：200 `BlogEpisodeListResponse`

#### `POST /api/v1/blog/generate`

立即生成一期（后台执行） · `blogGenerate`

- 请求体：（空对象）
- 响应：200 `BlogGenerateResponse` · 错误 409 / 503

#### `GET /api/v1/blog/mt/model`

本地翻译模型下载状态（实时探测磁盘） · `blogMtModel`

- 响应：200 `BlogMtModelResponse`

#### `POST /api/v1/blog/mt/model/cancel`

取消翻译模型下载（已下部分保留，下次续传） · `blogMtModelCancel`

- 响应：200 `BlogMtModelResponse`

#### `POST /api/v1/blog/mt/model/download`

下载本地翻译模型（后台执行，前端轮询进度） · `blogMtModelDownload`

- 响应：200 `BlogMtModelResponse`

#### `GET /api/v1/blog/news`

预览当前设置会抓到的新闻（不生成音频） · `blogNews`

- 响应：200 `BlogNewsResponse`

#### `POST /api/v1/blog/preview`

合成试听句（同一音色只合成一次，之后读缓存） · `blogPreview`

- 请求体：（空对象）
- 响应：200 `BlogPreviewResponse` · 错误 503

#### `GET /api/v1/blog/preview/audio`

试听音频（inline，支持 Range） · `blogPreviewAudio`

- 参数：`voice` · 查询 · string · **必填**
- 响应：200 - · 错误 404

#### `POST /api/v1/blog/remove`

删除一期（连同音频文件） · `blogRemove`

- 请求体：（空对象）
- 响应：200 `BlogOkResponse`

#### `POST /api/v1/blog/resynth`

从已有稿件重跑语音合成（不抓新闻、不调云端模型、不消耗 token） · `blogResynth`

- 请求体：（空对象）
- 响应：200 `BlogResynthResponse` · 错误 400 / 404 / 409 / 503

#### `GET /api/v1/blog/script`

某一期的播报稿全文与引用链接 · `blogScript`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `BlogScriptResponse` · 错误 404

#### `GET /api/v1/blog/settings`

AI 新闻设置 · `blogSettings`

- 响应：200 `BlogSettingsResponse`

#### `POST /api/v1/blog/settings`

保存 AI 新闻设置（counts 整体提交；其余字段未传则保持不变） · `blogSaveSettings`

- 请求体：（空对象）
- 响应：200 `BlogSettingsResponse` · 错误 400

#### `GET /api/v1/blog/status`

生成进度 · `blogStatus`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `BlogStatusResponse` · 错误 404

#### `GET /api/v1/blog/tts/model`

语音模型下载状态（实时探测磁盘） · `blogTtsModel`

- 响应：200 `BlogTtsModelResponse`

#### `POST /api/v1/blog/tts/model/cancel`

取消下载（已下部分保留，下次续传） · `blogTtsModelCancel`

- 响应：200 `BlogTtsModelResponse`

#### `POST /api/v1/blog/tts/model/download`

一键下载语音模型（后台执行，前端轮询进度） · `blogTtsModelDownload`

- 响应：200 `BlogTtsModelResponse`

#### `GET /api/v1/blog/voices`

参考音色清单（内置 3 段 + 用户上传） · `blogVoices`

- 响应：200 `BlogVoiceListResponse`

#### `POST /api/v1/blog/voices/remove`

删除用户上传的音色（内置音色不可删） · `blogVoiceRemove`

- 请求体：（空对象）
- 响应：200 `BlogOkResponse`

#### `POST /api/v1/blog/voices/upload`

上传参考音色（base64 wav/mp3，自动转 24kHz 单声道） · `blogVoiceUpload`

- 请求体：（空对象）
- 响应：200 `BlogVoiceUploadResponse` · 错误 400

#### `POST /api/v1/blog/warmup`

预热语音模型（进页面时调用，点试听才不用等 30 秒） · `blogWarmup`

- 响应：200 `BlogWarmupResponse`

## discover

### discover

#### `GET /api/v1/discover/cache/stats`

发现缓存统计（图片文件数 / 字节、评分数） · `discoverCacheStats`

- 响应：200 object

#### `GET /api/v1/discover/catalog`

发现目录（trending / popular / top_rated / upcoming / now_playing / on_air） · `discoverCatalog`

- 参数：`kind` · 查询 · string · 可选<br>`media` · 查询 · string · 可选<br>`page` · 查询 · integer · 可选<br>`genre` · 查询 · string · 可选<br>`year` · 查询 · integer · 可选<br>`yearFrom` · 查询 · integer · 可选<br>`yearTo` · 查询 · integer · 可选<br>`language` · 查询 · string · 可选<br>`sort` · 查询 · string · 可选<br>`country` · 查询 · string · 可选<br>`minVote` · 查询 · number · 可选
- 响应：200 `DiscoverCatalogResponse`

#### `POST /api/v1/discover/catalog/prune`

清理超过保留期的榜单快照 · `discoverCatalogPrune`

- 响应：200 `DiscoverCatalogPruneResponse`

#### `GET /api/v1/discover/catalog/snapshots`

榜单快照清单（含 age / fresh，不含 payload） · `discoverCatalogSnapshots`

- 响应：200 `DiscoverCatalogSnapshotList`

#### `GET /api/v1/discover/detail`

影视详情（简介 / 类型 / 时长 / 主要演员） · `discoverDetail`

- 参数：`id` · 查询 · integer · **必填**<br>`media` · 查询 · string · 可选
- 响应：200 `DiscoverDetailResponse`

#### `GET /api/v1/discover/douban`

豆瓣榜单（热门/选电影等 tag） · `discoverDouban`

- 参数：`tag` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/discover/douban/catalogs/{kind}`

豆瓣榜单（按 code 取豆瓣榜，TMDB 反查补卡片） · `discoverDoubanCatalogs`

- 参数：`kind` · 路径 · string · **必填**
- 请求体：`code` string · **必填**<br>`count` integer · 可选<br>`fast` boolean · 可选
- 响应：200 object

#### `POST /api/v1/discover/douban/enrich`

批量补豆瓣评分（带缓存，缺的才联网） · `discoverDoubanEnrich`

- 请求体：`mediaIds` array<integer> · **必填**<br>`mediaType` string · 可选
- 响应：200 object

#### `GET /api/v1/discover/douban/rating`

按标题（+年份）查豆瓣评分 · `discoverDoubanRating`

- 参数：`title` · 查询 · string · **必填**<br>`year` · 查询 · string · 可选
- 响应：200 object

#### `GET /api/v1/discover/douban/settings`

读取豆瓣配置（Cookie 明文回传） · `discoverDoubanSettingsGet`

- 响应：200 object

#### `POST /api/v1/discover/douban/settings`

设置豆瓣 Cookie（可选） · `discoverDoubanSettings`

- 请求体：`cookie` string · **必填**
- 响应：200 object

#### `POST /api/v1/discover/douban/test`

测试豆瓣连通性（网站 / Cookie / TMDB 反查） · `discoverDoubanTest`

- 请求体：`cookie` string · 可选
- 响应：200 object

#### `GET /api/v1/discover/favorites`

当前账号的发现收藏（id + mediaType + state） · `discoverFavorites`

- 参数：`state` · 查询 · string · 可选
- 响应：200 `DiscoverFavoriteListResponse`

#### `POST /api/v1/discover/favorites/set`

收藏 / 取消收藏发现条目（每用户独立） · `discoverFavoriteSet`

- 请求体：（空对象）
- 响应：200 `DiscoverFavoriteResponse` · 错误 400

#### `GET /api/v1/discover/genres/{mediaType}`

风格表（TMDB 官方 id + 中文名） · `discoverGenres`

- 参数：`mediaType` · 路径 · string · **必填**
- 响应：200 object

#### `GET /api/v1/discover/image`

海报 / 剧照代理（磁盘缓存；客户端不需要知道图片域） · `discoverImage`

- 参数：`path` · 查询 · string · **必填**<br>`size` · 查询 · string · 可选
- 响应：200 -

#### `GET /api/v1/discover/image-url`

图片地址（本机代理路径） · `discoverImageUrl`

- 参数：`path` · 查询 · string · **必填**<br>`size` · 查询 · string · 可选
- 响应：200 object

#### `GET /api/v1/discover/meta`

已刮削的条目（简介 / 年份 / 类型 / 评分） · `discoverMeta`

- 参数：`libraryId` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `DiscoverMetaList`

#### `POST /api/v1/discover/scrape`

扫描同目录 NFO（离线刮削） · `discoverScrape`

- 请求体：（空对象）
- 响应：200 `DiscoverScrapeResponse`

#### `GET /api/v1/discover/search`

搜索影视 · `discoverSearch`

- 参数：`q` · 查询 · string · **必填**<br>`media` · 查询 · string · 可选<br>`page` · 查询 · integer · 可选
- 响应：200 `DiscoverCatalogResponse`

#### `GET /api/v1/discover/settings`

影视发现设置（只回是否已配置 key，不回 key 本身） · `discoverSettingsGet`

- 响应：200 `DiscoverSettings`

#### `POST /api/v1/discover/settings`

保存影视发现设置（apiKey 留空 = 不改） · `discoverSettingsSet`

- 请求体：（空对象）
- 响应：200 `DiscoverSettings`

#### `POST /api/v1/discover/settings/test`

测试 TMDB 连通性（请求 /3/configuration） · `discoverSettingsTest`

- 响应：200 object

## events

### events

#### `GET /api/v1/events/recent`

事件增量拉取（按序号，供客户端局部刷新） · `eventsRecent`

- 参数：`since` · 查询 · integer · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 object

## files

### 文件

#### `POST /api/v1/files/check`

分片上传预检（秒传判定 + 已收分片） · `filesCheck`

- 请求体：（空对象）
- 响应：200 `FilesCheckResponse`

#### `POST /api/v1/files/chunk`

上传单个分片（application/octet-stream） · `filesChunk`

- 参数：`path` · 查询 · string · **必填**<br>`index` · 查询 · integer · **必填**<br>`total` · 查询 · integer · 可选<br>`sid` · 查询 · string · 可选
- 响应：200 `FilesChunkResponse`

#### `POST /api/v1/files/delete`

删除（默认移入回收站；permanent=true 才真删） · `filesDelete`

- 请求体：（空对象）
- 响应：200 `FilesOpResult` · 错误 400

#### `GET /api/v1/files/download`

下载文件（Range / ETag） · `filesDownload`

- 参数：`path` · 查询 · string · **必填**<br>`inline` · 查询 · string · 可选
- 响应：200 -

#### `POST /api/v1/files/index`

触发索引（入队，返回任务 id；同一时刻只跑一轮） · `filesIndex`

- 响应：200 object · 错误 503

#### `GET /api/v1/files/index/status`

索引进度（已索引条数 / 断点序号 / 最近事务耗时） · `filesIndexStatus`

- 响应：200 object

#### `GET /api/v1/files/list`

列出目录（单层，目录优先） · `filesList`

- 参数：`path` · 查询 · string · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `FilesListResponse`

#### `POST /api/v1/files/merge`

合并分片（幂等） · `filesMerge`

- 请求体：（空对象）
- 响应：200 `FilesMergeResponse`

#### `POST /api/v1/files/mkdir`

新建目录（中间层自动补齐） · `filesMkdir`

- 请求体：（空对象）
- 响应：200 `FilesMkdirResponse` · 错误 400 / 409

#### `POST /api/v1/files/move`

移动 / 复制（批量，单条失败不影响其它条） · `filesMove`

- 请求体：（空对象）
- 响应：200 `FilesOpResult` · 错误 400

#### `GET /api/v1/files/op-logs`

文件操作日志（按用户 / 类型 / 状态 / 关键词过滤，分页） · `filesOpLogs`

- 参数：`uid` · 查询 · string · 可选<br>`action` · 查询 · string · 可选<br>`status` · 查询 · enum(ok, failed) · 可选<br>`q` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`offset` · 查询 · integer · 可选
- 响应：200 `FilesOpLogListResponse`

#### `POST /api/v1/files/rename`

重命名（同目录改名，名称不允许含分隔符） · `filesRename`

- 请求体：（空对象）
- 响应：200 `FilesRenameResponse` · 错误 400 / 404 / 409

#### `GET /api/v1/files/roots`

可浏览的根（盘符 / 文件根 / 来源根） · `filesRoots`

- 响应：200 `FilesRootsResponse`

#### `GET /api/v1/files/search`

按路径关键词搜索已索引文件（先 POST /files/index） · `filesSearch`

- 参数：`q` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 object · 错误 400

#### `GET /api/v1/files/thumb`

图片缩略图（JPEG；懒生成 + 文件缓存，缺 ffmpeg 时 503） · `filesThumb`

- 参数：`path` · 查询 · string · **必填**<br>`size` · 查询 · integer · 可选<br>`at` · 查询 · number · 可选
- 响应：200 -

#### `GET /api/v1/files/trash`

回收站批次与条目 · `filesTrashList`

- 响应：200 `FilesTrashListResponse`

#### `POST /api/v1/files/trash/empty`

清空回收站（可指定批次） · `filesTrashEmpty`

- 请求体：（空对象）
- 响应：200 `FilesTrashEmptyResponse`

#### `POST /api/v1/files/trash/restore`

从回收站还原到原路径（目标已存在时该条失败） · `filesTrashRestore`

- 请求体：（空对象）
- 响应：200 `FilesOpResult` · 错误 400

## integration

### 开放集成（Webhook / deliveries）

#### `GET /api/v1/integration/deliveries`

投递记录 · `webhookDeliveries`

- 参数：`hookId` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/integration/emit`

触发事件（内部/调试） · `integrationEmit`

- 请求体：`event` string · **必填**<br>`payload` - · 可选
- 响应：200 object

#### `GET /api/v1/integration/webhooks`

Webhook 列表（不含 secret） · `webhookList`

- 响应：200 object

#### `POST /api/v1/integration/webhooks`

创建 Webhook（secret 仅本次返回） · `webhookCreate`

- 请求体：`url` string · **必填**<br>`events` array<string> · **必填**<br>`secret` string · 可选
- 响应：200 object · 错误 400

#### `POST /api/v1/integration/webhooks/remove`

删除 Webhook · `webhookRemove`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/integration/webhooks/test`

发送 test 事件 · `webhookTest`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

## music

### 音乐

#### `GET /api/v1/music/albums`

专辑聚合（张数 / 总时长 / 代表封面） · `musicAlbums`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`sort` · 查询 · enum(name, tracks, year) · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicAlbumListResponse`

#### `GET /api/v1/music/artists`

艺人聚合（曲目数 / 专辑数 / 代表封面） · `musicArtists`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`sort` · 查询 · enum(name, tracks) · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicArtistListResponse`

#### `GET /api/v1/music/auto-playlist`

自动歌单曲目（kind = recent_added / recently_played / most_played / never_played） · `musicAutoPlaylist`

- 参数：`kind` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicAutoPlaylistTracksResponse` · 错误 400

#### `GET /api/v1/music/auto-playlists`

自动歌单概览（最近添加 / 最近播放 / 最常播放 / 从未播放） · `musicAutoPlaylists`

- 响应：200 `MusicAutoPlaylistListResponse`

#### `GET /api/v1/music/cache`

音乐转码缓存占用 · `musicCacheStats`

- 响应：200 `MusicCacheStatsResponse`

#### `POST /api/v1/music/cache/clear`

清空音乐转码缓存 · `musicCacheClear`

- 响应：200 `MusicCacheClearResponse`

#### `GET /api/v1/music/collections`

当前用户的音乐合集（含曲目数与封面） · `musicCollectionList`

- 响应：200 `MusicCollectionListResponse`

#### `POST /api/v1/music/collections`

新建音乐合集 · `musicCollectionCreate`

- 请求体：（空对象）
- 响应：200 `MusicCollection` · 错误 400

#### `GET /api/v1/music/collections/items`

合集里的曲目 · `musicCollectionItems`

- 参数：`id` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicListResponse` · 错误 404

#### `POST /api/v1/music/collections/remove`

删除合集（不动磁盘文件与曲库索引） · `musicCollectionRemove`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse`

#### `POST /api/v1/music/collections/update`

改名 / 换目录 · `musicCollectionUpdate`

- 请求体：（空对象）
- 响应：200 `MusicCollection` · 错误 404

#### `GET /api/v1/music/cover`

内嵌封面（首次访问生成，之后走文件缓存） · `musicCover`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 -

#### `POST /api/v1/music/favorite`

收藏 / 取消收藏曲目（按用户隔离） · `musicFavorite`

- 请求体：（空对象）
- 响应：200 `MusicStateOk`

#### `GET /api/v1/music/favorites`

我的收藏（按收藏时间倒序，返回完整曲目） · `musicFavorites`

- 响应：200 `MusicListResponse`

#### `GET /api/v1/music/favorites/ids`

我的收藏 id 列表（曲库页星标状态用，只回 id 不带曲目） · `musicFavoriteIds`

- 响应：200 object

#### `GET /api/v1/music/history`

播放历史（按时间倒序，返回完整曲目） · `musicHistory`

- 参数：`limit` · 查询 · integer · 可选
- 响应：200 `MusicListResponse`

#### `GET /api/v1/music/item`

曲目详情 · `musicItem`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 `MusicTrack` · 错误 404

#### `GET /api/v1/music/libraries`

音乐库列表 · `musicLibraryList`

- 响应：200 `MusicLibraryListResponse`

#### `POST /api/v1/music/libraries`

新建音乐库（目录须在 files 根内） · `musicLibraryCreate`

- 请求体：（空对象）
- 响应：200 `MusicLibraryItem` · 错误 400 / 409

#### `POST /api/v1/music/libraries/remove`

删除音乐库（级联清理曲目与歌单引用） · `musicLibraryRemove`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse` · 错误 404

#### `GET /api/v1/music/list`

曲目列表（可排序 + 排序键 cursor） · `musicList`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`artist` · 查询 · string · 可选<br>`album` · 查询 · string · 可选<br>`albumArtist` · 查询 · string · 可选<br>`genre` · 查询 · string · 可选<br>`year` · 查询 · integer · 可选<br>`sort` · 查询 · enum(title, artist, album, created, duration, year) · 可选<br>`order` · 查询 · enum(asc, desc) · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicListResponse` · 错误 400

#### `GET /api/v1/music/lyrics`

歌词（旁挂 .lrc 优先，其次内嵌；可选 <base>.<lang>.lrc 双语对照） · `musicLyrics`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选<br>`lang` · 查询 · string · 可选
- 响应：200 `MusicLyricsResponse` · 错误 400 / 404

#### `POST /api/v1/music/play`

记录一次播放（写历史） · `musicPlay`

- 请求体：（空对象）
- 响应：200 `MusicStateOk`

#### `GET /api/v1/music/playlists`

当前用户的歌单 · `musicPlaylistList`

- 响应：200 `MusicPlaylistListResponse`

#### `POST /api/v1/music/playlists`

新建歌单（可按 id 批量加入） · `musicPlaylistCreate`

- 请求体：（空对象）
- 响应：200 `MusicPlaylist` · 错误 400

#### `POST /api/v1/music/playlists/add`

向歌单加入曲目 · `musicPlaylistAdd`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse` · 错误 404

#### `POST /api/v1/music/playlists/delete`

删除歌单 · `musicPlaylistDelete`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse` · 错误 404

#### `GET /api/v1/music/playlists/items`

歌单曲目（按加入顺序） · `musicPlaylistItems`

- 参数：`playlistId` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 `MusicListResponse` · 错误 404

#### `POST /api/v1/music/playlists/remove`

从歌单移出曲目 · `musicPlaylistRemove`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse` · 错误 404

#### `POST /api/v1/music/playlists/rename`

重命名歌单 · `musicPlaylistRename`

- 请求体：（空对象）
- 响应：200 `MusicOkResponse` · 错误 404

#### `POST /api/v1/music/scan`

扫描索引（ffmpeg 解析 tags / 时长；未变文件跳过） · `musicScan`

- 请求体：（空对象）
- 响应：200 `MusicScanResponse` · 错误 404

#### `POST /api/v1/music/scan/enqueue`

入队扫描（立即返回任务 id；进度与失败记录见 /tasks） · `musicScanEnqueue`

- 请求体：（空对象）
- 响应：200 object · 错误 404

#### `GET /api/v1/music/stats`

曲目 / 专辑 / 艺术家 / 总时长 · `musicStats`

- 响应：200 `MusicStatsResponse`

#### `GET /api/v1/music/stream`

播放 / 下载（支持 Range / ETag；format=transcoded 读 AAC 缓存） · `musicStream`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选<br>`format` · 查询 · string · 可选
- 响应：200 -

#### `GET /api/v1/music/stream-url`

生成带短期令牌的播放地址（format=auto 时 Web 端按需转 AAC） · `musicStreamUrl`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选<br>`format` · 查询 · string · 可选
- 响应：200 `MusicStreamUrlResponse` · 错误 404

## other

### 其他

#### `GET /api/mcp`

- · `-`

- 响应：200 -

#### `POST /api/mcp`

- · `-`

- 响应：200 -

## photo

### 相册

#### `GET /api/v1/photo/activities`

某个活动下的照片 · `photoActivities`

- 参数：`label` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoAiPhotoRefList`

#### `GET /api/v1/photo/activities/summary`

活动分布（按张数倒序） · `photoActivitySummary`

- 响应：200 `PhotoSceneSummary`

#### `POST /api/v1/photo/ai/activities`

分批做活动识别（SigLIP2 零样本，τ=0.078） · `photoAiActivities`

- 请求体：（空对象）
- 响应：200 `PhotoAiAnalyzeResponse` · 错误 503

#### `POST /api/v1/photo/ai/analyze`

分批分析照片（人脸 / 场景 / embedding，可选 OCR 与活动） · `photoAiAnalyze`

- 请求体：（空对象）
- 响应：200 `PhotoAiAnalyzeResponse` · 错误 503

#### `POST /api/v1/photo/ai/ask`

相册助手问答（配了模型走模型，没配走本地统计规则） · `photoAiAsk`

- 请求体：（空对象）
- 响应：200 `PhotoAskResponse`

#### `GET /api/v1/photo/ai/config`

AI 设置（配置 / 进度 / 任务队列） · `photoAiConfig`

- 响应：200 `PhotoAiSettings`

#### `POST /api/v1/photo/ai/config`

保存 AI 设置（部分字段） · `photoAiConfigSet`

- 请求体：（空对象）
- 响应：200 `PhotoAiConfig`

#### `POST /api/v1/photo/ai/mcp/config`

保存 MCP 配置（开关 / 挂载用户） · `photoMcpConfigSet`

- 请求体：（空对象）
- 响应：200 `PhotoMcpStatus`

#### `GET /api/v1/photo/ai/mcp/status`

MCP 开放平台状态 · `photoMcpStatus`

- 响应：200 `PhotoMcpStatus`

#### `POST /api/v1/photo/ai/mcp/token/rotate`

轮换 MCP 访问令牌（明文只返回一次） · `photoMcpTokenRotate`

- 响应：200 `PhotoMcpTokenResponse`

#### `GET /api/v1/photo/ai/model-api`

模型 API 配置（只读掩码视图，与全局 AI 服务共用一份） · `photoAiModelApi`

- 响应：200 `PhotoModelApi`

#### `POST /api/v1/photo/ai/model-api`

保存模型 API（apiKey 留空 = 保留已保存的密钥） · `photoAiModelApiSet`

- 请求体：（空对象）
- 响应：200 `PhotoModelApi`

#### `POST /api/v1/photo/ai/model-api/test`

测试模型 API 连通性（先 /models，失败再兜底最小 chat 请求） · `photoAiModelApiTest`

- 请求体：（空对象）
- 响应：200 `PhotoModelApiTestResult`

#### `GET /api/v1/photo/ai/models`

模型目录（只读） · `photoModels`

- 响应：200 `PhotoModelList`

#### `POST /api/v1/photo/ai/ocr`

分批做文字识别（票夹与语义搜索的原料） · `photoAiOcr`

- 请求体：（空对象）
- 响应：200 `PhotoAiAnalyzeResponse` · 错误 503

#### `POST /api/v1/photo/ai/queue/pause`

暂停 / 恢复 AI 任务队列 · `photoAiQueuePause`

- 请求体：（空对象）
- 响应：200 `PhotoAiConfig`

#### `POST /api/v1/photo/ai/rerun`

单张重新识别：face / place / ocr / activity 分项清除，等下一轮 analyze 重算 · `photoAiRerun`

- 请求体：`photoId` string · **必填**<br>`face` boolean · 可选<br>`place` boolean · 可选<br>`ocr` boolean · 可选<br>`activity` boolean · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/photo/ai/reset`

清空某一类识别结果（OCR / 场景 / 活动 / 去重） · `photoAiReset`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/ai/scan`

整库后台识别（入队，重启后可续跑） · `photoAiScan`

- 请求体：（空对象）
- 响应：200 `PhotoAiScanResponse` · 错误 503

#### `GET /api/v1/photo/albums`

当前用户的相册列表 · `photoAlbumList`

- 响应：200 `PhotoAlbumListResponse`

#### `POST /api/v1/photo/albums`

新建相册（可按 id 批量加入） · `photoAlbumCreate`

- 请求体：（空对象）
- 响应：200 `PhotoAlbum` · 错误 400

#### `POST /api/v1/photo/albums/add`

向相册加入照片 · `photoAlbumAdd`

- 请求体：（空对象）
- 响应：200 `PhotoOkResponse` · 错误 404

#### `POST /api/v1/photo/albums/delete`

删除相册 · `photoAlbumDelete`

- 请求体：（空对象）
- 响应：200 `PhotoOkResponse` · 错误 404

#### `GET /api/v1/photo/albums/items`

相册成员（时间轴序） · `photoAlbumItems`

- 参数：`albumId` · 查询 · string · **必填**<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoTimelineResponse` · 错误 400 / 404

#### `POST /api/v1/photo/albums/reapply`

按规则重算相册成员（只增不减，返回新增张数） · `photoAlbumReapply`

- 请求体：（空对象）
- 响应：200 `PhotoAlbum` · 错误 404

#### `POST /api/v1/photo/albums/remove`

从相册移出照片 · `photoAlbumRemove`

- 请求体：（空对象）
- 响应：200 `PhotoOkResponse` · 错误 404

#### `POST /api/v1/photo/albums/update`

编辑相册（名称 / 简介 / 封面 / 排序） · `photoAlbumUpdate`

- 请求体：（空对象）
- 响应：200 `PhotoAlbum` · 错误 400 / 404

#### `POST /api/v1/photo/backup/check`

（兼容）备份前置比对；新客户端请用 /backup/check_content · `photoBackupCheck`

- 请求体：（空对象）
- 响应：200 `PhotoBackupCheckResponse`

#### `POST /api/v1/photo/backup/check_content`

备份内容去重：跨全部相册源查已有内容与一定不存在的 size · `photoBackupCheckContent`

- 请求体：（空对象）
- 响应：200 `PhotoBackupCheckContentResponse`

#### `POST /api/v1/photo/backup/commit`

登记一次备份结果 · `photoBackupCommit`

- 请求体：（空对象）
- 响应：200 `PhotoBackupCommitResponse`

#### `GET /api/v1/photo/backup/status`

最近的备份记录 · `photoBackupStatus`

- 响应：200 `PhotoBackupStatusResponse`

#### `GET /api/v1/photo/calendar`

某年各月的张数与封面（年视图下钻） · `photoCalendar`

- 参数：`year` · 查询 · integer · 可选
- 响应：200 `PhotoCalendarResponse`

#### `POST /api/v1/photo/cleanup/apply`

执行清理（移入回收站，可按批次撤销） · `photoCleanupApply`

- 请求体：（空对象）
- 响应：200 `PhotoCleanupApplyResponse` · 错误 400

#### `GET /api/v1/photo/cleanup/batches`

最近的清理批次 · `photoCleanupBatches`

- 响应：200 `PhotoCleanupBatchList`

#### `POST /api/v1/photo/cleanup/md5`

补齐候选照片的 content_md5（只算 size 撞车的那批） · `photoCleanupBackfillMd5`

- 请求体：（空对象）
- 响应：200 `PhotoCleanupBackfillResponse`

#### `POST /api/v1/photo/cleanup/phash/scan`

开始相似照片扫描（pHash 扫描 → 比对） · `photoPhashScan`

- 响应：200 `PhotoPhashScanResponse`

#### `GET /api/v1/photo/cleanup/phash/status`

相似照片感知哈希扫描进度 · `photoPhashStatus`

- 响应：200 `PhotoPhashStatus`

#### `POST /api/v1/photo/cleanup/preview`

清理预演：内容重复 / 同名同大小 / 相似（只读，不改库） · `photoCleanupPreview`

- 请求体：（空对象）
- 响应：200 `PhotoCleanupPreviewResponse`

#### `POST /api/v1/photo/cleanup/undo`

撤销一个清理批次（恢复回收站状态） · `photoCleanupUndo`

- 请求体：（空对象）
- 响应：200 `PhotoCleanupUndoResponse` · 错误 404

#### `POST /api/v1/photo/delete`

批量删除（可选放入回收站） · `photoDelete`

- 请求体：（空对象）
- 响应：200 `PhotoDeleteResponse` · 错误 400

#### `GET /api/v1/photo/exif`

照片属性与 EXIF（按需解析文件头；无 EXIF 字段返回 null） · `photoExif`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 object · 错误 404

#### `GET /api/v1/photo/face/image`

人脸裁剪图（JPEG；无 bbox 的老数据回退整图缩略图） · `photoFaceImage`

- 参数：`id` · 查询 · string · **必填**<br>`size` · 查询 · integer · 可选
- 响应：200 -

#### `GET /api/v1/photo/faces`

某个人脸簇下的照片（分页，按拍摄时间倒序） · `photoFaces`

- 参数：`id` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · integer · 可选
- 响应：200 `PhotoFaceList`

#### `POST /api/v1/photo/faces/backfill`

只补人脸框（不重算场景/嵌入，保留簇归属） · `photoFaceBackfill`

- 请求体：（空对象）
- 响应：200 `PhotoFaceBackfillResponse`

#### `GET /api/v1/photo/faces/clusters`

人脸聚类列表（按人数倒序，分页；少于 minCount 的碎片组不显示，具名组豁免） · `photoFaceClusters`

- 参数：`minCount` · 查询 · integer · 可选<br>`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · integer · 可选
- 响应：200 `PhotoFaceClusterList`

#### `POST /api/v1/photo/faces/cover`

把簇内某张照片设为人脸封面 · `photoFaceCover`

- 请求体：（空对象）
- 响应：200 `PhotoFaceCoverResponse` · 错误 400

#### `POST /api/v1/photo/faces/dissolve`

解散人脸簇（脸放回未分组，不删数据） · `photoFaceDissolve`

- 请求体：（空对象）
- 响应：200 `PhotoFaceOk` · 错误 404

#### `POST /api/v1/photo/faces/merge`

把一个人脸簇并入另一个（from → to） · `photoFaceMerge`

- 请求体：（空对象）
- 响应：200 `PhotoFaceMergeResponse` · 错误 400

#### `POST /api/v1/photo/faces/merge-candidates`

跨照片二次合并的候选簇对（只读，逐对确认后调 /faces/merge） · `photoFaceMergeCandidates`

- 请求体：（空对象）
- 响应：200 `PhotoFaceMergeCandidateList`

#### `POST /api/v1/photo/faces/merge-similar`

自动合并相似人物（同框冲突跳过） · `photoFaceMergeSimilar`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/faces/merge-undo`

撤消人脸合并（按审计记录还原被并掉的簇与成员） · `photoFaceMergeUndo`

- 请求体：（空对象）
- 响应：200 `PhotoFaceMergeUndoResponse`

#### `POST /api/v1/photo/faces/move`

把单张人脸移到另一个簇（toClusterId=null 表示移出成未分组） · `photoFaceMove`

- 请求体：（空对象）
- 响应：200 `PhotoFaceMoveResponse` · 错误 400

#### `POST /api/v1/photo/faces/name`

给人脸簇命名（空串 = 取消命名） · `photoFaceName`

- 请求体：（空对象）
- 响应：200 `PhotoFaceOk` · 错误 404

#### `POST /api/v1/photo/faces/purge`

清理误检人脸（仅低检测置信度） · `photoFacePurge`

- 响应：200 `PhotoAiOpResponse`

#### `GET /api/v1/photo/faces/relations`

人物关系图：同框共现边 + 证据张数 · `photoFaceRelations`

- 参数：`limit` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/photo/faces/rescan-missing`

补齐漏检：对已分析但没有检出人脸的照片重新检测 · `photoFaceRescanMissing`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse` · 错误 503

#### `POST /api/v1/photo/faces/rescan/preview`

人脸重扫预演：只算差异，不写库 · `photoFaceRescanPreview`

- 响应：200 object

#### `POST /api/v1/photo/faces/reset`

全部重新识别人脸（清空现有聚类与人脸记录） · `photoFaceResetAll`

- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/faces/sweep`

二轮收割：把挂起脸与历史碎片簇按成员级相似度重新归位 · `photoFaceSweep`

- 请求体：（空对象）
- 响应：200 `PhotoFaceSweepResult`

#### `POST /api/v1/photo/faces/tuning`

保存人脸聚类参数（认人严格度 / 参考数 / 线程数） · `photoFaceTuning`

- 请求体：（空对象）
- 响应：200 `PhotoAiTuningResponse`

#### `POST /api/v1/photo/favorite`

批量收藏 / 取消收藏 · `photoFavoriteSet`

- 请求体：（空对象）
- 响应：200 `PhotoFavoriteResponse`

#### `POST /api/v1/photo/filter`

按条件组合筛选照片（与智能规则同一套判据，不落库） · `photoFilter`

- 请求体：（空对象）
- 响应：200 `PhotoFilterResponse` · 错误 400

#### `GET /api/v1/photo/folders`

文件视图：按目录聚合照片 · `photoFolders`

- 参数：`path` · 查询 · string · 可选
- 响应：200 `PhotoFolderList`

#### `GET /api/v1/photo/folders/roots`

文件视图根：当前用户的相册来源目录 · `photoFolderRoots`

- 响应：200 `PhotoFolderRoots`

#### `GET /api/v1/photo/fs/list`

列出本机目录（选择来源目录） · `photoFsList`

- 参数：`path` · 查询 · string · 可选
- 响应：200 `PhotoFsList` · 错误 400

#### `GET /api/v1/photo/fs/roots`

本机盘符 / 根目录 · `photoFsRoots`

- 响应：200 `PhotoFsRoots`

#### `GET /api/v1/photo/geo/missing`

缺 GPS 的照片 · `photoGeoMissing`

- 参数：`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · string · 可选
- 响应：200 `PhotoTimelineResponse`

#### `GET /api/v1/photo/geo/references`

最近带 GPS 的照片（GPS 补全的参考图） · `photoGeoReferences`

- 参数：`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · string · 可选
- 响应：200 `PhotoGeoReferenceList`

#### `POST /api/v1/photo/geo/set`

给照片补经纬度（同时物化 geohash） · `photoGeoSet`

- 请求体：（空对象）
- 响应：200 `PhotoGeoSetResponse` · 错误 400

#### `POST /api/v1/photo/geo/vision/apply`

确认视觉候选：写入坐标（可微调） · `photoGeoVisionApply`

- 请求体：（空对象）
- 响应：200 `PhotoGeoSetResponse` · 错误 404

#### `GET /api/v1/photo/geo/vision/candidates`

GPS 视觉候选（相似照片的坐标作为锚点） · `photoGeoVisionCandidates`

- 参数：`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · string · 可选
- 响应：200 `PhotoGeoVisionList`

#### `POST /api/v1/photo/geo/vision/reject`

忽略一个 GPS 视觉候选 · `photoGeoVisionReject`

- 请求体：（空对象）
- 响应：200 `PhotoGeoSetResponse`

#### `POST /api/v1/photo/geo/vision/scan`

开始生成 GPS 视觉候选（CLIP 最近邻） · `photoGeoVisionScan`

- 响应：200 `PhotoGeoVisionStatus`

#### `GET /api/v1/photo/geo/vision/status`

GPS 视觉候选生成进度 · `photoGeoVisionStatus`

- 响应：200 `PhotoGeoVisionStatus`

#### `GET /api/v1/photo/home/summary`

相册首页看板（统计 / 足迹 / 人物 / 那年今日） · `photoHomeSummary`

- 响应：200 `PhotoHomeSummary`

#### `GET /api/v1/photo/item`

单张照片详情 · `photoItem`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `PhotoItem` · 错误 404

#### `GET /api/v1/photo/libraries`

相册库列表 · `photoLibraryList`

- 响应：200 `PhotoLibraryListResponse`

#### `POST /api/v1/photo/libraries`

新建相册库（目录须在 files 根内） · `photoLibraryCreate`

- 请求体：（空对象）
- 响应：200 `PhotoLibraryItem` · 错误 400 / 409

#### `POST /api/v1/photo/libraries/remove`

删除相册库（级联清理索引与相册成员） · `photoLibraryRemove`

- 请求体：（空对象）
- 响应：200 `PhotoOkResponse` · 错误 404

#### `POST /api/v1/photo/libraries/update`

设置当前用户相册库的来源目录 · `photoLibraryUpdate`

- 请求体：（空对象）
- 响应：200 `PhotoLibraryItem` · 错误 400 / 404

#### `GET /api/v1/photo/live`

动态照片里的那段视频（支持 Range；非动态照片 404） · `photoLive`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 -

#### `GET /api/v1/photo/map/bounds`

可视范围内的 geohash 格代表点（客户端按世界像素聚簇） · `photoMapBounds`

- 参数：`minLat` · 查询 · number · **必填**<br>`minLng` · 查询 · number · **必填**<br>`maxLat` · 查询 · number · **必填**<br>`maxLng` · 查询 · number · **必填**<br>`zoom` · 查询 · number · 可选<br>`limit` · 查询 · integer · 可选<br>`libraryId` · 查询 · string · 可选
- 响应：200 `PhotoMapBoundsResponse` · 错误 400

#### `GET /api/v1/photo/map/cells`

点开一个簇：按格集合精确取回照片（total 与角标同源） · `photoMapCells`

- 参数：`keys` · 查询 · string · **必填**<br>`precision` · 查询 · integer · **必填**<br>`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · string · 可选
- 响应：200 `PhotoMapCellsResponse` · 错误 400

#### `GET /api/v1/photo/map/journey`

行程连线（有 GPS 的照片按拍摄时间串成若干段） · `photoMapJourney`

- 参数：`from` · 查询 · integer · 可选<br>`to` · 查询 · integer · 可选<br>`libraryId` · 查询 · string · 可选<br>`gapHours` · 查询 · integer · 可选<br>`maxPoints` · 查询 · integer · 可选
- 响应：200 `PhotoMapJourneyResponse` · 错误 400

#### `GET /api/v1/photo/map/place`

按真实距离取最近地名（30km 闸门，单语言） · `photoMapPlace`

- 参数：`geohash` · 查询 · string · **必填**<br>`lat` · 查询 · number · 可选<br>`lng` · 查询 · number · 可选<br>`locale` · 查询 · string · 可选
- 响应：200 `PhotoMapPlaceResponse`

#### `GET /api/v1/photo/map/tile`

底图瓦片（本地缓存代理，30 天） · `photoMapTile`

- 参数：`z` · 查询 · integer · **必填**<br>`x` · 查询 · integer · **必填**<br>`y` · 查询 · integer · **必填**<br>`server` · 查询 · string · 可选
- 响应：200 string · 错误 400 / 404 / 502

#### `GET /api/v1/photo/map/tile-servers`

可用底图源（默认 + 自定义） · `photoMapTileServers`

- 响应：200 `PhotoMapTileServerList`

#### `POST /api/v1/photo/map/tile-servers/current`

切换底图源（内置或自定义 URL 模板） · `photoMapTileServerSet`

- 请求体：（空对象）
- 响应：200 `PhotoMapTileServer` · 错误 400

#### `GET /api/v1/photo/memories`

记忆：候选 / 已确认 / 已忽略 + 年度章节 · `photoMemories`

- 参数：`days` · 查询 · integer · 可选<br>`minPhotos` · 查询 · integer · 可选<br>`limit` · 查询 · integer · 可选<br>`offset` · 查询 · integer · 可选
- 响应：200 `PhotoMemoryList`

#### `GET /api/v1/photo/memories/chapters`

人生章节：按年成书，一页 = 一天（左页大图 + 精选，右页影像日记） · `photoChapterBook`

- 参数：`year` · 查询 · integer · 可选<br>`locale` · 查询 · string · 可选<br>`limitDays` · 查询 · integer · 可选
- 响应：200 `PhotoChapterBook`

#### `GET /api/v1/photo/memories/day-frames`

一日一帧：每天挑一张代表作（配当日标签与地点） · `photoDayFrames`

- 参数：`days` · 查询 · integer · 可选<br>`locale` · 查询 · string · 可选
- 响应：200 `PhotoDayFrameList`

#### `POST /api/v1/photo/memories/ignore`

忽略一条记忆候选 · `photoMemoryIgnore`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/memories/remove`

删除一条已确认记忆 · `photoMemoryRemove`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/memories/restore`

把忽略的记忆恢复为已确认 · `photoMemoryRestore`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `POST /api/v1/photo/memories/save`

确认一条记忆（可带备注） · `photoMemorySave`

- 请求体：（空对象）
- 响应：200 `PhotoAiOpResponse`

#### `GET /api/v1/photo/memories/tickets`

票夹：识别火车票 / 机票 / 门票，按行程归组 · `photoTickets`

- 参数：`limit` · 查询 · integer · 可选
- 响应：200 `PhotoTicketResponse` · 错误 503

#### `GET /api/v1/photo/memories/year-report`

年度记录：张数 / 地点 / 活跃人物 / 常用场景，地点可跨年对照 · `photoYearReport`

- 参数：`year` · 查询 · integer · 可选<br>`locale` · 查询 · string · 可选
- 响应：200 `PhotoYearReport`

#### `GET /api/v1/photo/on-this-day`

那年今日：所有年份同月同日的照片（按年分组） · `photoOnThisDay`

- 参数：`month` · 查询 · integer · 可选<br>`day` · 查询 · integer · 可选<br>`perYear` · 查询 · integer · 可选
- 响应：200 `PhotoOnThisDayResponse`

#### `GET /api/v1/photo/operation/recent`

最近的可撤销操作（当前用户） · `photoOperationRecent`

- 参数：`limit` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/photo/operation/undo`

撤销一次操作（重复撤销返回 409） · `photoOperationUndo`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404 / 409

#### `POST /api/v1/photo/scan`

扫描索引（缺省扫描全部库；已索引且未变的文件跳过） · `photoScan`

- 请求体：（空对象）
- 响应：200 `PhotoScanResponse` · 错误 404

#### `GET /api/v1/photo/scan-policy`

相册扫描策略（自动监视 / 周期校验 / 跳过隐藏文件） · `photoScanPolicy`

- 响应：200 `PhotoScanPolicy`

#### `POST /api/v1/photo/scan-policy`

更新相册扫描策略（立即生效） · `photoScanPolicySet`

- 请求体：（空对象）
- 响应：200 `PhotoScanPolicy`

#### `POST /api/v1/photo/scan/task`

扫描索引（入队，立即返回任务 id；同一时刻只跑一轮） · `photoScanTask`

- 请求体：（空对象）
- 响应：200 `PhotoScanTask` · 错误 404

#### `GET /api/v1/photo/scene-tags`

某个场景标签下的照片（带 gate，可按高置信过滤） · `photoSceneTags`

- 参数：`label` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选<br>`onlyConfident` · 查询 · boolean · 可选
- 响应：200 `PhotoSceneTagList`

#### `GET /api/v1/photo/scene-tags/photo`

单张照片的全部场景标签（含 gate），详情页「这张像什么」用 · `photoSceneTagsOfPhoto`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `PhotoSceneTagList`

#### `GET /api/v1/photo/scene-tags/summary`

场景多标签分布：张数 + confident/ambiguous 分层 + 封面 · `photoSceneTagSummary`

- 响应：200 `PhotoSceneTagSummary`

#### `GET /api/v1/photo/scenes`

某个场景下的照片 · `photoScenes`

- 参数：`label` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoAiPhotoRefList`

#### `GET /api/v1/photo/scenes/summary`

场景分布（按照片数倒序） · `photoSceneSummary`

- 响应：200 `PhotoSceneSummary`

#### `GET /api/v1/photo/search`

按路径关键词与时间范围搜索 · `photoSearch`

- 参数：`q` · 查询 · string · 可选<br>`from` · 查询 · integer · 可选<br>`to` · 查询 · integer · 可选<br>`libraryId` · 查询 · string · 可选<br>`folder` · 查询 · string · 可选<br>`order` · 查询 · enum(asc, desc) · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoTimelineResponse` · 错误 400

#### `POST /api/v1/photo/search/hot`

热门推荐（人物 / 场景 / 活动 / 年份，给「随便看看」用） · `photoSearchHot`

- 请求体：（空对象）
- 响应：200 `PhotoSearchHotResponse`

#### `GET /api/v1/photo/search/hybrid`

混合检索：场景/活动标签 + OCR + 路径，按相关度排序（offset 分页） · `photoSearchHybrid`

- 参数：`q` · 查询 · string · **必填**<br>`offset` · 查询 · integer · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoHybridSearchResponse` · 错误 400

#### `POST /api/v1/photo/search/suggest`

搜索联想（人物/场景/活动/相机/文件名/OCR/年份，计数按可见库重算） · `photoSearchSuggest`

- 请求体：`q` string · 可选<br>`limit` string · 可选
- 响应：200 object

#### `GET /api/v1/photo/semantic/parse`

语义查询解析：中文短语 → 场景标签（含未识别片段，便于提示） · `photoSemanticParse`

- 参数：`q` · 查询 · string · **必填**
- 响应：200 `PhotoSemanticParse`

#### `GET /api/v1/photo/semantic/search`

语义搜索：短语绑定标签（有序）+ OCR 文本融合；词表不可用时降级为文字搜索 · `photoSemanticSearch`

- 参数：`q` · 查询 · string · **必填**
- 响应：200 `PhotoSemanticSearchResponse`

#### `GET /api/v1/photo/similar`

以图搜图（CLIP 余弦，内存内 top-k） · `photoSimilar`

- 参数：`id` · 查询 · string · **必填**<br>`limit` · 查询 · integer · 可选<br>`minScore` · 查询 · number · 可选
- 响应：200 `PhotoAiPhotoRefList` · 错误 404

#### `GET /api/v1/photo/smart-rules`

智能规则列表（含命中张数与封面） · `photoSmartRuleList`

- 响应：200 `PhotoSmartRuleListResponse`

#### `POST /api/v1/photo/smart-rules`

新建智能规则 · `photoSmartRuleCreate`

- 请求体：（空对象）
- 响应：200 `PhotoSmartRule` · 错误 400

#### `POST /api/v1/photo/smart-rules/delete`

删除智能规则（只删规则，不动照片） · `photoSmartRuleDelete`

- 请求体：（空对象）
- 响应：200 `PhotoOkResponse` · 错误 404

#### `GET /api/v1/photo/smart-rules/items`

智能规则命中的照片（时间轴序） · `photoSmartRuleItems`

- 参数：`id` · 查询 · string · **必填**<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoTimelineResponse` · 错误 404

#### `POST /api/v1/photo/smart-rules/update`

修改智能规则（改名 / 改条件） · `photoSmartRuleUpdate`

- 请求体：（空对象）
- 响应：200 `PhotoSmartRule` · 错误 400 / 404

#### `GET /api/v1/photo/stats`

总量与时间跨度 · `photoStats`

- 响应：200 `PhotoStatsResponse`

#### `GET /api/v1/photo/timeline`

时间轴（taken_at 倒序，排序键 cursor） · `photoTimeline`

- 参数：`libraryId` · 查询 · string · 可选<br>`favorite` · 查询 · boolean · 可选<br>`folder` · 查询 · string · 可选<br>`order` · 查询 · enum(asc, desc) · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `PhotoTimelineResponse` · 错误 400

#### `GET /api/v1/photo/trash`

回收站（清理与删除的照片） · `photoTrashList`

- 参数：`limit` · 查询 · integer · 可选<br>`cursor` · 查询 · string · 可选<br>`batchId` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/photo/trash/apply`

执行批量删除（写入操作日志，可撤销） · `photoTrashApply`

- 请求体：`ids` array<string> · **必填**
- 响应：200 object · 错误 400

#### `GET /api/v1/photo/trash/batches`

回收站按删除批次分组 · `photoTrashBatches`

- 响应：200 object

#### `POST /api/v1/photo/trash/empty`

清空回收站（只删索引，不动磁盘文件）；传 batchId 只清一个批次 · `photoTrashEmpty`

- 请求体：`batchId` string · 可选
- 响应：200 `PhotoCleanupOk`

#### `POST /api/v1/photo/trash/preview`

批量删除预演（只读：张数与占用字节） · `photoTrashPreview`

- 请求体：`ids` array<string> · **必填**
- 响应：200 object

#### `POST /api/v1/photo/trash/restore`

从回收站恢复 · `photoTrashRestore`

- 请求体：`ids` array<string> · 可选<br>`batchId` string · 可选
- 响应：200 `PhotoCleanupUndoResponse`

#### `POST /api/v1/photo/upload`

上传照片到相册来源（application/x-colanas-upload 原始流） · `photoUpload`

- 参数：`libraryId` · 查询 · string · **必填**<br>`dir` · 查询 · string · 可选<br>`fileName` · 查询 · string · **必填**
- 请求体：（空对象）
- 响应：200 object · 错误 400 / 404 / 413

#### `GET /api/v1/photo/year-covers`

每年一张「有人像」的代表图（年视图卡片封面） · `photoYearCovers`

- 响应：200 `PhotoYearCoversResponse`

## player

### player

#### `GET /api/v1/player/sessions`

查询转码会话状态与播放地址 · `playerSessionGet`

- 参数：`id` · 查询 · string · **必填**<br>`pos` · 查询 · number · 可选
- 响应：200 `PlayerSessionItem` · 错误 404

#### `POST /api/v1/player/sessions`

建 HLS 转码会话（可选字幕烧录） · `playerSessionCreate`

- 请求体：（空对象）
- 响应：200 `PlayerSessionCreated` · 错误 400 / 404 / 503

## pt

### pt

#### `GET /api/v1/pt/download/settings`

下载目录与筛选设置（发现设置页） · `ptDownloadSettingsGet`

- 响应：200 `PtDownloadSettingsResponse`

#### `POST /api/v1/pt/download/settings`

保存下载目录与筛选（自动下载 / 扫描间隔立即生效） · `ptDownloadSettingsSet`

- 请求体：（空对象）
- 响应：200 `PtDownloadSettingsResponse` · 错误 400

#### `GET /api/v1/pt/downloads`

下载留痕（最近 200 条） · `ptDownloads`

- 响应：200 object

#### `POST /api/v1/pt/downloads/action`

暂停 / 恢复 / 移除下载任务（移除不删本地数据） · `ptDownloadAction`

- 请求体：`id` string · **必填**<br>`action` enum(pause, resume, remove, retry) · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/pt/downloads/preview`

预览候选（搜索并落候选缓存，不建下载任务） · `ptDownloadPreview`

- 请求体：`keyword` string · 可选<br>`title` string · 可选<br>`originalTitle` string · 可选<br>`year` string · 可选<br>`season` integer · 可选<br>`mediaId` integer · 可选<br>`mediaType` string · 可选
- 响应：200 object

#### `POST /api/v1/pt/downloads/submit`

提交候选到 Transmission（幂等） · `ptDownloadSubmit`

- 请求体：`candidateId` integer · 可选<br>`rssEntryId` string · 可选<br>`savePath` string · 可选<br>`paused` boolean · 可选<br>`season` integer · 可选
- 响应：200 object · 错误 404

#### `POST /api/v1/pt/downloads/sync-status`

同步下载进度与完成状态 · `ptDownloadSyncStatus`

- 响应：200 object

#### `GET /api/v1/pt/favorites`

收藏三态列表（watching/downloading/downloaded/owned） · `ptFavoriteList`

- 参数：`state` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/pt/favorites/scan`

扫描待下载收藏并自动提交 · `ptFavoriteScan`

- 响应：200 object

#### `POST /api/v1/pt/rules/add`

新增择种规则 · `ptRuleAdd`

- 请求体：`name` string · **必填**<br>`enabled` boolean · 可选<br>`priority` integer · 可选<br>`quality` string · 可选<br>`hdr` string · 可选<br>`resolutionOrder` array<string> · 可选<br>`audioLangs` array<string> · 可选<br>`minSeeders` integer · 可选<br>`maxSizeBytes` integer · 可选<br>`excludedKeywords` array<string> · 可选
- 响应：200 object

#### `POST /api/v1/pt/rules/delete`

删除择种规则 · `ptRuleDelete`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/pt/rules/list`

择种规则列表 · `ptRuleList`

- 请求体：（空对象）
- 响应：200 object

#### `POST /api/v1/pt/rules/update`

修改择种规则 · `ptRuleUpdate`

- 请求体：`id` string · **必填**<br>`name` string · 可选<br>`enabled` boolean · 可选<br>`priority` integer · 可选<br>`quality` string · 可选<br>`hdr` string · 可选<br>`resolutionOrder` array<string> · 可选<br>`audioLangs` array<string> · 可选<br>`minSeeders` integer · 可选<br>`maxSizeBytes` integer · 可选<br>`excludedKeywords` array<string> · 可选
- 响应：200 object · 错误 404

#### `POST /api/v1/pt/search`

按媒体信息搜索所有启用站点（串行） · `ptSearch`

- 请求体：`title` string · **必填**<br>`originalTitle` string · 可选<br>`year` string · 可选<br>`season` integer · 可选
- 响应：200 object

#### `POST /api/v1/pt/settings`

设置 transmission（url / 账号） · `ptSettingsSet`

- 请求体：`url` string · **必填**<br>`username` string · 可选<br>`password` string · 可选
- 响应：200 object

#### `GET /api/v1/pt/sites`

PT 站点列表（不返回 cookie 明文） · `ptSiteList`

- 响应：200 object

#### `POST /api/v1/pt/sites/delete`

删除站点 · `ptSiteDelete`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/pt/sites/upsert`

新增 / 更新 PT 站点（cookie 密文落库） · `ptSiteUpsert`

- 请求体：`id` string · 可选<br>`name` string · 可选<br>`baseUrl` string · 可选<br>`enabled` boolean · 可选<br>`priority` integer · 可选<br>`timeoutMs` integer · 可选<br>`cookie` string · 可选<br>`kind` string · 可选<br>`apiKey` string · 可选<br>`userAgent` string · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/pt/sites/{id}/test`

测试 PT 站点连通性（真搜一次，结果落库） · `ptSiteTest`

- 参数：`id` · 路径 · string · **必填**
- 响应：200 object · 错误 404

#### `GET /api/v1/pt/subscriptions`

我的订阅 · `ptSubscriptionList`

- 响应：200 object

#### `POST /api/v1/pt/subscriptions/delete`

删除订阅 · `ptSubscriptionDelete`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/pt/subscriptions/run`

立即执行一条订阅 · `ptSubscriptionRun`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/pt/subscriptions/upsert`

新增 / 更新订阅 · `ptSubscriptionUpsert`

- 请求体：`id` string · 可选<br>`mediaId` integer · 可选<br>`mediaType` string · 可选<br>`ruleId` string · 可选<br>`libraryId` string · 可选<br>`posterPath` string · 可选<br>`mediaTitle` string · 可选<br>`mediaYear` string · 可选<br>`season` integer · 可选<br>`quality` string · 可选<br>`hdr` string · 可选<br>`audioLangs` array<string> · 可选<br>`resolutionOrder` array<string> · 可选<br>`minSeeders` integer · 可选<br>`maxSizeBytes` integer · 可选<br>`excludedKeywords` array<string> · 可选<br>`enabled` boolean · 可选
- 响应：200 object

#### `GET /api/v1/pt/torrents`

Transmission 实时任务（下载中 / 暂停 / 做种） · `ptTorrents`

- 响应：200 object

#### `POST /api/v1/pt/torrents/action`

批量暂停 / 开始 / 移除 Transmission 种子（移除不删本地数据） · `ptTorrentAction`

- 请求体：`hashes` array<string> · **必填**<br>`action` enum(pause, resume, remove) · **必填**<br>`deleteLocalData` boolean · 可选
- 响应：200 object · 错误 400

#### `POST /api/v1/pt/transmission/test`

探测 transmission 连通性 · `ptTransmissionTest`

- 响应：200 object

## rss

### RSS 订阅

#### `GET /api/v1/rss/downloaded`

永久下载台账（按账号隔离） · `rssDownloadedList`

- 参数：`keyword` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 object

#### `POST /api/v1/rss/downloaded/clear`

清空当前账号的下载台账 · `rssDownloadedClear`

- 响应：200 object

#### `POST /api/v1/rss/downloaded/delete`

删除一条下载台账 · `rssDownloadedDelete`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/rss/entries/action`

确认 / 拒绝 RSS 条目（兼容 guid 或 feedId:guid） · `rssEntryAction`

- 请求体：`id` string · **必填**<br>`action` enum(confirm, reject) · **必填**
- 响应：200 object

#### `GET /api/v1/rss/feeds`

订阅列表 · `rssListFeeds`

- 响应：200 object

#### `POST /api/v1/rss/feeds`

添加订阅（url 或直接给 xml） · `rssAddFeed`

- 请求体：`url` string · 可选<br>`xml` string · 可选<br>`title` string · 可选<br>`savePath` string · 可选<br>`immediate` boolean · 可选
- 响应：200 object · 错误 400

#### `POST /api/v1/rss/feeds/auto-download`

设置 feed 级自动下载开关 · `rssFeedAutoDownload`

- 请求体：`id` string · **必填**<br>`enabled` boolean · **必填**
- 响应：200 object

#### `POST /api/v1/rss/feeds/refresh`

刷新订阅（抓取 url 或解析传入 xml） · `rssRefresh`

- 请求体：`id` string · 可选<br>`url` string · 可选<br>`xml` string · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/rss/feeds/remove`

取消订阅（级联删条目） · `rssRemoveFeed`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/rss/feeds/settings`

修改 RSS 源设置（自动加种 / 立刻开始），立即生效 · `rssFeedSettings`

- 请求体：`id` string · **必填**<br>`autoDownload` boolean · 可选<br>`immediate` boolean · 可选
- 响应：200 object

#### `GET /api/v1/rss/items`

条目列表（发布时间倒序） · `rssItems`

- 参数：`feedId` · 查询 · string · 可选<br>`state` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 object

#### `GET /api/v1/rss/rules`

RSS 自动下载规则（按账号隔离） · `rssRuleList`

- 响应：200 object

#### `POST /api/v1/rss/rules/delete`

删除 RSS 自动下载规则 · `rssRuleDelete`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/rss/rules/run`

立即扫描一条规则（命中后自动建 PT 订阅） · `rssRuleRun`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/rss/rules/upsert`

新增 / 编辑 RSS 自动下载规则 · `rssRuleUpsert`

- 请求体：`id` string · 可选<br>`feedId` string · **必填**<br>`titleRegex` string · **必填**<br>`enabled` boolean · 可选
- 响应：200 object · 错误 400 / 404

## sync

### 同步

#### `GET /api/v1/sync/conflicts`

冲突列表 · `syncConflicts`

- 参数：`jobId` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/sync/conflicts/resolve`

冲突裁决：source 用源覆盖目标，target 保留目标 · `syncResolve`

- 请求体：`id` string · **必填**<br>`action` enum(source, target) · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/sync/deleteRemote`

按相对路径删除远端文件（仅文件，不删目录） · `syncDeleteRemote`

- 请求体：`taskId` string · **必填**<br>`paths` array<string> · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/sync/device/claimLegacy`

认领升级前的无主任务（uid 为空的同设备任务） · `syncClaimLegacy`

- 请求体：`deviceId` string · **必填**
- 响应：200 object

#### `GET /api/v1/sync/diff`

差异预览（只读） · `syncDiff`

- 参数：`source` · 查询 · string · **必填**<br>`target` · 查询 · string · **必填**
- 响应：200 object · 错误 400

#### `GET /api/v1/sync/jobs`

同步任务历史 · `syncJobs`

- 响应：200 object

#### `POST /api/v1/sync/mkdir`

在远端目录下创建子目录 · `syncMkdir`

- 请求体：`taskId` string · **必填**<br>`path` string · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/sync/plan`

三向比对：返回本轮要执行的动作（只读，不改文件） · `syncPlan`

- 请求体：`taskId` string · **必填**<br>`local` array<object> · **必填**<br>`baseline` array<object> · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/sync/probe`

探测远端目录（存在 / 可写 / 是否越界） · `syncProbe`

- 请求体：`remoteDir` string · **必填**
- 响应：200 object · 错误 400

#### `POST /api/v1/sync/report`

上报执行结果：刷新远端基线并落一次运行记录 · `syncReport`

- 请求体：`taskId` string · **必填**<br>`applied` array<object> · 可选<br>`bytes` integer · 可选<br>`status` enum(done, failed, partial) · 可选<br>`error` string · 可选
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/sync/run`

执行一次同步（merge，不删除目标多余文件） · `syncRun`

- 请求体：`source` string · **必填**<br>`target` string · **必填**<br>`policy` enum(overwrite, skip, rename) · 可选
- 响应：200 object · 错误 400 / 404

#### `GET /api/v1/sync/runs`

同步运行记录 · `syncRuns`

- 参数：`taskId` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/sync/status`

客户端回写任务状态（idle / running / paused / error） · `syncStatus`

- 请求体：`id` string · **必填**<br>`status` enum(idle, running, paused, error) · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/sync/summary`

同步任务汇总（按状态 / 设备） · `syncSummary`

- 响应：200 object

#### `GET /api/v1/sync/tasks`

同步任务列表（当前用户） · `syncTaskList`

- 响应：200 object

#### `POST /api/v1/sync/tasks/delete`

删除同步任务（保留基线以备审计，不删远端文件） · `syncTaskDelete`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/sync/tasks/upsert`

创建 / 更新同步任务（目录都在 files 根内） · `syncTaskUpsert`

- 请求体：`id` string · 可选<br>`name` string · 可选<br>`deviceId` string · **必填**<br>`deviceName` string · 可选<br>`mode` enum(bidirectional, download_only, upload_only) · 可选<br>`localDir` string · **必填**<br>`remoteDir` string · **必填**<br>`include` array<string> · 可选<br>`exclude` array<string> · 可选<br>`filterConfig` object · 可选<br>`syncConfig` object · 可选
- 响应：200 object · 错误 400 / 404

## system

### 系统监控

#### `POST /api/v1/system/cache/clear`

清理缩略图 / 封面 / PDF 渲染缓存并清零命中计数（不动媒体库文件） · `systemCacheClear`

- 响应：200 `SystemCacheClearResponse`

#### `GET /api/v1/system/cache/info`

缓存占用（缩略图 / 封面 / PDF 渲染） · `systemCacheInfo`

- 响应：200 `SystemCacheInfoResponse`

#### `GET /api/v1/system/cache/stats`

缓存命中统计（进程内累计，重启清零） · `systemCacheStats`

- 响应：200 object

#### `POST /api/v1/system/client-log`

上报一条客户端日志（前端错误 / 警告） · `systemClientLog`

- 请求体：`level` enum(error, warn, info) · **必填**<br>`message` string · **必填**<br>`route` string · 可选<br>`detail` string · 可选
- 响应：200 object

#### `POST /api/v1/system/db/compact`

数据库碎片整理（VACUUM，重写数据文件回收空洞空间） · `systemDbCompact`

- 响应：200 `SystemDbCompactResponse` · 错误 409

#### `POST /api/v1/system/exec`

受限命令执行（白名单 + 无 shell + 5 s 超时） · `systemExec`

- 请求体：`command` string · **必填**<br>`args` array<string> · 可选<br>`cwd` string · 可选
- 响应：200 object · 错误 400

#### `GET /api/v1/system/logs`

服务端日志分页（logs/kernel.log，时间倒序；第 1 页为最新） · `systemLogs`

- 参数：`limit` · 查询 · integer · 可选<br>`offset` · 查询 · integer · 可选<br>`lines` · 查询 · integer · 可选<br>`file` · 查询 · string · 可选<br>`level` · 查询 · enum(all, warn, error, info) · 可选
- 响应：200 `SystemLogsResponse`

#### `GET /api/v1/system/monitor`

整机监控（CPU / 内存 / 磁盘 / 负载） · `systemMonitor`

- 响应：200 object

#### `GET /api/v1/system/processes`

进程列表 · `systemProcesses`

- 参数：`limit` · 查询 · integer · 可选<br>`filter` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/system/processes/kill`

终止进程（拒绝 pid<=4 与自身） · `systemProcessKill`

- 请求体：`pid` integer · **必填**
- 响应：200 object · 错误 400 / 404

#### `POST /api/v1/system/restart`

重启内核（桌面端由外壳自动拉起；浏览器需手动刷新） · `systemRestart`

- 响应：200 `SystemRestartResponse`

#### `GET /api/v1/system/settings`

全局设置（端口 / 并发 / 主机名 / 欢迎语 / 代理 / 日系兜底 / 大模型） · `systemSettingsGet`

- 响应：200 `SystemSettingsResponse`

#### `POST /api/v1/system/settings`

保存全局设置（端口/并发重启后生效；代理立即生效） · `systemSettingsSet`

- 请求体：（空对象）
- 响应：200 `SystemSettingsResponse` · 错误 400

#### `GET /api/v1/system/tls`

HTTPS 证书状态（用户上传证书方案） · `systemTlsInfo`

- 响应：200 `SystemTlsInfoResponse`

#### `POST /api/v1/system/tls`

上传 HTTPS 证书与私钥（PEM；重启后启用） · `systemTlsUpload`

- 请求体：（空对象）
- 响应：200 `SystemTlsInfoResponse` · 错误 400

#### `POST /api/v1/system/tls/clear`

删除已上传的 HTTPS 证书 · `systemTlsClear`

- 响应：200 `SystemRestartResponse`

#### `GET /api/v1/system/update/check`

检查本地版本目录（当前版本 / 最新版本） · `systemUpdateCheck`

- 响应：200 `SystemUpdateCheckResponse`

#### `GET /health`

存活检查 · `healthCheck`

- 响应：200 -

#### `GET /openapi.json`

导出 OpenAPI 文档 · `openapiJson`

- 响应：200 -

#### `GET /ready`

就绪检查 · `readyCheck`

- 响应：200 -

## tasks

### tasks

#### `GET /api/v1/tasks`

任务列表与统计 · `tasksList`

- 响应：200 -

#### `POST /api/v1/tasks/cancel`

取消任务（pending 立即停；running 由 handler 的检查点退出） · `tasksCancel`

- 响应：200 -

#### `POST /api/v1/tasks/pause`

暂停任务（按 id / type，或缺省全部 pending） · `tasksPause`

- 响应：200 -

#### `POST /api/v1/tasks/resume`

恢复任务（paused → pending） · `tasksResume`

- 响应：200 -

#### `GET /api/v1/tasks/{id}`

单个任务状态与进度 · `tasksGet`

- 参数：`id` · 路径 · string · **必填**
- 响应：200 -

## transfer

### transfer

#### `POST /api/v1/transfer/begin`

开启或续传一个传输会话（同路径活跃会话直接复用） · `transferBegin`

- 请求体：（空对象）
- 响应：200 `TransferBeginResponse`

#### `POST /api/v1/transfer/cancel`

取消传输（已传分片保留，可再次续传） · `transferCancel`

- 请求体：（空对象）
- 响应：200 `TransferOkResponse`

#### `POST /api/v1/transfer/finish`

标记会话完成（幂等） · `transferFinish`

- 请求体：（空对象）
- 响应：200 `TransferOkResponse`

#### `POST /api/v1/transfer/pause`

暂停传输 · `transferPause`

- 请求体：（空对象）
- 响应：200 `TransferOkResponse`

#### `POST /api/v1/transfer/prune`

清理已结束的旧会话记录（不碰磁盘文件） · `transferPrune`

- 响应：200 -

#### `POST /api/v1/transfer/resume`

恢复传输 · `transferResume`

- 请求体：（空对象）
- 响应：200 `TransferOkResponse`

#### `GET /api/v1/transfer/sessions`

传输会话列表（全部来源：本机 / 其他设备 / 其他用户） · `transferSessions`

- 参数：`state` · 查询 · string · 可选<br>`direction` · 查询 · string · 可选<br>`owner` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`offset` · 查询 · integer · 可选
- 响应：200 `TransferSessionsResponse`

#### `GET /api/v1/transfer/sessions/{id}`

单个传输会话 · `transferSessionGet`

- 参数：`id` · 路径 · string · **必填**
- 响应：200 -

## video

### 影视

#### `POST /api/v1/video/actor/avatars`

按演员名批量取头像与档案（详情页演职人员区用） · `videoActorAvatars`

- 请求体：`names` array<string> · **必填**<br>`libraryId` string · 可选
- 响应：200 object

#### `GET /api/v1/video/actors`

演员候选（从 NFO 演员聚合，供查重页排除指定演员） · `videoActors`

- 参数：`q` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 object

#### `GET /api/v1/video/art`

刮削海报 / 剧照（本地文件读流，远端 URL 302 跳转） · `videoArt`

- 参数：`id` · 查询 · string · **必填**<br>`kind` · 查询 · enum(poster, fanart) · 可选<br>`size` · 查询 · integer · 可选
- 响应：200 -

#### `GET /api/v1/video/audio-tracks`

源文件的音轨清单（语言 / 音轨名 / 声道），供播放器音轨菜单使用 · `videoAudioTracks`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 `VideoAudioTracksResponse` · 错误 404

#### `GET /api/v1/video/browse`

按库目录浏览（文件夹 / 图片 / 视频） · `videoBrowse`

- 参数：`libraryId` · 查询 · string · **必填**<br>`path` · 查询 · string · 可选
- 响应：200 `VideoBrowseResponse` · 错误 400 / 404 / 503

#### `GET /api/v1/video/collections`

我的合集（按更新时间倒序，带条目数） · `videoCollectionList`

- 响应：200 `VideoCollectionListResponse`

#### `POST /api/v1/video/collections/delete`

删除合集（只删合集与其条目关系，不删影片） · `videoCollectionDelete`

- 请求体：（空对象）
- 响应：200 `VideoOkResponse` · 错误 404

#### `GET /api/v1/video/collections/items`

合集内影片（按加入时间倒序） · `videoCollectionItems`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `VideoCollectionItemsResponse` · 错误 404

#### `POST /api/v1/video/collections/items`

批量加入 / 移出合集 · `videoCollectionItemsSet`

- 请求体：（空对象）
- 响应：200 `VideoCollectionItemsResponse` · 错误 404

#### `POST /api/v1/video/collections/merge`

合并两个合集（来源的影片并入目标，来源合集被删除） · `videoCollectionMerge`

- 请求体：`sourceId` string · **必填**<br>`targetId` string · **必填**
- 响应：200 `VideoCollection` · 错误 400 / 404

#### `POST /api/v1/video/collections/upsert`

创建 / 编辑合集（名称 / 简介 / 封面 / 顺序） · `videoCollectionUpsert`

- 请求体：（空对象）
- 响应：200 `VideoCollection` · 错误 400

#### `GET /api/v1/video/duplicates`

重复视频（豆瓣 / IMDB / 番号 / 标题+年份 四把钥匙，并查集分组） · `videoDuplicates`

- 参数：`libraryId` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`excludeActors` · 查询 · string · 可选
- 响应：200 `VideoDuplicatesResponse`

#### `GET /api/v1/video/facets`

筛选面板选项：来源 / 标签 / 分辨率计数 + NFO 题材前 30（排除单体作品） · `videoFacets`

- 参数：`libraryId` · 查询 · string · 可选
- 响应：200 `VideoFacetsResponse`

#### `GET /api/v1/video/favorites`

我收藏的影片 · `videoFavorites`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`mediaType` · 查询 · string · 可选<br>`series` · 查询 · string · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`sortBy` · 查询 · string · 可选<br>`sortOrder` · 查询 · string · 可选<br>`years` · 查询 · string · 可选<br>`genres` · 查询 · string · 可选<br>`regions` · 查询 · string · 可选<br>`actor` · 查询 · string · 可选<br>`director` · 查询 · string · 可选<br>`watched` · 查询 · string · 可选<br>`scraped` · 查询 · string · 可选<br>`flag` · 查询 · string · 可选<br>`folderPath` · 查询 · string · 可选<br>`folderMode` · 查询 · string · 可选<br>`letter` · 查询 · string · 可选<br>`resolution` · 查询 · string · 可选<br>`jpTag` · 查询 · string · 可选<br>`sourceId` · 查询 · string · 可选
- 响应：200 `VideoListResponse`

#### `POST /api/v1/video/favorites/set`

批量收藏 / 取消收藏 · `videoFavoriteSet`

- 请求体：（空对象）
- 响应：200 `VideoFavoriteResponse`

#### `GET /api/v1/video/home`

影视首页：来源 / 推荐 / 继续观看 / 每库最近添加 · `videoHome`

- 参数：`recommendLimit` · 查询 · integer · 可选<br>`recentPlayLimit` · 查询 · integer · 可选<br>`recentAddLimit` · 查询 · integer · 可选
- 响应：200 `VideoHomeResponse`

#### `GET /api/v1/video/image/folders`

图片库 / 混合库的文件夹层级（子文件夹 / 封面 / 数量） · `videoImageFolders`

- 参数：`libraryId` · 查询 · string · **必填**<br>`folderPath` · 查询 · string · 可选
- 响应：200 `VideoImageFolderResponse` · 错误 403

#### `POST /api/v1/video/image/folders/delete`

删除图片库 / 混合库的一个文件夹（移入回收站） · `videoImageFolderDelete`

- 请求体：（空对象）
- 响应：200 `VideoImageFolderDeleteResponse` · 错误 404

#### `GET /api/v1/video/item`

影片详情 · `videoItem`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 `VideoItem` · 错误 404

#### `POST /api/v1/video/items/delete`

删除视频（移入回收站，并清掉索引 / 观看进度 / 收藏） · `videoItemsDelete`

- 请求体：（空对象）
- 响应：200 `VideoDeleteItemsResponse`

#### `POST /api/v1/video/items/delete-task`

删除视频（后台任务，返回 taskId，用 /tasks/:id 看进度） · `videoItemsDeleteTask`

- 请求体：（空对象）
- 响应：200 object

#### `POST /api/v1/video/jp_actor/favorite`

收藏 / 取消收藏演员 · `videoJpActorFavorite`

- 请求体：`name` string · **必填**<br>`favorite` boolean · **必填**
- 响应：200 object

#### `GET /api/v1/video/jp_actor/favorites`

我的演员收藏 · `videoJpActorFavorites`

- 响应：200 object

#### `GET /api/v1/video/jp_actor/list`

演员列表（影片数 / 未看数 / 热度 / 封面片 / 收藏 / 档案） · `videoJpActorList`

- 参数：`libraryId` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选<br>`resolution` · 查询 · string · 可选<br>`jpTag` · 查询 · string · 可选<br>`genre` · 查询 · string · 可选<br>`sourceId` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/video/jp_actor/profile`

演员档案（JavDB 确认身份 + 日文维基补三围；失败返回空档案） · `videoJpActorProfile`

- 请求体：`name` string · **必填**
- 响应：200 object

#### `POST /api/v1/video/jp_actor/rebuild`

从 nfo_actors 重建演员作品关联（老库补齐用） · `videoJpActorRebuild`

- 请求体：`libraryId` string · 可选<br>`limit` integer · 可选
- 响应：200 object

#### `GET /api/v1/video/jp_actor/works`

某演员在库的作品（未看优先，再按入库时间倒序） · `videoJpActorWorks`

- 参数：`key` · 查询 · string · 可选<br>`name` · 查询 · string · 可选<br>`limit` · 查询 · string · 可选<br>`libraryId` · 查询 · string · 可选<br>`resolution` · 查询 · string · 可选<br>`jpTag` · 查询 · string · 可选<br>`genre` · 查询 · string · 可选<br>`sourceId` · 查询 · string · 可选
- 响应：200 object

#### `POST /api/v1/video/jp_rank/actor`

日本演员榜单（日/周/月） · `videoJpRankActor`

- 请求体：`period` enum(daily, weekly, monthly) · 可选
- 响应：200 object

#### `POST /api/v1/video/jp_rank/clear`

清空日系榜单缓存（内存 + 快照） · `videoJpRankClear`

- 响应：200 object

#### `POST /api/v1/video/jp_rank/movie`

日本片榜单（日/周/月），标出已在库 · `videoJpRankMovie`

- 请求体：`period` enum(daily, weekly, monthly) · 可选
- 响应：200 object

#### `GET /api/v1/video/libraries`

影视库列表（含全部来源） · `videoLibraryList`

- 响应：200 `VideoLibraryListResponse`

#### `POST /api/v1/video/libraries`

新建影视库（可一次给多个来源目录） · `videoLibraryCreate`

- 请求体：（空对象）
- 响应：200 `VideoLibraryItem` · 错误 400 / 409

#### `POST /api/v1/video/libraries/flags`

修改库级开关（首页可见 / 排序 / 响度归一 / 刮削 / 入库即刮 / 自动字幕） · `videoLibraryFlags`

- 请求体：（空对象）
- 响应：200 `VideoLibraryItem` · 错误 404

#### `POST /api/v1/video/libraries/remove`

删除影视库（级联清理索引与来源） · `videoLibraryRemove`

- 请求体：（空对象）
- 响应：200 `VideoOkResponse` · 错误 404

#### `POST /api/v1/video/libraries/update`

修改影视库（名称 / 类型 / 来源集合） · `videoLibraryUpdate`

- 请求体：（空对象）
- 响应：200 `VideoLibraryItem` · 错误 400 / 404 / 409

#### `POST /api/v1/video/library/auto_subtitle`

开关日本片自动字幕（打开时异步补一轮，不等下次扫描） · `videoAutoSubtitle`

- 请求体：`id` string · **必填**<br>`enabled` boolean · **必填**
- 响应：200 object · 错误 404

#### `GET /api/v1/video/list`

影片列表（标题序 + 排序键 cursor） · `videoList`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`mediaType` · 查询 · string · 可选<br>`series` · 查询 · string · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`sortBy` · 查询 · string · 可选<br>`sortOrder` · 查询 · string · 可选<br>`years` · 查询 · string · 可选<br>`genres` · 查询 · string · 可选<br>`regions` · 查询 · string · 可选<br>`actor` · 查询 · string · 可选<br>`director` · 查询 · string · 可选<br>`watched` · 查询 · string · 可选<br>`scraped` · 查询 · string · 可选<br>`flag` · 查询 · string · 可选<br>`folderPath` · 查询 · string · 可选<br>`folderMode` · 查询 · string · 可选<br>`letter` · 查询 · string · 可选<br>`resolution` · 查询 · string · 可选<br>`jpTag` · 查询 · string · 可选<br>`sourceId` · 查询 · string · 可选
- 响应：200 `VideoListResponse` · 错误 400

#### `GET /api/v1/video/list/count`

条目数（总数 / 已刮削数），筛选口径与 /video/list 一致 · `videoListCount`

- 参数：`libraryId` · 查询 · string · 可选<br>`series` · 查询 · string · 可选<br>`mediaType` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`folderPath` · 查询 · string · 可选<br>`folderMode` · 查询 · string · 可选<br>`letter` · 查询 · string · 可选
- 响应：200 `VideoListCountResponse`

#### `GET /api/v1/video/poster`

影片海报（首次访问生成，之后走文件缓存） · `videoPoster`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 -

#### `GET /api/v1/video/progress`

当前用户在某条影片 / 剧集上的观看进度 · `videoProgress`

- 参数：`id` · 查询 · string · **必填**
- 响应：200 `VideoProgress` · 错误 404

#### `POST /api/v1/video/progress/clear`

清空观看历史（可只清"已看完"，可按剧） · `videoProgressClear`

- 请求体：（空对象）
- 响应：200 `VideoProgressClearResponse`

#### `GET /api/v1/video/progress/list`

本用户的观看进度（按更新时间倒序；可按剧名 / 库过滤） · `videoProgressList`

- 参数：`series` · 查询 · string · 可选<br>`libraryId` · 查询 · string · 可选<br>`state` · 查询 · enum(all, finished, unfinished) · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `VideoProgressListResponse`

#### `POST /api/v1/video/progress/save`

保存观看进度（0-100，按用户隔离） · `videoProgressSave`

- 请求体：（空对象）
- 响应：200 `VideoProgress` · 错误 400 / 404

#### `POST /api/v1/video/scan`

扫描索引（ffmpeg 提取元数据；未变文件跳过） · `videoScan`

- 请求体：（空对象）
- 响应：200 `VideoScanResponse` · 错误 404

#### `POST /api/v1/video/scan/enqueue`

入队扫描（立即返回任务 id；进度与失败记录见 /tasks） · `videoScanEnqueue`

- 请求体：`libraryId` string · 可选
- 响应：200 object

#### `POST /api/v1/video/scrape/batch`

批量刮削（缺省只刮还没元数据的条目） · `videoScrapeBatch`

- 请求体：（空对象）
- 响应：200 `VideoScrapeBatchResponse`

#### `POST /api/v1/video/scrape/cleanup`

清空一条的刮削结果 · `videoScrapeCleanup`

- 请求体：（空对象）
- 响应：200 `VideoScrapeCleanupResponse`

#### `POST /api/v1/video/scrape/match`

设置该条目是否参与自动刮削 · `videoScrapeMatch`

- 请求体：（空对象）
- 响应：200 `VideoOkResponse`

#### `GET /api/v1/video/scrape/progress`

刮削进度（每日快照，含按库明细；最新的在前） · `videoScrapeProgress`

- 参数：`days` · 查询 · integer · 可选
- 响应：200 object

#### `POST /api/v1/video/scrape/progress/refresh`

立即重算一次刮削进度（入队，不阻塞请求） · `videoScrapeProgressRefresh`

- 响应：200 object

#### `POST /api/v1/video/scrape/start`

刮削单条（番号优先，失败回退 TMDB） · `videoScrapeStart`

- 请求体：（空对象）
- 响应：200 `VideoScrapeResponse`

#### `GET /api/v1/video/series`

剧集列表（剧名序 + 排序键 cursor；只含能解析出季 / 集号的文件） · `videoSeriesList`

- 参数：`libraryId` · 查询 · string · 可选<br>`q` · 查询 · string · 可选<br>`cursor` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选<br>`sortBy` · 查询 · string · 可选<br>`sortOrder` · 查询 · string · 可选<br>`watched` · 查询 · string · 可选
- 响应：200 `VideoSeriesListResponse` · 错误 400

#### `GET /api/v1/video/series/favorites`

我收藏的剧集（按最近收藏倒序） · `videoSeriesFavorites`

- 响应：200 `VideoSeriesFavoriteListResponse`

#### `POST /api/v1/video/series/favorites/set`

收藏 / 取消收藏一部剧 · `videoSeriesFavoriteSet`

- 请求体：（空对象）
- 响应：200 `VideoSeriesFavoriteResponse` · 错误 400 / 404

#### `GET /api/v1/video/series/items`

某部剧的全部季 / 集（按季号、集号、标题排序） · `videoSeriesItems`

- 参数：`name` · 查询 · string · **必填**<br>`libraryId` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `VideoSeriesItemsResponse` · 错误 400 / 404

#### `GET /api/v1/video/settings`

影视设置（字幕抓取 + 转码） · `videoSettingsGet`

- 响应：200 object

#### `PUT /api/v1/video/settings`

写影视设置（只传要改的段 / 字段） · `videoSettingsSet`

- 请求体：`subtitle` object · 可选<br>`transcode` object · 可选
- 响应：200 object

#### `GET /api/v1/video/smart-albums`

智能合集（预设规则）与各自条数 · `videoSmartAlbums`

- 响应：200 `VideoSmartAlbumListResponse`

#### `GET /api/v1/video/smart-albums/items`

智能合集条目（与计数同一份规则） · `videoSmartAlbumItems`

- 参数：`key` · 查询 · string · **必填**<br>`libraryId` · 查询 · string · 可选<br>`limit` · 查询 · integer · 可选
- 响应：200 `VideoListResponse` · 错误 400

#### `POST /api/v1/video/source/list`

影视库源目录（发现页下载目录下拉用） · `videoSourceList`

- 请求体：（空对象）
- 响应：200 object

#### `POST /api/v1/video/sources/probe`

探测 SMB 来源可达性并刷新在线状态 · `videoSourceProbe`

- 请求体：（空对象）
- 响应：200 `VideoSourceProbeResponse` · 错误 400

#### `GET /api/v1/video/stats`

片数与总时长（可按库过滤，缺省为全部库合计） · `videoStats`

- 参数：`libraryId` · 查询 · string · 可选
- 响应：200 `VideoStatsResponse`

#### `GET /api/v1/video/stream`

播放 / 下载（支持 Range / ETag） · `videoStream`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 -

#### `GET /api/v1/video/stream-url`

生成带短期令牌的播放地址（可直接交给外部播放器） · `videoStreamUrl`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 `VideoStreamUrlResponse` · 错误 404

#### `GET /api/v1/video/subtitle`

读取一条外挂字幕（srt / ass / ssa / vtt → WebVTT） · `videoSubtitle`

- 参数：`id` · 查询 · string · **必填**<br>`name` · 查询 · string · **必填**
- 响应：200 `VideoSubtitleResponse` · 错误 404 / 413

#### `POST /api/v1/video/subtitle/fetch`

手动抓取一条日本片的字幕（avsubtitles 五步链路） · `videoSubtitleFetch`

- 请求体：`id` string · **必填**
- 响应：200 object · 错误 404

#### `POST /api/v1/video/subtitle/fetch-library`

按库补全字幕（入队 video.subtitle.fetch） · `videoSubtitleFetchLibrary`

- 请求体：`id` string · **必填**
- 响应：200 object

#### `POST /api/v1/video/subtitle/test-sources`

测试各字幕源链接（连通性，不下载） · `videoSubtitleSourcesTest`

- 请求体：`assrtToken` string · 可选<br>`openSubtitlesKey` string · 可选
- 响应：200 object

#### `GET /api/v1/video/subtitles`

外挂字幕列表（与影片同目录、同主名） · `videoSubtitles`

- 参数：`id` · 查询 · string · **必填**<br>`token` · 查询 · string · 可选
- 响应：200 `VideoSubtitleListResponse` · 错误 404

#### `POST /api/v1/video/tmdb/search`

手动搜索 TMDB 条目（用于「匹配到别的片子」时纠正） · `videoTmdbSearch`

- 请求体：（空对象）
- 响应：200 `VideoTmdbSearchResponse`

#### `GET /api/v1/video/tmdb/settings`

刮削设置（Key / 语言 / 是否写 .nfo / 置信度阈值） · `videoTmdbSettingsGet`

- 响应：200 `VideoTmdbSettings`

#### `POST /api/v1/video/tmdb/settings`

写刮削设置（Key 传空字符串表示沿用发现页的 Key） · `videoTmdbSettingsSet`

- 请求体：（空对象）
- 响应：200 `VideoTmdbSettings`

#### `POST /api/v1/video/tmdb/test`

测试 TMDB 连通性（用当前配置的 Key） · `videoTmdbTest`

- 请求体：`apiKey` string · 可选
- 响应：200 object

#### `POST /api/v1/video/watch`

标记已观看 / 未观看（电视剧可一次展开到全部集） · `videoWatchMark`

- 请求体：（空对象）
- 响应：200 `VideoWatchResponse`
