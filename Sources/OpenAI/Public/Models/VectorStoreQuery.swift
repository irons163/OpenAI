//
//  VectorStoreQuery.swift
//  OpenAI
//
//  Created by Phil Chang on 2025/2/16.
//

import Foundation

public struct VectorStoreQuery: Codable, Equatable {
    public let name: String?
    public let metadata: [String: String]?
    public let fileIDs: [String]?
    public let expiresAfter: ExpiresAfter?
    public let chunkingStrategy: ChunkingStrategy?

    enum CodingKeys: String, CodingKey {
        case name
        case metadata
        case fileIDs = "file_ids"
        case expiresAfter = "expires_after"
        case chunkingStrategy = "chunking_strategy"
    }

    public struct ExpiresAfter: Codable, Equatable {
        let anchor: String
        let days: Int
    }

    public enum ChunkingStrategy: Codable, Equatable {
        case auto
        case `static`(StaticChunking)

        enum CodingKeys: String, CodingKey {
            case type
            case maxChunkSizeTokens = "max_chunk_size_tokens"
            case chunkOverlapTokens = "chunk_overlap_tokens"
        }

        public struct StaticChunking: Codable, Equatable {
            let type: String = "static"
            let maxChunkSizeTokens: Int
            let chunkOverlapTokens: Int
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            if type == "auto" {
                self = .auto
            } else if type == "static" {
                let maxChunkSizeTokens = try container.decode(Int.self, forKey: .maxChunkSizeTokens)
                let chunkOverlapTokens = try container.decode(Int.self, forKey: .chunkOverlapTokens)
                self = .static(StaticChunking(maxChunkSizeTokens: maxChunkSizeTokens, chunkOverlapTokens: chunkOverlapTokens))
            } else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid chunking strategy type")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .auto:
                try container.encode("auto", forKey: .type)
            case .static(let staticChunking):
                try container.encode(staticChunking.type, forKey: .type)
                try container.encode(staticChunking.maxChunkSizeTokens, forKey: .maxChunkSizeTokens)
                try container.encode(staticChunking.chunkOverlapTokens, forKey: .chunkOverlapTokens)
            }
        }

        public static func == (lhs: ChunkingStrategy, rhs: ChunkingStrategy) -> Bool {
            switch (lhs, rhs) {
            case (.auto, .auto):
                return true
            case (.static(let lhsValue), .static(let rhsValue)):
                return lhsValue == rhsValue
            default:
                return false
            }
        }
    }

    public init(name: String? = nil,
                fileIDs: [String]? = nil,
                expiresAfter: ExpiresAfter? = nil,
                chunkingStrategy: ChunkingStrategy? = nil,
                metadata: [String: String]? = nil) {
        self.name = name
        self.fileIDs = fileIDs
        self.expiresAfter = expiresAfter
        self.chunkingStrategy = chunkingStrategy
        self.metadata = metadata
    }

    public static func == (lhs: VectorStoreQuery, rhs: VectorStoreQuery) -> Bool {
        return lhs.name == rhs.name &&
               lhs.metadata == rhs.metadata &&
               lhs.fileIDs == rhs.fileIDs &&
               lhs.expiresAfter == rhs.expiresAfter &&
               lhs.chunkingStrategy == rhs.chunkingStrategy
    }
}
