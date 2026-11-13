import Foundation

/// A bounded, random-access byte source. Implementations never accept an
/// unbounded length and always validate the requested range.
protocol ByteSource: AnyObject {
    var length: Int { get }
    func read(at offset: Int, count: Int) throws -> [UInt8]
}

enum SourceReadError: Error, Hashable {
    case outOfBounds
    case readFailed
}

final class DataByteSource: ByteSource {
    let length: Int
    private let data: Data

    init(data: Data) {
        self.data = data
        self.length = data.count
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset <= length, count <= length - offset else {
            throw SourceReadError.outOfBounds
        }
        let start = data.startIndex + offset
        return Array(data[start..<(start + count)])
    }
}

final class FileByteSource: ByteSource {
    let length: Int
    private let handle: FileHandle

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let end = try handle.seekToEnd()
        guard end <= UInt64(Int.max) else {
            try? handle.close()
            throw SourceReadError.outOfBounds
        }
        self.handle = handle
        self.length = Int(end)
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset <= length, count <= length - offset else {
            throw SourceReadError.outOfBounds
        }
        guard count > 0 else { return [] }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw SourceReadError.readFailed
            }
            return Array(data)
        } catch let error as SourceReadError {
            throw error
        } catch {
            throw SourceReadError.readFailed
        }
    }
}

enum ParseFailure: Error, Hashable {
    case truncated
    case outOfBounds
    case arithmeticOverflow
    case limitExceeded
    case invalidIFD
    case unsupported
    case budgetExceeded
    case readFailure
}

extension MetadataIssue {
    init(failure: ParseFailure, context: String) {
        let kind: Kind
        switch failure {
        case .truncated:
            kind = .truncatedData
        case .outOfBounds:
            kind = .offsetOutOfBounds
        case .arithmeticOverflow:
            kind = .arithmeticOverflow
        case .limitExceeded:
            kind = .entryCountLimitExceeded
        case .invalidIFD:
            kind = .invalidIFD
        case .unsupported:
            kind = .unsupportedValueLayout
        case .budgetExceeded:
            kind = .metadataBudgetExceeded
        case .readFailure:
            kind = .readFailure
        }
        self.init(kind: kind, context: context)
    }
}

/// Adds a per-parse read budget and the configured single-read ceiling.
final class BoundedReader {
    let length: Int
    private let source: ByteSource
    private let limits: FocusMetadataReader.Limits
    private var remainingBytes: Int

    init(source: ByteSource, limits: FocusMetadataReader.Limits) {
        self.source = source
        self.length = source.length
        self.limits = limits
        self.remainingBytes = limits.maximumTotalReadBytes
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        guard count >= 0, offset >= 0, offset <= length, count <= length - offset else {
            throw ParseFailure.outOfBounds
        }
        guard count <= limits.maximumValueBytes else {
            throw ParseFailure.limitExceeded
        }
        guard count <= remainingBytes else {
            throw ParseFailure.budgetExceeded
        }
        do {
            let bytes = try source.read(at: offset, count: count)
            remainingBytes -= count
            return bytes
        } catch {
            throw ParseFailure.readFailure
        }
    }

    func u8(at offset: Int) throws -> UInt8 {
        guard let byte = try read(at: offset, count: 1).first else {
            throw ParseFailure.truncated
        }
        return byte
    }

    func u16(at offset: Int, byteOrder: TIFFByteOrder) throws -> UInt16 {
        let bytes = try read(at: offset, count: 2)
        switch byteOrder {
        case .littleEndian:
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        case .bigEndian:
            return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        }
    }

    func u32(at offset: Int, byteOrder: TIFFByteOrder) throws -> UInt32 {
        let bytes = try read(at: offset, count: 4)
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        case .bigEndian:
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
    }

    func u64(at offset: Int, byteOrder: TIFFByteOrder) throws -> UInt64 {
        let bytes = try read(at: offset, count: 8)
        var value: UInt64 = 0
        switch byteOrder {
        case .littleEndian:
            for index in stride(from: 7, through: 0, by: -1) {
                value = (value << 8) | UInt64(bytes[index])
            }
        case .bigEndian:
            for byte in bytes {
                value = (value << 8) | UInt64(byte)
            }
        }
        return value
    }
}
