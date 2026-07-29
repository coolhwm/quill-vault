# Quillvault MVP 依赖调研与选型

> 状态：已确认，实施中
> 日期：2026-07-30
> 原则：Native First，少而稳定，所有依赖均可替换

## 1. 选型原则

依赖只有同时满足以下条件才进入生产 Target：

1. 解决的是复杂、通用且不构成产品核心差异的能力；
2. 相比 Apple 原生 API 或小型 Adapter，显著降低正确性风险；
3. 支持 Swift 6、iOS 26 和 Swift Package Manager；
4. 有清晰许可证、持续维护和可审计源码；
5. 不要求引入全局架构或把第三方类型泄漏到 Domain；
6. 可以固定版本，并能通过 Adapter 在未来替换。

核心差异能力——可恢复纪要任务、会议资产规则、状态机、Provider 能力模型与诊断语义——必须由项目自身维护。

## 2. 结论摘要

### 2.1 生产依赖

| 能力 | 选择 | 决策 |
| --- | --- | --- |
| SQLite | [GRDB.swift](https://github.com/groue/GRDB.swift) | 采用 |
| Markdown 展示 | [MarkdownUI](https://github.com/markiv/MarkdownUI) | 条件采用，先做长文性能 Spike |
| Mermaid | [mermaid-js/mermaid](https://github.com/mermaid-js/mermaid) | 采用固定版本的本地构建产物 |

### 2.2 测试依赖

| 能力 | 选择 | 决策 |
| --- | --- | --- |
| 代码测试 | [Swift Testing](https://github.com/swiftlang/swift-testing) | 采用，随 Swift 工具链 |
| UI/值快照 | [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | 仅测试 Target 采用 |

### 2.3 使用 Apple 原生框架

| 能力 | 原生框架 |
| --- | --- |
| UI 和状态观察 | SwiftUI、Observation |
| 录音和播放 | AVFAudio、AVFoundation |
| 设备端转写 | SpeechAnalyzer、SpeechTranscriber |
| 后台纪要 | BackgroundTasks |
| Action Button | App Intents、App Shortcuts |
| 网络与流式响应 | Foundation URLSession |
| 文件访问 | Foundation、NSFileCoordinator、安全作用域 URL |
| 密钥 | Security / Keychain Services |
| Mermaid 容器 | WebKit |
| 日志与性能 | Logger、OSSignposter、URLSessionTaskMetrics |

### 2.4 不采用

- TCA 或其他全局状态管理框架；
- SwiftData 作为索引或任务存储；
- 通用 OpenAI Swift SDK；
- Alamofire；
- AudioKit；
- KeychainAccess/Valet 等 Keychain Wrapper；
- 第三方 DI 容器；
- 通用 UI 组件框架；
- 通用 SSE 自动重连库。

## 3. 逐项调研

### 3.1 GRDB

**结论：采用。**

GRDB 是长期维护的 SQLite Swift 工具包，提供迁移、事务、WAL 并发、数据库观察和 FTS。它允许项目直接控制 schema 与 SQL，同时减少 sqlite3 C API 的错误表面积。[GRDB 官方仓库](https://github.com/groue/GRDB.swift)

适用范围：

- 会议与文件指纹索引；
- FTS5 本地全文检索；
- 生成 Job/Step 检查点；
- 模型配置非密钥字段；
- 本地诊断事件；
- schema migration。

边界：

- GRDB 类型不得进入 Domain 或 Feature 公共接口；
- Repository Adapter 完成 Record 与领域类型映射；
- 不在数据库保存唯一的逐字稿或纪要正文；
- 数据库必须可删除并从文件重建；
- 固定 major/minor release，不跟踪分支。

不选 SwiftData 的原因：

- 任务状态需要明确事务与幂等更新；
- FTS 和重建流程需要可预测 SQL；
- 长期迁移需要可测试的显式步骤；
- 数据库是操作索引而不是 Apple 对象图。

### 3.2 MarkdownUI

**结论：条件采用。**

MarkdownUI 提供 SwiftUI 原生 CommonMark 展示和主题能力，可减少标题、列表、引用、代码块和链接的重复实现。[MarkdownUI 官方仓库](https://github.com/markiv/MarkdownUI)

采用前置 Spike：

- 使用真实 60–180 分钟会议的 `minutes.md`；
- 验证首次展示、滚动、动态字体和内存；
- 验证超长逐字稿不一次性构建全部 View；
- Mermaid fenced block 必须由项目预解析后交给独立 Renderer；
- 本地相对链接必须经过 Quillvault 安全路由，不允许任意远程资源加载。

使用方式：

- 只负责纪要正文 section；
- 逐字稿使用原生虚拟化列表，不用单个 Markdown View 渲染全文；
- Mermaid 使用占位节点和本地 WKWebView；
- 如果 Spike 不达标，退回 `swift-markdown` AST + 项目自有 section renderer，不改变 Domain。

### 3.3 Mermaid

**结论：采用固定版本本地资源。**

Mermaid 支持 flowchart、timeline、sequenceDiagram 和 mindmap，采用 MIT License，并提供 parse API 验证定义。[Mermaid 官方仓库](https://github.com/mermaid-js/mermaid) · [许可证](https://github.com/mermaid-js/mermaid/blob/develop/LICENSE)

集成规范：

- 构建时固定 release 和资源校验和；
- 只把所需 JS/CSS 打包进 App；
- WKWebView 禁止远程导航、脚本、字体、图片和遥测；
- 使用 Content Security Policy；
- Mermaid 输入来自 App 确定性生成或用户明确编辑的源码；
- 渲染失败只影响图示，不阻塞正文；
- 更新 Mermaid 版本必须运行图示回归样本。

### 3.4 Swift Testing

**结论：采用。**

Swift Testing 随 Swift 6/Xcode 工具链提供，支持参数化、traits、并行和与 XCTest 并存，不需要额外生产依赖。[Swift Testing 官方仓库](https://github.com/swiftlang/swift-testing)

使用范围：

- Domain 状态机；
- Application 用例；
- GRDB migration；
- 文件原子发布；
- AI 解析、分块和重试；
- 故障注入与属性测试。

XCUITest 继续负责端到端 UI；必须使用 XCTest API 的系统测试不强制迁移。

### 3.5 SnapshotTesting

**结论：仅测试 Target 采用。**

SnapshotTesting 可测试 SwiftUI/UIKit 图片、JSON、请求和 WebKit 输出，并支持 Swift Testing。[官方仓库](https://github.com/pointfreeco/swift-snapshot-testing)

使用范围：

- 首页、录音、会议列表和详情的关键状态；
- Dynamic Type、Dark Mode 和窄屏布局；
- 纪要结构 JSON 与 Mermaid 源码；
- 脱敏后的 URLRequest；
- 数据库 migration schema。

限制：

- 只链接测试 Target；
- 固定 CI Simulator Runtime；
- 快照不能替代 VoiceOver、交互和真机测试；
- 不对系统动态 Liquid Glass 像素做过度脆弱的全屏断言。

## 4. 原生能力说明

### 4.1 SwiftUI + Observation

Apple 的 Observation 直接将可观察模型与 SwiftUI 数据依赖连接，满足 Feature Model 的状态投影需求。[SwiftUI Model Data](https://developer.apple.com/documentation/swiftui/model-data)

不采用 TCA：

- 领域复杂度主要来自持久状态机，不是页面 Reducer；
- TCA 会成为所有 Feature 的强依赖；
- 原生 Observation 与显式 Use Case 已足够；
- 保留未来局部采用其他技术的自由。

### 4.2 AVFAudio

使用 AVAudioSession、AVAudioEngine/AVAudioRecorder、AVAudioFile 和 AVPlayer 系列。AudioKit 更适合音乐合成与复杂 DSP，本项目只需要可靠录音、缓冲分发和播放，原生框架具有最完整的系统生命周期集成。

Apple 提供音频中断和路由变化通知，必须由 Audio Adapter 显式处理。[Audio Interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)

### 4.3 Speech

使用 iOS 26 的 SpeechAnalyzer 与 SpeechTranscriber，不引入 WhisperKit 或云端转写。SpeechAnalyzer 是 Actor，并以 AsyncSequence 解耦输入和结果，适合与录音管线分离。[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)

### 4.4 BackgroundTasks

使用 BGContinuedProcessingTask 承载由用户启动的长纪要工作。它提供 Live Activity 进度，但系统仍可终止任务，因此不能替代持久 Job 状态。[BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)

BGProcessingTask 只作为将来评估的机会性恢复手段，不承诺立即调度，也不作为 MVP 正确性的唯一机制。

### 4.5 App Intents

使用一个高价值 App Shortcut 暴露“开始面对面会话”，供支持的 iPhone Action Button 绑定。Apple 明确允许用户将 App Shortcut 配置到 Action Button。[Action Button](https://developer.apple.com/documentation/appintents/actionbutton)

Intent 只调用与首页相同的 Application Use Case，不复制录音规则。

### 4.6 Foundation URLSession

**结论：自建薄 OpenAI-compatible Adapter，不采用通用 OpenAI SDK。**

调研的 [MacPaw/OpenAI](https://github.com/macpaw/openai) 和 [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) 都覆盖大量 OpenAI API、流式响应和部分兼容服务。Quillvault 只需要一个受控 Chat Completions 子集，但需要：

- 非标准兼容服务的宽容解码；
- 与 Generation Step 一致的取消和重试；
- `URLSessionTaskMetrics` 的 DNS/TLS/首字节指标；
- 字段级隐私日志；
- 后台 expiration 协作；
- 不让 Provider DTO 进入业务层。

完整 SDK 的额外端点和严格 DTO 反而扩大兼容与升级风险。项目因此使用 URLSession、Codable 和一个小型 SSE Decoder 实现薄 Adapter。

不采用 Alamofire：

- URLSession 已覆盖所需请求、流、取消和 metrics；
- 额外抽象不能替代任务恢复；
- 直接 delegate 更利于精确诊断。

不采用通用 SSE 库：

- Provider 重试由持久 Job 控制，不能让网络库私自重连；
- 只需要解析 `data:`、结束标记和有限事件字段；
- SSE Decoder 保持纯函数并以标准样本测试。

### 4.7 Security / Keychain

直接使用 Keychain Services，原因是后台访问级别是产品行为：

- 明确设置 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；
- 明确禁止同步；
- 精确区分未首次解锁、项目不存在和认证错误；
- 避免 Wrapper 默认值变化。

Apple 推荐该等级用于后台应用，并说明它不迁移到新设备。[Apple Keychain](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

### 4.8 Foundation 文件协调

直接使用安全作用域 URL、持久书签和 NSFileCoordinator。第三方文件抽象无法消除 iCloud、Files 与 Obsidian 的系统协调要求。[Security-scoped URLs](https://developer.apple.com/documentation/foundation/nsurl) · [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

### 4.9 诊断

开发期使用 Logger 和 OSSignposter；可导出诊断使用项目自有白名单事件结构和 GRDB 环形表。`swift-log` 是跨平台日志 facade，但本项目只面向 Apple 平台，不能直接提供所需的隐私、signpost、URLSession metrics 与导出策略，因此不引入。

## 5. UI 依赖策略

不采用通用 UI 框架。SwiftUI、SF Symbols、系统 Material/Liquid Glass 能覆盖 MVP 基础交互，项目自建小型 Design System：

- Semantic Color；
- Typography；
- Spacing；
- Card/Section；
- Primary/Secondary Button；
- Status Badge；
- Empty/Error/Paused State；
- Progress；
- Audio Transport；
- Markdown/Mermaid Container。

AI 生成图片只允许作为品牌探索或非关键空状态素材，必须有无图片回退、深浅色适配和许可证记录。

## 6. 依赖治理

### 6.1 引入检查

每个依赖 PR 必须记录：

- 使用目标和替代方案；
- 最新稳定版本和固定策略；
- 许可证；
- 支持平台与 Swift 版本；
- 维护活跃度；
- 生产 Target 或测试 Target；
- 数据和网络行为；
- 替换边界；
- 二进制体积变化。

### 6.2 更新策略

- 不使用 branch dependency；
- `Package.resolved` 提交仓库；
- 每月检查安全与兼容更新；
- major update 单独 Issue 和 migration test；
- Mermaid 资源记录版本、许可证和 SHA-256；
- 未经审查不得加入包含遥测、广告或远程资源的包。

### 6.3 初始依赖预算

- 生产 Swift Package：最多 2 个（GRDB、MarkdownUI）；
- 本地 JS Runtime：1 个（Mermaid）；
- 测试 Package：最多 1 个（SnapshotTesting）；
- 超出预算必须通过 ADR 解释。

## 7. 实施前 Spike

进入正式 Feature 实现前完成：

1. GRDB migration、FTS 和 2,000 场索引基准；
2. MarkdownUI 真实长纪要滚动与内存测试；
3. BGContinuedProcessingTask + URLSession + Keychain 锁屏生成；
4. 外部修改 `transcript.md` / `minutes.md` 的文件协调；
5. Mermaid 固定版本离线安全渲染；
6. OpenAI-compatible SSE、非流式、宽容 DTO 和 URLSession metrics；
7. Action Button 冷启动录音。

Spike 代码可以进入正式模块的前提是遵守架构边界并有自动化测试；不得重复 Demo 的抛弃式工程方式。
