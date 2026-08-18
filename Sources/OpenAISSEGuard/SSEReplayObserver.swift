import Foundation

/// The wire shape inferred from event names and a small amount of JSON text.
public enum SSEProtocolHint: String, Equatable, Sendable {
    case chatCompletions = "chat_completions"
    case responses
    case unknown
}

/// The evidence observed at the end of a stream.
public enum SSEStreamTermination: String, Equatable, Sendable {
    case open
    case done
    case incomplete
    case error
    case unexpectedEOF = "unexpected_eof"
}

/// Memory and event bounds applied to every observer.
public struct SSEReplayOptions: Equatable, Sendable {
    public let maxFrameBytes: Int
    public let maxEvents: Int

    public init(maxFrameBytes: Int = 64 * 1024, maxEvents: Int = 10_000) {
        self.maxFrameBytes = Self.clamp(maxFrameBytes, minimum: 256, maximum: 4 * 1024 * 1024)
        self.maxEvents = Self.clamp(maxEvents, minimum: 1, maximum: 1_000_000)
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        min(max(value, minimum), maximum)
    }
}

/// Bounded metadata that can be persisted with an HTTP attempt.
public struct SSESnapshot: Equatable, Sendable {
    public let protocolHint: SSEProtocolHint
    public let termination: SSEStreamTermination
    public let hasOutput: Bool
    public let sawTerminalEvent: Bool
    public let eventCount: Int
    public let malformedEventCount: Int
    public let lastEventType: String?
    public let errorCode: String?

    public init(
        protocolHint: SSEProtocolHint,
        termination: SSEStreamTermination,
        hasOutput: Bool,
        sawTerminalEvent: Bool,
        eventCount: Int,
        malformedEventCount: Int,
        lastEventType: String?,
        errorCode: String?
    ) {
        self.protocolHint = protocolHint
        self.termination = termination
        self.hasOutput = hasOutput
        self.sawTerminalEvent = sawTerminalEvent
        self.eventCount = eventCount
        self.malformedEventCount = malformedEventCount
        self.lastEventType = lastEventType
        self.errorCode = errorCode
    }
}

/// An incremental, dependency-free observer for OpenAI-compatible SSE.
///
/// The observer recognizes SSE event blocks, tolerates network chunks that
/// split UTF-8 code points, and fails closed when an input bound is exceeded.
/// It never stores generated text after a frame is consumed and never makes
/// HTTP requests or decides whether a caller should retry.
public struct SSEReplayObserver: Sendable {
    private struct ParsedEvent {
        let eventType: String?
        let data: String
    }

    private static let maxIdentifierLength = 96
    private static let eventBoundaries: [[UInt8]] = [
        [13, 10, 13, 10], // CRLF CRLF
        [13, 10, 10],     // CRLF LF
        [13, 10, 13],     // CRLF CR
        [10, 13, 10],     // LF CRLF
        [10, 10],         // LF LF
        [10, 13],         // LF CR
        [13, 13, 10],     // CR CRLF
        [13, 13]          // CR CR
    ]

    private let options: SSEReplayOptions
    private var buffer: [UInt8] = []
    private var protocolHint: SSEProtocolHint = .unknown
    private var termination: SSEStreamTermination = .open
    private var hasOutput = false
    private var sawTerminalEvent = false
    private var eventCount = 0
    private var malformedEventCount = 0
    private var lastEventType: String?
    private var errorCode: String?
    private var finished = false

    public init(options: SSEReplayOptions = .init()) {
        self.options = options
    }

    /// Adds a transport chunk. Chunk boundaries do not need to align with SSE lines.
    public mutating func push(_ chunk: Data) {
        push(Array(chunk))
    }

    /// Adds raw bytes without retaining them after the corresponding event is consumed.
    public mutating func push(_ bytes: [UInt8]) {
        guard !finished, termination == .open, !bytes.isEmpty else { return }
        buffer.append(contentsOf: bytes)
        drainFrames()
    }

    /// Flushes the observer. An absent terminal event is conservative `unexpectedEOF`.
    public mutating func finish() -> SSESnapshot {
        guard !finished else { return snapshot() }

        drainFrames()

        if termination == .open {
            if String(bytes: buffer, encoding: .utf8) == nil {
                fail()
            } else if !buffer.isEmpty {
                // A partial line can still represent visible or billable output.
                hasOutput = true
                buffer.removeAll(keepingCapacity: false)
            }
        }

        if termination == .open {
            termination = .unexpectedEOF
        }

        finished = true
        return snapshot()
    }

    /// Observes a sequence of `Data` chunks and returns its final bounded snapshot.
    public static func observe<C: Sequence>(
        _ chunks: C,
        options: SSEReplayOptions = .init()
    ) -> SSESnapshot where C.Element == Data {
        var observer = Self(options: options)

        for chunk in chunks {
            observer.push(chunk)
            if observer.termination == .error { break }
        }

        return observer.finish()
    }

    private func snapshot() -> SSESnapshot {
        SSESnapshot(
            protocolHint: protocolHint,
            termination: termination,
            hasOutput: hasOutput,
            sawTerminalEvent: sawTerminalEvent,
            eventCount: eventCount,
            malformedEventCount: malformedEventCount,
            lastEventType: lastEventType,
            errorCode: errorCode
        )
    }

    private mutating func drainFrames() {
        while termination == .open {
            guard let boundary = Self.findBoundary(in: buffer) else {
                if buffer.count > options.maxFrameBytes { fail() }
                return
            }

            if boundary.index > options.maxFrameBytes {
                fail()
                return
            }

            let frame = Array(buffer[..<boundary.index])
            buffer = Array(buffer.dropFirst(boundary.index + boundary.length))
            consume(frame)
        }
    }

    private static func findBoundary(in bytes: [UInt8]) -> (index: Int, length: Int)? {
        var best: (index: Int, length: Int)?

        for index in bytes.indices {
            for pattern in eventBoundaries {
                guard index + pattern.count <= bytes.count else { continue }

                var matches = true
                for offset in pattern.indices where bytes[index + offset] != pattern[offset] {
                    matches = false
                    break
                }

                guard matches else { continue }

                if best == nil
                    || index < best!.index
                    || (index == best!.index && pattern.count > best!.length)
                {
                    best = (index, pattern.count)
                }
            }
        }

        return best
    }

    private mutating func consume(_ frame: [UInt8]) {
        guard eventCount < options.maxEvents else {
            fail()
            return
        }

        eventCount += 1

        guard let parsed = Self.parse(frame) else {
            fail()
            return
        }

        let eventType = Self.boundedIdentifier(parsed.eventType)
        protocolHint = Self.inferProtocol(current: protocolHint, eventType: eventType, data: parsed.data)
        lastEventType = eventType

        if errorCode == nil {
            errorCode = Self.extractErrorCode(from: parsed.data)
        }

        if parsed.data == "[DONE]" {
            if protocolHint == .unknown { protocolHint = .chatCompletions }
            termination = .done
            sawTerminalEvent = true
        } else if eventType == "response.incomplete" || eventType == "response.incomplete_event" {
            termination = .incomplete
            sawTerminalEvent = true
            hasOutput = hasOutput || !parsed.data.isEmpty
        } else if eventType == "response.completed" || eventType == "response.complete" {
            termination = .done
            sawTerminalEvent = true
            hasOutput = hasOutput || !parsed.data.isEmpty
        } else if eventType == "error" || parsed.data.contains("\"error\"") {
            termination = .error
            hasOutput = true
        } else {
            hasOutput = hasOutput || !parsed.data.isEmpty || eventType != nil
        }
    }

    private static func parse(_ frame: [UInt8]) -> ParsedEvent? {
        guard let text = String(bytes: frame, encoding: .utf8) else { return nil }

        var eventType: String?
        var dataLines: [String] = []
        let lines = text.split(
            whereSeparator: { $0 == "\n" || $0 == "\r" },
            omittingEmptySubsequences: false
        )

        for rawLine in lines {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.first == " " { value.removeFirst() }

            switch field {
            case "event":
                eventType = value
            case "data":
                dataLines.append(value)
            default:
                // SSE id/retry fields do not affect replay safety evidence.
                continue
            }
        }

        return ParsedEvent(eventType: eventType, data: dataLines.joined(separator: "\n"))
    }

    private static func inferProtocol(
        current: SSEProtocolHint,
        eventType: String?,
        data: String
    ) -> SSEProtocolHint {
        guard current == .unknown else { return current }
        if eventType?.hasPrefix("response.") == true { return .responses }
        if data.contains("\"choices\"") || data == "[DONE]" { return .chatCompletions }
        return .unknown
    }

    private static func extractErrorCode(from data: String) -> String? {
        for key in ["\"code\"", "\"type\""] {
            guard let keyRange = data.range(of: key) else { continue }
            let afterKey = data[keyRange.upperBound...]
            guard let colon = afterKey.firstIndex(of: ":") else { continue }

            var value = afterKey[afterKey.index(after: colon)...]
            while value.first == " " { value = value.dropFirst() }
            guard value.first == "\"" else { continue }
            value = value.dropFirst()
            guard let end = value.firstIndex(of: "\"") else { continue }

            return boundedIdentifier(String(value[..<end]))
        }

        return nil
    }

    private static func boundedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }

        var result = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isAllowed = (code >= 48 && code <= 57)
                || (code >= 65 && code <= 90)
                || (code >= 97 && code <= 122)
                || code == 95 || code == 46 || code == 58 || code == 45

            guard isAllowed else { continue }
            result.unicodeScalars.append(scalar)
            if result.unicodeScalars.count == maxIdentifierLength { break }
        }

        return result.isEmpty ? nil : result
    }

    private mutating func fail() {
        buffer.removeAll(keepingCapacity: false)
        termination = .error
        hasOutput = true
        malformedEventCount += 1
        finished = true
    }
}
