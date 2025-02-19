//
//  AssistantsQuery.swift
//  
//
//  Created by Chris Dillard on 11/07/2023.
//

import Foundation

public struct RunsQuery: Codable {

    public let assistantId: String
    public let tools: [ChatQuery.ChatCompletionToolParam]?
    public let toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam?

    enum CodingKeys: String, CodingKey {
        case assistantId = "assistant_id"
        case tools
        case toolChoice = "tool_choice"
    }
    
    public init(assistantId: String,
                tools: [ChatQuery.ChatCompletionToolParam]? = nil,
                toolChoice: ChatQuery.ChatCompletionFunctionCallOptionParam? = nil) {

        self.assistantId = assistantId
        self.tools = tools
        self.toolChoice = toolChoice
    }
}
