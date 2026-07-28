import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var workflow = MeetingWorkflow(dependencies: .liveSetup)
    @State private var showingBYOKSettings = false
    @State private var showingDirectoryImporter = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    demoNotice
                    phaseStrip
                    stateContent
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Quillvault Demo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("BYOK 设置") {
                        workflow.reloadBYOKSettings()
                        showingBYOKSettings = true
                    }
                }
            }
            .sheet(isPresented: $showingBYOKSettings) {
                NavigationStack {
                    BYOKSettingsView(workflow: workflow)
                }
            }
            .fileImporter(
                isPresented: $showingDirectoryImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    Task { await workflow.applySelectedDirectory(url) }
                }
            }
            .task {
                await workflow.reloadAuthoritativeDirectory()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    workflow.handleEnteredBackground()
                case .active:
                    Task { await workflow.handleBecameActive() }
                default:
                    break
                }
            }
        }
    }

    private var demoNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("真机技术闭环 Demo", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.headline)
            Text("抛弃式可行性原型 · 真机技术闭环 Demo")
                .font(.subheadline)
            Text("麦克风单路连续录音优先；转写可从录音追平；BYOK 纪要与离线 Mermaid 已接入。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
    }

    private var phaseStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可观察状态")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MeetingWorkflowPhase.allCases, id: \.self) { phase in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(workflow.phase == phase ? phaseColor(phase) : .secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                            Text("\(phase.rawValue) · \(phase.title)")
                        }
                        .font(.caption.weight(workflow.phase == phase ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            workflow.phase == phase ? phaseColor(phase).opacity(0.13) : .clear,
                            in: Capsule()
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch workflow.state {
        case .setup:
            setupView
        case .recording:
            recordingView
        case .finalizing:
            progressView(title: "正在补齐最终逐字稿…", systemImage: "text.badge.checkmark")
        case .generating:
            progressView(title: "正在生成结构化纪要与核心观点图…", systemImage: "wand.and.stars")
        case let .completed(assets):
            completedView(assets)
        case let .failed(message):
            failedView(message)
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("准备开始")
                .font(.title2.bold())
            Label(
                workflow.byokSettings.hasStoredAPIKey
                    ? "BYOK：Keychain 已有密钥 · \(workflow.byokSettings.model)"
                    : "BYOK：尚未保存 API Key",
                systemImage: "key.fill"
            )
            directoryStatusLabel
            Label("录音 / 转写 / BYOK / Mermaid / 权威目录已接入", systemImage: "waveform")

            Button {
                showingBYOKSettings = true
            } label: {
                Label("配置 DeepSeek BYOK", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                showingDirectoryImporter = true
            } label: {
                Label(
                    workflow.directoryState.isWritable ? "重新选择权威目录" : "选择权威目录",
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await workflow.startFaceToFaceSession() }
            } label: {
                Label("开始面对面会话", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!workflow.byokSettings.hasStoredAPIKey || !workflow.directoryState.isWritable)

            Button("演示 failed 状态（受控替身）") {
                workflow = MeetingWorkflow(dependencies: .failingDemo)
                Task {
                    await workflow.startFaceToFaceSession()
                    await workflow.finishFaceToFaceSession()
                }
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var directoryStatusLabel: some View {
        switch workflow.directoryState {
        case .unset:
            Label("权威目录：尚未选择", systemImage: "folder")
        case let .ready(info):
            VStack(alignment: .leading, spacing: 4) {
                Label("权威目录：\(info.displayName)", systemImage: "folder.fill")
                Text(info.pathDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case let .needsReauthorization(detail):
            VStack(alignment: .leading, spacing: 4) {
                Label("权威目录授权失效，需重新选择", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.red)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("不会回退到 App 沙盒隐藏副本。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("录音中", systemImage: "record.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Spacer()
                Text(durationText(workflow.recordingDuration))
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(.red)
            }
            Text("红色为最终片段 · 灰色斜体为 volatile 临时结果")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(
                    format: "已完成分析至 %.1f 秒%@",
                    workflow.lastCompletedAudioEnd,
                    workflow.analysisPaused ? " · 分析可能已暂停（录音继续）" : ""
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let note = workflow.diagnosticNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("实时逐字稿")
                .font(.headline)
            if workflow.liveTranscript.isEmpty {
                Text("等待语音识别结果…（录音已持续写入 m4a）")
                    .foregroundStyle(.secondary)
            }
            ForEach(workflow.liveTranscript) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(timeRange(for: segment))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(segment.isFinal ? "final" : "volatile")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                segment.isFinal ? Color.red.opacity(0.15) : Color.gray.opacity(0.15),
                                in: Capsule()
                            )
                    }
                    if segment.isFinal {
                        Text(segment.text)
                    } else {
                        Text(segment.text)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            }
            Button {
                Task { await workflow.finishFaceToFaceSession() }
            } label: {
                Label("结束并生成纪要", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .cardStyle()
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func progressView(title: String, systemImage: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.largeTitle)
            ProgressView()
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func completedView(_ assets: MeetingAssets) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("会议链路已完成", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)

            section("逐字稿") {
                ForEach(assets.transcript.segments) { segment in
                    Text("\(timeRange(for: segment))  \(segment.text)")
                }
            }

            section("结构化纪要") {
                Text(assets.minutes.title).font(.headline)
                Text(assets.minutes.overview)
                Text(assets.minutes.summary)
                if let item = assets.minutes.actionItems.first {
                    Label("\(item.owner) · \(item.task) · \(item.deadline)", systemImage: "checklist")
                }
            }

            section("核心观点图（可编辑 · 离线渲染）") {
                VStack(spacing: 10) {
                    ForEach(
                        Array(assets.renderedDiagram.nodeLabels.enumerated()),
                        id: \.offset
                    ) { index, label in
                        if index > 0 {
                            Image(systemName: "arrow.down")
                            Text(assets.renderedDiagram.edgeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(label)
                            .graphNodeStyle()
                    }
                }
                .frame(maxWidth: .infinity)

                TextEditor(text: Binding(
                    get: { workflow.editableMermaidSource },
                    set: { workflow.updateMermaidSource($0) }
                ))
                .font(.caption.monospaced())
                .frame(minHeight: 120)
                .padding(6)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                if let error = workflow.mermaidRenderError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await workflow.rerenderMermaid() }
                } label: {
                    Label("重新渲染 Mermaid", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            section("会议资产模型") {
                ForEach(assets.files) { file in
                    Label {
                        VStack(alignment: .leading) {
                            Text(file.name)
                            Text(file.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "doc.fill")
                    }
                }
            }

            Button("重新演示") {
                resetToLiveSetup()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("链路失败", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text(message)
            Text("录音与逐字稿应已保留；失败不会留下残缺权威 minutes.md。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await workflow.retryGenerateMinutes() }
            } label: {
                Label("重试 BYOK 纪要生成", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("回到 setup") {
                resetToLiveSetup()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func resetToLiveSetup() {
        workflow = MeetingWorkflow(dependencies: .liveSetup)
        Task { await workflow.reloadAuthoritativeDirectory() }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseColor(_ phase: MeetingWorkflowPhase) -> Color {
        phase == .failed ? .red : .blue
    }

    private func timeRange(for segment: TranscriptSegment) -> String {
        String(format: "%04.1f–%04.1f 秒", segment.startTime, segment.endTime)
    }
}

struct BYOKSettingsView: View {
    @Bindable var workflow: MeetingWorkflow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("验收目标预填 DeepSeek。API Key 仅写入 Keychain；保存后界面不回显完整密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("服务配置") {
                TextField("Base URL", text: baseURLBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Model", text: modelBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(apiKeyPlaceholder, text: apiKeyBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("连接测试") {
                Button {
                    Task { await workflow.saveAndTestBYOK() }
                } label: {
                    if case .testing = workflow.byokConnectionTestState {
                        HStack {
                            ProgressView()
                            Text("保存并测试中…")
                        }
                    } else {
                        Label("保存并测试", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled({
                    if case .testing = workflow.byokConnectionTestState { return true }
                    return false
                }())

                switch workflow.byokConnectionTestState {
                case .idle:
                    Text("将发起真实 Chat Completions 请求，并用 JSON Output 校验 title / overview / summary。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .testing:
                    Text("正在请求模型…")
                        .font(.caption)
                case let .succeeded(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case let .failed(message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("BYOK 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .onAppear {
            workflow.reloadBYOKSettings()
        }
    }

    private var apiKeyPlaceholder: String {
        workflow.byokSettings.hasStoredAPIKey ? "已保存（输入新密钥可覆盖）" : "API Key"
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { workflow.byokSettings.baseURL },
            set: { workflow.setBYOKBaseURL($0) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { workflow.byokSettings.model },
            set: { workflow.setBYOKModel($0) }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { workflow.byokSettings.apiKeyField },
            set: { workflow.setBYOKAPIKeyField($0) }
        )
    }
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    func graphNodeStyle() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.blue.opacity(0.5))
            }
    }
}
