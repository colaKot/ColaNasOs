/// Web / 无 dart:io 环境：没有「机器名」这回事，返回空串，
/// 由应用层用持久化的随机 id 覆盖（见 ColanasClientId.override）。
String computeClientId() => '';
