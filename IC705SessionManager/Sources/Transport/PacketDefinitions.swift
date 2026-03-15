import Foundation

// MARK: - Packet Sizes

enum PacketSize {
    static let control: UInt32    = 0x10  // 16 bytes - base header
    static let watchdog: UInt32   = 0x14  // 20 bytes
    static let ping: UInt32       = 0x15  // 21 bytes
    static let openClose: UInt32  = 0x16  // 22 bytes
    static let retransmit: UInt32 = 0x18  // 24 bytes
    static let token: UInt32      = 0x40  // 64 bytes
    static let status: UInt32     = 0x50  // 80 bytes
    static let loginResponse: UInt32 = 0x60  // 96 bytes
    static let login: UInt32      = 0x80  // 128 bytes
    static let connInfo: UInt32   = 0x90  // 144 bytes
    static let capabilities: UInt32 = 0xA8 // 168 bytes
    static let civHeader: UInt32  = 0x15  // 21 bytes before CI-V data
}

// MARK: - Packet Type Codes (offset 0x04)

enum PacketType {
    static let idle: UInt16         = 0x0000
    static let retransmit: UInt16   = 0x0001
    static let areYouThere: UInt16  = 0x0003
    static let iAmHere: UInt16      = 0x0004
    static let disconnect: UInt16   = 0x0005
    static let areYouReady: UInt16  = 0x0006
    static let ping: UInt16         = 0x0007
}

// MARK: - Control Header Offsets (16-byte header)

enum ControlOffset {
    static let length: Int   = 0x00  // UInt32
    static let type: Int     = 0x04  // UInt16
    static let sequence: Int = 0x06  // UInt16
    static let sendId: Int   = 0x08  // UInt32
    static let recvId: Int   = 0x0C  // UInt32
}

// MARK: - Ping Offsets (21 bytes)

enum PingOffset {
    static let request: Int = 0x10  // UInt8 - 0=request, 1=response
    static let dataA: Int   = 0x11  // UInt16
    static let dataB: Int   = 0x13  // UInt16
}

// MARK: - Token Offsets (64 bytes, extends control header)

enum TokenOffset {
    // 0x10-0x12 padding
    static let code: Int        = 0x13  // UInt16
    static let res: Int         = 0x15  // UInt16
    static let innerSeq: Int    = 0x17  // UInt8
    // 0x18-0x19 padding
    static let tokReq: Int      = 0x1A  // UInt16
    static let token: Int       = 0x1C  // UInt32
    // 0x20-0x26 padding
    static let commCap: Int     = 0x27  // UInt16
    static let reqRep: Int      = 0x29  // UInt8
    static let macAddr: Int     = 0x2A  // 6 bytes
}

// MARK: - Token Code/Res Values

enum TokenCode {
    static let loginRequest: UInt16       = 0x0170
    static let loginResponse: UInt16      = 0x0250
    static let tokenAck: UInt16           = 0x0130
    static let tokenAckResponse: UInt16   = 0x0230
    static let connInfoFromHost: UInt16   = 0x0180
    static let connInfoFromRadio: UInt16  = 0x0380
    static let status: UInt16             = 0x0240
    static let capabilities: UInt16       = 0x0298
}

enum TokenRes {
    static let login: UInt16        = 0x0000
    static let ack: UInt16          = 0x0002
    static let connInfo: UInt16     = 0x0003
    static let renew: UInt16        = 0x0005
    static let remove: UInt16       = 0x0001
}

// MARK: - Login Offsets (128 bytes)

enum LoginOffset {
    static let userName: Int   = 0x40  // 16 bytes, encoded
    static let password: Int   = 0x50  // 16 bytes, encoded
    static let computer: Int   = 0x60  // 16 bytes, plaintext
}

// MARK: - ConnInfo Offsets (144 bytes)

enum ConnInfoOffset {
    static let radioName: Int  = 0x40  // 16 bytes
    // 0x50-0x5F padding
    static let userName: Int   = 0x60  // 16 bytes, encoded
    static let enableRx: Int   = 0x70  // UInt8
    static let enableTx: Int   = 0x71  // UInt8
    static let rxCodec: Int    = 0x72  // UInt8
    static let txCodec: Int    = 0x73  // UInt8
    static let rxSample: Int   = 0x74  // UInt32 big-endian
    static let txSample: Int   = 0x78  // UInt32 big-endian
    static let civPort: Int    = 0x7C  // UInt32 big-endian
    static let audioPort: Int  = 0x80  // UInt32 big-endian
    static let txBuffer: Int   = 0x84  // UInt32 big-endian
    static let convert: Int    = 0x88  // UInt8
}

// MARK: - Capabilities Offsets (168 bytes)

enum CapabilitiesOffset {
    static let macAddr: Int    = 0x4C  // 6 bytes
    static let radioName: Int  = 0x52  // 16 bytes
    static let civAddr: Int    = 0x94  // UInt8
}

// MARK: - OpenClose Offsets (22 bytes)

enum OpenCloseOffset {
    static let cmd: Int      = 0x10  // UInt8, always 0xC0
    static let length: Int   = 0x11  // UInt16
    static let sequence: Int = 0x13  // UInt16
    static let request: Int  = 0x15  // UInt8 - 0x04=open, 0x00=close
}

// MARK: - CIV Packet Offsets (header = 21 bytes before CI-V data)

enum CIVPacketOffset {
    static let cmd: Int      = 0x10  // UInt8, always 0xC1
    static let length: Int   = 0x11  // UInt16 LE
    static let sequence: Int = 0x13  // UInt16 (LE from host, BE from radio)
    static let data: Int     = 0x15  // CI-V frame starts here
}

// MARK: - Timing Constants

enum Timing {
    static let pingInterval: TimeInterval    = 0.5
    static let idleInterval: TimeInterval    = 0.1
    static let resendInterval: TimeInterval  = 0.1
    static let tokenRenewInterval: TimeInterval = 60.0
}

// MARK: - Credential Encoding

enum CredentialCodec {
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
