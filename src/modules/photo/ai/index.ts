import type { KernelApi } from '../../../../kernel/types';
import { registerPhotoFaces } from './face';
import { PHOTO_AI_SCHEMAS } from './schemas';
import { registerPhotoSemantic } from './semantic';
import { registerPhotoVision } from './vision';
import { registerPhotoAiSettings } from './settings';
import { registerPhotoAssistant } from './assistant';

/**
 * photo 智能分析（人脸 / 场景 / 活动 / OCR / 语义 / 以图搜图）。
 *
 * 拆分原因：人脸簇、视觉批处理、语义检索三块的状态与失败模式完全不同
 * （人脸是内存索引 + 全库重建；视觉是 sidecar 批处理；语义是词表解析 + SQL 融合），
 * 放一个文件里既难读也难改。
 */
export async function registerPhotoAi(app: any, k: KernelApi): Promise<void> {
  for (const schema of PHOTO_AI_SCHEMAS) app.addSchema(schema);
  await registerPhotoVision(app, k);
  await registerPhotoFaces(app, k);
  await registerPhotoSemantic(app, k);
  await registerPhotoAiSettings(app, k);
  // 相册助手 / 模型 API / 热搜：对齐既有实现的 app_ai/ask、model_api/*、search/hot
  await registerPhotoAssistant(app, k);
}