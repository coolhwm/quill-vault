# Quillvault 真机技术闭环 Demo 范围说明

> 状态：技术验证已通过
> 目标：在 iOS 26 真机上跑通并验收 Quillvault 的最小核心链路
> 规格：[本地规格说明](./真机技术闭环Demo_规格说明.md) · [技术验证结论](./真机技术闭环Demo_技术验证结论.md) · [GitHub Issue #1](https://github.com/coolhwm/quill-vault/issues/1)

## 原型原则

这是用于验证技术可行性的抛弃式原型，不作为正式产品的工程基础。实现优先保证核心链路能够在真机上观察、诊断和验收，不为未来扩展提前建设抽象层或生产级架构。

## 已确认范围

- 面对面会话录音；
- 设备端实时转写；
- BYOK 配置页，包含 Base URL、Model、API Key、保存与连接测试；
- API Key 保存至系统 Keychain；
- 连接测试必须实际请求模型并验证纪要所需的结构化输出，不能只检查 HTTP 状态；
- BYOK 生成结构化纪要；
- 根据结构化节点和关系确定性生成 Mermaid `flowchart`；
- 将 Mermaid 运行时作为本地资源打包，断网可渲染；
- 用户可编辑 Mermaid 源码并重新渲染；
- 通过系统文件夹选择器选择 iCloud Drive 或 Obsidian 中的唯一权威目录；
- 使用持久书签保存权威目录授权，App 重启后仍可继续写入；
- 将逐字稿、纪要和录音直接写入权威目录中的 Markdown 会议资产目录；
- 设备端纪要不作为 Demo 通过条件；
- 导入已有音频不属于 Demo；
- 章节图不属于 Demo；
- `timeline`、`sequenceDiagram` 和 `mindmap` 不属于 Demo；
- 默认 iCloud 目录和文件冲突处理不属于 Demo；
- 完整产品 UI、付费和上架质量不属于 Demo 目标。

## BYOK 验收目标

- 服务商：DeepSeek；
- Base URL：`https://api.deepseek.com`；
- Model：`deepseek-v4-pro`；
- 接口：OpenAI Chat Completions；
- 请求使用 JSON Output 模式；
- App 使用本地类型校验模型返回的 JSON，不能把“合法 JSON”直接视为“合法结构化纪要”。
- 空内容、非法 JSON 或业务字段校验失败时自动重试一次；
- 重试仍失败时保留录音和逐字稿，显示错误并允许用户手动重新生成，不写入残缺的 `minutes.md`。

DeepSeek 官方文档：

- [首次 API 调用](https://api-docs.deepseek.com/guides/function_calling/)
- [JSON Output](https://api-docs.deepseek.com/guides/json_mode/)

## 结构化纪要

Demo 使用 v1 的核心固定结构：

1. 会议总览；
2. 核心摘要；
3. 带时间范围的主题章节；
4. 带原因和原文依据的关键决策；
5. 带负责人、截止时间和原文依据的行动项；
6. 风险与未决问题；
7. 核心观点图；
8. 指向完整逐字稿和录音的来源链接。

行动项只有在原文明确出现姓名与责任关系时才填写负责人，否则使用“待确认负责人”。

## 已确认验收场景

### 锁屏与后台记录

使用一场至少 15 分钟的中文面对面会话，其中锁屏或切换至后台至少 5 分钟：

- 原始录音不中断；
- 后台期间不强求实时显示转写；
- 停止会议后最终逐字稿补齐完整音频时间轴。
