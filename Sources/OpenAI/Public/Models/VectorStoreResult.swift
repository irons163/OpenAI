//
//  VectorStoreResult.swift
//  OpenAI
//
//  Created by Phil Chang on 2025/2/16.
//

import Foundation

public struct VectorStoreResult: Codable {
    public let id: String
    public let object: String
    public let createdAt: Int
    public let name: String?
    public let bytes: Int
    public let fileCounts: FileCounts

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case name
        case bytes
        case fileCounts = "file_counts"
    }

    public struct FileCounts: Codable {
        let inProgress: Int
        let completed: Int
        let failed: Int
        let cancelled: Int
        let total: Int

        enum CodingKeys: String, CodingKey {
            case inProgress = "in_progress"
            case completed
            case failed
            case cancelled
            case total
        }
    }
}
