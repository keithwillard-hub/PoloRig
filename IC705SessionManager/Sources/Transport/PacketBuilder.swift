import Foundation

/// Constructs packets for the Icom RS-BA1 UDP protocol.
public enum PacketBuilder {

    // MARK: - Base Control Packets (16 bytes)

    /// Create a base control header packet.
    public static func controlPacket(
        type: UInt16,
        sequence: UInt16,
        sendId: UInt32,
        recvId: UInt32
    ) -> Data {
        var data = Data(count: Int(PacketSize.control))
        data.writeUInt32(PacketSize.control, at: ControlOffset.length)
        data.writeUInt16(type, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        return data
    }

    public static func areYouThere(sendId: UInt32) -> Data {
        controlPacket(type: PacketType.areYouThere, sequence: 0, sendId: sendId, recvId: 0)
    }

    public static func areYouReady(sequence: UInt16, sendId: UInt32, recvId: UInt32) -> Data {
        controlPacket(type: PacketType.areYouReady, sequence: sequence, sendId: sendId, recvId: recvId)
    }

    public static func disconnect(sequence: UInt16, sendId: UInt32, recvId: UInt32) -> Data {
        controlPacket(type: PacketType.disconnect, sequence: sequence, sendId: sendId, recvId: recvId)
    }

    public static func idle(sequence: UInt16, sendId: UInt32, recvId: UInt32) -> Data {
        controlPacket(type: PacketType.idle, sequence: sequence, sendId: sendId, recvId: recvId)
    }

    // MARK: - Ping Packet (21 bytes)

    public static func ping(
        sequence: UInt16,
        sendId: UInt32,
        recvId: UInt32,
        isReply: Bool,
        dataA: UInt16,
        dataB: UInt16
    ) -> Data {
        var data = Data(count: Int(PacketSize.ping))
        data.writeUInt32(PacketSize.ping, at: ControlOffset.length)
        data.writeUInt16(PacketType.ping, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data[PingOffset.request] = isReply ? 0x01 : 0x00
        data.writeUInt16(dataA, at: PingOffset.dataA)
        data.writeUInt16(dataB, at: PingOffset.dataB)
        return data
    }

    /// Build a pong reply to an incoming ping.
    public static func pongReply(from pingData: Data, sendId: UInt32, recvId: UInt32) -> Data {
        var reply = pingData
        // Set length header (in case it's missing)
        reply.writeUInt32(PacketSize.ping, at: ControlOffset.length)
        // Swap sender/receiver
        reply.writeUInt32(sendId, at: ControlOffset.sendId)
        reply.writeUInt32(recvId, at: ControlOffset.recvId)
        // Mark as reply
        reply[PingOffset.request] = 0x01
        return reply
    }

    // MARK: - Token Base Packet (64 bytes)

    public static func tokenPacket(
        code: UInt16,
        res: UInt16,
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        token: UInt32
    ) -> Data {
        var data = Data(count: Int(PacketSize.token))
        data.writeUInt32(PacketSize.token, at: ControlOffset.length)
        data.writeUInt16(PacketType.idle, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data.writeUInt16(code, at: TokenOffset.code)
        data.writeUInt16(res, at: TokenOffset.res)
        data[TokenOffset.innerSeq] = innerSeq
        data.writeUInt16(tokReq, at: TokenOffset.tokReq)
        data.writeUInt32(token, at: TokenOffset.token)
        return data
    }

    // MARK: - Login Packet (128 bytes)

    public static func login(
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        userName: String,
        password: String,
        computerName: String
    ) -> Data {
        var data = Data(count: Int(PacketSize.login))
        data.writeUInt32(PacketSize.login, at: ControlOffset.length)
        data.writeUInt16(PacketType.idle, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data.writeUInt16(TokenCode.loginRequest, at: TokenOffset.code)
        data.writeUInt16(TokenRes.login, at: TokenOffset.res)
        data[TokenOffset.innerSeq] = innerSeq
        data.writeUInt16(tokReq, at: TokenOffset.tokReq)
        data.writeUInt32(0, at: TokenOffset.token) // no token yet

        // Encoded credentials
        let encodedUser = CredentialCodec.encode(userName)
        data.replaceSubrange(LoginOffset.userName..<LoginOffset.userName + 16, with: encodedUser)

        let encodedPass = CredentialCodec.encode(password)
        data.replaceSubrange(LoginOffset.password..<LoginOffset.password + 16, with: encodedPass)

        // Computer name in plaintext
        var compBytes = Data(count: 16)
        let compUTF8 = Array(computerName.utf8.prefix(16))
        for (i, b) in compUTF8.enumerated() {
            compBytes[i] = b
        }
        data.replaceSubrange(LoginOffset.computer..<LoginOffset.computer + 16, with: compBytes)

        return data
    }

    // MARK: - Token Acknowledge

    public static func tokenAcknowledge(
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        token: UInt32
    ) -> Data {
        tokenPacket(
            code: TokenCode.tokenAck,
            res: TokenRes.ack,
            innerSeq: innerSeq,
            sendId: sendId,
            recvId: recvId,
            sequence: sequence,
            tokReq: tokReq,
            token: token
        )
    }

    // MARK: - Token Renew

    public static func tokenRenew(
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        token: UInt32
    ) -> Data {
        tokenPacket(
            code: TokenCode.tokenAck,
            res: TokenRes.renew,
            innerSeq: innerSeq,
            sendId: sendId,
            recvId: recvId,
            sequence: sequence,
            tokReq: tokReq,
            token: token
        )
    }

    // MARK: - Token Remove

    public static func tokenRemove(
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        token: UInt32
    ) -> Data {
        tokenPacket(
            code: TokenCode.tokenAck,
            res: TokenRes.remove,
            innerSeq: innerSeq,
            sendId: sendId,
            recvId: recvId,
            sequence: sequence,
            tokReq: tokReq,
            token: token
        )
    }

    // MARK: - ConnInfo from Host (144 bytes)

    public static func connInfo(
        innerSeq: UInt8,
        sendId: UInt32,
        recvId: UInt32,
        sequence: UInt16,
        tokReq: UInt16,
        token: UInt32,
        commCap: UInt16,
        macAddr: Data,
        radioName: String,
        userName: String,
        serialPort: UInt16,
        audioPort: UInt16
    ) -> Data {
        var data = Data(count: Int(PacketSize.connInfo))
        data.writeUInt32(PacketSize.connInfo, at: ControlOffset.length)
        data.writeUInt16(PacketType.idle, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data.writeUInt16(TokenCode.connInfoFromHost, at: TokenOffset.code)
        data.writeUInt16(TokenRes.connInfo, at: TokenOffset.res)
        data[TokenOffset.innerSeq] = innerSeq
        data.writeUInt16(tokReq, at: TokenOffset.tokReq)
        data.writeUInt32(token, at: TokenOffset.token)
        data.writeUInt16(commCap, at: TokenOffset.commCap)
        if macAddr.count >= 6 {
            data.replaceSubrange(TokenOffset.macAddr..<TokenOffset.macAddr + 6, with: macAddr.prefix(6))
        }

        // Radio name plaintext
        let nameBytes = Array(radioName.utf8.prefix(16))
        for (i, b) in nameBytes.enumerated() {
            data[ConnInfoOffset.radioName + i] = b
        }

        // Encoded username
        let encodedUser = CredentialCodec.encode(userName)
        data.replaceSubrange(ConnInfoOffset.userName..<ConnInfoOffset.userName + 16, with: encodedUser)

        // Audio settings — for CW-only we still need valid values
        data[ConnInfoOffset.enableRx] = 0x01
        data[ConnInfoOffset.enableTx] = 0x01
        data[ConnInfoOffset.rxCodec] = 0x04   // PCM 16-bit
        data[ConnInfoOffset.txCodec] = 0x04
        data.writeUInt32BE(8000, at: ConnInfoOffset.rxSample)
        data.writeUInt32BE(8000, at: ConnInfoOffset.txSample)
        data.writeUInt32BE(UInt32(serialPort), at: ConnInfoOffset.civPort)
        data.writeUInt32BE(UInt32(audioPort), at: ConnInfoOffset.audioPort)
        data.writeUInt32BE(100, at: ConnInfoOffset.txBuffer)
        data[ConnInfoOffset.convert] = 0x01

        return data
    }

    // MARK: - OpenClose Packet (22 bytes, serial port)

    public static func openClose(
        sequence: UInt16,
        sendId: UInt32,
        recvId: UInt32,
        civSequence: UInt16,
        isOpen: Bool
    ) -> Data {
        var data = Data(count: Int(PacketSize.openClose))
        data.writeUInt32(PacketSize.openClose, at: ControlOffset.length)
        data.writeUInt16(PacketType.idle, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data[OpenCloseOffset.cmd] = 0xC0
        data.writeUInt16(0x0001, at: OpenCloseOffset.length)
        data.writeUInt16(civSequence, at: OpenCloseOffset.sequence)
        data[OpenCloseOffset.request] = isOpen ? 0x04 : 0x00
        return data
    }

    // MARK: - CI-V Data Packet

    public static func civPacket(
        sequence: UInt16,
        sendId: UInt32,
        recvId: UInt32,
        civSequence: UInt16,
        civData: Data
    ) -> Data {
        let totalLength = Int(PacketSize.civHeader) + civData.count
        var data = Data(count: totalLength)
        data.writeUInt32(UInt32(totalLength), at: ControlOffset.length)
        data.writeUInt16(PacketType.idle, at: ControlOffset.type)
        data.writeUInt16(sequence, at: ControlOffset.sequence)
        data.writeUInt32(sendId, at: ControlOffset.sendId)
        data.writeUInt32(recvId, at: ControlOffset.recvId)
        data[CIVPacketOffset.cmd] = 0xC1
        data.writeUInt16(UInt16(civData.count), at: CIVPacketOffset.length)
        data.writeUInt16(civSequence, at: CIVPacketOffset.sequence)
        data.replaceSubrange(CIVPacketOffset.data..<CIVPacketOffset.data + civData.count, with: civData)
        return data
    }
}

// MARK: - Data Extension for Little-Endian Read/Write

extension Data {
    public func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    public func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    public func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    public func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    public mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        guard offset + 2 <= count else { return }
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    public mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        guard offset + 4 <= count else { return }
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    public mutating func writeUInt32BE(_ value: UInt32, at offset: Int) {
        guard offset + 4 <= count else { return }
        self[offset] = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}
