import SwiftUI

struct ContentView: View {
    @State private var workflow = MeetingWorkflow(dependencies: .liveSetup)
    @State private var showingBYOKSettings = false

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
        }
    }

    private var demoNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("真机技术闭环 Demo", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.headline)
            Text("抛弃式可行性原型 · BYOK 配置已接入 Keychain / 真实连接测试")
                .font(.subheadline)
            Text("录音、转写、目录与纪要生成仍使用受控替身，不代表这些能力已验证。")
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
            Label("权威目录：仍为受控替身", systemImage: "folder.fill")
            Label("录音、转写与 Mermaid：受控替身", systemImage: "switch.2")

            Button {
                showingBYOKSettings = true
            } label: {
                Label("配置 DeepSeek BYOK", systemImage: "gearshape")
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
            .disabled(!workflow.byokSettings.hasStoredAPIKey)

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

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("正在记录面对面会话", systemImage: "waveform.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text("实时逐字稿")
                .font(.headline)
            ForEach(workflow.liveTranscript) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeRange(for: segment))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(segment.text)
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
            Label("完整假链路已完成", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)

            section("假逐字稿") {
                ForEach(assets.transcript.segments) { segment in
                    Text("\(timeRange(for: segment))  \(segment.text)")
                }
            }

            section("假结构化纪要") {
                Text(assets.minutes.title).font(.headline)
                Text(assets.minutes.overview)
                Text(assets.minutes.summary)
                if let item = assets.minutes.actionItems.first {
                    Label("\(item.owner) · \(item.task) · \(item.deadline)", systemImage: "checklist")
                }
            }

            section("假核心观点图") {
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
                Text(assets.mermaidSource)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
                workflow = MeetingWorkflow(dependencies: .liveSetup)
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
            Text("这是可观察的失败态。受控录音与逐字稿没有被删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("回到 setup") {
                workflow = MeetingWorkflow(dependencies: .liveSetup)
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
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
