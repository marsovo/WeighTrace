import Foundation

/// One weighing the B1 scale stored on-device (frame subtype 0x54), parsed
/// per the layout reverse-engineered in the OHealthBridge project and
/// cross-checked against this project's captures; see docs/PROTOCOL-B1.md.
struct AFUStoredRecord: Equatable {
    /// Low 2 bits of the meta byte; the scale's own record classification.
    let historyType: Int
    /// Bits 2...7 of the meta byte; echoed back in the acknowledgement frame.
    let sequence: Int
    let date: Date
    /// Locked weight in kilograms.
    let weight: Double
    /// Resistance in ohms; 0 when the stored weighing has none (e.g. socks).
    let impedance: Double
    let locked: Bool
}

struct AFUPacket {
    enum Kind { case weight, impedance, history, settings, stored, control }
    let type: Kind; let raw: Data

    init?(data: Data) {
        // B1 (AFU-BH-TZ-B1, 薄荷平台): frames start with 0xAF and carry a subtype
        // byte at index 18 — 0x51 = measurement frame, 0x52 = status frame,
        // 0x54 = stored record, 0x5F = control frame.
        // Reverse-engineered 2026-10-26; see docs/PROTOCOL-B1.md.
        if data.count >= 20, data.first == 0xAF {
            raw = data
            switch data[18] {
            case 0x51: type = .weight
            // Status frames carry the impedance value at bytes 4...5 (little-endian):
            // nonzero → treat as an impedance packet; all-zero → ignore like settings.
            case 0x52: type = (data[4] != 0 || data[5] != 0) ? .impedance : .settings
            case 0x54: type = .stored
            case 0x5F: type = .control
            default: return nil
            }
            return
        }

        guard data.count >= 20, data.first == 0xAC else {
            // Fallback for original standard AFU packets (without wrapper)
            guard let first = data.first else { return nil }
            raw = data
            switch first {
            case 0xD5: type = .weight
            case 0xD6: type = .impedance
            case 0xD8: type = .history
            case 0xDF: type = .settings
            default: return nil
            }
            return
        }
        
        raw = data
        let opcode = data[18]
        switch opcode {
        case 0xD5: type = .weight
        case 0xD6: type = .impedance
        case 0xD8: type = .history
        case 0xDF: type = .settings
        default: return nil
        }
    }
    
    private var payload32: UInt32 {
        guard raw.count >= 5 else { return 0 }
        return UInt32(raw[1]) | UInt32(raw[2]) << 8 | UInt32(raw[3]) << 16 | UInt32(raw[4]) << 24
    }
    
    var stable: Bool {
        if raw.first == 0xAF {
            // B1 measurement frames carry the locked value (verified against the scale
            // display). Byte 5's 0x80 bit is set exactly when a valid weight is present
            // (0x4880 frames) and clear in the zeroed post-measurement frame (0x4800).
            return raw.count >= 19 && raw[18] == 0x51 && weight > 0 && raw[5] & 0x80 != 0
        }
        if raw.first == 0xAC {
            // Status byte at index 6: 0x02 indicates stable
            return raw.count >= 7 && raw[6] == 0x02 && weight > 0
        } else {
            return payload32 & 0x8000_0000 != 0
        }
    }
    
    var weight: Double {
        if raw.first == 0xAF {
            // B1: weight is a little-endian UInt16 in grams at bytes 2...3
            // (verified: 0x9E34 = 40500 g at a 40.5 kg display; 0xFD20 = 64800 g at 64.80 kg).
            guard raw.count >= 4 else { return 0.0 }
            return Double(UInt16(raw[2]) | UInt16(raw[3]) << 8) / 1000.0
        }
        if raw.first == 0xAC {
            // 3-byte weight encoding: rawVal = (raw[3] - 0x68) * 65536 + raw[4] * 256 + raw[5]
            // weight(kg) = rawVal / 1000
            // e.g. 82.05kg → raw[3]=0x69, raw[4]=0x40, raw[5]=0x82 → (1*65536+0x4082)/1000=82.05
            guard raw.count >= 6, raw[3] >= 0x68 else { return 0.0 }
            let base = UInt32(raw[3] - 0x68)
            let rawVal = (base << 16) | (UInt32(raw[4]) << 8) | UInt32(raw[5])
            return Double(rawVal) / 1000.0
        } else {
            return Double(payload32 & 0x0003_FFFF) / 1000.0
        }
    }
    
    /// B1 only: true for AF000003 measurement frames (header 0xAF, subtype 0x51).
    /// Note: the bytes 6...7 field (0x021F = 543 in every capture) is a constant,
    /// NOT impedance — a socks-on weighing left it untouched, which a real BIA
    /// reading cannot survive. The real impedance rides in status frames
    /// (subtype 0x52) at bytes 4...5; see docs/PROTOCOL-B1.md.
    var isBHMeasurement: Bool {
        raw.first == 0xAF && raw.count >= 19 && raw[18] == 0x51
    }

    /// B1 status frames mark a trustworthy impedance reading with byte 2
    /// set to 0x01 (both 2026-10-26 status-frame captures show `01 00` here).
    /// Exposed for logging/acking decisions; packet classification keeps the
    /// long-standing nonzero-value rule so live behaviour cannot regress.
    var impedanceValid: Bool {
        raw.first == 0xAF && raw.count >= 20 && raw[18] == 0x52 && raw[2] == 0x01
    }

    /// B1 frame checksum: byte 19 holds (sum of bytes 2...18) & 0x1F.
    /// Verified against every frame in this project's 2026-10-26 captures
    /// (see docs/PROTOCOL-B1.md, v1.13 note). Live weight/impedance frames are
    /// still accepted when this fails (ScaleManager only logs it); stored
    /// records and control frames are trusted only when it passes.
    var checksumValid: Bool {
        guard raw.first == 0xAF, raw.count >= 20 else { return false }
        var sum = 0
        for index in 2...18 { sum += Int(raw[index]) }
        return (sum & 0x1F) == (Int(raw[19]) & 0x1F)
    }

    private func le32(at offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | UInt32(raw[offset + 1]) << 8
            | UInt32(raw[offset + 2]) << 16
            | UInt32(raw[offset + 3]) << 24
    }

    /// The stored weighing carried by a 0x54 frame; nil for other frames and
    /// for frames whose checksum does not validate.
    var storedRecord: AFUStoredRecord? {
        guard raw.first == 0xAF, raw.count >= 20, raw[18] == 0x54, checksumValid else { return nil }
        let meta = Int(raw[2])
        let flags = le32(at: 7)
        return AFUStoredRecord(
            historyType: meta & 0x03,
            sequence: (meta >> 2) & 0x3F,
            date: Date(timeIntervalSince1970: TimeInterval(le32(at: 3))),
            weight: Double(flags & 0x0003_FFFF) / 1000.0,
            impedance: Double(UInt16(raw[13]) | UInt16(raw[14]) << 8),
            locked: flags & 0x8000_0000 != 0
        )
    }

    /// True for a 0x5F control frame carrying a report chunk (command 0x14);
    /// the chunk index rides at byte 3 and must be acknowledged.
    var isReportChunk: Bool {
        raw.first == 0xAF && raw.count >= 20 && raw[18] == 0x5F && raw[2] == 0x14 && checksumValid
    }

    var adcs: [Double] {
        if raw.first == 0xAF {
            // B1: the impedance value rides in status frames (subtype 0x52) as a
            // little-endian UInt16 at bytes 4...5 — 506 Ω barefoot, 0 with socks on
            // or nobody standing (captured 2026-10-26). Returned as a single "ADC"
            // so ScaleManager's existing selection/normalization path applies.
            guard raw.count >= 6, raw[18] == 0x52 else { return [] }
            let value = UInt16(raw[4]) | UInt16(raw[5]) << 8
            return value > 0 ? [Double(value)] : []
        }
        if raw.first == 0xAC {
            guard raw.count >= 19, raw[18] == 0xD6 else { return [] }
            let count = Int(raw[2])
            let start = 4
            guard count > 0, start + count * 2 <= raw.count else { return [] }
            return (0..<count).map { index in
                let offset = start + index * 2
                return Double(UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1]))
            }
        }

        guard raw.first == 0xD6, raw.count >= 3 else { return [] }
        return [Double(UInt16(raw[1]) << 8 | UInt16(raw[2]))]
    }

    var adcWeight: Double {
        guard raw.first == 0xAC, raw.count >= 13, raw[18] == 0xD6 else { return 0 }
        let encoded = UInt32(raw[9]) << 24
            | UInt32(raw[10]) << 16
            | UInt32(raw[11]) << 8
            | UInt32(raw[12])
        return Double(encoded & 0x0003_FFFF) / 1000.0
    }

    static func normalizeImpedances(_ adcs: [Double], weight: Double) -> [Double] {
        // Single-impedance pipeline: values already arrive in ohms (the B1's
        // status-frame reading needs no conversion), so they pass through.
        adcs.map(roundToTwoPlaces)
    }

    nonisolated private static func roundToTwoPlaces(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
    
    @MainActor func historyMeasurement(profile: UserProfile?, history: [BodyMeasurement]) -> BodyMeasurement? {
        guard let profile else { return nil }
        let kg = weight
        guard kg > 0 else { return nil }
        let member = profile.matchedMember(for: kg, history: history)
        
        let imp: Double
        if raw.first == 0xAC {
            imp = raw.count >= 10 ? Double(UInt16(raw[9]) | UInt16(raw[8]) << 8) : 0
        } else {
            imp = raw.count >= 7 ? Double(UInt16(raw[5]) | UInt16(raw[6]) << 8) : 0
        }
        return BodyAlgorithm.measure(weight: kg, impedance: imp, member: member)
    }
}

/// Builders for the frames the app writes to the B1 on characteristic
/// AF000002 (v1.13). Byte layouts are a faithful port of the OHealthBridge
/// project's AfuProtocol (itself reverse-engineered from the official OPPO
/// Health flow); every frame is 20 bytes, headed AF 45, subtype at byte 18,
/// and sealed with the (sum of bytes 2...18) & 0x1F checksum at byte 19.
enum AFUCommand {
    enum ProfileVariant {
        case initial, getWeighAgain1, getWeighAgain2, final, historyDump
        var code: UInt8 {
            switch self {
            case .initial: return 0x3F
            case .getWeighAgain1: return 0x4B
            case .getWeighAgain2: return 0x5B
            case .final: return 0x68
            case .historyDump: return 0x8E
            }
        }
        var openByte: UInt8 {
            switch self {
            case .initial, .getWeighAgain1: return 0xB6
            case .getWeighAgain2, .final: return 0xD9
            case .historyDump: return 0xDE
            }
        }
    }

    private static func putLE32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func applyingChecksum(_ bytes: [UInt8]) -> Data {
        var bytes = bytes
        var sum = 0
        for index in 2...18 { sum += Int(bytes[index]) }
        bytes[19] = UInt8(sum & 0x1F)
        return Data(bytes)
    }

    private static func frame(type: UInt8, _ body: (inout [UInt8]) -> Void) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0xAF
        bytes[1] = 0x45
        bytes[18] = type
        body(&bytes)
        return applyingChecksum(bytes)
    }

    /// Clock sync (control frame, command 0x16) sent first after connecting.
    static func timeSync(epochSeconds: UInt32) -> Data {
        frame(type: 0x5F) { bytes in
            bytes[2] = 0x16
            putLE32(&bytes, at: 3, epochSeconds)
            bytes[7] = 0x20
        }
    }

    /// Two fixed sync frames (type 0x62) that follow the clock sync verbatim.
    static func syncFirst() -> Data {
        applyingChecksum([0xAF, 0x45, 0x04, 0x00, 0x01, 0xAF, 0xB6, 0x17, 0x1D, 0x01,
                          0x00, 0x02, 0xB4, 0xC6, 0x1B, 0x56, 0x01, 0x00, 0x62, 0x00])
    }

    static func syncSecond() -> Data {
        applyingChecksum([0xAF, 0x45, 0x04, 0x01, 0x03, 0xA5, 0xF8, 0x11, 0x1D, 0x02,
                          0x00, 0x04, 0xB4, 0xC6, 0x1B, 0x1D, 0x01, 0x00, 0x62, 0x00])
    }

    /// User profile frame (type 0x61). The history-dump variant asks the scale
    /// to replay its stored records as 0x54 frames.
    static func profile(
        variant: ProfileVariant,
        epochSeconds: UInt32,
        userSlot: Int,
        age: Int,
        male: Bool,
        targetKg: Double
    ) -> Data {
        frame(type: 0x61) { bytes in
            bytes[2] = variant.code
            putLE32(&bytes, at: 3, epochSeconds)
            bytes[7] = 0
            bytes[8] = UInt8(min(max(userSlot, 0), 255))
            bytes[9] = 0xAF
            bytes[10] = variant.openByte
            bytes[11] = 0x17
            bytes[12] = UInt8(min(max(age, 0), 255))
            bytes[13] = male ? 1 : 0
            let target = min(max(Int((targetKg * 100).rounded()), 0), 0xFFFF)
            bytes[14] = UInt8(target & 0xFF)
            bytes[15] = UInt8((target >> 8) & 0xFF)
            bytes[16] = 0x03
            bytes[17] = 0
        }
    }

    /// Acknowledgement (control frame, command 0x12) for a received frame:
    /// stored records are acked with their sequence as the correlation byte,
    /// other frame types with 0.
    static func ack(replyType: UInt8, correlation: Int = 0) -> Data {
        frame(type: 0x5F) { bytes in
            bytes[2] = 0x12
            bytes[3] = replyType
            bytes[4] = 0
            bytes[5] = UInt8(min(max(correlation, 0), 255))
        }
    }

    /// Requests the next report chunk (control frame, command 0x14).
    static func chunkRequest() -> Data {
        frame(type: 0x5F) { bytes in
            bytes[2] = 0x14
        }
    }
}
