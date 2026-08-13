import CryptoKit
import Foundation

struct UsageSourceFileMetadata: Equatable, Sendable {
    let size: Int64
    let modifiedAtMilliseconds: Int64
    let identity: String
}

enum UsageImportSupportError: Error, Equatable {
    case invalidFileSize
    case invalidTimestamp(String)
    case invalidCost(Double)
}

enum UsageSourceIdentity {
    static func sourceKey(agent: UsageAgent, url: URL) -> String {
        digest("\(agent.rawValue)|\(url.standardizedFileURL.path)")
    }

    static func eventID(_ value: String) -> String {
        digest(value)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(for url: URL, fileManager: FileManager = .default) throws -> UsageSourceFileMetadata {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw UsageImportSupportError.invalidFileSize
        }

        let modifiedAt = (attributes[.modificationDate] as? Date) ?? .distantPast
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "unknown-device"
        let file = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "unknown-file"

        return UsageSourceFileMetadata(
            size: sizeNumber.int64Value,
            modifiedAtMilliseconds: UsageEpoch.milliseconds(modifiedAt),
            identity: "\(device):\(file)"
        )
    }
}

struct JSONLRecord: Sendable {
    let byteOffset: Int64
    let data: Data
}

struct JSONLReadResult: Sendable {
    let records: [JSONLRecord]
    let nextByteOffset: Int64
}

enum JSONLIncrementalReader {
    static func read(url: URL, from startOffset: Int64) throws -> JSONLReadResult {
        guard startOffset >= 0 else {
            throw UsageImportSupportError.invalidFileSize
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(startOffset))
        let chunk = try handle.readToEnd() ?? Data()

        var records: [JSONLRecord] = []
        var lineStart = 0

        for (relativeOffset, byte) in chunk.enumerated() where byte == 0x0A {
            let line = chunk.subdata(in: lineStart..<relativeOffset)
            if !line.isEmpty {
                records.append(
                    JSONLRecord(
                        byteOffset: startOffset + Int64(lineStart),
                        data: line
                    )
                )
            }
            lineStart = relativeOffset + 1
        }

        return JSONLReadResult(
            records: records,
            nextByteOffset: startOffset + Int64(lineStart)
        )
    }
}

enum UsageTimestampParser {
    static func milliseconds(from value: String) throws -> Int64 {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return UsageEpoch.milliseconds(date)
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        if let date = wholeSeconds.date(from: value) {
            return UsageEpoch.milliseconds(date)
        }

        throw UsageImportSupportError.invalidTimestamp(value)
    }
}

enum UsageEpoch {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

enum UsageMoney {
    static let nanodollarsPerDollar = Decimal(1_000_000_000)

    static func nanodollars(fromUSD value: Double?) throws -> Int64? {
        guard let value else {
            return nil
        }
        guard value.isFinite, value >= 0 else {
            throw UsageImportSupportError.invalidCost(value)
        }

        let scaled = Decimal(value) * nanodollarsPerDollar
        let number = NSDecimalNumber(decimal: scaled)
        guard number != .notANumber else {
            throw UsageImportSupportError.invalidCost(value)
        }
        return number.int64Value
    }

    static func usd(fromNanodollars value: Int64) -> Decimal {
        Decimal(value) / nanodollarsPerDollar
    }
}

extension Collection where Element == Int64 {
    func checkedSum() -> Int64? {
        var total: Int64 = 0
        for value in self {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }
}

protocol UsageSourceImporter: Sendable {
    var agent: UsageAgent { get }
    var importerVersion: Int { get }

    func importBatch(checkpoints: [String: UsageImportCheckpoint]) throws -> UsageImportBatch
}

struct PreparedJSONLSource: Sendable {
    let url: URL
    let sourceKey: String
    let metadata: UsageSourceFileMetadata
    let startOffset: Int64
    let resetRequired: Bool
    let priorHighWatermark: String?
}

enum UsageSourceDiscovery {
    static func jsonlFiles(below root: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func prepareJSONLSource(
        agent: UsageAgent,
        url: URL,
        checkpoint: UsageImportCheckpoint?,
        importerVersion: Int
    ) throws -> PreparedJSONLSource {
        let sourceKey = UsageSourceIdentity.sourceKey(agent: agent, url: url)
        let metadata = try UsageSourceIdentity.metadata(for: url)
        let resetRequired = checkpoint.map {
            $0.sourceIdentity != metadata.identity
                || $0.sourceSize > metadata.size
                || $0.byteOffset > metadata.size
                || $0.importerVersion != importerVersion
        } ?? false

        return PreparedJSONLSource(
            url: url,
            sourceKey: sourceKey,
            metadata: metadata,
            startOffset: resetRequired ? 0 : (checkpoint?.byteOffset ?? 0),
            resetRequired: resetRequired,
            priorHighWatermark: resetRequired ? nil : checkpoint?.highWatermark
        )
    }
}

extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }

    func int64(_ key: String) -> Int64? {
        if let number = self[key] as? NSNumber { return number.int64Value }
        if let value = self[key] as? Int64 { return value }
        if let value = self[key] as? Int { return Int64(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        return self[key] as? Double
    }
}
