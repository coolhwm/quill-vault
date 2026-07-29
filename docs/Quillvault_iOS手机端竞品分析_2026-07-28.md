# Quillvault iOS 手机端竞品分析

> 调研日期：2026-07-28
> 调研对象：仅限可在 iPhone 上完成录音、转写或会议纪要工作的 App
> 不纳入核心横评：以会议机器人、日历自动入会、团队 SaaS 为主要形态的在线会议软件
> 目标产品：Quillvault / 墨匣（暂定名）

---

## 1. 执行结论

### 1.1 总体判断

Quillvault 所在市场不是功能空白市场。实时转写、本地转写、智能纪要、BYOK、iCloud、Obsidian、一次性付费和视觉化输出，均已有 iOS 产品分别覆盖。

本次调研没有发现一款 iPhone App 同时明确提供以下完整组合：

> **麦克风实时本地转写 + 飞书式智能纪要 + BYOK + 零遥测/零采集 + Markdown 事实源 + 可编辑 Mermaid 图示 + iCloud 同步 + Obsidian 保存 + 一次性付费。**

因此，Quillvault 仍有产品空位，但它的优势是**组合完整性**，不是任何单一功能的独占。

### 1.2 关键结论

1. **Synopsule 是头号直接竞品。**
   它已经覆盖 iPhone 实时转写、本地 Whisper、说话人识别、BYOK、智能纪要、Markdown 导出、Obsidian 直送和一次性基础付费。Quillvault 不能再把 BYOK、本地化或 Obsidian 当作独立差异。

2. **“图示”在广义市场中并不独有。**
   Renote 已提供会议记录到 AI mind map，Evernote 已支持 Mermaid，Meeting.ai 有 Visual Notes。真正可以建立区隔的是：**图示以可编辑 Mermaid 源码写入用户自己的 Markdown 文件，而不是云端生成一张不可控图片。**

3. **“完全本地”和 BYOK 必须拆成两种隐私模式。**
   BYOK 调用 OpenAI、Anthropic 等服务时，会议文本会离开设备，因此不能笼统宣传“所有处理完全本地”。建议定义：

   - 本地模式：音频、转写、总结和图示全部在设备端完成；
   - BYOK 模式：音频与转写留在本机，只有用户主动生成纪要时，文本直达其选择的 AI 服务商；
   - 两种模式都不经过 Quillvault 服务器，不含遥测、采集、广告或账号系统。

4. **文件主权是比“隐私”更可防守的长期卖点。**
   多数竞品虽然宣称本地处理，但数据仍保存在私有数据库中，Markdown 只是导出格式。Quillvault 应将 Markdown 定义为唯一事实源，而不是附属导出能力。

5. **$6.99–$9.99 一次性解锁具备竞争基础。**
   直接竞品中已有 £1.99 一次性基础购买、$9.99 lifetime IAP、免费本地产品和订阅产品。建议采用“免费下载、短时完整体验、一次性永久解锁”，而不是付费下载后才能验证核心价值。

### 1.3 建议决策

**有条件 GO。**

开工条件不是“市场上没人做”，而是接受以下定位：

> Quillvault 不是另一个转写工具，而是一个把会议变成用户自有、可被人和 AI 长期读取的 Markdown 资产包，并附带可编辑图示的隐私会议工作台。

---

## 2. 调研范围与方法

### 2.1 纳入范围

纳入以下三类 iPhone 产品：

1. **直接竞品**：在 iPhone 上录音，并提供本地转写、智能纪要、BYOK 或隐私能力；
2. **系统级替代品**：Apple Notes / Voice Memos；
3. **视觉输出替代品**：能把录音或笔记生成 mind map、Visual Notes 或 Mermaid 的 iOS App。

### 2.2 排除范围

Otter、Fireflies、Fathom 等产品不纳入核心功能矩阵，原因是其主要产品单元是：

- 在线会议机器人或日历自动入会；
- Zoom、Google Meet、Teams 等平台集成；
- 云端账号、团队空间与协作；
- 按月或按席位订阅。

Quillvault 的主要产品单元是：

- iPhone 麦克风录制或本地文件导入；
- 音频与转写在设备端处理；
- 无账号、无自建后端；
- 用户直接拥有 Markdown 和音频文件。

两者解决的虽都是“会议记录”，但采购逻辑、隐私模型和使用场景不同。Quillvault 不应在 ASO 中主打“替代 Zoom AI Companion”，而应主打“无需机器人、适合面对面会议与个人录音”。

### 2.3 证据说明

- 优先使用 App Store 产品页、Apple 官方支持文档和厂商官网；
- App Store 的隐私标签为开发者自报，未经 Apple 实质验证；
- `?` 表示官方产品页未明确说明，不等同于确定不支持；
- 价格会因国家、税费和促销变化，本文仅记录调研时可见价格；
- App Store 产品更新频繁，本结论应在提交商店前重新核验。

---

## 3. Quillvault 目标能力基线

### 3.1 核心卖点

- 智能纪要；
- 麦克风实时录音与实时转写；
- Mermaid 图示；
- BYOK；
- 本地优先，无遥测、无采集、无广告；
- Markdown 管理存储文件，适合 AI 读取与二次处理；
- 同时保存原文和纪要；
- 纪要参考飞书输出：会议总结、章节纪要、待办事项和逐字稿；
- iCloud 同步；
- 保存到 Obsidian；
- 一次性付费。

### 3.2 隐私承诺的准确版本

不建议使用：

> 完全本地，任何数据都不会离开设备。

因为它与云端 BYOK 模式冲突。

建议使用：

> **音频始终留在设备；转写与文件存储完全本地。总结可选择设备端 AI，或由用户授权后将文本直达其选择的 BYOK 服务商。Quillvault 无服务器、无账号、无遥测、无采集、无广告。**

### 3.3 文件主权的产品定义

Markdown 不应只是“导出选项”，而应是应用内部的唯一事实源：

```text
2026-07-28-product-review/
├── meeting.md       # 元数据、总结、决策、待办、Mermaid 图示
├── transcript.md    # 带时间戳的完整原文
└── audio.m4a        # 原始录音
```

建议在 `meeting.md` 使用 YAML frontmatter 保存标题、日期、时长、语言、AI provider、模型和关联音频，正文保持普通 Markdown。这样用户可以用 Obsidian、Git、Finder、Files、Claude、Codex 或其他工具继续处理，不依赖 Quillvault 私有数据库。

---

## 4. 竞品分层

### 4.1 第一层：直接竞品

| 产品 | 直接竞争原因 | 威胁等级 |
|---|---|---:|
| Synopsule | 实时本地转写、说话人、BYOK、智能总结、Markdown、Obsidian、一次性基础付费 | 极高 |
| AI Notes: BYOK Transcription | 本地 Whisper、BYOK、Apple Intelligence 总结、iCloud、一次性付费 | 高 |
| Note Taker AI - 100% local | SpeechAnalyzer、Apple Foundation Models、完整本地总结、零采集、免费 | 高 |
| Local AI Note Taker | iOS 26 本地实时转写、总结、行动项、问答、零采集 | 中高 |
| Whisper Notes | 强本地转写、说话人标签、零采集、一次性付费、低价 | 中 |
| Aiko | 成熟的纯本地 Whisper 转写与零采集心智 | 中低 |

### 4.2 第二层：系统级替代品

| 产品 | 替代能力 | 威胁等级 |
|---|---|---:|
| Apple Notes / Voice Memos | 系统录音、实时转写、Apple Intelligence 总结、iCloud、免费预装 | 高 |

### 4.3 第三层：视觉与云端替代品

| 产品 | 替代能力 | 威胁等级 |
|---|---|---:|
| Renote | 录音转写、AI 总结、行动项、mind map、信息图 | 中 |
| Evernote | 会议录音、转写、总结、跨设备同步、Mermaid 编辑 | 中 |
| Meeting.ai | iPhone 录音、转写、行动项、Visual Notes | 中低 |

这些产品不能满足 Quillvault 的本地与文件主权承诺，但会削弱“图示是独家功能”的营销说法。

---

## 5. 核心功能矩阵

图例：`✅` 明确支持；`◐` 条件支持或只覆盖部分场景；`❌` 明确不支持；`?` 官方资料未证明。

### 5.1 会议处理能力

| 产品 | iPhone 录音 | 实时转写 | 本地转写 | 保存原文 | 智能总结/待办 | 图示 | BYOK |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Quillvault（目标）** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ Mermaid | ✅ |
| Synopsule | ✅ | ✅ | ✅ Whisper | ✅ | ✅ | ❌ | ✅ |
| AI Notes: BYOK Transcription | ✅ | ◐ ElevenLabs 云端 | ✅ Whisper | ✅ | ✅ | ❌ | ✅ |
| Note Taker AI - 100% local | ✅ | ? | ✅ SpeechAnalyzer | ✅ | ✅ | ❌ | ❌ |
| Local AI Note Taker | ✅ | ✅ | ✅ Apple 能力 | ✅ | ✅ | ❌ | ❌ |
| Whisper Notes | ✅ | ❌ | ✅ 多模型 | ✅ | ❌ | ❌ | ❌ |
| Aiko | ◐ | ❌ | ✅ Whisper | ✅ | ❌ | ❌ | ❌ |
| Apple Notes | ✅ | ✅ | ◐ 系统管理 | ✅ | ✅ | ❌ | ❌ |
| Renote | ✅ | ? | ❌/云端 | ✅ | ✅ | ✅ Mind map | ❌ |
| Evernote | ✅ | ✅ | ❌/云端 | ✅ | ✅ | ✅ Mermaid | ❌ |

### 5.2 隐私、文件主权与商业模式

| 产品 | 零遥测/零采集 | 无广告 | Markdown 事实源 | iCloud | Obsidian | 一次性付费 |
|---|---:|---:|---:|---:|---:|---:|
| **Quillvault（目标）** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Synopsule | ❌ 可关闭匿名分析 | ✅ | ◐ Markdown 导出 | ? | ✅ 直送 | ✅ 基础版；另有可选订阅 |
| AI Notes: BYOK Transcription | ◐ 宣称无跟踪；隐私标签列出音频数据 | ✅ | ? | ✅ | ? | ✅ $9.99 lifetime IAP |
| Note Taker AI - 100% local | ✅ 自报不采集 | ✅ | ❌/未说明 | ❌ 本地 Documents | ? | ✅ 免费 |
| Local AI Note Taker | ✅ 自报不采集 | ✅ | ❌/未说明 | ❌ 明确无云存储 | ? | ❌ $4.99/月或 $19.99/年 |
| Whisper Notes | ✅ 自报不采集 | ✅ | ❌，TXT/SRT/VTT 导出 | ❌ 仅设备 | ? | ✅ 一次性 |
| Aiko | ✅ 自报不采集 | ✅ | ❌/未说明 | ? | ? | ✅ $24 |
| Apple Notes | ◐ Apple 系统政策 | ✅ | ❌ | ✅ | ❌ | ✅ 系统免费 |
| Renote | ❌ 隐私标签含跟踪 | ? | ❌ | ? | ❌ | ❌ 订阅 |
| Evernote | ❌ 云账号与服务 | ◐ | ❌ | 自有云同步 | ❌ | ❌ 订阅 |

---

## 6. 重点竞品分析

### 6.1 Synopsule

**为什么最危险**

Synopsule 与 Quillvault 的目标人群高度重合。其 App Store 页面明确提供：

- iPhone 麦克风录音和实时转写；
- 本地 Whisper；
- 说话人分离与跨录音声纹识别；
- 结构化摘要、行动项和多种会议模板；
- OpenAI、Anthropic、Gemini BYOK；
- Apple Intelligence 设备端总结；
- Markdown、Word、SRT、VTT、HTML 导出；
- 一键发送到 Obsidian 或 Apple Notes；
- £1.99 一次性基础购买；
- 可选 $4.99/月或 $39.99/年的托管 AI 服务。

**明显优势**

- 已经支持 Quillvault v1 不准备做的说话人分离；
- iOS 17 起可用，设备覆盖比 iOS 26-only 更广；
- iPhone、Mac、Apple Watch 多端组合；
- 价格锚点极低；
- 摘要模板与音频回放体验较成熟。

**可攻击点**

- 没有图示；
- 未明确提供 iCloud 文件同步；
- Markdown 是导出能力，不是明确的内部事实源；
- App Store 隐私标签显示会收集不关联身份的标识符、使用数据和诊断数据；
- 产品页也说明匿名分析仅是“可以关闭”，不是默认零遥测。

**Quillvault 应对**

不能用“我们也本地、也 BYOK”对抗，而应明确：

> Synopsule 是私密转写工作室；Quillvault 是用户自有 Markdown 会议资产库，并能把决策关系画成可编辑图。

来源：[Synopsule App Store](https://apps.apple.com/gb/app/synopsule/id6773112941)、[Synopsule 官网](https://synopsule.com/)

### 6.2 AI Notes: BYOK Transcription

**已覆盖能力**

- 本地 Whisper；
- 多种云端 provider 与 BYOK；
- Apple Intelligence 设备端总结和问答；
- 多种摘要样式；
- iCloud 同步音频、转写、摘要与对话；
- 文件导入、录音、搜索与文件夹；
- $9.99 一次性 Pro 解锁；
- 无广告、无需账号。

**重要限制**

- 实时转写依赖 ElevenLabs，不能算“本地实时转写”；
- 未明确支持 Markdown 事实源、Obsidian 或图示；
- 产品文案宣称无跟踪，但 App Store 隐私标签列出可能收集不关联身份的音频数据，隐私叙事不够干净。

**Quillvault 应对**

- 强调 SpeechAnalyzer 的本地实时转写；
- 明确“音频永不上传”，BYOK 只发送文本；
- 公开、简单、可验证的数据流图；
- 用 Markdown + Mermaid + Obsidian 形成文件主权闭环。

来源：[AI Notes: BYOK Transcription App Store](https://apps.apple.com/us/app/ai-notes-byok-transcription/id6749819451)

### 6.3 Note Taker AI - 100% local

**已覆盖能力**

- iOS 26 原生 SpeechAnalyzer；
- Apple Foundation Models 本地总结；
- 摘要、关键点、行动项、标题、标签和单会议问答；
- 录音存在本地 Documents；
- App Store 隐私标签为不采集数据；
- 免费、无账号、无订阅。

**重要限制**

- 依赖 Apple Intelligence 兼容设备；
- 未明确提供录音中的实时文字；
- 没有 BYOK；
- 没有 Markdown 事实源、iCloud/Obsidian 工作流或会议图示。

**战略含义**

“完全本地智能纪要”本身已经很难收费。用户愿意支付的理由必须来自更好的输出、开放文件、跨设备和 PKM 工作流，而不是调用 Apple 原生框架本身。

来源：[Note Taker AI - 100% local App Store](https://apps.apple.com/fr/app/note-taker-ai-100-local/id6760299554?l=en-GB)

### 6.4 Local AI Note Taker

**已覆盖能力**

- iOS 26 本地实时转写；
- 摘要、关键点、行动项；
- 单会议问答、搜索和自定义摘要提示；
- 无账号、无云存储；
- App Store 隐私标签为不采集数据。

**重要限制**

- 不支持 BYOK；
- 没有图示；
- 未说明 Markdown、iCloud 或 Obsidian；
- 采用 $4.99/月、$19.99/年的订阅。

**Quillvault 应对**

一次性付费、文件主权和 BYOK 足以形成清晰区分，不需要与其竞争通用 AI 搜索。

来源：[Local AI Note Taker App Store](https://apps.apple.com/us/app/local-ai-note-taker/id6759070933)

### 6.5 Whisper Notes

**已覆盖能力**

- 本地录音和音视频导入；
- 多种本地转写模型；
- 100+ 语言；
- 本地说话人标签；
- 无长度限制；
- App Store 隐私标签为不采集数据；
- 无订阅、无广告、一次性付费。

**重要限制**

- 明确不支持边录边实时转写；
- 明确不提供 AI 总结；
- 只导出 TXT、SRT、VTT；
- 数据只在本机，删除 App 可能同时删除录音；
- 没有 iCloud、Obsidian 或图示。

**Quillvault 应对**

Whisper Notes 建立了低价、强隐私的转写锚点。Quillvault 必须通过“实时文字 + 飞书式纪要 + 图示 + 文件同步”证明溢价，不能只宣传本地转写。

来源：[Whisper Notes App Store](https://apps.apple.com/us/app/whisper-notes-speech-to-text/id6447090616)、[Whisper Notes 官网](https://whispernotes.app/whisper-app)

### 6.6 Aiko

**已覆盖能力**

- Whisper large v2 完全本地运行；
- 100 种语言；
- App Store 隐私标签为不采集数据；
- 一次性购买。

**重要限制**

- 1.8 GB 左右包体；
- 更重准确率而非速度；
- 不支持 App 内编辑；
- 无实时转写、智能总结、图示、BYOK 和明确的 PKM 工作流。

**战略含义**

Aiko 证明用户会为高质量离线转写支付较高一次性价格，但其定位是纯工具，不是会议知识管理。

来源：[Aiko App Store](https://apps.apple.com/us/app/aiko/id1672085276)

---

## 7. 系统级替代：Apple Notes / Voice Memos

Apple Notes 已经可以：

- 在 iPhone 内录音；
- 查看、搜索和复制实时 transcript；
- 使用 Apple Intelligence 总结录音；
- 通过 iCloud 在 Apple 设备间同步；
- 免费预装。

这是 Quillvault 最容易被忽略的替代品。对普通用户而言，“系统自带、能转写、能总结”已经够用。

Quillvault 不能在通用易用性上战胜 Apple Notes，应聚焦 Apple 不提供的能力：

- BYOK 和 provider 选择；
- Markdown 原文件；
- Obsidian 工作流；
- 原文、纪要、音频组成可迁移的资产包；
- 飞书式结构化纪要；
- 可编辑 Mermaid 图示；
- 明确的零遥测承诺。

来源：[Apple：在 iPhone 备忘录中录音和转写](https://support.apple.com/en-us/118442)、[Apple：使用 Apple Intelligence 总结录音](https://support.apple.com/guide/iphone/use-apple-intelligence-in-notes-iph59143007d/ios)

---

## 8. 视觉输出竞品与 Mermaid 判断

### 8.1 已有视觉产品

- Renote 能将会议录音、文件和笔记生成 mind map 与信息图；
- Evernote 已支持会议录音、转写、总结和 Mermaid 编辑；
- Meeting.ai 提供 Visual Notes；
- Mermaid AI 可以直接把 transcript 转换为 flowchart、mind map 或 timeline。

因此，不应再使用：

> 海外竞品全无图示，这是唯一硬差异。

建议改为：

> **把会议总结转换为可编辑 Mermaid，并将源码与原文一起保存在用户自己的 Markdown 中。**

这里的差异不在“能看到一张图”，而在：

- 图示是文本，不是不可修改的图片；
- 图示可以用 Git 版本管理；
- Obsidian、GitHub、VS Code 和其他 AI 能直接读取；
- 用户可以修改 Mermaid 源码；
- 图示和文字共享同一个事实源；
- 渲染失败时仍然保留可恢复的源数据。

来源：[Renote App Store](https://apps.apple.com/us/app/ai-notes-voice-to-text-renote/id6448519306)、[Evernote App Store](https://apps.apple.com/id/app/evernote-ai-notes-organizer/id281796108)、[Meeting.ai App Store](https://apps.apple.com/ca/app/meeting-ai-agent-for-work/id6478665147)、[Mermaid AI](https://mermaid.ai/products/ai)

### 8.2 Mermaid 的竞争边界

本次 iPhone 样本中，没有发现一款直接本地会议竞品明确做到：

> 本地实时转写 → 飞书式纪要 → 可编辑 Mermaid → Markdown 事实源 → iCloud / Obsidian。

但这只能表述为“本次样本未发现”，不能宣传为全球唯一。

---

## 9. 推荐定位与商店表达

### 9.1 推荐一句话定位

英文：

> **Private meeting notes that you truly own — live transcript, structured recap, and editable Mermaid, saved as Markdown.**

中文：

> **把会议实时转成你真正拥有的 Markdown：原文、纪要和可编辑图示，全都在自己的文件里。**

### 9.2 卖点优先级

建议按用户感知而不是技术架构排序：

1. **会后直接得到结构化纪要与图示；**
2. **原文、纪要、音频都保存为用户自己的文件；**
3. **实时本地转写，无需机器人入会；**
4. **直接进入 iCloud / Obsidian；**
5. **设备端 AI 或 BYOK，自主选择；**
6. **零账号、零遥测、零广告；**
7. **一次性购买。**

不建议把 BYOK 放在首屏第一卖点。API Key 是高级用户能力，不是普通用户最先理解的价值。

### 9.3 不应使用的宣传

- “全球唯一带图示的会议纪要”；
- “所有处理永远完全本地”——BYOK 云端模式下不准确；
- “100% 准确”；
- “自动识别所有发言人”——当前方案不做 diarization；
- “支持在线会议录音”——iPhone 不捕获其他 App 的系统音频；
- “iCloud + Obsidian 双向实时同步”——除非已经解决冲突与文件协调。

---

## 10. 飞书式纪要输出建议

飞书官方资料中的核心产物是：

- 会议总结；
- 章节纪要；
- 待办事项；
- 逐字稿；
- 原文跳转与回放。

Quillvault 可将其转化为更适合个人文件与 AI 使用的 Markdown：

````markdown
---
title: Product Review
date: 2026-07-28
duration: 01:12:34
language: en
audio: ./audio.m4a
transcript: ./transcript.md
provider: anthropic
model: claude-...
---

# Product Review

## Executive Summary

## Key Decisions

## Action Items
| Action | Owner | Due | Evidence |
|---|---|---|---|

## Topics and Chapters
### 00:00–12:30 Topic A

## Risks and Open Questions

## Diagram
```mermaid
flowchart TD
```

## Source
- [Full transcript](./transcript.md)
- [Audio](./audio.m4a)
````

建议每条决策、待办和章节保留时间戳，支持从纪要跳回原文和音频。这比只生成一段摘要更接近飞书的“可溯源”价值，也是文件主权产品的重要可信度设计。

来源：[飞书妙记](https://www.feishu.cn/product/minutes)、[飞书智能纪要帮助文档](https://www.feishu.cn/hc/zh-CN/articles/244959839578-%E5%9C%A8%E8%A7%86%E9%A2%91%E4%BC%9A%E8%AE%AE%E4%B8%AD%E4%BD%BF%E7%94%A8%E6%99%BA%E8%83%BD%E7%BA%AA%E8%A6%81)

---

## 11. 产品范围建议

### 11.1 v1 必须形成的闭环

1. iPhone 麦克风录音；
2. SpeechAnalyzer 本地实时转写；
3. 同时保存音频和逐字稿；
4. 结束会议后生成结构化纪要；
5. 输出至少一种可靠 Mermaid 图示，首版建议仅支持 flowchart；
6. 会议保存为 Markdown 资产包；
7. iCloud Documents 同步；
8. 选择 Obsidian 目录并保存；
9. 本地模式与 BYOK 模式有清晰的数据流说明；
10. StoreKit 一次性永久解锁。

### 11.2 v1 不建议加入

- 在线会议机器人；
- iPhone 系统音频捕获；
- 团队账号与协作；
- 自建云端转写或总结服务；
- 多种复杂 Mermaid 图类型；
- 跨所有会议的向量数据库与语义搜索；
- 说话人声纹识别；
- 图片生成；
- 订阅套餐。

### 11.3 建议付费结构

推荐：

- 免费下载；
- 允许录制并完整体验一段 2–5 分钟会议；
- 一次性 $6.99–$9.99 解锁；
- 不提供订阅；
- BYOK 推理费由用户直接承担；
- 若支持 Apple Foundation Models，本地模式无额外推理费。

原因：

- AI Notes: BYOK Transcription 已采用“Demo + $9.99 lifetime”；
- Synopsule 的 £1.99 会形成低价锚点；
- 免费本地竞品意味着用户不会仅为“本地总结”付费；
- Quillvault 的付费理由应是完整文件工作流与图示，而不是转写次数。

---

## 12. 风险与应对

| 风险 | 证据 | 应对 |
|---|---|---|
| Synopsule 快速补上图示或 iCloud | 已在较短时间加入实时转写、Watch、Apple Intelligence、Obsidian | 把 Markdown 事实源、文件格式和图示可编辑性做深 |
| Apple Notes 继续增强 | 系统已经有实时转写、总结、iCloud | 服务 PKM/开发者，不与系统笔记争大众用户 |
| 免费本地竞品压低价格 | Note Taker AI 完全免费 | 通过文件资产包、Obsidian、BYOK 和 Mermaid 收费 |
| “完全本地”宣传被质疑 | BYOK 会向第三方发送文本 | 产品内展示两种模式和逐次 provider 同意 |
| Mermaid 生成错误 | LLM 直接输出 Mermaid 不稳定，渲染库只支持部分语法 | 先生成结构化数据，再由 App 生成受限 Mermaid |
| iCloud 与 Obsidian 冲突副本 | 双轨双向同步可能出现覆盖 | 只允许一个 Markdown 事实源，其他目标单向写入 |
| 没有说话人分离 | Synopsule、Whisper Notes 已支持 | 首版诚实标注；优先保证时间戳、原文和人工修订 |
| iOS 26 限制设备覆盖 | SpeechAnalyzer 与 Foundation Models 有系统/硬件要求 | 明确以新系统隐私用户为目标，不做脆弱的旧 API 长音频回退 |

---

## 13. 上线前验证指标

不要只验证“功能能运行”，应验证“组合差异是否真的有价值”。

### 13.1 原型验证

- 20 段真实会议录音；
- 录音长度覆盖 5、30、60、120 分钟；
- 实时转写不中断率；
- 纪要中决策、待办、章节的人工可接受率；
- Mermaid 首次可渲染率；
- 从纪要点击回原文/音频的正确率；
- iCloud 与 Obsidian 文件完整性。

### 13.2 用户验证

至少招募 8–12 位 iPhone + Obsidian/Markdown 用户，验证：

- 是否愿意用 Quillvault 替代 Voice Memos + 手动粘贴 AI；
- 是否真正打开和修改 Mermaid 图；
- 是否重视 Markdown 事实源，而不只是“可以导出”；
- 是否接受配置 API Key；
- 是否愿意一次性支付 $6.99–$9.99；
- 一周内是否主动记录第二次会议。

### 13.3 继续投入门槛

建议同时满足：

- 至少 60% 测试用户完成“录音 → 纪要 → 保存”；
- 至少 40% 在 7 天内再次使用；
- 至少 5 人明确认为 Markdown/Obsidian 或 Mermaid 是购买理由；
- Mermaid 首次渲染成功率不低于 90%；
- 没有音频或 Markdown 丢失事故。

---

## 14. 最终竞争判断

### 14.1 已被验证的需求

- 用户需要无机器人、面对面会议录音；
- 本地转写和隐私确实有市场；
- BYOK 已被多个产品验证；
- 一次性付费在本地 AI 工具中可行；
- 用户需要摘要、行动项、章节和原文回放；
- iCloud 与 Obsidian 都有明确受众；
- 视觉化会议输出已经出现。

### 14.2 尚未被验证的核心假设

> 用户是否愿意为了“可编辑 Mermaid + Markdown 文件主权”而从现有本地转写工具迁移并付费。

这是 Quillvault 当前最重要、也是唯一需要优先验证的市场假设。

### 14.3 推荐竞争策略

不做“功能最多的会议 App”，而做：

> **iPhone 上最开放、最可迁移、最适合个人 AI 工作流的隐私会议纪要。**

把资源集中在四件事：

1. 实时本地转写稳定；
2. 飞书式纪要可溯源；
3. Mermaid 真正可编辑、可复用；
4. Markdown、iCloud、Obsidian 没有文件锁定。

只要这四项明显优于 Synopsule、Apple Notes 和 AI Notes: BYOK Transcription，Quillvault 就有清晰的上架理由。

---

## 15. 主要来源

- [Synopsule App Store](https://apps.apple.com/gb/app/synopsule/id6773112941)
- [AI Notes: BYOK Transcription App Store](https://apps.apple.com/us/app/ai-notes-byok-transcription/id6749819451)
- [Note Taker AI - 100% local App Store](https://apps.apple.com/fr/app/note-taker-ai-100-local/id6760299554?l=en-GB)
- [Local AI Note Taker App Store](https://apps.apple.com/us/app/local-ai-note-taker/id6759070933)
- [Whisper Notes App Store](https://apps.apple.com/us/app/whisper-notes-speech-to-text/id6447090616)
- [Aiko App Store](https://apps.apple.com/us/app/aiko/id1672085276)
- [Apple Notes 录音、转写与总结](https://support.apple.com/en-us/118442)
- [Renote App Store](https://apps.apple.com/us/app/ai-notes-voice-to-text-renote/id6448519306)
- [Evernote App Store](https://apps.apple.com/id/app/evernote-ai-notes-organizer/id281796108)
- [Meeting.ai App Store](https://apps.apple.com/ca/app/meeting-ai-agent-for-work/id6478665147)
- [Mermaid AI](https://mermaid.ai/products/ai)
- [飞书妙记](https://www.feishu.cn/product/minutes)
- [Apple SpeechAnalyzer WWDC 示例](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple iCloud Documents 同步](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)
- [BeautifulMermaid Swift](https://github.com/lukilabs/beautiful-mermaid-swift)
