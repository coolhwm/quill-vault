## Problem Statement

Quillvault 已通过 iOS 26 真机技术闭环 Demo 验证录音、设备端转写、BYOK 结构化纪要、Mermaid 和 Markdown 会议资产的核心技术路线，但 Demo 是抛弃式原型，不能承担长期产品迭代。

目标用户需要一款可以通过 TestFlight 分发并用于真实、高强度会议工作的正式 App：从首页或 Action Button 快速录音，在后台和锁屏中可靠保存音频，管理大量历史会议，并让长时间 BYOK 纪要任务在网络异常、模型异常、系统终止或 App 退出后仍能恢复。现有 Demo 缺少正式工程架构、持久任务、历史管理、后台生成、可诊断性能、产品级 UI 和生产可靠性。

MVP 必须重新建设，不能基于 Demo 工程继续开发。录音、逐字稿和纪要不能因数据库、AI 或 UI 故障发生不可逆损坏；逐字稿一旦就绪，最终纪要必须始终能够通过继续或重新生成获得。

## Solution

建设一个面向 iOS 26 的原生 Quillvault MVP，采用 SwiftUI、Observation、Swift Concurrency 和 Local Swift Packages 组成模块化分层架构。产品提供首页、纪要、设置三个一级入口，支持首页和 Action Button 快速录音、后台可靠记录、设备端转写、历史会议与本地全文搜索、录音播放、Markdown/Mermaid 详情、多模型 BYOK 配置，以及可检查点恢复的异步后台纪要生成。

会议资产继续以 `recording.m4a`、`transcript.md` 和 `minutes.md` 作为内容真相；SQLite/GRDB 只保存可重建索引、全文检索、模型配置元数据、诊断事件和生成任务检查点。生成任务绑定逐字稿版本与模型配置快照，使用确定性步骤、幂等检查点、原子发布和可解释状态，确保任何中断都不会损坏已有资产。

MVP 仅交付 OpenAI-compatible Provider，但业务层通过 Provider 边界与协议实现解耦。AI 输出采用可用性优先策略：有效正文先发布，缺失次要结构或图示时提示信息可能不完整，用户可以重新生成。App 使用本地脱敏诊断和 URLSession 分阶段指标证明性能瓶颈不在 App 侧，不自动上传任何遥测或会议数据。

## User Stories

1. As a PKM technical user, I want one prominent recording action on the home screen, so that I can start a face-to-face session without navigating through settings.
2. As a user with a supported iPhone, I want to bind Quillvault to the Action Button, so that I can start a meeting quickly when the App is closed.
3. As a first-time user, I want clear permission, recording-consent, storage, and directory guidance, so that I understand what will happen before recording starts.
4. As a user, I want an unmistakable recording indicator and elapsed time, so that I never confuse an idle screen with an active recording.
5. As a user, I want audio capture to start before AI or network work, so that unavailable models cannot block recording.
6. As a user, I want recording to continue while the phone is locked or another App is active, so that long meetings remain complete.
7. As a user, I want live transcript feedback while Quillvault is visible, so that I can confirm recognition is working.
8. As a user, I want transcription to catch up from the recording after background analysis pauses, so that the final transcript remains complete.
9. As a user, I want calls and route changes detected and shown, so that gaps are not silently presented as continuous audio.
10. As a user, I want temporary interruptions to resume automatically when the system permits, so that short interruptions require no manual recovery.
11. As a user, I want previously written audio to remain playable after a crash or force quit, so that abnormal termination does not destroy the meeting.
12. As a user, I want to continue an interrupted meeting or finish and process it, so that I can choose the correct recovery.
13. As an Action Button user, I want a prompt when an interrupted meeting exists, so that a new recording never overwrites it.
14. As a user, I want “transcript ready” to mean the complete transcript is safely stored, so that generation never depends on volatile memory.
15. As a user, I want a ready transcript to enter “待生成纪要”, so that I understand the next step without internal queue terminology.
16. As a user, I want automatic minutes generation when enabled, so that routine meetings require no extra action.
17. As a cost-conscious user, I want to disable automatic generation, so that model requests require explicit action.
18. As a user without a working model or network, I want the meeting to remain safely pending, so that AI availability never becomes meeting failure.
19. As a user, I want a recent-first meeting history, so that I can return to prior work quickly.
20. As a user with many meetings, I want local search over titles, summaries, and transcripts, so that I can find information without a cloud service.
21. As a user, I want date, state, and model filters, so that I can manage a large history efficiently.
22. As a user, I want meeting cards to show title, time, duration, state, and model, so that the list is easy to scan.
23. As a user, I want one detail screen for summary, diagram, transcript, and recording, so that related assets remain together.
24. As a user, I want to play, pause, and seek the recording, so that I can verify what was said.
25. As a user, I want transcript timestamps to seek audio, so that I can move from evidence to source.
26. As a user, I want to read the transcript and listen to audio during generation, so that AI processing does not block completed assets.
27. As a user, I want a percentage and concrete stage such as “第 3/8 段”, so that long generation has understandable progress.
28. As a user, I want progress to persist and never move backward after restart, so that recovery feels trustworthy.
29. As a user, I want generation to continue after locking the device or switching Apps, so that I need not keep Quillvault open.
30. As a user, I want system-visible background progress, so that I can monitor or cancel work outside the App.
31. As a user, I want transient network and model failures to retry automatically, so that temporary faults need no intervention.
32. As a user, I want a paused task to explain what it needs, so that I know how to recover it.
33. As a user, I want to continue a paused task without losing verified checkpoints, so that completed model work is not repeated.
34. As a user, I want eligible work to resume when the App can run again, so that process termination does not strand it.
35. As a user, I want to regenerate minutes with the same or another model, so that I can improve an unsatisfactory result.
36. As a user, I want old minutes readable until replacement succeeds, so that regeneration never removes a useful result.
37. As a user who edited `minutes.md` externally, I want confirmation before replacement, so that Obsidian changes are not silently overwritten.
38. As a user who edited `transcript.md` externally, I want existing minutes marked stale, so that I know they used an older source.
39. As a user, I want regeneration from the latest transcript version, so that the new result reflects corrections.
40. As a user, I want readable AI content published when optional structure or diagrams are missing, so that strict formatting cannot hide a useful summary.
41. As a user, I want an “information may be incomplete” notice on degraded output, so that tolerant publishing remains honest.
42. As a user, I want Mermaid failure to leave text and source visible, so that diagram rendering cannot invalidate minutes.
43. As a user, I want Mermaid rendered entirely offline, so that viewing minutes never loads remote scripts or telemetry.
44. As a BYOK user, I want multiple named model profiles, so that I can use different compatible services.
45. As a BYOK user, I want to choose the current model, so that new jobs use my preferred profile.
46. As a user, I want a real capability request before a model is marked usable, so that HTTP success cannot hide incompatibility.
47. As a user, I want resumed jobs to retain their original model snapshot, so that output is reproducible.
48. As a user, I want a warning before deleting a profile used by unfinished work, so that tasks are not accidentally stranded.
49. As a user with an expired key, I want to repair it and continue, so that existing checkpoints remain useful.
50. As a privacy-conscious user, I want API keys stored only in Keychain and never shown in full, so that secrets are protected.
51. As a user, I want locked-device generation after first unlock since reboot, so that background work and Keychain protection coexist.
52. As a user moving devices, I want to configure keys again, so that secrets do not silently migrate.
53. As a privacy-conscious user, I want only transcript text sent to my selected BYOK endpoint, so that audio and local paths never leave the device.
54. As a user, I want the target domain and possible provider cost disclosed, so that BYOK data flow is informed.
55. As an Obsidian user, I want my selected Vault subdirectory to be authoritative, so that Quillvault does not create a private duplicate.
56. As an iCloud user, I want a default Quillvault directory, so that the App works without Obsidian setup.
57. As a user, I want recording, transcript, and minutes stored as ordinary files, so that they remain readable outside Quillvault.
58. As a user, I want history and search rebuilt from files, so that database loss cannot erase meetings.
59. As a user, I want external Markdown edits detected and reindexed, so that in-App state reflects authoritative files.
60. As a user, I want writes coordinated with Files, iCloud, and Obsidian, so that external access does not silently corrupt assets.
61. As a user, I want low-storage and lost-directory conditions surfaced before destructive failure, so that I can take corrective action.
62. As a heavy user, I want a three-hour meeting to record and process reliably, so that workshops and interviews are supported.
63. As a heavy user, I want ten meetings and eight recording hours per day to remain manageable, so that intensive work is supported.
64. As a heavy user, I want twenty pending generation jobs queued safely, so that a busy day needs no manual sequencing.
65. As a user starting a recording, I want recording to outrank generation, so that AI work cannot compromise source audio.
66. As a user with 2,000 meetings, I want responsive lists and search, so that long-term use does not degrade.
67. As a beta tester, I want a local diagnostic view and export action, so that I can provide evidence for slow or paused generation.
68. As a privacy-conscious tester, I want exports to omit secrets and meeting content, so that debugging does not leak data.
69. As a maintainer, I want DNS, connection, TLS, first-byte, streaming, parsing, persistence, retry, and background timings, so that bottlenecks are attributable.
70. As a user, I want no automatic telemetry or crash upload, so that Quillvault preserves its privacy boundary.
71. As a VoiceOver user, I want recording, playback, recovery, and model configuration fully labeled, so that the workflow is accessible.
72. As a user with large text settings, I want critical actions to remain usable, so that Dynamic Type does not break the workflow.
73. As a user, I want light, dark, and reduced-motion behavior to remain clear, so that the interface respects system preferences.
74. As a user, I want only three top-level entries, so that the product remains efficient instead of exposing technical subsystems.
75. As a user, I want AI-generated imagery limited to nonessential decoration, so that functional meaning never depends on it.

## Implementation Decisions

- MVP is a new long-lived implementation. Demo behavior, samples, and test shapes are prior art only; its engineering structure is not reused.
- The minimum system is iOS 26. Use Swift 6 strict concurrency, SwiftUI, Observation, Swift Concurrency, and repository-local Swift Packages.
- Use a modular monolith with App composition, feature presentation, application use cases, domain, infrastructure adapters, design system, and testing support.
- Dependency direction is Presentation → Application → Domain, with Infrastructure implementing Domain ports and the App composition root assembling adapters.
- Feature modules cover Home, Recording, Meetings, Generation, Models, and Settings. Features do not import each other directly.
- Do not adopt TCA, a global service locator, general DI framework, or a single global workflow object.
- Keep types and files focused; UI views do not contain business state machines, retries, database operations, file operations, audio, or networking.
- Use the Application workflow boundary as the primary behavioral test seam. Drive user commands against injected adapters and assert public state, durable checkpoints, and authoritative assets.
- Add platform adapter integration tests and physical-device acceptance for audio, Speech, BackgroundTasks, App Intents, Keychain, and coordinated file access.
- User-visible meeting states are recording, recording interrupted, finalizing transcript, pending minutes, generating minutes, generation paused, minutes completed, and minutes stale.
- A failed technical attempt is not a terminal meeting state.
- `recording.m4a`, `transcript.md`, and `minutes.md` are content truth.
- Use SQLite with GRDB for rebuildable meeting metadata, FTS, file fingerprints, revision metadata, generation jobs/steps, nonsecret model metadata, schema metadata, and diagnostics.
- Use named transactional migrations, WAL, and a complete index rebuild path that never mutates content files.
- Use stable meeting UUIDs that survive index rebuilds.
- Centralize authoritative-directory access behind a file-store adapter using security-scoped bookmarks and coordinated reads/writes.
- Publish files through a same-directory candidate, flush/sync, coordinated atomic replacement, and read-back confirmation.
- Never leave a partial current `minutes.md`, delete old minutes before replacement, or maintain a hidden duplicate meeting library.
- Give audio capture one actor/owner. Persist audio before offering buffers to Speech; slow transcription cannot block recording writes.
- Model interruptions, route changes, media-service resets, insufficient storage, and termination explicitly.
- Isolate SpeechAnalyzer/SpeechTranscriber behind an adapter. Volatile results are UI-only; final results feed persisted transcript finalization.
- Finalize transcripts through deterministic catch-up, ordering, overlap handling, and deduplication before publishing a transcript version.
- Bind each generation job to a transcript revision/fingerprint, model-profile snapshot, Keychain reference, prompt/schema version, chunk-plan version, and generation number.
- Give each generation step a stable idempotency key derived from job, versions, step kind, chunk index, and input hash.
- Recover only verified checkpoints whose inputs and outputs still match.
- Generate through deterministic chunk planning, serial summaries, synthesis, tolerant normalization, deterministic Mermaid generation, candidate write, source verification, and atomic publication.
- Run only one generation job at a time; queue others. Recording has higher priority and may pause generation at a safe checkpoint.
- Define progress by deterministic work: summaries 70%, synthesis 20%, validation/diagram 5%, publication 5%. Show a stage label, never regress, and publish 100% only after file confirmation.
- Use BGContinuedProcessingTask for user-started generation, shared App/system progress, expiration handling, and cancellation.
- Do not promise immediate restart after force quit. Scan for resumable work when the App can run; always provide continue and regenerate.
- Automatically retry only retryable network, timeout, 408, 429, and selected 5xx errors with jitter and `Retry-After`.
- Pause rather than retry forever for authentication, missing model, oversized request, user cancellation, or persistent invalid output.
- Expose an `AIProvider` domain boundary and ship only an OpenAI-compatible Chat Completions adapter in MVP.
- Implement the adapter with Foundation URLSession and a small tested SSE decoder to retain tolerant decoding, cancellation, background coordination, privacy, and detailed metrics.
- Make connection testing a real minimal model request; HTTP 200 alone is insufficient.
- Allow multiple named model profiles. New jobs use the current profile; resumed jobs keep the original; regeneration may choose another.
- Store API keys only in Keychain with AfterFirstUnlockThisDeviceOnly and no synchronization.
- Publish any nonempty, meaningful, safe minutes body. Normalize recoverable defects locally; missing structure or diagrams shows “information may be incomplete”, not a partial state.
- Reject empty, meaningless, unsafe, or unusable output without replacing current minutes.
- Render a pinned local Mermaid runtime in a locked-down WKWebView with no remote resources or telemetry.
- Mark minutes stale when the transcript changes externally. Require confirmation before replacing externally edited minutes.
- Search title, summary, and transcript locally with date, state, and model filters. Do not use embeddings or network search.
- Use Home, Minutes, and Settings as the only top-level entries. Recording is focused and meeting detail contains summary, diagrams, transcript, and audio.
- Use a small first-party design system over system typography, SF Symbols, semantic colors, Dynamic Type, materials, and accessibility APIs.
- Adopt GRDB. Adopt MarkdownUI only after a real long-document performance Spike. Bundle a pinned Mermaid runtime. Keep SnapshotTesting test-only.
- Collect local correlation IDs, stage durations, retries, request sizes, Provider domain/model/status, URLSession timing, checkpoints, and background events.
- Never record keys, authorization headers, transcript/minutes content, full payloads, or private path names. Retain diagnostics in a bounded local ring for at most 14 days and export only by user action.
- Perform no automatic analytics, advertising, third-party crash upload, or diagnostic upload.
- Target one three-hour meeting, ten meetings/eight recording hours per day, 2,000 historical meetings, and twenty pending jobs.
- Include Action Button. Defer device-side minutes, audio import, and StoreKit without hard-coding barriers to later addition.

## Testing Decisions

- Good tests assert externally observable behavior at the highest stable seam: user command, meeting state, durable checkpoint, published file, search result, or outbound request. Do not assert private method calls, actor scheduling, SQL details, or SwiftUI internals.
- The primary seam is the Application workflow boundary with injected adapters, covering normal flow, interruption, transcript finalization, pending generation, pause/resume, regeneration, external changes, index rebuild, and model-profile changes.
- Preserve the Demo’s proven testing shapes—start/finish workflow tests, controlled adapters, transcript timeline merging, BYOK validation, background catch-up, Mermaid, and authoritative-directory failures—while reimplementing them at the new boundaries.
- Exhaustively test Domain transitions and invariants: one recording, one active generation, no terminal failed meeting, monotonic progress, no 100% before publication, no generation before transcript readiness, and no source deletion after downstream failure.
- Test Application idempotency, queue ordering, model snapshot binding, job generation isolation, transaction boundaries, and recording priority.
- Test generation across zero/one/many/long chunks; restart before/during/after steps; retry classification; cancellation; arbitrary SSE byte boundaries and split UTF-8; tolerant output; invalid graphs; empty output; external changes; continue; and regeneration.
- Test every GRDB migration, WAL concurrency, FTS, database deletion/corruption, 2,000-meeting rebuild, transactional job updates, and bounded diagnostics.
- Inject file failures before/during/after write and replace, low storage, permission loss, unavailable iCloud content, and external edits. No test may lose a valid source or old minutes.
- Verify exact AI destination, HTTPS policy, secret redaction, absence of audio/path data, compatibility variants, error mapping, cancellation, first-byte and size metrics, and no private infinite reconnect.
- Snapshot all important user states across light/dark, accessibility text sizes, reduced motion, narrow/mainstream screens, Chinese, and English.
- Use XCUITest for navigation, recording, model configuration, generation, pause/continue/regenerate, search, playback, transcript seek, and diagnostic export.
- Require physical-device tests for background audio, Speech catch-up, continued processing, Action Button, Keychain lock/reboot, iCloud/Obsidian coordination, and real BYOK.
- TestFlight requires at least two iOS 26 iPhones, including an Action Button device and a different size or hardware generation.
- Recording acceptance includes one three-hour meeting with at least two hours background/locked, a ten-session/eight-hour soak, interruptions, route changes, force-quit recovery, low storage, denied permissions, container inspection, and human audio sampling.
- Transcription acceptance includes three-hour finalization, monotonic nonduplicate final segments, background catch-up, no known speech gaps, cold-start continuation, full Simplified Chinese QA, and core English regression.
- Background generation acceptance uses real 60–180 minute transcripts and covers lock, other-App use, force close at each stage, network loss, 429/5xx, repaired credentials, reboot-before-unlock, recording preemption, twenty queued jobs, and system cancellation.
- App-controlled AI overhead must be under 10% of total generation wall time and under ten seconds for a 60-minute transcript.
- Capture DNS, connection, TLS, request, first byte, response, parsing, persistence, explicit backoff, and suspension separately.
- Target cold home readiness within two seconds, persistent recording within one second of home action/two seconds of Action Button, 2,000-meeting first screen within 300 ms, and search results within 500 ms on the reference device.
- Privacy tests inspect dependencies, network traffic, diagnostic exports, Keychain accessibility, Mermaid isolation, and absence of telemetry.
- Accessibility tests require VoiceOver completion of recording, playback, recovery, and model configuration, plus maximum Dynamic Type, non-color-only state, reduced motion, contrast, and diagram fallback.
- CI runs static checks, Package tests, integration tests, Debug/Release builds, migrations, fixed-runtime UI/snapshots, dependency-boundary checks, license/secret checks, and whitespace validation.
- TestFlight requires zero P0/P1 defects. P0 includes data loss/corruption, secret/content leakage, uncontrolled billing, or erroneous bulk directory mutation. P1 includes unreliable recording/recovery, an unrecoverable ready transcript, unrebuildable history, conflicting Action Button recording, core crashes, or inaccessible transcript/audio.

## Out of Scope

- Reusing, refactoring, or productizing the Demo project structure.
- Apple Foundation Models or another device-side minutes generator.
- Audio/video import, batch import, photo extraction, or share extensions.
- StoreKit, paid unlock, subscriptions, metered billing, or Quillvault-funded inference.
- Anthropic, Gemini, or other non-OpenAI-compatible proprietary protocols.
- Speaker diarization, voiceprints, automatic identity mapping, or “Speaker 1/2”.
- In-App editing of transcript or full minutes content.
- Semantic/vector search, cross-meeting AI Q&A, knowledge graphs, or industry templates.
- Online meeting bots, calendar auto-join, system audio capture, call recording, or meeting-platform integration.
- Accounts, teams, shared spaces, a Quillvault backend, remote orchestration, or server telemetry.
- Siri phrases, Lock Screen widgets, Control Center, Apple Watch, or quick entry beyond Action Button.
- iOS 17–25 support or SFSpeechRecognizer long-audio fallback.
- Automatic multi-device conflict merging or a hidden mirrored content database.
- Full minutes version history.
- A general-purpose UI framework or AI imagery for critical controls/status.

## Further Notes

- The approved domain glossary governs MVP, model profile, recoverable minutes job, transcript revision, pending minutes, generation paused, minutes completed, minutes stale, local search, interrupted meeting, authoritative directory, and local diagnostic bundle.
- Accepted architecture decisions remain in force: iOS 26; Demo as disposable evidence; files as content truth; native SwiftUI modular layering; and GRDB for rebuildable index/task state.
- Device-side minutes, imported audio, and StoreKit remain later v1 milestones. Their MVP exclusion is deliberate sequencing.
- This Spec synthesizes the approved MVP product specification, architecture standard, dependency research, testing/nonfunctional criteria, glossary, ADRs, and Demo evidence.
- This is a multi-session build. After approval, use `to-tickets` to create tracer-bullet implementation tickets with explicit blocking edges, then implement each ticket in a fresh context using TDD and two-axis code review.
