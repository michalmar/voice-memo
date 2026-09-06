import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case created, recording, uploading, transcribing, refining, completed, failed
}

public struct CreateSessionRequest: Codable, Sendable {
    public let id: UUID
    public let audioFormat: String
    public let locale: String

    public init(id: UUID, audioFormat: String = "m4a", locale: String = "cs-CZ") {
        self.id = id
        self.audioFormat = audioFormat
        self.locale = locale
    }

    enum CodingKeys: String, CodingKey {
        case id, locale
        case audioFormat = "audio_format"
    }
}

public struct CompleteSessionRequest: Codable, Sendable {
    public let expectedSegmentCount: Int
    public init(expectedSegmentCount: Int) { self.expectedSegmentCount = expectedSegmentCount }

    enum CodingKeys: String, CodingKey {
        case expectedSegmentCount = "expected_segment_count"
    }
}

public struct Session: Codable, Identifiable, Sendable {
    public let id: UUID
    public let status: SessionStatus
    public let acceptedSegments: [Int]
    public let expectedSegmentCount: Int?
    public let errorCode: String?
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case acceptedSegments = "accepted_segments"
        case expectedSegmentCount = "expected_segment_count"
        case errorCode = "error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct TranscriptSummary: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let createdAt: Date
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public struct Transcript: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let markdown: String

    enum CodingKeys: String, CodingKey {
        case id, markdown
        case sessionID = "session_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public struct TranscriptList: Codable, Sendable {
    public let items: [TranscriptSummary]
}

public struct EventToken: Codable, Sendable {
    public let url: URL
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
    }
}

public struct ChunkMetadata: Codable, Identifiable, Equatable, Sendable {
    public let sessionID: UUID
    public let sequence: Int
    public let startedMilliseconds: Int
    public let durationMilliseconds: Int
    public let byteLength: Int
    public let checksum: String
    public let fileURL: URL
    public var attempts: Int

    public init(
        sessionID: UUID,
        sequence: Int,
        startedMilliseconds: Int,
        durationMilliseconds: Int,
        byteLength: Int,
        checksum: String,
        fileURL: URL,
        attempts: Int
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.startedMilliseconds = startedMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.byteLength = byteLength
        self.checksum = checksum
        self.fileURL = fileURL
        self.attempts = attempts
    }

    public var id: String { "\(sessionID.uuidString)-\(sequence)" }
}
