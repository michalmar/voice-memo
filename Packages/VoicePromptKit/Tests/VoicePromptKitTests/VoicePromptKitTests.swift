import Foundation
import Testing
@testable import VoicePromptKit

@Test func chunkIdentityIsStable() {
    let id = UUID()
    let chunk = ChunkMetadata(
        sessionID: id,
        sequence: 3,
        startedMilliseconds: 90_000,
        durationMilliseconds: 30_000,
        byteLength: 42,
        checksum: String(repeating: "a", count: 64),
        fileURL: URL(fileURLWithPath: "/tmp/chunk.m4a"),
        attempts: 0
    )
    #expect(chunk.id == "\(id.uuidString)-3")
}

@Test func queuePersistsAcrossLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let file = directory.appending(path: "chunk.m4a")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: file)
    let value = ChunkMetadata(
        sessionID: UUID(), sequence: 0, startedMilliseconds: 0,
        durationMilliseconds: 1, byteLength: 5,
        checksum: String(repeating: "b", count: 64), fileURL: file, attempts: 0
    )
    let first = try UploadQueue(directory: directory)
    try await first.enqueue(value)
    let restored = try UploadQueue(directory: directory)
    #expect(await restored.pending() == [value])
}
