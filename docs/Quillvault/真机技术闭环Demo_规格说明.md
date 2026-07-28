# Quillvault 真机技术闭环 Demo

## Problem Statement

PKM 技术用户希望验证 Quillvault 的核心产品假设能否在 iOS 26 真机上成立：一次面对面会话能否从可靠录音开始，经设备端实时转写、BYOK 结构化纪要和可编辑 Mermaid，最终成为用户自己掌握的 Markdown 会议资产。

当前仓库只有产品说明、领域词汇和 ADR，没有可运行代码。完整 v1 的范围过大，不适合在技术可行性尚未证明时直接投入。因此需要一个明确可抛弃的真机技术闭环 Demo，以最低必要工程投入验证系统能力、关键集成和故障安全，而不是建立生产版本骨架。

## Solution

构建一个面向 iOS 26 真机的 SwiftUI 单 Target 抛弃式原型。用户可以选择 iCloud Drive 或 Obsidian 中的权威目录，配置 DeepSeek BYOK 并将 API Key 保存到 Keychain，然后开始一场面对面会话。App 持续保存录音并展示设备端实时逐字稿；进入锁屏或后台时优先保证录音不中断，停止后补齐最终逐字稿。

用户随后通过 BYOK 生成结构化纪要。模型只接收逐字稿文本，返回 JSON Output；App 在本地验证业务结构，确定性生成一张 Mermaid `flowchart`，并将 `minutes.md`、`transcript.md` 和 `recording.m4a` 直接写入权威目录中的会议资产目录。用户可以编辑 Mermaid 源码并离线重新渲染。

Demo 以一个最高层 `MeetingWorkflow` 作为主要行为与测试切面，贯穿 UI 意图、录音、转写、BYOK、图示和文件落盘。它用于验证可行性，不作为正式产品的工程基础。

## User Stories

1. As a PKM technical user, I want to run the Demo on an iOS 26 iPhone, so that I can validate Quillvault against the intended system APIs.
2. As a PKM technical user, I want to understand that this is a disposable feasibility prototype, so that I do not mistake it for production-ready software.
3. As a PKM technical user, I want to choose an iCloud Drive or Obsidian folder as the authoritative directory, so that my meeting assets live where I control them.
4. As a returning user, I want the authoritative directory authorization to survive an App restart, so that I do not have to select the folder before every meeting.
5. As a returning user, I want a clear recovery prompt when the authoritative directory permission is no longer valid, so that the App never silently writes to a hidden fallback copy.
6. As a BYOK user, I want a simple settings page for Base URL, Model, and API Key, so that I can configure my own model service without editing source code.
7. As a BYOK user, I want my API Key stored in Keychain, so that it is not persisted as ordinary preferences or committed source.
8. As a BYOK user, I want my Base URL and Model restored after relaunch, so that I can reuse the configuration.
9. As a BYOK user, I want a Save and Test action, so that I can verify the configuration before recording.
10. As a BYOK user, I want the connection test to make a real model request and validate a required structured response, so that HTTP 200 alone cannot produce false success.
11. As a BYOK user, I want a useful error when the service rejects my credentials or model, so that I can correct the configuration.
12. As a privacy-conscious user, I want BYOK requests to send only transcript text, so that the original audio remains local.
13. As a privacy-conscious user, I want requests to go directly to my configured service, so that no Quillvault server participates in the data flow.
14. As a meeting participant, I want microphone permission requested before the first recording, so that recording begins only with explicit authorization.
15. As a meeting participant, I want an obvious recording state, so that I can tell when the iPhone is capturing the conversation.
16. As a PKM technical user, I want to start a face-to-face session from the App, so that I can exercise the core workflow with minimal interaction.
17. As a PKM technical user, I want the original audio written continuously, so that transcription failure cannot erase the primary evidence.
18. As a PKM technical user, I want volatile and final transcription results visibly distinguished, so that tentative text is not mistaken for final text.
19. As a PKM technical user, I want transcript segments associated with audio time ranges, so that the transcript remains traceable to the recording.
20. As a PKM technical user, I want recording to continue when the phone locks or the App enters the background, so that a normal meeting is not truncated.
21. As a PKM technical user, I want recording prioritized over uninterrupted background transcription, so that system scheduling limits do not cause audio loss.
22. As a PKM technical user, I want transcription to catch up from saved audio after foregrounding or stopping, so that the final transcript covers the complete timeline.
23. As a PKM technical user, I want to stop the meeting explicitly, so that audio and transcript can be finalized before summary generation.
24. As a PKM technical user, I want visible finalization progress, so that I know when the transcript is ready.
25. As a PKM technical user, I want BYOK generation to begin only after finalization, so that the minutes represent the complete meeting.
26. As a PKM technical user, I want a meeting overview, so that I can quickly identify the topic, time, duration, language, and conclusion.
27. As a PKM technical user, I want a core summary and topic chapters with time ranges, so that I can understand the meeting without reading the entire transcript.
28. As a PKM technical user, I want decisions to include reasons and source evidence, so that I can verify important conclusions.
29. As a PKM technical user, I want action items to include owner, deadline, and source evidence when present, so that follow-up work is actionable and traceable.
30. As a meeting participant, I want an owner marked as “待确认负责人” when no explicit name-to-responsibility relationship exists, so that the model does not invent attribution.
31. As a PKM technical user, I want risks and unresolved questions separated, so that uncertainty is not hidden inside confident prose.
32. As a PKM technical user, I want one core viewpoint diagram, so that the meeting's important relationships are visible at a glance.
33. As a PKM technical user, I want constrained graph nodes and relationships instead of arbitrary model-authored Mermaid, so that syntax can be generated predictably.
34. As a PKM technical user, I want deterministic Mermaid `flowchart` generation, so that identical graph data produces stable source.
35. As a PKM technical user, I want Mermaid rendered from bundled local assets, so that diagrams work without remote scripts or telemetry.
36. As a PKM technical user, I want to edit Mermaid source and rerender it, so that the diagram remains a reusable knowledge artifact.
37. As a PKM technical user, I want `minutes.md` to contain front matter, structured minutes, Mermaid, and relative source links, so that it remains useful outside Quillvault.
38. As a PKM technical user, I want `transcript.md` to contain the complete timestamped transcript, so that I can inspect and reuse the source material.
39. As a PKM technical user, I want `recording.m4a` retained, so that the Demo preserves the original evidence.
40. As a PKM technical user, I want each completed meeting stored in its own meeting asset directory, so that files remain understandable without a private database.
41. As a PKM technical user, I want relative source links, so that moving the meeting asset directory does not break it.
42. As a PKM technical user, I want invalid model output rejected locally, so that malformed data cannot become authoritative minutes.
43. As a PKM technical user, I want empty or invalid model output retried once, so that a transient response does not immediately require manual recovery.
44. As a PKM technical user, I want recording and transcript preserved after BYOK failure, so that AI failure never destroys captured meeting data.
45. As a PKM technical user, I want a diagnostic error and manual Retry action, so that I can recover without recording again.
46. As a PKM technical user, I want no partial `minutes.md` written after failure, so that incomplete content is never presented as success.
47. As a feasibility evaluator, I want a Chinese session lasting at least 15 minutes with at least 5 minutes locked or backgrounded, so that I can test the critical recording path realistically.
48. As a feasibility evaluator, I want uninterrupted audio and a complete final transcript, so that recording and catch-up have a clear pass/fail result.
49. As a feasibility evaluator, I want the same session to produce validated BYOK minutes, an editable flowchart, and complete meeting assets, so that the entire vertical path is proven.
50. As a developer evaluating the prototype, I want errors and workflow state observable in the UI, so that failures can be diagnosed without production telemetry.

## Implementation Decisions

- Target iOS 26 with SwiftUI in a single application target.
- Treat the Demo as disposable. Prefer the smallest understandable implementation that proves external behavior; do not build speculative production abstractions.
- Use `MeetingWorkflow` as the single high-level orchestration seam. It receives UI intents and exposes observable setup, recording, finalizing, generating, completed, and failed states.
- Compose narrow replaceable boundaries for audio recording, transcription, BYOK, credential storage, authoritative-directory access, meeting-asset writing, Mermaid generation, and rendering. These boundaries exist to test the workflow, not to form a reusable framework.
- Use a background-capable audio session and continuously write an `m4a` source file. Audio survival takes precedence over uninterrupted background transcription.
- Use SpeechAnalyzer and SpeechTranscriber for device-side real-time transcription. Keep volatile results distinct from final results and retain time ranges.
- If analysis pauses in the background, record the finalized range and catch up from saved audio after foregrounding or stopping. Finalization must prevent duplicate or missing ranges.
- Store the API Key only in Keychain. Base URL and Model may use ordinary local preferences.
- Use DeepSeek at `https://api.deepseek.com` with model `deepseek-v4-pro` as the acceptance target.
- Use the OpenAI-compatible Chat Completions API in JSON Output mode. Requests contain transcript text and instructions, never audio.
- Make the connection test perform a real model request and decode a representative structured result.
- Decode model output into local structured-minutes types and check required business fields; syntactically valid JSON alone is insufficient.
- Retry empty content, invalid JSON, or failed business validation once. A second failure becomes an observable error with manual retry.
- Include overview, summary, topic chapters with time ranges, decisions with reasons and evidence, action items with owner/deadline/evidence, risks, unresolved questions, constrained graph data, and source links.
- Accept an owner only when the transcript explicitly establishes the name-to-responsibility relationship. Otherwise use “待确认负责人”.
- Generate Mermaid deterministically from constrained graph data and support only `flowchart`.
- Bundle Mermaid runtime assets and render locally without remote assets or business network requests. Allow source editing and rerendering.
- Select one authoritative directory with the system folder picker. Persist security-scoped access with a bookmark and restore it after relaunch.
- Stop writing and request reauthorization when the bookmark is invalid; never silently fall back to an App-private content copy.
- Write `minutes.md`, `transcript.md`, and `recording.m4a` to one meeting asset directory. Markdown remains the content truth; do not introduce a private content database.
- Preserve the recording after transcription, generation, validation, rendering, or writing failures. Never write partial authoritative minutes.
- Keep the UI to setup/status, recording/live transcript, finalization/generation, completed minutes/Mermaid editing, BYOK settings, and authoritative-directory selection.
- Include no analytics, ads, third-party crash reporting, account system, or Quillvault backend.

## Testing Decisions

- Use `MeetingWorkflow` as the primary automated seam. Drive workflow intents and assert observable state plus produced meeting assets, not private helper calls.
- Use controlled substitutes for recording, transcription events, BYOK responses, Keychain, security-scoped directory access, clock, and Mermaid rendering.
- Cover one complete automated success path from saved setup through recording, finalization, valid minutes, deterministic Mermaid, and complete meeting-asset output.
- Cover microphone denial, unavailable transcription, paused analysis with catch-up, invalid directory authorization, authentication failure, empty content, invalid JSON, missing fields, retry success, retry exhaustion, Mermaid parse failure, and write failure.
- Assert that the recording survives every downstream failure and failed generation never creates partial authoritative minutes.
- Assert that only transcript text is assembled for BYOK and that no audio payload or URL is sent.
- Assert “待确认负责人” behavior and retention of explicit owner/deadline evidence.
- Assert deterministic Mermaid generation and successful rerender after edits without network access.
- Perform the real DeepSeek integration check manually with a user-entered API Key; never commit secrets or embed them in fixtures.
- Use one decisive real-device acceptance test: a Simplified Chinese face-to-face session lasting at least 15 minutes, including at least 5 minutes locked or backgrounded.
- Passing the real-device test requires uninterrupted audio, a final transcript with no duplicate or missing timeline ranges, validated BYOK minutes, an editable offline-rendered flowchart, and all three meeting assets in the persisted authoritative directory.
- Relaunch acceptance verifies both Keychain-backed BYOK configuration and bookmark-backed authoritative-directory access.
- There is no existing test prior art. This workflow seam and real-device checklist establish the prototype's initial convention.

## Out of Scope

- Production architecture, reusable framework design, migration from the Demo, release hardening, App Store submission, and complete visual design.
- Device-side minutes using Apple Foundation Models.
- Action Button, App Intents, Siri, lock-screen widgets, Apple Watch, and other quick-start surfaces.
- Importing existing audio or video, batch import, and share extensions.
- Speaker diarization, voiceprints, real-name inference, or “speaker 1/2” identities.
- Mermaid `timeline`, `sequenceDiagram`, `mindmap`, chapter diagrams, and arbitrary model-authored Mermaid.
- Default Quillvault iCloud container, mirror copies, bidirectional sync, conflict merging, and production-grade file coordination.
- Deleting the source recording after successful generation.
- StoreKit, trial limits, permanent unlock, subscriptions, and other monetization.
- Multiple provider-specific adapters, native Anthropic/Gemini protocols, certification beyond DeepSeek, and Quillvault-hosted inference.
- English QA, experimental locales, mixed-language recognition, and in-meeting language switching.
- Online meeting bots, calendar integration, conferencing integrations, call recording, and system-audio capture.
- Accounts, teams, collaboration, cross-meeting search, knowledge Q&A, vector databases, templates, analytics, telemetry, ads, and third-party crash reporting.
- The full 60-minute v1 technical gate. This Demo uses the agreed 15-minute/5-minute-background acceptance scenario.

## Further Notes

- This specification uses the Quillvault domain glossary and respects ADR 0001: iOS 26, SpeechAnalyzer, and deterministic Mermaid remain the direction.
- The Demo deliberately narrows ADR 0001: BYOK is the only minutes-generation acceptance path, only Mermaid `flowchart` is required, and the acceptance meeting is shorter than the eventual v1 gate.
- DeepSeek documents [`deepseek-v4-pro` and OpenAI-compatible Chat Completions](https://api-docs.deepseek.com/guides/function_calling/) plus [JSON Output](https://api-docs.deepseek.com/guides/json_mode/). JSON Output may still be empty or semantically incomplete, hence local validation and retry.
- Completion means the real-device scenario passes end to end. Rendering screens, receiving HTTP 200, or producing files from hard-coded fixtures is insufficient.
- The code may be discarded after feasibility is established. Production decisions must be revisited rather than inferred from prototype structure.
