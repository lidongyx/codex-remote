// FILE: CodexV2PreviewProtoCodec.swift
// Purpose: Minimal protobuf encoder/decoder for the Version 2.0 preview transport inside the iOS app snapshot.
// Layer: Service support
// Exports: CodexV2PreviewProtoCodec

import Foundation

enum CodexV2PreviewProtoCodecError: Error {
    case malformedFrame
    case unsupportedWireType(Int)
    case unsupportedServerPayload
}

private enum CodexV2WireType: Int {
    case varint = 0
    case lengthDelimited = 2
}

enum CodexV2PreviewProtoCodec {
    static func makeSessionResumeFrame(
        macDeviceID: String,
        phoneDeviceID: String,
        globalSequence: UInt64 = 0
    ) -> Data {
        let inner = CodexV2ProtoWriter()
            .string(field: 1, value: macDeviceID)
            .string(field: 2, value: phoneDeviceID)
            .uint64(field: 3, value: globalSequence)
            .build()

        return CodexV2ProtoWriter()
            .message(field: 2, payload: inner)
            .build()
    }

    static func makeThreadListRequestFrame(sinceGlobalSequence: UInt64 = 0) -> Data {
        let inner = CodexV2ProtoWriter()
            .uint64(field: 1, value: sinceGlobalSequence)
            .build()

        return CodexV2ProtoWriter()
            .message(field: 10, payload: inner)
            .build()
    }

    static func makeRunStartRequestFrame(threadID: String = "", text: String) -> Data {
        let inner = CodexV2ProtoWriter()
            .string(field: 1, value: threadID)
            .string(field: 2, value: text)
            .build()

        return CodexV2ProtoWriter()
            .message(field: 20, payload: inner)
            .build()
    }

    static func makeRunInterruptRequestFrame(threadID: String, turnID: String) -> Data {
        let inner = CodexV2ProtoWriter()
            .string(field: 1, value: threadID)
            .string(field: 2, value: turnID)
            .build()

        return CodexV2ProtoWriter()
            .message(field: 21, payload: inner)
            .build()
    }

    static func makeThreadCatchUpRequestFrame(
        threadID: String,
        sinceThreadSequence: UInt64 = 0
    ) -> Data {
        let inner = CodexV2ProtoWriter()
            .string(field: 1, value: threadID)
            .uint64(field: 2, value: sinceThreadSequence)
            .build()

        return CodexV2ProtoWriter()
            .message(field: 11, payload: inner)
            .build()
    }

    static func decodeServerFrame(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        guard let topLevel = try reader.nextField() else {
            throw CodexV2PreviewProtoCodecError.malformedFrame
        }

        switch (topLevel.fieldNumber, topLevel.wireType) {
        case (2, .lengthDelimited):
            return try decodeSessionReady(topLevel.payload)
        case (10, .lengthDelimited):
            return try decodeThreadListSnapshot(topLevel.payload)
        case (11, .lengthDelimited):
            return try decodeThreadCatchUpBatch(topLevel.payload)
        case (20, .lengthDelimited):
            return try decodeRunEvent(topLevel.payload)
        case (21, .lengthDelimited):
            return try decodeRunCompletion(topLevel.payload)
        case (98, .lengthDelimited):
            return try decodeError(topLevel.payload)
        default:
            throw CodexV2PreviewProtoCodecError.unsupportedServerPayload
        }
    }

    private static func decodeSessionReady(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var sessionID = ""
        var connectionMode = ""
        var globalSequence: UInt64 = 0

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): sessionID = field.payload.stringValue
            case (2, .lengthDelimited): connectionMode = field.payload.stringValue
            case (3, .varint): globalSequence = field.varintValue
            default: break
            }
        }

        return .sessionReady(
            sessionID: sessionID,
            connectionMode: connectionMode,
            globalSequence: globalSequence
        )
    }

    private static func decodeThreadListSnapshot(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var globalSequence: UInt64 = 0
        var threads: [CodexV2ThreadSummary] = []

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .varint): globalSequence = field.varintValue
            case (2, .lengthDelimited):
                threads.append(try decodeThreadSummary(field.payload))
            default: break
            }
        }

        return .threadListSnapshot(globalSequence: globalSequence, threads: threads)
    }

    private static func decodeThreadSummary(_ data: Data) throws -> CodexV2ThreadSummary {
        var reader = CodexV2ProtoReader(data: data)
        var threadID = ""
        var title = ""
        var preview = ""
        var updatedAtMs: UInt64 = 0
        var isRunning = false

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): threadID = field.payload.stringValue
            case (2, .lengthDelimited): title = field.payload.stringValue
            case (3, .lengthDelimited): preview = field.payload.stringValue
            case (4, .varint): updatedAtMs = field.varintValue
            case (5, .varint): isRunning = field.varintValue != 0
            default: break
            }
        }

        return CodexV2ThreadSummary(
            threadID: threadID,
            title: title,
            preview: preview,
            updatedAtMs: updatedAtMs,
            isRunning: isRunning
        )
    }

    private static func decodeRunEvent(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var threadID = ""
        var turnID = ""
        var globalSequence: UInt64 = 0
        var payloadFieldNumber = 0
        var payloadData = Data()

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): threadID = field.payload.stringValue
            case (2, .lengthDelimited): turnID = field.payload.stringValue
            case (3, .varint): globalSequence = field.varintValue
            case (10, .lengthDelimited), (11, .lengthDelimited), (14, .lengthDelimited):
                payloadFieldNumber = field.fieldNumber
                payloadData = field.payload
            default: break
            }
        }

        switch payloadFieldNumber {
        case 10:
            var payloadReader = CodexV2ProtoReader(data: payloadData)
            var model = ""
            while let field = try payloadReader.nextField() {
                if field.fieldNumber == 1, field.wireType == .lengthDelimited {
                    model = field.payload.stringValue
                }
            }
            return .runStarted(
                threadID: threadID,
                turnID: turnID,
                globalSequence: globalSequence,
                model: model
            )
        case 11:
            var payloadReader = CodexV2ProtoReader(data: payloadData)
            var itemID = ""
            var delta = ""
            while let field = try payloadReader.nextField() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .lengthDelimited): itemID = field.payload.stringValue
                case (2, .lengthDelimited): delta = field.payload.stringValue
                default: break
                }
            }
            return .reasoning(
                threadID: threadID,
                turnID: turnID,
                globalSequence: globalSequence,
                itemID: itemID,
                delta: delta
            )
        case 14:
            var payloadReader = CodexV2ProtoReader(data: payloadData)
            var delta = ""
            while let field = try payloadReader.nextField() {
                if field.fieldNumber == 1, field.wireType == .lengthDelimited {
                    delta = field.payload.stringValue
                }
            }
            return .assistantText(
                threadID: threadID,
                turnID: turnID,
                globalSequence: globalSequence,
                delta: delta
            )
        default:
            throw CodexV2PreviewProtoCodecError.unsupportedServerPayload
        }
    }

    private static func decodeRunCompletion(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var threadID = ""
        var turnID = ""
        var globalSequence: UInt64 = 0
        var result = ""
        var errorMessage = ""

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): threadID = field.payload.stringValue
            case (2, .lengthDelimited): turnID = field.payload.stringValue
            case (3, .varint): globalSequence = field.varintValue
            case (4, .lengthDelimited): result = field.payload.stringValue
            case (5, .lengthDelimited): errorMessage = field.payload.stringValue
            default: break
            }
        }

        return .runCompletion(
            threadID: threadID,
            turnID: turnID,
            globalSequence: globalSequence,
            result: result,
            errorMessage: errorMessage
        )
    }

    private static func decodeThreadCatchUpBatch(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var threadID = ""
        var latestThreadSequence: UInt64 = 0
        var eventCount = 0
        var hasMore = false

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): threadID = field.payload.stringValue
            case (2, .varint): latestThreadSequence = field.varintValue
            case (3, .lengthDelimited): eventCount += 1
            case (4, .varint): hasMore = field.varintValue != 0
            default: break
            }
        }

        return .threadCatchUpBatch(
            threadID: threadID,
            latestThreadSequence: latestThreadSequence,
            eventCount: eventCount,
            hasMore: hasMore
        )
    }

    private static func decodeError(_ data: Data) throws -> CodexV2ServerFrame {
        var reader = CodexV2ProtoReader(data: data)
        var code = ""
        var message = ""
        var retryable = false

        while let field = try reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited): code = field.payload.stringValue
            case (2, .lengthDelimited): message = field.payload.stringValue
            case (3, .varint): retryable = field.varintValue != 0
            default: break
            }
        }

        return .error(code: code, message: message, retryable: retryable)
    }
}

private struct CodexV2ProtoWriter {
    private(set) var data = Data()

    func string(field: Int, value: String) -> CodexV2ProtoWriter {
        var copy = self
        guard let valueData = value.data(using: .utf8) else { return copy }
        copy.appendKey(field: field, wireType: .lengthDelimited)
        copy.appendVarint(UInt64(valueData.count))
        copy.data.append(valueData)
        return copy
    }

    func uint64(field: Int, value: UInt64) -> CodexV2ProtoWriter {
        var copy = self
        copy.appendKey(field: field, wireType: .varint)
        copy.appendVarint(value)
        return copy
    }

    func message(field: Int, payload: Data) -> CodexV2ProtoWriter {
        var copy = self
        copy.appendKey(field: field, wireType: .lengthDelimited)
        copy.appendVarint(UInt64(payload.count))
        copy.data.append(payload)
        return copy
    }

    func build() -> Data {
        data
    }

    private mutating func appendKey(field: Int, wireType: CodexV2WireType) {
        appendVarint(UInt64((field << 3) | wireType.rawValue))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while true {
            if remaining < 0x80 {
                data.append(UInt8(remaining))
                return
            } else {
                data.append(UInt8((remaining & 0x7f) | 0x80))
                remaining >>= 7
            }
        }
    }
}

private struct CodexV2ProtoField {
    let fieldNumber: Int
    let wireType: CodexV2WireType
    let payload: Data
    let varintValue: UInt64
}

private struct CodexV2ProtoReader {
    private let data: Data
    private var index: Data.Index

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func nextField() throws -> CodexV2ProtoField? {
        guard index < data.endIndex else {
            return nil
        }

        let key = try readVarint()
        let fieldNumber = Int(key >> 3)
        guard let wireType = CodexV2WireType(rawValue: Int(key & 0x07)) else {
            throw CodexV2PreviewProtoCodecError.unsupportedWireType(Int(key & 0x07))
        }

        switch wireType {
        case .varint:
            let value = try readVarint()
            return CodexV2ProtoField(
                fieldNumber: fieldNumber,
                wireType: wireType,
                payload: Data(),
                varintValue: value
            )
        case .lengthDelimited:
            let length = Int(try readVarint())
            guard index <= data.endIndex, data.distance(from: index, to: data.endIndex) >= length else {
                throw CodexV2PreviewProtoCodecError.malformedFrame
            }
            let payload = data[index..<data.index(index, offsetBy: length)]
            index = data.index(index, offsetBy: length)
            return CodexV2ProtoField(
                fieldNumber: fieldNumber,
                wireType: wireType,
                payload: Data(payload),
                varintValue: 0
            )
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                throw CodexV2PreviewProtoCodecError.malformedFrame
            }
        }

        throw CodexV2PreviewProtoCodecError.malformedFrame
    }
}

private extension Data {
    var stringValue: String {
        String(data: self, encoding: .utf8) ?? ""
    }
}
