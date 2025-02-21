//
//  ChatStore.swift
//  DemoChat
//
//  Created by Sihao Lu on 3/25/23.
//

import Foundation
import Combine
import OpenAI
import SwiftUI

public final class ChatStore: ObservableObject {
    public var openAIClient: OpenAIProtocol
    let idProvider: () -> String

    @Published var conversations: [Conversation] = []
    @Published var conversationErrors: [Conversation.ID: Error] = [:]
    @Published var selectedConversationID: Conversation.ID?

    // Used for assistants API state.
    private var timers: [String: Timer] = [:]
    private var timeInterval: TimeInterval = 1.0
    private var currentRunId: String?
    private var currentThreadId: String?
    private var currentConversationId: String?

    @Published var isSendingMessage = false
    @Published public var productIds: [String] = []

    var selectedConversation: Conversation? {
        selectedConversationID.flatMap { id in
            conversations.first { $0.id == id }
        }
    }

    var selectedConversationPublisher: AnyPublisher<Conversation?, Never> {
        $selectedConversationID.receive(on: RunLoop.main).map { id in
            self.conversations.first(where: { $0.id == id })
        }
        .eraseToAnyPublisher()
    }

    public init(
        openAIClient: OpenAIProtocol,
        idProvider: @escaping () -> String
    ) {
        self.openAIClient = openAIClient
        self.idProvider = idProvider
    }

    deinit {
        print("deinit")
    }

    public func createAssistantConversation(assistantId: String) {
        let conversation = Conversation(id: idProvider(), messages: [], type: .assistant, assistantId: assistantId)
        conversations.append(conversation)
    }

    // MARK: - Events

    func createConversation(type: ConversationType = .normal, assistantId: String? = nil) {
        let conversation = Conversation(id: idProvider(), messages: [], type: type, assistantId: assistantId)
        conversations.append(conversation)
    }

    func selectConversation(_ conversationId: Conversation.ID?) {
        selectedConversationID = conversationId
    }

    func deleteConversation(_ conversationId: Conversation.ID) {
        conversations.removeAll(where: { $0.id == conversationId })
    }

    @MainActor
    func sendMessage(
        _ message: Message,
        conversationId: Conversation.ID,
        model: Model
    ) async {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }

        switch conversations[conversationIndex].type  {
        case .normal:
            conversations[conversationIndex].messages.append(message)

            await completeChat(
                conversationId: conversationId,
                model: model
            )
            // For assistant case we send chats to thread and then poll, polling will receive sent chat + new assistant messages.
        case .assistant:

            // First message in an assistant thread.
            if conversations[conversationIndex].messages.count == 0 {

                var localMessage = message
                localMessage.isLocal = true
                conversations[conversationIndex].messages.append(localMessage)

                guard let newMessage = ChatQuery.ChatCompletionMessageParam(role: message.role, content: message.content) else { 
                    print("error: Couldn't form message")
                    return
                }

                do {

                    let threadsQuery = ThreadsQuery(messages: [newMessage])
                    let threadsResult = try await openAIClient.threads(query: threadsQuery)

                    guard let currentAssistantId = conversations[conversationIndex].assistantId else { return print("No assistant selected.")}

                    let runsQuery = RunsQuery(assistantId:  currentAssistantId)
                    let runsResult = try await openAIClient.runs(threadId: threadsResult.id, query: runsQuery)

                    // check in on the run every time the poller gets hit.
                    startPolling(conversationId: conversationId, runId: runsResult.id, threadId: threadsResult.id)
                }
                catch {
                    print("error: \(error) creating thread w/ message")
                }
            }
            // Subsequent messages on the assistant thread.
            else {

                var localMessage = message
                localMessage.isLocal = true
                conversations[conversationIndex].messages.append(localMessage)

                do {
                    guard let currentThreadId else { return print("No thread to add message to.")}

                    let _ = try await openAIClient.threadsAddMessage(threadId: currentThreadId,
                                                                     query: MessageQuery(role: message.role, content: message.content))

                    guard let currentAssistantId = conversations[conversationIndex].assistantId else { return print("No assistant selected.")}

                    let runsQuery = RunsQuery(assistantId: currentAssistantId)
                    let runsResult = try await openAIClient.runs(threadId: currentThreadId, query: runsQuery)

                    // check in on the run every time the poller gets hit.
                    startPolling(conversationId: conversationId, runId: runsResult.id, threadId: currentThreadId)
                }
                catch {
                    print("error: \(error) adding to thread w/ message")
                }
            }
        }
    }

    @MainActor
    func completeChat(
        conversationId: Conversation.ID,
        model: Model
    ) async {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            return
        }

        conversationErrors[conversationId] = nil

        do {
            guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationId }) else {
                return
            }

            let weatherFunction = ChatQuery.ChatCompletionToolParam(function: .init(
                name: "getWeatherData",
                description: "Get the current weather in a given location",
                parameters: .init(
                    type: .object,
                    properties: [
                        "location": .init(type: .string, description: "The city and state, e.g. San Francisco, CA")
                    ],
                    required: ["location"]
                )
            ))

            let functions = [weatherFunction]

            let chatsStream: AsyncThrowingStream<ChatStreamResult, Error> = openAIClient.chatsStream(
                query: ChatQuery(
                    messages: conversation.messages.map { message in
                        ChatQuery.ChatCompletionMessageParam(role: message.role, content: message.content)!
                    }, model: model,
                    tools: functions
                )
            )

            var functionCalls = [(name: String, argument: String?)]()
            for try await partialChatResult in chatsStream {
                for choice in partialChatResult.choices {
                    let existingMessages = conversations[conversationIndex].messages
                    // Function calls are also streamed, so we need to accumulate.
                    choice.delta.toolCalls?.forEach { toolCallDelta in
                        if let functionCallDelta = toolCallDelta.function {
                            if let nameDelta = functionCallDelta.name {
                                functionCalls.append((nameDelta, functionCallDelta.arguments))
                            }
                        }
                    }
                    var messageText = choice.delta.content ?? ""
                    var fileIDs: [String]?
                    if let finishReason = choice.finishReason,
                       finishReason == .toolCalls
                    {
                        functionCalls.forEach { (name: String, argument: String?) in
                            messageText += "Function call: name=\(name) arguments=\(argument ?? "")\n"
                            if let jsonData = argument?.data(using: .utf8) {
                                let request = try? JSONDecoder().decode(FileSearchFunctionCall.self, from: jsonData)
                                fileIDs = request?.fileIDs
                                print(request?.fileIDs)  // Output: ["Y12345", "Y67890"]
                            }
                        }
                    }
                    let message = Message(
                        id: partialChatResult.id,
                        role: choice.delta.role ?? .assistant,
                        content: messageText,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(partialChatResult.created))
                    )
                    if let existingMessageIndex = existingMessages.firstIndex(where: { $0.id == partialChatResult.id }) {
                        // Meld into previous message
                        let previousMessage = existingMessages[existingMessageIndex]
                        let combinedMessage = Message(
                            id: message.id, // id stays the same for different deltas
                            role: message.role,
                            content: previousMessage.content + message.content,
                            createdAt: message.createdAt
                        )
                        conversations[conversationIndex].messages[existingMessageIndex] = combinedMessage
                    } else {
                        conversations[conversationIndex].messages.append(message)
                    }

                    if let fileIDs {
                        for fileID in fileIDs {
                            let file = try await openAIClient.file(fileId: fileID)
                            let message = Message(
                                id: partialChatResult.id,
                                role: choice.delta.role ?? .assistant,
                                content: file.filename ?? "empty",
                                createdAt: Date(timeIntervalSince1970: TimeInterval(partialChatResult.created))
                            )
                            conversations[conversationIndex].messages.append(message)
                        }
                    }
                }
            }
        } catch {
            conversationErrors[conversationId] = error
        }
    }

    // Start Polling section
    func startPolling(conversationId: Conversation.ID, runId: String, threadId: String) {
        currentRunId = runId
        currentThreadId = threadId
        currentConversationId = conversationId
        isSendingMessage = true
        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: self.timeInterval, repeats: true) { [weak self] _ in
                self?.timerFired(conversationId: conversationId, runId: runId, threadId: threadId)
            }
            self.timers[conversationId+runId+threadId] = timer
        }
    }

    func stopPolling(conversationId: Conversation.ID, runId: String, threadId: String) {
        isSendingMessage = false
        let timer = timers[conversationId+runId+threadId]
        timer?.invalidate()
        timers[conversationId+runId+threadId] = nil
    }

    private func timerFired(conversationId: Conversation.ID, runId: String, threadId: String) {
        Task {
            let result = try await openAIClient.runRetrieve(threadId: threadId, runId: runId)

            // TESTING RETRIEVAL OF RUN STEPS
            let assistantId = try await handleRunRetrieveSteps()
            if let assistantId {
                try await forceHandleAction(assistantId: assistantId, conversationId: conversationId, threadId: threadId)
            }

            switch result.status {
                // Get threadsMesages.
            case .completed:
                handleCompleted(conversationId: conversationId, runId: runId, threadId: threadId)
            case .failed:
                // Handle more gracefully with a popup dialog or failure indicator
                await MainActor.run {
                    self.stopPolling(conversationId: conversationId, runId: runId, threadId: threadId)
                }
            case .requiresAction:
                // FIXME: Workaround, avoid endless loop.
                // try await handleRequiresAction(result)
                handleCompleted(conversationId: conversationId, runId: runId, threadId: threadId)
            default:
                // Handle additional statuses "requires_action", "queued" ?, "expired", "cancelled"
                // https://platform.openai.com/docs/assistants/how-it-works/runs-and-run-steps
                break
            }
        }
    }
    // END Polling section
    
    // This function is called when a thread is marked "completed" by the run status API.
    private func handleCompleted(conversationId: Conversation.ID, runId: String, threadId: String) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == currentConversationId }) else {
            return
        }
        Task {
            await MainActor.run {
                self.stopPolling(conversationId: conversationId, runId: runId, threadId: threadId)
            }
            // Once a thread is marked "completed" by the status API, we can retrieve the threads messages, including a pagins cursor representing the last message we received.
            var before: String?
            if let lastNonLocalMessage = self.conversations[conversationIndex].messages.last(where: { $0.isLocal == false }) {
                before = lastNonLocalMessage.id
            }

            let result = try await openAIClient.threadsMessages(threadId: currentThreadId ?? "", before: before)

            for item in result.data.reversed() {
                let role = item.role
                for innerItem in item.content {
                    let message = Message(
                        id: item.id,
                        role: role,
                        content: innerItem.text?.value ?? "",
                        createdAt: Date(),
                        isLocal: false // Messages from the server are not local
                    )
                    await MainActor.run {
                        // Check if this message from the API matches a local message
                        if let localMessageIndex = self.conversations[conversationIndex].messages.firstIndex(where: { $0.isLocal == true }) {

                            // Replace the local message with the API message
                            self.conversations[conversationIndex].messages[localMessageIndex] = message
                        } else {
                            // This is a new message from the server, append it
                            self.conversations[conversationIndex].messages.append(message)
                        }
                    }
                }
            }
        }
    }
    
    // Store the function call as a message and submit tool outputs with a simple done message.
    private func handleRequiresAction(_ result: RunResult) async throws {
        guard let currentThreadId, let currentRunId else {
            return
        }
        
        guard let toolCalls = result.requiredAction?.submitToolOutputs.toolCalls else {
            return
        }
        
        var toolOutputs = [RunToolOutputsQuery.ToolOutput]()

        for toolCall in toolCalls {
            let msgContent = "RequiresAction\nfunction\nname: \(toolCall.function.name ?? "")\nargs: \(toolCall.function.arguments ?? "{}")"

            let runStepMessage = Message(
                id: toolCall.id,
                role: .assistant,
                content: msgContent,
                createdAt: Date(),
                isRunStep: true
            )
            await addOrUpdateRunStepMessage(runStepMessage)
            
            // Just return a generic "Done" output for now
            toolOutputs.append(.init(toolCallId: toolCall.id, output: "Done"))
        }
        
        let query = RunToolOutputsQuery(toolOutputs: toolOutputs)
        _ = try await openAIClient.runSubmitToolOutputs(threadId: currentThreadId, runId: currentRunId, query: query)
    }

    private func forceHandleAction(assistantId: String, conversationId: Conversation.ID, threadId: String) async throws {
        guard let currentThreadId else {
            return
        }

        let weatherFunction = ChatQuery.ChatCompletionToolParam(function: .init(
            name: "find_files",
            description: "Find uploaded files that match the given criteria, return the files ids(start with specific prefix `file-`), sorted by relevance.",
            parameters: .init(
                type: .object,
                properties: [
                    "file_ids": .init(
                        type: .array,
                        items: .init(type: .string)
                    )
                ],
                required: ["file_ids"]
            )
        ))

        let functions = [weatherFunction]

        let runsQuery = RunsQuery(assistantId: assistantId,
                                  tools: functions,
                                  toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam(function: "find_files"))
        let runsResult = try await openAIClient.runs(threadId: currentThreadId, query: runsQuery)
        print(runsResult)
        let runId = runsResult.id

        startPolling(conversationId: conversationId, runId: runId, threadId: threadId)

        guard let tools = runsResult.tools else {
            return
        }

//        var toolOutputs = [RunToolOutputsQuery.ToolOutput]()

        for tool in tools {
            let msgContent = "function\nname: \(tool.function?.name ?? "")\nparameters: \(tool.function?.parameters)"
            let runStepMessage = Message(
                id: runsResult.id,
                role: .assistant,
                content: msgContent,
                createdAt: Date(),
                isRunStep: true
            )

            await addOrUpdateRunStepMessage(runStepMessage)
        }

        switch runsResult.status {
            // Get threadsMesages.
        case .completed:
            handleCompleted(conversationId: conversationId, runId: runId, threadId: threadId)
        case .failed:
            // Handle more gracefully with a popup dialog or failure indicator
            await MainActor.run {
                self.stopPolling(conversationId: conversationId, runId: runId, threadId: threadId)
            }
        case .requiresAction:
            try await handleRequiresAction(runsResult)
        default:
            // Handle additional statuses "requires_action", "queued" ?, "expired", "cancelled"
            // https://platform.openai.com/docs/assistants/how-it-works/runs-and-run-steps
            break
        }
    }

    // The run retrieval steps are fetched in a separate task. This request is fetched, checking for new run steps, each time the run is fetched.
    private func handleRunRetrieveSteps() async throws -> String? {
        var before: String?
//            if let lastRunStepMessage = self.conversations[conversationIndex].messages.last(where: { $0.isRunStep == true }) {
//                before = lastRunStepMessage.id
//            }

        let stepsResult = try await openAIClient.runRetrieveSteps(threadId: currentThreadId ?? "", runId: currentRunId ?? "", before: before)

        var assistantId: String?
        for item in stepsResult.data.reversed() {
            let toolCalls = item.stepDetails.toolCalls?.reversed() ?? []

            for step in toolCalls {
                // TODO: Depending on the type of tool tha is used we can add additional information here
                // ie: if its a fileSearch: add file information, code_interpreter: add inputs and outputs info, or function: add arguemts and additional info.
                let msgContent: String
                switch step.type {
                case .fileSearch:
                    msgContent = "RUN STEP: \(step.type)"
                    assistantId = item.assistantId

                case .codeInterpreter:
                    let code = step.codeInterpreter
                    msgContent = "code_interpreter\ninput:\n\(code?.input ?? "")\noutputs: \(code?.outputs?.first?.logs ?? "")"

                case .function:
                    msgContent = "get function\nname: \(step.function?.name ?? "")\nargs: \(step.function?.arguments ?? "{}")"

                }
                let runStepMessage = Message(
                    id: step.id,
                    role: .assistant,
                    content: msgContent,
                    createdAt: Date(),
                    isRunStep: true
                )

                if let jsonData = step.function?.arguments.data(using: .utf8) {
                    let request = try? JSONDecoder().decode(FileSearchFunctionCall.self, from: jsonData)

                    if let fileIDs = request?.fileIDs {
                        print(fileIDs)

                        var filenames: [String] = []
                        for fileID in fileIDs {
                            do {
                                var fileID = fileID
                                if fileID.hasPrefix("file-") == false {
                                    fileID = "file-" + fileID
                                }
                                let file = try await openAIClient.file(fileId: fileID)
                                guard let filename = file.filename else {
                                    continue
                                }
                                let message = Message(
                                    id: file.id,
                                    role: .assistant,
                                    content: filename,
                                    createdAt: Date(),
                                    isRunStep: true
                                )
                                filenames.append((filename as NSString).deletingPathExtension)
                                await addOrUpdateRunStepMessage(message)
                            } catch {
                                continue
                            }
                        }

                        if filenames.isEmpty == false {
                            DispatchQueue.main.async {
                                self.productIds = filenames
                            }
                        }
                    }
                } else {
                    await addOrUpdateRunStepMessage(runStepMessage)
                }
            }
        }

        return assistantId
    }
    
    @MainActor
    private func addOrUpdateRunStepMessage(_ message: Message) async {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == currentConversationId }) else {
            return
        }
        
        if let localMessageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.isRunStep == true && $0.id == message.id }) {
            conversations[conversationIndex].messages[localMessageIndex] = message
        }
        else {
            conversations[conversationIndex].messages.append(message)
        }
    }
}

struct FileSearchFunctionCall: Codable {
    let fileIDs: [String]

    enum CodingKeys: String, CodingKey {
        case fileIDs = "file_ids"
    }
}
