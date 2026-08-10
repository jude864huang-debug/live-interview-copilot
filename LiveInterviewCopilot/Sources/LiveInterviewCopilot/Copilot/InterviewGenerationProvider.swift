import Foundation

struct InterviewGenerationMetadata: Sendable {
    let transport: String?
    let firstDeltaMilliseconds: Int?
    let prewarmReady: Bool?
    let prewarmDurationMilliseconds: Int?
}

protocol InterviewGenerationProvider: Actor {
    func generateProgressiveAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewProgressiveAnswer
    func generateProgressiveAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer
    func generateCue(_ request: InterviewGenerationRequest, credential: String?) async throws -> InterviewCue
    func generateCueStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewCueProgress) -> Void
    ) async throws -> InterviewCue
    func generateReferenceAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewReferenceAnswer
    func generateReferenceAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable ([InterviewReferenceAnswerSegment]) -> Void
    ) async throws -> InterviewReferenceAnswer
    func generateFollowUps(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpSet
    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer
    func cancel(id: UUID) async
    func takeGenerationMetadata(for id: UUID) async -> InterviewGenerationMetadata?
}

extension InterviewGenerationProvider {
    /// Compatibility shim for the original cue-only provider API.
    func generate(_ request: InterviewGenerationRequest, credential: String?) async throws -> InterviewCue {
        try await generateCue(request, credential: credential)
    }

    func generateCueStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewCueProgress) -> Void
    ) async throws -> InterviewCue {
        let cue = try await generateCue(request, credential: credential)
        onProgress(InterviewCueProgress(
            directOpening: cue.directOpening,
            talkingPoints: cue.talkingPoints
        ))
        return cue
    }

    func takeGenerationMetadata(for id: UUID) async -> InterviewGenerationMetadata? { nil }

    func generateProgressiveAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewProgressiveAnswer {
        throw CopilotError.invalidResponse
    }

    func generateProgressiveAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer {
        let answer = try await generateProgressiveAnswer(request, credential: credential)
        onProgress(InterviewAnswerProgress(
            entry: answer.entry,
            spine: answer.spine,
            segments: answer.segments,
            closing: answer.closing,
            metadata: answer.metadata,
            isSpineComplete: true
        ))
        return answer
    }

    func generateReferenceAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable ([InterviewReferenceAnswerSegment]) -> Void
    ) async throws -> InterviewReferenceAnswer {
        let answer = try await generateReferenceAnswer(request, credential: credential)
        onProgress(answer.segments)
        return answer
    }

    func generateFollowUps(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpSet {
        throw CopilotError.invalidResponse
    }

    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer {
        throw CopilotError.invalidResponse
    }
}

actor OpenAIResponsesProvider: InterviewGenerationProvider {
    /// Third-party Responses implementations frequently accept `json_object`
    /// but do not reliably finish a large nested object. Keep their contract
    /// small: establish the answer skeleton first, then fill each point.
    private struct CompatibilityAnswerSkeleton: Codable, Sendable {
        var entry: InterviewAnswerEntry
        var spine: [InterviewAnswerSpinePoint]
        var metadata: InterviewAnswerMetadata
    }

    private struct CompatibilityAnswerSegment: Codable, Sendable {
        var text: String
        var claimType: InterviewAnswerClaimType
        var sourceIDs: [String]
    }

    private let session: URLSession
    private var generationMetadata: [UUID: InterviewGenerationMetadata] = [:]
    private var cueTasks: [UUID: Task<InterviewCue, Error>] = [:]
    private var referenceAnswerTasks: [UUID: Task<InterviewReferenceAnswer, Error>] = [:]
    private var followUpTasks: [UUID: Task<InterviewFollowUpSet, Error>] = [:]
    private var followUpAnswerTasks: [UUID: Task<InterviewFollowUpAnswer, Error>] = [:]
    private var progressiveAnswerTasks: [UUID: Task<InterviewProgressiveAnswer, Error>] = [:]

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func generateProgressiveAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewProgressiveAnswer {
        try await generateProgressiveAnswerStreaming(request, credential: credential) { _ in }
    }

    func generateProgressiveAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        let task = Task {
            if Self.usesSegmentedCompatibilityAnswer(for: request) {
                return try await self.generateSegmentedCompatibilityAnswer(
                    request,
                    apiKey: credential,
                    onProgress: onProgress
                )
            }
            let rawAnswer = try await perform(
                request,
                apiKey: credential,
                schemaName: "interview_progressive_answer",
                schema: Self.makeProgressiveAnswerOutputSchema(),
                orderedSchemaJSON: Self.progressiveAnswerOutputSchemaJSON,
                responseType: InterviewProgressiveAnswer.self,
                onTextProgress: { text in
                    let progress = Self.answerProgress(in: text)
                    if progress.hasUsefulContent { onProgress(progress) }
                }
            )
            guard let answer = Self.normalizedProgressiveAnswerShape(rawAnswer) else {
                Log.suggestionEngine.error(
                    "Progressive answer shape rejected provider=responses-api spine=\(rawAnswer.spine.count) segments=\(rawAnswer.segments.count)"
                )
                throw CopilotError.invalidResponse
            }
            return answer
        }
        progressiveAnswerTasks[request.id] = task
        defer { progressiveAnswerTasks.removeValue(forKey: request.id) }
        return try await task.value
    }

    private static func usesSegmentedCompatibilityAnswer(
        for request: InterviewGenerationRequest
    ) -> Bool {
        request.apiProtocol == .responses
            && !request.apiBaseURL.lowercased().contains("openai.com")
    }

    private func generateSegmentedCompatibilityAnswer(
        _ request: InterviewGenerationRequest,
        apiKey: String,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer {
        let rawSkeleton = try await perform(
            request,
            apiKey: apiKey,
            schemaName: "interview_progressive_skeleton",
            schema: Self.makeCompatibilityAnswerSkeletonSchema(),
            responseType: CompatibilityAnswerSkeleton.self
        )
        guard let skeleton = Self.normalizedCompatibilityAnswerSkeleton(rawSkeleton) else {
            Log.suggestionEngine.error(
                "Compatibility answer skeleton rejected spine=\(rawSkeleton.spine.count)"
            )
            throw CopilotError.invalidResponse
        }

        onProgress(InterviewAnswerProgress(
            entry: skeleton.entry,
            spine: skeleton.spine,
            segments: [],
            closing: nil,
            metadata: skeleton.metadata,
            isSpineComplete: true
        ))

        var completed = Array<InterviewAnswerSegment?>(repeating: nil, count: skeleton.spine.count)
        try await withThrowingTaskGroup(of: (Int, InterviewAnswerSegment).self) { group in
            for (index, point) in skeleton.spine.enumerated() {
                group.addTask { [self] in
                    do {
                        let segment = try await self.generateCompatibilitySegment(
                            request,
                            apiKey: apiKey,
                            skeleton: skeleton,
                            point: point
                        )
                        return (index, segment)
                    } catch let error as CopilotError where error == .cancelled {
                        // The provider maps transport cancellation to CopilotError.cancelled.
                        // Preserve it so an explicit stop cancels the whole segmented answer
                        // instead of being converted into a synthetic fallback segment.
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.suggestionEngine.error(
                            "Compatibility answer segment fallback point=\(point.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        return (index, Self.compatibilitySegmentFallback(for: point))
                    }
                }
            }

            for try await (index, segment) in group {
                completed[index] = segment
                let contiguousSegments = completed.prefix { $0 != nil }.compactMap { $0 }
                onProgress(InterviewAnswerProgress(
                    entry: skeleton.entry,
                    spine: skeleton.spine,
                    segments: contiguousSegments,
                    closing: nil,
                    metadata: skeleton.metadata,
                    isSpineComplete: true
                ))
            }
        }

        let answer = InterviewProgressiveAnswer(
            entry: skeleton.entry,
            spine: skeleton.spine,
            segments: completed.compactMap { $0 },
            closing: nil,
            metadata: skeleton.metadata
        )
        guard let normalized = Self.normalizedProgressiveAnswerShape(answer) else {
            throw CopilotError.invalidResponse
        }
        return normalized
    }

    private func generateCompatibilitySegment(
        _ request: InterviewGenerationRequest,
        apiKey: String,
        skeleton: CompatibilityAnswerSkeleton,
        point: InterviewAnswerSpinePoint
    ) async throws -> InterviewAnswerSegment {
        let prompt = Self.compatibilitySegmentPrompt(
            basePrompt: request.prompt,
            skeleton: skeleton,
            point: point
        )
        let segmentRequest = InterviewGenerationRequest(
            id: UUID(),
            model: request.model,
            prompt: prompt,
            promptCacheKey: "\(request.promptCacheKey):\(point.id)",
            maxOutputTokens: min(max(1_200, request.maxOutputTokens / max(skeleton.spine.count, 2)), 4_000),
            kind: request.kind,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort,
            apiProtocol: request.apiProtocol,
            apiBaseURL: request.apiBaseURL
        )
        let rawSegment = try await perform(
            segmentRequest,
            apiKey: apiKey,
            schemaName: "interview_progressive_segment",
            schema: Self.makeCompatibilityAnswerSegmentSchema(),
            responseType: CompatibilityAnswerSegment.self
        )
        let text = rawSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CopilotError.invalidResponse }
        return InterviewAnswerSegment(
            pointID: point.id,
            text: text,
            claimType: rawSegment.claimType,
            sourceIDs: rawSegment.sourceIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func compatibilitySegmentFallback(
        for point: InterviewAnswerSpinePoint
    ) -> InterviewAnswerSegment {
        InterviewAnswerSegment(
            pointID: point.id,
            text: "请围绕“\(point.label)”说明你的判断依据、具体动作和验证方式。",
            claimType: .professionalJudgment,
            sourceIDs: []
        )
    }

    func generateCue(_ request: InterviewGenerationRequest, credential: String?) async throws -> InterviewCue {
        try await generateCueStreaming(request, credential: credential) { _ in }
    }

    func generateCueStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewCueProgress) -> Void
    ) async throws -> InterviewCue {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        let task = Task {
            try await perform(
                request,
                apiKey: credential,
                schemaName: "interview_cue",
                schema: Self.makeCueOutputSchema(),
                responseType: InterviewCue.self,
                onTextProgress: { text in
                    let progress = Self.cueProgress(in: text)
                    if progress.hasVisibleContent { onProgress(progress) }
                }
            )
        }
        cueTasks[request.id] = task
        defer { cueTasks.removeValue(forKey: request.id) }
        return try await task.value
    }

    func generateReferenceAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewReferenceAnswer {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        return try await generateReferenceAnswerStreaming(request, credential: credential) { _ in }
    }

    func generateReferenceAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable ([InterviewReferenceAnswerSegment]) -> Void
    ) async throws -> InterviewReferenceAnswer {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        let task = Task {
            let answer = try await perform(
                request,
                apiKey: credential,
                schemaName: "interview_reference_answer",
                schema: Self.makeReferenceAnswerOutputSchema(),
                responseType: InterviewReferenceAnswer.self,
                onTextProgress: { text in
                    let segments = Self.referenceSegmentsProgress(in: text)
                    if !segments.isEmpty { onProgress(segments) }
                }
            )
            guard Self.hasValidReferenceAnswerShape(answer) else {
                throw CopilotError.invalidResponse
            }
            return answer
        }
        referenceAnswerTasks[request.id] = task
        defer { referenceAnswerTasks.removeValue(forKey: request.id) }
        return try await task.value
    }

    func generateFollowUps(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpSet {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        let task = Task {
            let value = try await perform(
                request,
                apiKey: credential,
                schemaName: "interview_follow_ups",
                schema: Self.makeFollowUpsOutputSchema(),
                responseType: InterviewFollowUpSet.self
            )
            guard Self.hasValidFollowUpsShape(value) else { throw CopilotError.invalidResponse }
            return value
        }
        followUpTasks[request.id] = task
        defer { followUpTasks.removeValue(forKey: request.id) }
        return try await task.value
    }

    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer {
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            throw CopilotError.missingAPIKey
        }
        let task = Task {
            let value = try await perform(
                request,
                apiKey: credential,
                schemaName: "interview_follow_up_answer",
                schema: Self.makeFollowUpAnswerOutputSchema(),
                responseType: InterviewFollowUpAnswer.self
            )
            guard Self.hasValidFollowUpAnswerShape(value) else {
                throw CopilotError.invalidResponse
            }
            return value
        }
        followUpAnswerTasks[request.id] = task
        defer { followUpAnswerTasks.removeValue(forKey: request.id) }
        return try await task.value
    }

    func cancel(id: UUID) {
        progressiveAnswerTasks.removeValue(forKey: id)?.cancel()
        cueTasks.removeValue(forKey: id)?.cancel()
        referenceAnswerTasks.removeValue(forKey: id)?.cancel()
        followUpTasks.removeValue(forKey: id)?.cancel()
        followUpAnswerTasks.removeValue(forKey: id)?.cancel()
    }

    func takeGenerationMetadata(for id: UUID) -> InterviewGenerationMetadata? {
        generationMetadata.removeValue(forKey: id)
    }

    private func perform<Response: Decodable & Sendable>(
        _ request: InterviewGenerationRequest,
        apiKey: String,
        schemaName: String,
        schema: [String: Any],
        orderedSchemaJSON: String? = nil,
        responseType: Response.Type,
        onTextProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Response {
        if request.apiProtocol == .chatCompletion {
            return try await performChatCompletions(
                request,
                apiKey: apiKey,
                responseType: responseType,
                onTextProgress: onTextProgress
            )
        }
        guard let url = OpenRouterClient.responsesURL(from: request.apiBaseURL) else {
            throw CopilotError.invalidRequest("Responses Base URL 无效")
        }
        let isOpenAIEndpoint = request.apiBaseURL.lowercased().contains("openai.com")
        let bodyData: Data
        if isOpenAIEndpoint {
            bodyData = try Self.makeResponsesRequestBodyData(
                request: request,
                schemaName: schemaName,
                schema: schema,
                orderedSchemaJSON: orderedSchemaJSON
            )
        } else {
            // DeepSeek's json_schema support is unreliable for the large
            // interview schemas (it can echo the schema or return 400), while
            // json_object reliably produces valid JSON. Embed the schema in
            // the prompt so the model still returns the exact contract.
            let schemaPrompt = request.prompt
                + "\n\n<OUTPUT_SCHEMA>\n"
                + Self.schemaJSON(schema: schema, orderedSchemaJSON: orderedSchemaJSON)
                + "\n</OUTPUT_SCHEMA>"
            bodyData = try Self.makeResponsesRequestBodyData(
                request: request,
                schemaName: schemaName,
                schema: schema,
                orderedSchemaJSON: nil,
                compatibilityMode: true,
                promptOverride: schemaPrompt,
                formatType: "json_object"
            )
        }
        do {
            return try await performResponsesRequest(
                request: request,
                apiKey: apiKey,
                url: url,
                bodyData: bodyData,
                responseType: responseType,
                onTextProgress: onTextProgress
            )
        } catch let error as CopilotError {
            throw error
        }
    }

    private static func schemaJSON(
        schema: [String: Any],
        orderedSchemaJSON: String?
    ) -> String {
        if let orderedSchemaJSON { return orderedSchemaJSON }
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func performResponsesRequest<Response: Decodable & Sendable>(
        request: InterviewGenerationRequest,
        apiKey: String,
        url: URL,
        bodyData: Data,
        responseType: Response.Type,
        onTextProgress: (@Sendable (String) -> Void)?
    ) async throws -> Response {
        let startedAt = Date()
        var firstDeltaMilliseconds: Int?
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = bodyData

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw CopilotError.network("OpenAI API 返回了未知响应。")
            }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw CopilotError.authenticationFailed
            case 429: throw CopilotError.rateLimited
            case 500...599: throw CopilotError.serverUnavailable(http.statusCode)
            default:
                var detail = ""
                for try await line in bytes.lines {
                    detail += line
                    if detail.utf8.count > 2_000 { break }
                }
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = trimmed.isEmpty
                    ? "HTTP \(http.statusCode)，请检查模型名、上下文上限和 Structured Outputs 支持。"
                    : "HTTP \(http.statusCode)：\(trimmed)"
                throw CopilotError.invalidRequest(message)
            }

            var output = ""
            var incompleteReason: String?
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard payload != "[DONE]", let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                if type == "response.output_text.delta", let delta = object["delta"] as? String {
                    if firstDeltaMilliseconds == nil {
                        firstDeltaMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    }
                    output += delta
                    onTextProgress?(output)
                } else if type == "response.failed" {
                    let responseObject = object["response"] as? [String: Any]
                    let errorObject = responseObject?["error"] as? [String: Any]
                    let message = errorObject?["message"] as? String
                        ?? responseObject?["error_description"] as? String
                        ?? "Responses API 请求失败。"
                    throw CopilotError.network(message)
                } else if type == "response.incomplete" {
                    let responseObject = object["response"] as? [String: Any]
                    let details = responseObject?["incomplete_details"] as? [String: Any]
                    incompleteReason = details?["reason"] as? String ?? "unknown"
                } else if type == "error" {
                    let message = (object["message"] as? String) ?? "OpenAI streaming error"
                    throw CopilotError.network(message)
                }
            }
            generationMetadata[request.id] = InterviewGenerationMetadata(
                transport: "responses-api",
                firstDeltaMilliseconds: firstDeltaMilliseconds,
                prewarmReady: nil,
                prewarmDurationMilliseconds: nil
            )
            guard let data = output.data(using: .utf8),
                  let result = try? JSONDecoder().decode(responseType, from: data) else {
                Log.suggestionEngine.error(
                    "Structured response decode failed schema=\(request.kind.rawValue, privacy: .public) chars=\(output.utf8.count) shape=\(Self.responseShapeSummary(output), privacy: .public) incomplete=\(incompleteReason ?? "none", privacy: .public)"
                )
                throw CopilotError.invalidResponse
            }
            return result
        } catch is CancellationError {
            throw CopilotError.cancelled
        } catch let error as CopilotError {
            throw error
        } catch {
            throw CopilotError.network(error.localizedDescription)
        }
    }

    private func performChatCompletions<Response: Decodable & Sendable>(
        _ request: InterviewGenerationRequest,
        apiKey: String,
        responseType: Response.Type,
        onTextProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Response {
        guard let url = OpenRouterClient.chatCompletionsURL(from: request.apiBaseURL) else {
            throw CopilotError.invalidRequest("DeepSeek Base URL 无效")
        }

        let startedAt = Date()
        var firstDeltaMilliseconds: Int?
        var output = ""
        var body: [String: Any] = [
            "model": request.model,
            "messages": [["role": "user", "content": request.prompt]],
            "stream": true,
            "max_tokens": request.maxOutputTokens,
        ]
        // deepseek-reasoner does not accept response_format; JSON mode is
        // supported by deepseek-chat and the newer hybrid chat models.
        if !request.model.lowercased().contains("reasoner") {
            body["response_format"] = ["type": "json_object"]
        }
        // DeepSeek rejects reasoning_effort; OpenAI and most compatible
        // providers accept it. The model-specific picker keeps this optional.
        if !request.apiBaseURL.lowercased().contains("deepseek.com"),
           request.model.lowercased() != "deepseek-chat" {
            body["reasoning_effort"] = request.reasoningEffort.chatCompletionValue
        }
        if request.fastServiceTier,
           !request.apiBaseURL.lowercased().contains("deepseek.com") {
            body["service_tier"] = "priority"
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw CopilotError.network("DeepSeek API 返回了未知响应。")
            }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw CopilotError.authenticationFailed
            case 429: throw CopilotError.rateLimited
            case 500...599: throw CopilotError.serverUnavailable(http.statusCode)
            default: throw CopilotError.invalidRequest("HTTP \(http.statusCode)，请检查模型名和 DeepSeek 配额。")
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                guard payload != "[DONE]" else { break }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let apiError = object["error"] as? [String: Any] {
                    let message = apiError["message"] as? String ?? "DeepSeek streaming error"
                    throw CopilotError.network(message)
                }
                guard let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String,
                      !content.isEmpty else { continue }
                if firstDeltaMilliseconds == nil {
                    firstDeltaMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                }
                output += content
                onTextProgress?(output)
            }
            generationMetadata[request.id] = InterviewGenerationMetadata(
                transport: "deepseek-api",
                firstDeltaMilliseconds: firstDeltaMilliseconds,
                prewarmReady: nil,
                prewarmDurationMilliseconds: nil
            )
            guard let result = Self.decodeJSONResponse(output, as: responseType) else {
                Log.suggestionEngine.error(
                    "Structured response decode failed schema=deepseek chars=\(output.utf8.count)"
                )
                throw CopilotError.invalidResponse
            }
            return result
        } catch is CancellationError {
            throw CopilotError.cancelled
        } catch let error as CopilotError {
            throw error
        } catch {
            throw CopilotError.network(error.localizedDescription)
        }
    }

    private static func responseShapeSummary(_ output: String) -> String {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "unparseable"
        }
        let spine = object["spine"] as? [[String: Any]] ?? []
        let segments = object["segments"] as? [[String: Any]] ?? []
        let spineIDs = spine.compactMap { $0["id"] as? String }
        let segmentIDs = segments.compactMap { $0["pointID"] as? String }
        let entry = object["entry"] as? [String: Any]
        let metadata = object["metadata"] as? [String: Any]
        return "keys=\(object.keys.sorted().joined(separator: ",")) spine=\(spine.count):\(spineIDs.joined(separator: ",")) segments=\(segments.count):\(segmentIDs.joined(separator: ",")) entry=\(entry != nil) metadata=\(metadata != nil)"
    }

    private static func decodeJSONResponse<Response: Decodable>(
        _ output: String,
        as type: Response.Type
    ) -> Response? {
        var candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2, lines.first?.hasPrefix("```") == true,
               lines.last?.hasPrefix("```") == true {
                candidate = lines.dropFirst().dropLast().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// JSON objects are unordered by specification, and Foundation may emit a
    /// Swift dictionary in a different key order on every process. Structured
    /// Outputs follows the schema's serialized property order while generating,
    /// so the progressive schema is inserted as already-ordered JSON.
    static func makeResponsesRequestBodyData(
        request: InterviewGenerationRequest,
        schemaName: String,
        schema: [String: Any],
        orderedSchemaJSON: String? = nil,
        compatibilityMode: Bool = false,
        promptOverride: String? = nil,
        formatType: String = "json_schema"
    ) throws -> Data {
        let placeholder = "__liveinterviewcopilot_ordered_schema_\(UUID().uuidString)__"
        let schemaValue: Any = orderedSchemaJSON == nil ? schema as Any : placeholder as Any
        var textFormat: [String: Any] = ["type": formatType]
        if formatType == "json_schema" {
            textFormat["name"] = schemaName
            textFormat["strict"] = !compatibilityMode
            textFormat["schema"] = schemaValue
        }
        var body: [String: Any] = [
            "model": request.model,
            "input": promptOverride ?? request.prompt,
            "reasoning": ["effort": request.reasoningEffort.rawValue],
            "max_output_tokens": request.maxOutputTokens,
            "stream": true,
            "text": ["format": textFormat],
        ]
        if !compatibilityMode {
            body["store"] = false
            body["prompt_cache_key"] = request.promptCacheKey
        }
        if request.fastServiceTier, !compatibilityMode {
            body["service_tier"] = "priority"
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        guard let orderedSchemaJSON else { return encoded }

        let orderedSchemaData = Data(orderedSchemaJSON.utf8)
        _ = try JSONSerialization.jsonObject(with: orderedSchemaData)
        guard var bodyText = String(data: encoded, encoding: .utf8),
              let encodedPlaceholder = String(
                data: try JSONEncoder().encode(placeholder),
                encoding: .utf8
              ),
              let placeholderRange = bodyText.range(of: encodedPlaceholder) else {
            throw CopilotError.invalidRequest("无法构造有序的渐进回答 Schema。")
        }
        bodyText.replaceSubrange(placeholderRange, with: orderedSchemaJSON)
        return Data(bodyText.utf8)
    }

    static func makeCueOutputSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "questionSummary", "questionType", "isFollowUp", "directOpening", "framework",
            "talkingPoints", "evidenceAnchors", "missingFacts", "clarifyingQuestion",
            "likelyFollowUps", "confidence",
        ],
        "properties": [
            "questionSummary": ["type": "string"],
            "questionType": [
                "type": "string",
                "enum": InterviewQuestionType.allCases.map(\.rawValue),
            ],
            "isFollowUp": ["type": "boolean"],
            "directOpening": ["type": "string"],
            "framework": ["type": "string"],
            "talkingPoints": ["type": "array", "items": ["type": "string"]],
            "evidenceAnchors": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["cue", "sourceIDs"],
                    "properties": [
                        "cue": ["type": "string"],
                        "sourceIDs": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
            "missingFacts": ["type": "array", "items": ["type": "string"]],
            "clarifyingQuestion": ["type": ["string", "null"]],
            "likelyFollowUps": ["type": "array", "items": ["type": "string"]],
            "confidence": ["type": "string", "enum": ["high", "medium", "low", "unknown"]],
        ],
    ] }

    /// This raw schema is the source of truth for the progressive answer. Its
    /// property order is intentional because the Responses API generates keys
    /// in that order: opening, all titles, ordered detail, closing, metadata.
    static var progressiveAnswerOutputSchemaJSON: String {
        func jsonArray(_ values: [String]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: values)
            return String(decoding: data, as: UTF8.self)
        }

        let entryModes = jsonArray(InterviewAnswerEntryMode.allCases.map(\.rawValue))
        let spineRoles = jsonArray(InterviewAnswerSpineRole.allCases.map(\.rawValue))
        let claimTypes = jsonArray(InterviewAnswerClaimType.allCases.map(\.rawValue))
        let questionTypes = jsonArray(InterviewQuestionType.allCases.map(\.rawValue))
        let answerModes = jsonArray(InterviewAnswerMode.allCases.map(\.rawValue))
        let claimType = "{\"type\":\"string\",\"enum\":\(claimTypes)}"
        let sourceIDs = "{\"type\":\"array\",\"maxItems\":4,\"items\":{\"type\":\"string\"}}"

        return """
        {"type":"object","additionalProperties":false,"required":["entry","spine","segments","closing","metadata"],"properties":{
          "entry":{"type":"object","additionalProperties":false,"required":["mode","text","assumption","claimType","sourceIDs"],"properties":{
            "mode":{"type":"string","enum":\(entryModes)},"text":{"type":"string"},"assumption":{"type":["string","null"]},"claimType":\(claimType),"sourceIDs":\(sourceIDs)
          }},
          "spine":{"type":"array","minItems":2,"maxItems":4,"items":{"type":"object","additionalProperties":false,"required":["id","label","role","claimType","sourceIDs"],"properties":{
            "id":{"type":"string"},"label":{"type":"string"},"role":{"type":"string","enum":\(spineRoles)},"claimType":\(claimType),"sourceIDs":\(sourceIDs)
          }}},
          "segments":{"type":"array","minItems":2,"maxItems":4,"items":{"type":"object","additionalProperties":false,"required":["pointID","text","claimType","sourceIDs"],"properties":{
            "pointID":{"type":"string"},"text":{"type":"string"},"claimType":\(claimType),"sourceIDs":\(sourceIDs)
          }}},
          "closing":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["text","claimType","sourceIDs"],"properties":{
            "text":{"type":"string"},"claimType":\(claimType),"sourceIDs":\(sourceIDs)
          }}]},
          "metadata":{"type":"object","additionalProperties":false,"required":["questionType","answerMode","concreteGaps"],"properties":{
            "questionType":{"type":"string","enum":\(questionTypes)},"answerMode":{"type":"string","enum":\(answerModes)},"concreteGaps":{"type":"array","maxItems":3,"items":{"type":"string"}}
          }}
        }}
        """
    }

    static func makeProgressiveAnswerOutputSchema() -> [String: Any] {
        let data = Data(progressiveAnswerOutputSchemaJSON.utf8)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func makeCompatibilityAnswerSkeletonSchema() -> [String: Any] {
        let fullSchema = makeProgressiveAnswerOutputSchema()
        let properties = fullSchema["properties"] as! [String: Any]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["entry", "spine", "metadata"],
            "properties": [
                "entry": properties["entry"]!,
                "spine": properties["spine"]!,
                "metadata": properties["metadata"]!,
            ],
        ]
    }

    static func makeCompatibilityAnswerSegmentSchema() -> [String: Any] {
        let claimTypes = InterviewAnswerClaimType.allCases.map(\.rawValue)
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["text", "claimType", "sourceIDs"],
            "properties": [
                "text": ["type": "string"],
                "claimType": ["type": "string", "enum": claimTypes],
                "sourceIDs": [
                    "type": "array",
                    "maxItems": 4,
                    "items": ["type": "string"],
                ],
            ],
        ]
    }

    private static func normalizedCompatibilityAnswerSkeleton(
        _ raw: CompatibilityAnswerSkeleton
    ) -> CompatibilityAnswerSkeleton? {
        guard (2...4).contains(raw.spine.count) else { return nil }
        let trim: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var skeleton = raw
        skeleton.entry.text = trim(skeleton.entry.text)
        skeleton.entry.assumption = skeleton.entry.assumption.flatMap {
            let value = trim($0)
            return value.isEmpty ? nil : value
        }
        skeleton.entry.sourceIDs = skeleton.entry.sourceIDs.map(trim).filter { !$0.isEmpty }
        for index in skeleton.spine.indices {
            skeleton.spine[index].id = "p\(index + 1)"
            skeleton.spine[index].label = trim(skeleton.spine[index].label)
            skeleton.spine[index].cue = skeleton.spine[index].cue.flatMap {
                let value = trim($0)
                return value.isEmpty ? nil : value
            }
            skeleton.spine[index].sourceIDs = skeleton.spine[index].sourceIDs
                .map(trim)
                .filter { !$0.isEmpty }
        }
        skeleton.metadata.concreteGaps = Array(
            skeleton.metadata.concreteGaps.map(trim).filter { !$0.isEmpty }.prefix(3)
        )
        guard !skeleton.entry.text.isEmpty,
              skeleton.spine.allSatisfy({ !$0.label.isEmpty }) else {
            return nil
        }
        return skeleton
    }

    private static func compatibilitySegmentPrompt(
        basePrompt: String,
        skeleton: CompatibilityAnswerSkeleton,
        point: InterviewAnswerSpinePoint
    ) -> String {
        let encoder = JSONEncoder()
        let skeletonJSON = (try? encoder.encode(skeleton)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        let pointJSON = (try? encoder.encode(point)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
        return """
        \(basePrompt)

        <STABLE_ANSWER_SKELETON>
        \(skeletonJSON)
        </STABLE_ANSWER_SKELETON>
        <CURRENT_SPINE_POINT>
        \(pointJSON)
        </CURRENT_SPINE_POINT>
        <SEGMENT_TASK>
        Only write the speakable detail for CURRENT_SPINE_POINT. Return exactly one JSON object matching OUTPUT_SCHEMA. Do not repeat the opening, other points, closing, or metadata. Do not invent candidate facts; use professional judgment or an explicit assumption when evidence is unavailable.
        </SEGMENT_TASK>
        """
    }

    static func hasValidProgressiveAnswerShape(_ answer: InterviewProgressiveAnswer) -> Bool {
        guard (2...4).contains(answer.spine.count), answer.segments.count == answer.spine.count else {
            return false
        }
        let ids = answer.spine.map(\.id)
        return Set(ids).count == ids.count
            && answer.segments.map(\.pointID) == ids
            && !answer.entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && answer.spine.allSatisfy {
                !$0.id.isEmpty && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            && answer.segments.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Normalizes internal linkage keys and harmless surrounding whitespace.
    /// Point IDs are never user-visible; canonicalizing them by semantic order
    /// prevents `p1` / `p1 ` drift from discarding otherwise valid content.
    static func normalizedProgressiveAnswerShape(
        _ raw: InterviewProgressiveAnswer
    ) -> InterviewProgressiveAnswer? {
        guard (2...4).contains(raw.spine.count), raw.segments.count == raw.spine.count else {
            return nil
        }

        let trim: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rawSpineIDs = raw.spine.map { trim($0.id) }
        let rawSegmentIDs = raw.segments.map { trim($0.pointID) }
        let canPairByID = rawSpineIDs.allSatisfy { !$0.isEmpty }
            && rawSegmentIDs.allSatisfy { !$0.isEmpty }
            && Set(rawSpineIDs).count == rawSpineIDs.count
            && Set(rawSegmentIDs).count == rawSegmentIDs.count
            && Set(rawSpineIDs) == Set(rawSegmentIDs)
        let canPairEmptyIDsByPosition = rawSpineIDs.allSatisfy(\.isEmpty)
            && rawSegmentIDs.allSatisfy(\.isEmpty)
        let pairedSegments: [InterviewAnswerSegment]
        if canPairByID {
            let segmentByID = Dictionary(
                uniqueKeysWithValues: zip(rawSegmentIDs, raw.segments)
            )
            pairedSegments = rawSpineIDs.compactMap { segmentByID[$0] }
        } else if canPairEmptyIDsByPosition {
            // When both sides omit linkage IDs, the schema-mandated array order
            // is the only available mapping. Assign deterministic IDs below.
            pairedSegments = raw.segments
        } else {
            // Duplicate or contradictory non-empty IDs are ambiguous. Never
            // guess, because that could attach detail to the wrong title.
            return nil
        }
        guard pairedSegments.count == raw.spine.count else { return nil }

        var answer = raw
        answer.entry.text = trim(answer.entry.text)
        answer.entry.assumption = answer.entry.assumption.flatMap {
            let value = trim($0)
            return value.isEmpty ? nil : value
        }
        answer.entry.sourceIDs = answer.entry.sourceIDs.map(trim).filter { !$0.isEmpty }

        for index in answer.spine.indices {
            let canonicalID = "p\(index + 1)"
            answer.spine[index].id = canonicalID
            answer.spine[index].label = trim(answer.spine[index].label)
            answer.spine[index].cue = answer.spine[index].cue.flatMap {
                let value = trim($0)
                return value.isEmpty ? nil : value
            }
            answer.spine[index].sourceIDs = answer.spine[index].sourceIDs
                .map(trim)
                .filter { !$0.isEmpty }

            answer.segments[index] = pairedSegments[index]
            answer.segments[index].pointID = canonicalID
            answer.segments[index].text = trim(answer.segments[index].text)
            answer.segments[index].sourceIDs = answer.segments[index].sourceIDs
                .map(trim)
                .filter { !$0.isEmpty }
        }
        if var closing = answer.closing {
            closing.text = trim(closing.text)
            closing.sourceIDs = closing.sourceIDs.map(trim).filter { !$0.isEmpty }
            answer.closing = closing.text.isEmpty ? nil : closing
        }
        answer.metadata.concreteGaps = Array(
            answer.metadata.concreteGaps.map(trim).filter { !$0.isEmpty }.prefix(3)
        )
        return hasValidProgressiveAnswerShape(answer) ? answer : nil
    }

    /// Codex app-server responses are usually exact JSON, but some transports
    /// may wrap it in a Markdown fence or append a short note. Decode the first
    /// complete JSON object without attempting speculative text repair.
    static func decodeProgressiveAnswerResponse(
        _ response: String
    ) -> InterviewProgressiveAnswer? {
        let text = response
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        func decode(_ candidate: Substring) -> InterviewProgressiveAnswer? {
            guard let data = String(candidate).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(InterviewProgressiveAnswer.self, from: data)
            else { return nil }
            return normalizedProgressiveAnswerShape(raw)
        }

        if let exact = decode(text[...]) { return exact }
        var searchIndex = text.startIndex
        while searchIndex < text.endIndex,
              let objectStart = text[searchIndex...].firstIndex(of: "{") {
            if let range = balancedObjectRange(in: text, startingAt: objectStart),
               let decoded = decode(text[range]) {
                return decoded
            }
            searchIndex = text.index(after: objectStart)
        }
        return nil
    }

    static func answerProgress(in text: String) -> InterviewAnswerProgress {
        guard let entry = completedObject(
            for: "entry",
            in: text,
            as: InterviewAnswerEntry.self
        ) else { return .empty }

        let rawSpine = completedObjects(
            inArray: "spine",
            in: text,
            as: InterviewAnswerSpinePoint.self
        )
        let spine = rawSpine.enumerated().map { index, point in
            var value = point
            value.id = "p\(index + 1)"
            return value
        }
        let isSpineComplete = completedArrayRange(for: "spine", in: text) != nil
        let normalizedRawSpineIDs = rawSpine.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let hasUniqueNonemptySpineIDs = normalizedRawSpineIDs.allSatisfy { !$0.isEmpty }
            && Set(normalizedRawSpineIDs).count == normalizedRawSpineIDs.count
        let hasOnlyEmptySpineIDs = normalizedRawSpineIDs.allSatisfy(\.isEmpty)
        let parsedSegments = isSpineComplete
            && (hasUniqueNonemptySpineIDs || hasOnlyEmptySpineIDs)
            ? completedObjects(inArray: "segments", in: text, as: InterviewAnswerSegment.self)
            : []
        var segments: [InterviewAnswerSegment] = []
        for (index, segment) in parsedSegments.enumerated() {
            guard rawSpine.indices.contains(index) else { break }
            let segmentID = segment.pointID.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedID = normalizedRawSpineIDs[index]
            guard hasOnlyEmptySpineIDs ? segmentID.isEmpty : segmentID == expectedID else { break }
            var normalizedSegment = segment
            normalizedSegment.pointID = spine[index].id
            segments.append(normalizedSegment)
        }
        let areSegmentsComplete = isSpineComplete
            && completedArrayRange(for: "segments", in: text) != nil
        return InterviewAnswerProgress(
            entry: entry,
            spine: spine,
            segments: segments,
            closing: areSegmentsComplete
                ? completedObject(for: "closing", in: text, as: InterviewAnswerClosing.self)
                : nil,
            metadata: areSegmentsComplete
                ? completedObject(for: "metadata", in: text, as: InterviewAnswerMetadata.self)
                : nil,
            isSpineComplete: isSpineComplete
        )
    }

    private static func completedObject<Value: Decodable>(
        for key: String,
        in text: String,
        as type: Value.Type
    ) -> Value? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let start = text[keyRange.upperBound...].firstIndex(of: "{") else { return nil }
        guard let range = balancedObjectRange(in: text, startingAt: start),
              let data = String(text[range]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func completedObjects<Value: Decodable>(
        inArray key: String,
        in text: String,
        as type: Value.Type
    ) -> [Value] {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let arrayStart = text[keyRange.upperBound...].firstIndex(of: "[") else { return [] }
        var result: [Value] = []
        var index = text.index(after: arrayStart)
        while index < text.endIndex {
            if text[index] == "]" { break }
            guard text[index] == "{" else {
                index = text.index(after: index)
                continue
            }
            guard let range = balancedObjectRange(in: text, startingAt: index) else { break }
            if let data = String(text[range]).data(using: .utf8),
               let value = try? JSONDecoder().decode(type, from: data) {
                result.append(value)
            }
            index = range.upperBound
        }
        return result
    }

    private static func completedArrayRange(
        for key: String,
        in text: String
    ) -> Range<String.Index>? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let start = text[keyRange.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func balancedObjectRange(
        in text: String,
        startingAt start: String.Index
    ) -> Range<String.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func makeReferenceAnswerOutputSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["segments", "missingFacts", "estimatedSpeakingSeconds"],
        "properties": [
            "segments": [
                "type": "array",
                "minItems": 3,
                "maxItems": 3,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["label", "text", "sourceIDs"],
                    "properties": [
                        "label": ["type": "string"],
                        "text": ["type": "string"],
                        "sourceIDs": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
            "missingFacts": ["type": "array", "items": ["type": "string"]],
            "estimatedSpeakingSeconds": [
                "type": "integer",
                "minimum": 45,
                "maximum": 60,
            ],
        ],
    ] }

    static func hasValidReferenceAnswerShape(_ answer: InterviewReferenceAnswer) -> Bool {
        answer.segments.count == 3
            && (45...60).contains(answer.estimatedSpeakingSeconds)
    }

    static let requiredFollowUpCount = 3
    static let followUpAnswerTalkingPointCount = 2...3
    static let followUpAnswerSpeakingSeconds = 20...40

    static func makeFollowUpsOutputSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["items"],
        "properties": [
            "items": [
                "type": "array",
                "minItems": requiredFollowUpCount,
                "maxItems": requiredFollowUpCount,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["question", "intent"],
                    "properties": [
                        "question": ["type": "string"],
                        "intent": ["type": "string"],
                    ],
                ],
            ],
        ],
    ] }

    static func hasValidFollowUpsShape(_ followUps: InterviewFollowUpSet) -> Bool {
        followUps.items.count == requiredFollowUpCount
    }

    static func makeFollowUpAnswerOutputSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["directOpening", "talkingPoints", "sampleAnswer", "sourceIDs", "estimatedSpeakingSeconds"],
        "properties": [
            "directOpening": ["type": "string"],
            "talkingPoints": [
                "type": "array",
                "minItems": followUpAnswerTalkingPointCount.lowerBound,
                "maxItems": followUpAnswerTalkingPointCount.upperBound,
                "items": ["type": "string"],
            ],
            "sampleAnswer": ["type": "string"],
            "sourceIDs": ["type": "array", "maxItems": 4, "items": ["type": "string"]],
            "estimatedSpeakingSeconds": [
                "type": "integer",
                "minimum": followUpAnswerSpeakingSeconds.lowerBound,
                "maximum": followUpAnswerSpeakingSeconds.upperBound,
            ],
        ],
    ] }

    static func hasValidFollowUpAnswerShape(_ answer: InterviewFollowUpAnswer) -> Bool {
        followUpAnswerTalkingPointCount.contains(answer.talkingPoints.count)
            && followUpAnswerSpeakingSeconds.contains(answer.estimatedSpeakingSeconds)
    }

    static func completedReferenceSegments(in text: String) -> [InterviewReferenceAnswerSegment] {
        guard let key = text.range(of: "\"segments\""),
              let arrayStart = text[key.upperBound...].firstIndex(of: "[") else { return [] }
        var segments: [InterviewReferenceAnswerSegment] = []
        var objectStart: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.index(after: arrayStart)
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { objectStart = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let end = text.index(after: index)
                    if let data = String(text[start..<end]).data(using: .utf8),
                       let segment = try? JSONDecoder().decode(InterviewReferenceAnswerSegment.self, from: data) {
                        segments.append(segment)
                    }
                    objectStart = nil
                }
            } else if character == "]", depth == 0 {
                break
            }
            index = text.index(after: index)
        }
        return segments
    }

    /// Decodes completed segment objects and, when possible, the growing `text`
    /// string in the current object. This gives the lens a true character-level
    /// preview without treating an unfinished structured response as final data.
    static func referenceSegmentsProgress(in text: String) -> [InterviewReferenceAnswerSegment] {
        var result = completedReferenceSegments(in: text)
        guard result.count < 3,
              let key = text.range(of: "\"segments\""),
              let arrayStart = text[key.upperBound...].firstIndex(of: "[") else {
            return Array(result.prefix(3))
        }

        var objectStart: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.index(after: arrayStart)
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { objectStart = index }
                depth += 1
            } else if character == "}" {
                depth = max(0, depth - 1)
                if depth == 0 { objectStart = nil }
            }
            index = text.index(after: index)
        }

        guard depth > 0, let objectStart else { return Array(result.prefix(3)) }
        let object = String(text[objectStart...])
        guard let partialText = partialJSONStringValue(for: "text", in: object),
              !partialText.isEmpty else { return Array(result.prefix(3)) }
        let label = partialJSONStringValue(for: "label", in: object)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "回答 \(result.count + 1)"
        result.append(InterviewReferenceAnswerSegment(
            label: label,
            text: partialText,
            sourceIDs: []
        ))
        return Array(result.prefix(3))
    }

    static func cueProgress(in text: String) -> InterviewCueProgress {
        InterviewCueProgress(
            directOpening: partialJSONStringValue(for: "directOpening", in: text),
            talkingPoints: partialJSONStringArrayValues(for: "talkingPoints", in: text)
        )
    }

    static func partialJSONStringValue(for key: String, in source: String) -> String? {
        guard let keyRange = source.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < source.endIndex, source[index].isWhitespace || source[index] == ":" {
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index] == "\"" else { return nil }
        index = source.index(after: index)

        var result = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" { return result }
            guard character == "\\" else {
                result.append(character)
                index = source.index(after: index)
                continue
            }

            let escapedIndex = source.index(after: index)
            guard escapedIndex < source.endIndex else { return result }
            switch source[escapedIndex] {
            case "\"", "\\", "/": result.append(source[escapedIndex])
            case "b": result.append("\u{8}")
            case "f": result.append("\u{c}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                let hexStart = source.index(after: escapedIndex)
                guard let hexEnd = source.index(hexStart, offsetBy: 4, limitedBy: source.endIndex),
                      source.distance(from: hexStart, to: hexEnd) == 4,
                      let value = UInt32(source[hexStart..<hexEnd], radix: 16) else { return result }
                if (0xD800...0xDBFF).contains(value) {
                    guard hexEnd < source.endIndex, source[hexEnd] == "\\" else { return result }
                    let lowMarker = source.index(after: hexEnd)
                    guard lowMarker < source.endIndex, source[lowMarker] == "u" else { return result }
                    let lowStart = source.index(after: lowMarker)
                    guard let lowEnd = source.index(lowStart, offsetBy: 4, limitedBy: source.endIndex),
                          source.distance(from: lowStart, to: lowEnd) == 4,
                          let low = UInt32(source[lowStart..<lowEnd], radix: 16),
                          (0xDC00...0xDFFF).contains(low),
                          let scalar = UnicodeScalar(
                              0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                          ) else { return result }
                    result.unicodeScalars.append(scalar)
                    index = lowEnd
                    continue
                }
                guard let scalar = UnicodeScalar(value) else { return result }
                result.unicodeScalars.append(scalar)
                index = hexEnd
                continue
            default: return result
            }
            index = source.index(after: escapedIndex)
        }
        return result
    }

    private static func partialJSONStringArrayValues(for key: String, in source: String) -> [String] {
        guard let keyRange = source.range(of: "\"\(key)\"") else { return [] }
        var index = keyRange.upperBound
        while index < source.endIndex, source[index].isWhitespace || source[index] == ":" {
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index] == "[" else { return [] }
        index = source.index(after: index)

        var values: [String] = []
        while index < source.endIndex {
            while index < source.endIndex,
                  source[index].isWhitespace || source[index] == "," {
                index = source.index(after: index)
            }
            guard index < source.endIndex, source[index] != "]", source[index] == "\"" else { break }
            index = source.index(after: index)
            let parsed = partialJSONStringContent(in: source, startingAt: index)
            let value = parsed.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values.append(value) }
            index = parsed.nextIndex
            if !parsed.closed { break }
        }
        return values
    }

    private static func partialJSONStringContent(
        in source: String,
        startingAt start: String.Index
    ) -> (value: String, nextIndex: String.Index, closed: Bool) {
        var index = start
        var result = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                return (result, source.index(after: index), true)
            }
            guard character == "\\" else {
                result.append(character)
                index = source.index(after: index)
                continue
            }
            let escapedIndex = source.index(after: index)
            guard escapedIndex < source.endIndex else { return (result, source.endIndex, false) }
            switch source[escapedIndex] {
            case "\"", "\\", "/": result.append(source[escapedIndex])
            case "b": result.append("\u{8}")
            case "f": result.append("\u{c}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                let hexStart = source.index(after: escapedIndex)
                guard let hexEnd = source.index(hexStart, offsetBy: 4, limitedBy: source.endIndex),
                      source.distance(from: hexStart, to: hexEnd) == 4,
                      let value = UInt32(source[hexStart..<hexEnd], radix: 16),
                      let scalar = UnicodeScalar(value) else {
                    return (result, source.endIndex, false)
                }
                result.unicodeScalars.append(scalar)
                index = hexEnd
                continue
            default:
                return (result, source.endIndex, false)
            }
            index = source.index(after: escapedIndex)
        }
        return (result, source.endIndex, false)
    }
}

actor CodexInterviewProvider: InterviewGenerationProvider {
    private let worker: CodexWorkerClient
    private var generationMetadata: [UUID: InterviewGenerationMetadata] = [:]

    init(worker: CodexWorkerClient) {
        self.worker = worker
        // Starting the persistent Codex app-server is local-only and does not
        // consume a model turn. Hide its cold start behind normal app launch.
        Task(priority: .utility) {
            await worker.prewarm()
        }
    }

    func generateProgressiveAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewProgressiveAnswer {
        try await generateProgressiveAnswerStreaming(request, credential: credential) { _ in }
    }

    func generateProgressiveAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void
    ) async throws -> InterviewProgressiveAnswer {
        let accumulator = AnswerProgressAccumulator(onProgress: onProgress)
        let (deltaStream, deltaContinuation) = AsyncStream<String>.makeStream()
        let progressTask = Task {
            for await delta in deltaStream {
                await accumulator.append(delta)
            }
        }
        let result: CopilotWorkerResult
        do {
            result = try await worker.generate(CopilotGenerationRequest(
                id: request.id,
                model: request.model,
                prompt: request.prompt,
                kind: request.kind,
                maxOutputTokens: request.maxOutputTokens,
                fastServiceTier: request.fastServiceTier,
                reasoningEffort: request.reasoningEffort
            ), onDelta: { delta in
                // CodexWorkerClient invokes this callback in wire order. A
                // single consumer preserves that order while crossing actors;
                // one unstructured Task per delta could reorder JSON chunks.
                deltaContinuation.yield(delta)
            })
        } catch {
            deltaContinuation.finish()
            // Drain deltas that were emitted before the failure so the engine
            // can make one coherent owner/failure decision.
            await progressTask.value
            throw error
        }
        deltaContinuation.finish()
        await progressTask.value
        generationMetadata[request.id] = InterviewGenerationMetadata(
            transport: result.transport,
            firstDeltaMilliseconds: result.firstDeltaMilliseconds,
            prewarmReady: result.prewarmReadyAtStart,
            prewarmDurationMilliseconds: result.prewarmDurationAtStartMilliseconds
        )
        guard let answer = OpenAIResponsesProvider.decodeProgressiveAnswerResponse(result.response) else {
            Log.suggestionEngine.error(
                "Progressive answer decode failed provider=codex chars=\(result.response.utf8.count) transport=\(result.transport ?? "unknown", privacy: .public)"
            )
            throw CopilotError.invalidResponse
        }
        onProgress(InterviewAnswerProgress(
            entry: answer.entry,
            spine: answer.spine,
            segments: answer.segments,
            closing: answer.closing,
            metadata: answer.metadata,
            isSpineComplete: true
        ))
        return answer
    }

    func generateCue(_ request: InterviewGenerationRequest, credential: String?) async throws -> InterviewCue {
        try await generateCueStreaming(request, credential: credential) { _ in }
    }

    func generateCueStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable (InterviewCueProgress) -> Void
    ) async throws -> InterviewCue {
        let accumulator = CueProgressAccumulator(onProgress: onProgress)
        let result = try await worker.generate(CopilotGenerationRequest(
            id: request.id,
            model: request.model,
            prompt: request.prompt,
            kind: request.kind,
            maxOutputTokens: request.maxOutputTokens,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort
        ), onDelta: { delta in
            Task { await accumulator.append(delta) }
        })
        generationMetadata[request.id] = InterviewGenerationMetadata(
            transport: result.transport,
            firstDeltaMilliseconds: result.firstDeltaMilliseconds,
            prewarmReady: result.prewarmReadyAtStart,
            prewarmDurationMilliseconds: result.prewarmDurationAtStartMilliseconds
        )
        guard let data = result.response.data(using: .utf8),
              let cue = try? JSONDecoder().decode(InterviewCue.self, from: data) else {
            throw CopilotError.invalidResponse
        }
        return cue
    }

    func generateReferenceAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewReferenceAnswer {
        let result = try await worker.generate(CopilotGenerationRequest(
            id: request.id,
            model: request.model,
            prompt: request.prompt,
            kind: request.kind,
            maxOutputTokens: request.maxOutputTokens,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort
        ))
        guard let data = result.response.data(using: .utf8),
              let answer = try? JSONDecoder().decode(InterviewReferenceAnswer.self, from: data),
              OpenAIResponsesProvider.hasValidReferenceAnswerShape(answer) else {
            throw CopilotError.invalidResponse
        }
        return answer
    }

    func generateReferenceAnswerStreaming(
        _ request: InterviewGenerationRequest,
        credential: String?,
        onProgress: @escaping @Sendable ([InterviewReferenceAnswerSegment]) -> Void
    ) async throws -> InterviewReferenceAnswer {
        let accumulator = ReferenceProgressAccumulator(onProgress: onProgress)
        let result = try await worker.generate(CopilotGenerationRequest(
            id: request.id,
            model: request.model,
            prompt: request.prompt,
            kind: request.kind,
            maxOutputTokens: request.maxOutputTokens,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort
        ), onDelta: { delta in
            Task { await accumulator.append(delta) }
        })
        guard let data = result.response.data(using: .utf8),
              let answer = try? JSONDecoder().decode(InterviewReferenceAnswer.self, from: data),
              OpenAIResponsesProvider.hasValidReferenceAnswerShape(answer) else {
            throw CopilotError.invalidResponse
        }
        onProgress(answer.segments)
        return answer
    }

    func generateFollowUps(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpSet {
        let value = try await decodeWorkerResponse(request, as: InterviewFollowUpSet.self)
        guard OpenAIResponsesProvider.hasValidFollowUpsShape(value) else {
            throw CopilotError.invalidResponse
        }
        return value
    }

    func generateFollowUpAnswer(
        _ request: InterviewGenerationRequest,
        credential: String?
    ) async throws -> InterviewFollowUpAnswer {
        let value = try await decodeWorkerResponse(request, as: InterviewFollowUpAnswer.self)
        guard OpenAIResponsesProvider.hasValidFollowUpAnswerShape(value) else {
            throw CopilotError.invalidResponse
        }
        return value
    }

    private func decodeWorkerResponse<Response: Decodable>(
        _ request: InterviewGenerationRequest,
        as type: Response.Type
    ) async throws -> Response {
        let result = try await worker.generate(CopilotGenerationRequest(
            id: request.id,
            model: request.model,
            prompt: request.prompt,
            kind: request.kind,
            maxOutputTokens: request.maxOutputTokens,
            fastServiceTier: request.fastServiceTier,
            reasoningEffort: request.reasoningEffort
        ))
        guard let data = result.response.data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw CopilotError.invalidResponse
        }
        return value
    }

    func cancel(id: UUID) async {
        await worker.cancel(id: id)
    }

    func takeGenerationMetadata(for id: UUID) async -> InterviewGenerationMetadata? {
        generationMetadata.removeValue(forKey: id)
    }
}

private actor CueProgressAccumulator {
    private var text = ""
    private var lastProgress = InterviewCueProgress(directOpening: nil, talkingPoints: [])
    private let onProgress: @Sendable (InterviewCueProgress) -> Void

    init(onProgress: @escaping @Sendable (InterviewCueProgress) -> Void) {
        self.onProgress = onProgress
    }

    func append(_ delta: String) {
        text += delta
        let progress = OpenAIResponsesProvider.cueProgress(in: text)
        guard progress.hasVisibleContent, progress != lastProgress else { return }
        lastProgress = progress
        onProgress(progress)
    }
}

private actor ReferenceProgressAccumulator {
    private var text = ""
    private var lastSegments: [InterviewReferenceAnswerSegment] = []
    private let onProgress: @Sendable ([InterviewReferenceAnswerSegment]) -> Void

    init(onProgress: @escaping @Sendable ([InterviewReferenceAnswerSegment]) -> Void) {
        self.onProgress = onProgress
    }

    func append(_ delta: String) {
        text += delta
        let segments = OpenAIResponsesProvider.referenceSegmentsProgress(in: text)
        guard !segments.isEmpty, segments != lastSegments else { return }
        lastSegments = segments
        onProgress(segments)
    }
}

private actor AnswerProgressAccumulator {
    private var text = ""
    private var lastProgress = InterviewAnswerProgress.empty
    private let onProgress: @Sendable (InterviewAnswerProgress) -> Void

    init(onProgress: @escaping @Sendable (InterviewAnswerProgress) -> Void) {
        self.onProgress = onProgress
    }

    func append(_ delta: String) {
        text += delta
        let progress = OpenAIResponsesProvider.answerProgress(in: text)
        guard progress.hasUsefulContent, progress != lastProgress else { return }
        lastProgress = progress
        onProgress(progress)
    }
}
