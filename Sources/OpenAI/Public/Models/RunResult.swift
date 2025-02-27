//
//  RunResult.swift
//
//
//  Created by Chris Dillard on 11/07/2023.
//

import Foundation

public struct RunResult: Codable, Equatable {
    public enum Status: String, Codable {
        case queued
        case inProgress = "in_progress"
        case requiresAction = "requires_action"
        case cancelling
        case cancelled
        case failed
        case completed
        case expired
    }

    public struct RequiredAction: Codable, Equatable {
        public let submitToolOutputs: SubmitToolOutputs
        
        enum CodingKeys: String, CodingKey {
            case submitToolOutputs = "submit_tool_outputs"
        }
    }

    public struct SubmitToolOutputs: Codable, Equatable {
        public let toolCalls: [ToolCall]
        
        enum CodingKeys: String, CodingKey {
            case toolCalls = "tool_calls"
        }
    }

    public struct ToolCall: Codable, Equatable {
        public let id: String
        public let type: String
        public let function: ChatFunctionCall
    }

    public struct Tool: Codable, Equatable {
        public let type: String
        public let function: ChatQuery.ChatCompletionToolParam.FunctionDefinition?

        enum CodingKeys: String, CodingKey {
            case type
            case function
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case assistantId = "assistant_id"
        case status
        case requiredAction = "required_action"
        case tools
    }

    public let id: String
    public let threadId: String
    public let assistantId: String
    public let status: Status
    public let requiredAction: RequiredAction?

    public let tools: [Tool]?
}
