import XCTest
@testable import QuillvaultDemo

@MainActor
final class BYOKConfigurationTests: XCTestCase {
    func testSaveAndReloadKeepsPreferencesAndDoesNotEchoFullAPIKey() async {
        let keyStore = InMemoryAPIKeyStore()
        let preferences = InMemoryBYOKPreferences()
        let tester = ControllableConnectionTester(result: .success("probe ok"))
        let workflow = makeWorkflow(keyStore: keyStore, preferences: preferences, tester: tester)

        workflow.setBYOKBaseURL("https://api.example.com")
        workflow.setBYOKModel("demo-model")
        workflow.setBYOKAPIKeyField("sk-secret-should-not-echo")
        await workflow.saveAndTestBYOK()

        XCTAssertEqual(preferences.baseURL, "https://api.example.com")
        XCTAssertEqual(preferences.model, "demo-model")
        XCTAssertEqual(try keyStore.load(), "sk-secret-should-not-echo")
        XCTAssertEqual(workflow.byokSettings.apiKeyField, "")
        XCTAssertTrue(workflow.byokSettings.hasStoredAPIKey)
        XCTAssertEqual(workflow.byokConnectionTestState, .succeeded("probe ok"))

        let reloaded = makeWorkflow(keyStore: keyStore, preferences: preferences, tester: tester)
        reloaded.reloadBYOKSettings()

        XCTAssertEqual(reloaded.byokSettings.baseURL, "https://api.example.com")
        XCTAssertEqual(reloaded.byokSettings.model, "demo-model")
        XCTAssertEqual(reloaded.byokSettings.apiKeyField, "")
        XCTAssertTrue(reloaded.byokSettings.hasStoredAPIKey)
        XCTAssertFalse(reloaded.byokSettings.apiKeyField.contains("sk-secret"))
    }

    func testConnectionTestSuccessRequiresValidatedStructuredFields() async {
        let tester = ControllableConnectionTester(result: .success("连接测试通过：已返回代表性结构化字段"))
        let workflow = makeWorkflow(tester: tester)

        workflow.setBYOKAPIKeyField("sk-test")
        await workflow.saveAndTestBYOK()

        XCTAssertEqual(
            workflow.byokConnectionTestState,
            .succeeded("连接测试通过：已返回代表性结构化字段")
        )
        let hasCredential = await workflow.dependencies.credentialChecker.hasBYOKCredential()
        XCTAssertTrue(hasCredential)
        XCTAssertEqual(tester.lastRequest?.model, "deepseek-v4-pro")
        XCTAssertEqual(tester.lastRequest?.baseURL, "https://api.deepseek.com")
        XCTAssertTrue(tester.lastRequest?.usesJSONOutput == true)
    }

    func testConnectionTestFailureSurfacesDiagnosticMessage() async {
        let tester = ControllableConnectionTester(
            result: .failure(BYOKConnectionError.authenticationFailed)
        )
        let workflow = makeWorkflow(tester: tester)

        workflow.setBYOKAPIKeyField("sk-bad")
        await workflow.saveAndTestBYOK()

        guard case let .failed(message) = workflow.byokConnectionTestState else {
            return XCTFail("Expected failed connection test")
        }
        XCTAssertTrue(message.contains("认证") || message.contains("API Key"))
    }

    func testNetworkFailureSurfacesDiagnosticMessage() async {
        let tester = ControllableConnectionTester(
            result: .failure(BYOKConnectionError.networkFailure("模拟断网"))
        )
        let workflow = makeWorkflow(tester: tester)
        workflow.setBYOKAPIKeyField("sk-test")
        await workflow.saveAndTestBYOK()

        guard case let .failed(message) = workflow.byokConnectionTestState else {
            return XCTFail("Expected network failure")
        }
        XCTAssertTrue(message.contains("网络"))
    }

    func testConnectionTestFailsWhenStoredKeyMissingAndFieldEmpty() async {
        let workflow = makeWorkflow()
        workflow.reloadBYOKSettings()
        await workflow.saveAndTestBYOK()

        guard case let .failed(message) = workflow.byokConnectionTestState else {
            return XCTFail("Expected missing key failure")
        }
        XCTAssertTrue(message.contains("API Key"))
    }

    func testEmptyAndInvalidProbeResponsesAreRejectedByValidator() throws {
        XCTAssertThrowsError(
            try BYOKProbeValidator.validate(content: "")
        ) { error in
            XCTAssertEqual(error as? BYOKConnectionError, .emptyContent)
        }

        XCTAssertThrowsError(
            try BYOKProbeValidator.validate(content: "{not-json")
        ) { error in
            XCTAssertEqual(error as? BYOKConnectionError, .invalidJSON)
        }

        XCTAssertThrowsError(
            try BYOKProbeValidator.validate(content: #"{"title":"only title"}"#)
        ) { error in
            XCTAssertEqual(error as? BYOKConnectionError, .invalidStructure)
        }

        let ok = try BYOKProbeValidator.validate(
            content: #"{"title":"t","overview":"o","summary":"s"}"#
        )
        XCTAssertEqual(ok.title, "t")
        XCTAssertEqual(ok.overview, "o")
        XCTAssertEqual(ok.summary, "s")
    }

    func testOpenAICompatibleRequestBuilderUsesJSONOutputMode() throws {
        let request = try BYOKConnectionRequestBuilder.makeURLRequest(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-demo"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-demo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "deepseek-v4-pro")
        let responseFormat = json?["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_object")
        XCTAssertNotNil(json?["messages"])
    }

    func testResponseMapperSurfacesAuthModelNetworkAndStructureFailures() throws {
        XCTAssertEqual(
            BYOKHTTPResponseMapper.map(
                data: Data(),
                response: HTTPURLResponse.stub(statusCode: 401)
            ) as? BYOKConnectionError,
            .authenticationFailed
        )
        XCTAssertEqual(
            BYOKHTTPResponseMapper.map(
                data: Data(#"{"error":{"message":"Model Not Exist"}}"#.utf8),
                response: HTTPURLResponse.stub(statusCode: 404)
            ) as? BYOKConnectionError,
            .modelNotFound
        )
        XCTAssertEqual(
            BYOKHTTPResponseMapper.map(
                data: Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8),
                response: HTTPURLResponse.stub(statusCode: 200)
            ) as? BYOKConnectionError,
            .emptyContent
        )
        XCTAssertEqual(
            BYOKHTTPResponseMapper.map(
                data: Data(#"{"choices":[{"message":{"content":"{\"title\":\"t\"}"}}]}"#.utf8),
                response: HTTPURLResponse.stub(statusCode: 200)
            ) as? BYOKConnectionError,
            .invalidStructure
        )

        let content = try BYOKHTTPResponseMapper.content(
            from: Data(
                #"{"choices":[{"message":{"content":"{\"title\":\"t\",\"overview\":\"o\",\"summary\":\"s\"}"}}]}"#
                    .utf8
            ),
            response: HTTPURLResponse.stub(statusCode: 200)
        )
        XCTAssertTrue(content.contains("overview"))
    }

    func testStartSessionStillRequiresStoredCredential() async {
        let keyStore = InMemoryAPIKeyStore()
        let workflow = makeWorkflow(keyStore: keyStore)
        await workflow.startFaceToFaceSession()
        guard case let .failed(message) = workflow.state else {
            return XCTFail("Expected missing credential failure")
        }
        XCTAssertTrue(message.contains("BYOK") || message.contains("API Key") || message.contains("凭据"))
    }

    private func makeWorkflow(
        keyStore: InMemoryAPIKeyStore = InMemoryAPIKeyStore(),
        preferences: InMemoryBYOKPreferences = InMemoryBYOKPreferences(),
        tester: ControllableConnectionTester = ControllableConnectionTester(
            result: .success("连接测试通过：已返回代表性结构化字段")
        )
    ) -> MeetingWorkflow {
        MeetingWorkflow(
            dependencies: MeetingWorkflowDependencies(
                audioRecorder: DemoAudioRecorder(),
                transcriber: DemoTranscriber(),
                minutesGenerator: DemoMinutesGenerator(shouldFail: false),
                credentialChecker: StoreBackedCredentialChecker(store: keyStore),
                directoryAccess: DemoDirectoryAccess(),
                assetWriter: DemoAssetWriter(),
                mermaidGenerator: DeterministicMermaidGenerator(),
                mermaidRenderer: DemoMermaidRenderer(),
                apiKeyStore: keyStore,
                byokPreferences: preferences,
                connectionTester: tester
            )
        )
    }
}

@MainActor
final class ControllableConnectionTester: BYOKConnectionTesting {
    struct CapturedRequest: Equatable {
        let baseURL: String
        let model: String
        let usesJSONOutput: Bool
    }

    private let result: Result<String, Error>
    private(set) var lastRequest: CapturedRequest?

    init(result: Result<String, Error>) {
        self.result = result
    }

    func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String {
        lastRequest = CapturedRequest(
            baseURL: baseURL,
            model: model,
            usesJSONOutput: true
        )
        switch result {
        case let .success(message):
            return message
        case let .failure(error):
            throw error
        }
    }
}

private extension HTTPURLResponse {
    static func stub(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
