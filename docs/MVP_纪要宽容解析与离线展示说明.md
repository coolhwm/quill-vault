# MVP 纪要宽容解析与离线展示说明

> 状态：实施中；代码与自动化测试已落地，真机长文档/可访问性 Spike 待验收
> 日期：2026-08-03

## 1. 用户可见契约

纪要生成只把“空、无意义或不安全”视为不可发布。模型缺少次要字段、时间范围或图示时，先在本地规范化并发布可读正文，同时在纪要页显示“信息可能不完整”；不引入“部分完成”状态，也不删除录音或文字记录。用户可以从已完成的文字记录重新生成纪要。

## 2. 输出边界

`MinutesOutputNormalizer` 位于 Application 层，负责把 Provider 输出转换为安全的 Markdown 候选：

- 接受普通 Markdown、合法 JSON、Markdown fenced JSON 以及 JSON 前后的解释性噪声；
- 从 `markdown`、`summary`、`content`、`minutes`、`text` 等常见字段提取正文；
- 规范化可恢复的带方括号时间范围，并在发布前将其限制到文字记录音频边界；无效范围只移除锚点，不丢弃正文；
- 只接受至少包含可读文字的正文；空响应、垃圾内容、脚本/事件处理器/危险协议等安全违规不发布；
- Mermaid 源码独立校验。图示无效时移除图块并保留正文，前端仍显示源码回退；
- 由 `informationMayBeIncomplete` 前置元数据传递降级提示，状态仍为 `minutesCompleted`。

规范化后的候选仍通过原有来源指纹、外部修改检查和原子发布流程；因此宽容解析不会扩大覆盖旧纪要的范围。

## 3. Markdown 展示 Spike 与决议

当前实现采用原生 `AttributedString(markdown:)` + `LazyVStack` 的自有展示边界：正文按段懒加载，使用系统字体、Dynamic Type、文本选择和 VoiceOver；文字记录仍由已有时间线虚拟化列表展示。没有在未完成真实长文档测试前引入 MarkdownUI 生产依赖。

Spike 必须在 iOS 26 参考真机使用真实 60–180 分钟 `minutes.md` 复核：

1. 首屏出现与首次可交互时间；
2. 连续滚动到底部，无明显卡顿、截断或崩溃；
3. 最大 Dynamic Type、深浅色和 VoiceOver；
4. 进入/离开详情后的内存回收；
5. 长文字记录不会构建单一无限大的 View。

若实测不达标，保留当前自有段落渲染器并继续按段/分页优化；若 MarkdownUI 在真实数据上达标，也只能在 section 边界通过 Adapter 引入，不能让第三方类型进入 Domain。

## 4. Mermaid 离线资源

Mermaid runtime 固定为 `11.16.0`，MIT 许可证文本见 [`ThirdPartyNotices/MERMAID-LICENSE.txt`](../ThirdPartyNotices/MERMAID-LICENSE.txt)。打包资源为 `Packages/QuillvaultFeatures/Sources/MeetingsFeature/Resources/mermaid.min.js`，SHA-256：

```text
07fb9c98a9718885cb4b68c29bdfdbd1e96bc6e731f5387cdc70ce8aadd4b2a6
```

渲染器使用非持久化 `WKWebView`，HTML 通过 `Bundle.module` 加载同包脚本；CSP 仅允许本地脚本和内联样式，启动内联脚本使用每文档随机 nonce，禁止远程脚本、字体、图片、连接、Frame、对象、表单和 Base URL，导航代理拒绝所有导航。Mermaid `securityLevel` 固定为 `strict`，渲染失败只切换到源码回退，不影响正文、文字记录、播放器或完成状态。

真机验收还需断网检查：图示仍可显示、脚本错误仍显示源码、无远程导航和网络请求。

## 5. 自动化覆盖

- Application：JSON/fenced JSON/噪声、缺少次要字段、无效 Mermaid、危险输出、时间范围和长正文；
- MeetingFileStore：读取 `informationMayBeIncomplete` 前置元数据；
- MeetingsFeature：固定 runtime/CSP、JSON 字符串转义和本地资源入口；
- Xcode/CI：继续执行 package tests、Swift format、架构/隐私清单和 Debug build。

真机长文档、最大字体、VoiceOver、断网和内存 Spike 是下一阶段的 `ready-for-human` 验收项，不作为研发代码推进的阻塞条件。
