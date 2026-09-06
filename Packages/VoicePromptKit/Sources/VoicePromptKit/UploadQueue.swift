import Foundation

public actor UploadQueue {
    public enum QueueError: Error { case attemptsExhausted }

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var chunks: [ChunkMetadata]

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let index = directory.appending(path: "queue.json")
        chunks = (try? decoder.decode([ChunkMetadata].self, from: Data(contentsOf: index))) ?? []
    }

    public func enqueue(_ metadata: ChunkMetadata) throws {
        if !chunks.contains(where: { $0.id == metadata.id }) {
            chunks.append(metadata)
            try persist()
        }
    }

    public func pending() -> [ChunkMetadata] { chunks }

    public func drain(using client: APIClient, maxAttempts: Int = 5) async throws {
        while let next = chunks.first {
            do {
                try await client.upload(next)
                try? FileManager.default.removeItem(at: next.fileURL)
                chunks.removeFirst()
                try persist()
            } catch {
                chunks[0].attempts += 1
                try persist()
                guard chunks[0].attempts < maxAttempts else { throw QueueError.attemptsExhausted }
                let delay = min(30.0, pow(2.0, Double(chunks[0].attempts)))
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func persist() throws {
        let data = try encoder.encode(chunks)
        #if os(iOS)
        try data.write(to: directory.appending(path: "queue.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appending(path: "queue.json"), options: .atomic)
        #endif
    }
}
