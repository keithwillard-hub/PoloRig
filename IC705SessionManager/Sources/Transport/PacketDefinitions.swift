import Foundation

// MARK: - Packet Sizes

public enum PacketSize {
    public static let control: UInt32    = 0x10
    public static let watchdog: UInt32   = 0x14
    public static let ping: UInt32       = 0x15
    public static let openClose: UInt32  = 0x16
    public static let retransmit: UInt32 = 0x18
    public static let token: UInt32      = 0x40
    public static let status: UInt32     = 0x50
    public static let loginResponse: UInt32 = 0x60
    public static let login: UInt32      = 0x80
    public static let connInfo: UInt32   = 0x90
    public static let capabilities: UInt32 = 0xA8
    public static let civHeader: UInt32  = 0x15
}

// MARK: - Packet Type Codes (offset 0x04)

public enum PacketType {
    public static let idle: UInt16         = 0x0000
    public static let retransmit: UInt16   = 0x0001
    public static let areYouThere: UInt16  = 0x0003
    public static let iAmHere: UInt16      = 0x0004
    public static let disconnect: UInt16   = 0x0005
    public static let areYouReady: UInt16  = 0x0006
    public static let ping: UInt16         = 0x0007
}

// MARK: - Control Header Offsets (16-byte header)

public enum ControlOffset {
    public static let length: Int   = 0x00
    public static let type: Int     = 0x04
    public static let sequence: Int = 0x06
    public static let sendId: Int   = 0x08
    public static let recvId: Int   = 0x0C
}

// MARK: - Ping Offsets (21 bytes)

public enum PingOffset {
    public static let request: Int = 0x10
    public static let dataA: Int   = 0x11
    public static let dataB: Int   = 0x13
}

// MARK: - Token Offsets (64 bytes, extends control header)

public enum TokenOffset {
    // 0x10-0x12 padding
    public static let code: Int        = 0x13
    public static let res: Int         = 0x15
    public static let innerSeq: Int    = 0x17
    // 0x18-0x19 padding
    public static let tokReq: Int      = 0x1A
    public static let token: Int       = 0x1C
    // 0x20-0x26 padding
    public static let commCap: Int     = 0x27
    public static let reqRep: Int      = 0x29
    public static let macAddr: Int     = 0x2A
}

// MARK: - Token Code/Res Values

public enum TokenCode {
    public static let loginRequest: UInt16       = 0x0170
    public static let loginResponse: UInt16      = 0x0250
    public static let tokenAck: UInt16           = 0x0130
    public static let tokenAckResponse: UInt16   = 0x0230
    public static let connInfoFromHost: UInt16   = 0x0180
    public static let connInfoFromRadio: UInt16  = 0x0380
    public static let status: UInt16             = 0x0240
    public static let capabilities: UInt16       = 0x0298
}

public enum TokenRes {
    public static let login: UInt16        = 0x0000
    public static let ack: UInt16          = 0x0002
    public static let connInfo: UInt16     = 0x0003
    public static let renew: UInt16        = 0x0005
    public static let remove: UInt16       = 0x0001
}

// MARK: - Login Offsets (128 bytes)

public enum LoginOffset {
    public static let userName: Int   = 0x40
    public static let password: Int   = 0x50
    public static let computer: Int   = 0x60
}

// MARK: - ConnInfo Offsets (144 bytes)

public enum ConnInfoOffset {
    public static let radioName: Int  = 0x40
    // 0x50-0x5F padding
    public static let userName: Int   = 0x60
    public static let enableRx: Int   = 0x70
    public static let enableTx: Int   = 0x71
    public static let rxCodec: Int    = 0x72
    public static let txCodec: Int    = 0x73
    public static let rxSample: Int   = 0x74
    public static let txSample: Int   = 0x78
    public static let civPort: Int    = 0x7C
    public static let audioPort: Int  = 0x80
    public static let txBuffer: Int   = 0x84
    public static let convert: Int    = 0x88
}

// MARK: - Capabilities Offsets (168 bytes)

public enum CapabilitiesOffset {
    public static let macAddr: Int    = 0x4C
    public static let radioName: Int  = 0x52
    public static let civAddr: Int    = 0x94
}

// MARK: - OpenClose Offsets (22 bytes)

public enum OpenCloseOffset {
    public static let cmd: Int      = 0x10
    public static let length: Int   = 0x11
    public static let sequence: Int = 0x13
    public static let request: Int  = 0x15
}

// MARK: - CIV Packet Offsets (header = 21 bytes before CI-V data)

public enum CIVPacketOffset {
    public static let cmd: Int      = 0x10
    public static let length: Int   = 0x11
    public static let sequence: Int = 0x13
    public static let data: Int     = 0x15
}

// MARK: - Timing Constants

public enum Timing {
    public static let pingInterval: TimeInterval    = 0.5
    public static let idleInterval: TimeInterval    = 0.1
    public static let resendInterval: TimeInterval  = 0.1
    public static let tokenRenewInterval: TimeInterval = 60.0
}

// MARK: - Credential Encoding

public enum CredentialCodec {
    static let encodeKey: [UInt8] = [
        0x47, 0x5d, 0x4c, 0x42, 0x66, 0x20, 0x23, 0x46,
        0x4e, 0x57, 0x45, 0x3d, 0x67, 0x76, 0x60, 0x41,
        0x62, 0x39, 0x59, 0x2d, 0x68, 0x7e, 0x7c, 0x65,
        0x7d, 0x49, 0x29, 0x72, 0x73, 0x78, 0x21, 0x6e,
        0x5a, 0x5e, 0x4a, 0x3e, 0x71, 0x2c, 0x2a, 0x54,
        0x3c, 0x3a, 0x63, 0x4f, 0x43, 0x75, 0x27, 0x79,
        0x5b, 0x35, 0x70, 0x48, 0x6b, 0x56, 0x6f, 0x34,
        0x32, 0x6c, 0x30, 0x61, 0x6d, 0x7b, 0x2f, 0x4b,
        0x64, 0x38, 0x2b, 0x2e, 0x50, 0x40, 0x3f, 0x55,
        0x33, 0x37, 0x25, 0x77, 0x24, 0x26, 0x74, 0x6a,
        0x28, 0x53, 0x4d, 0x69, 0x22, 0x5c, 0x44, 0x31,
        0x36, 0x58, 0x3b, 0x7a, 0x51, 0x5f, 0x52
    ]

    /// Encode a username or password for the RS-BA1 protocol.
    /// Position-dependent substitution cipher. Max 16 chars, zero-padded.
    static func encode(_ string: String) -> Data {
        var result = Data(count: 16)
        let bytes = Array(string.utf8)
        for (index, item) in bytes.prefix(16).enumerated() {
            var p = index + Int(item)
            if p > 126 {
                p = 32 + (p % 127)
            }
            result[index] = encodeKey[p - 32]
        }
        return result
    }
}
