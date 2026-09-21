import Foundation

struct JSONLReadResult {
    var malformedLineCount = 0
    var finalOffset: UInt64 = 0
}

enum JSONLReader {
    static func readObjects(
        at url: URL,
        fromOffset: UInt64 = 0,
        shouldParse: ((Data.SubSequence) -> Bool)? = nil,
        handler: ([String: Any]) -> Void
    ) throws -> JSONLReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if fromOffset > 0 {
            try handle.seek(toOffset: fromOffset)
        }

        var buffer = Data()
        var lineStart = buffer.startIndex
        var searchStart = buffer.startIndex
        var result = JSONLReadResult(finalOffset: fromOffset)
        var isDiscardingLongLine = false

        while true {
            var reachedEnd = false
            try autoreleasepool {
                guard let readChunk = try handle.read(upToCount: 64 * 1024), !readChunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                result.finalOffset += UInt64(readChunk.count)
                var chunk = readChunk
                if isDiscardingLongLine {
                    guard let newline = chunk.firstIndex(of: 0x0A) else { return }
                    chunk = Data(chunk[chunk.index(after: newline)...])
                    isDiscardingLongLine = false
                    if chunk.isEmpty { return }
                }
                buffer.append(chunk)
                while searchStart < buffer.endIndex,
                      let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                    let line = buffer[lineStart..<newline]
                    if shouldParse?(line) ?? true {
                        parseLine(Data(line), result: &result, handler: handler)
                    }
                    lineStart = buffer.index(after: newline)
                    searchStart = lineStart
                }

                // Avoid repeatedly shifting the entire remaining buffer for every line.
                // Compact only after a sizeable parsed prefix has accumulated.
                if lineStart >= 1_048_576 {
                    buffer.removeSubrange(buffer.startIndex..<lineStart)
                    lineStart = buffer.startIndex
                    searchStart = buffer.startIndex
                } else {
                    searchStart = buffer.endIndex
                }

                if let shouldParse,
                   buffer.distance(from: lineStart, to: buffer.endIndex) >= 64 * 1024,
                   !shouldParse(buffer[lineStart...]) {
                    buffer.removeAll(keepingCapacity: false)
                    lineStart = buffer.startIndex
                    searchStart = buffer.startIndex
                    isDiscardingLongLine = true
                }
            }
            if reachedEnd { break }
        }

        if !isDiscardingLongLine, lineStart < buffer.endIndex {
            let line = buffer[lineStart...]
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                if shouldParse?(line) ?? true { handler(object) }
            } else if line.contains(where: { ![0x20, 0x09, 0x0D].contains($0) }) {
                // An active writer may not have finished this line. Retry from its start.
                result.finalOffset -= UInt64(line.count)
            }
        }

        return result
    }

    /// Reads complete JSONL records from newest to oldest and stops when the
    /// handler returns false. This avoids scanning years of tool output when a
    /// caller only needs the latest few events.
    static func readObjectsFromEnd(
        at url: URL,
        handler: ([String: Any]) -> Bool
    ) throws -> JSONLReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var position = try handle.seekToEnd()
        var leadingPartialLine = Data()
        var result = JSONLReadResult()
        var shouldContinue = true

        while position > 0 && shouldContinue {
            let readSize = min(UInt64(256 * 1024), position)
            position -= readSize
            try handle.seek(toOffset: position)
            var buffer = try handle.read(upToCount: Int(readSize)) ?? Data()
            buffer.append(leadingPartialLine)

            let completeStart: Data.Index
            if position > 0 {
                guard let firstNewline = buffer.firstIndex(of: 0x0A) else {
                    leadingPartialLine = buffer
                    continue
                }
                leadingPartialLine = Data(buffer[..<firstNewline])
                completeStart = buffer.index(after: firstNewline)
            } else {
                leadingPartialLine.removeAll(keepingCapacity: false)
                completeStart = buffer.startIndex
            }

            var lineEnd = buffer.endIndex
            while lineEnd > completeStart && shouldContinue {
                let searchRange = buffer[completeStart..<lineEnd]
                if let newline = searchRange.lastIndex(of: 0x0A) {
                    let lineStart = buffer.index(after: newline)
                    shouldContinue = parseLineFromEnd(
                        Data(buffer[lineStart..<lineEnd]),
                        result: &result,
                        handler: handler
                    )
                    lineEnd = newline
                } else {
                    shouldContinue = parseLineFromEnd(
                        Data(buffer[completeStart..<lineEnd]),
                        result: &result,
                        handler: handler
                    )
                    lineEnd = completeStart
                }
            }
        }

        return result
    }

    private static func parseLine(
        _ data: Data,
        result: inout JSONLReadResult,
        handler: ([String: Any]) -> Void
    ) {
        guard data.contains(where: { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0D
        }) else { return }

        autoreleasepool {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    result.malformedLineCount += 1
                    return
                }
                handler(dictionary)
            } catch {
                result.malformedLineCount += 1
            }
        }
    }

    private static func parseLineFromEnd(
        _ data: Data,
        result: inout JSONLReadResult,
        handler: ([String: Any]) -> Bool
    ) -> Bool {
        guard data.contains(where: { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0D
        }) else { return true }

        return autoreleasepool {
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    result.malformedLineCount += 1
                    return true
                }
                return handler(dictionary)
            } catch {
                result.malformedLineCount += 1
                return true
            }
        }
    }
}

enum ConversationText {
    static func preview(_ value: String, limit: Int = 600) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    static func title(from value: String?) -> String {
        guard let value = value.flatMap({ preview($0, limit: 90) }) else {
            return "未命名会话"
        }
        return value.replacingOccurrences(of: "\n", with: " ")
    }
}

enum ConversationDate {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 10_000_000_000
                ? number.doubleValue / 1_000
                : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        return fractionalFormatter.date(from: string) ?? standardFormatter.date(from: string)
    }
}
