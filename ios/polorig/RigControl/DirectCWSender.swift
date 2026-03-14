import Foundation
import Network

final class DirectCWSender {
    private let host: String
    private let userName: String
    private let password: String
    private let text: String
    private let queue = DispatchQueue(label: "com.ac0vw.polorig.directcwsender")

    private var controlConnection: NWConnection?
    private var serialConnection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?
    private var finished = false

    private let controlMyId = UInt32.random(in: 1...UInt32.max)
    private let serialMyId = UInt32.random(in: 1...UInt32.max)
    private let tokReq = UInt16.random(in: 1...UInt16.max)

    private var controlRemoteId: UInt32 = 0
    private var serialRemoteId: UInt32 = 0
    private var controlSequence: UInt16 = 0
    private var serialSequence: UInt16 = 0
    private var innerSequence: UInt8 = 0
    private var token: UInt32 = 0
    private var radioMAC = Data(count: 6)
    private var radioName = "IC-705"
    private var commCap: UInt16 = 0
    private var remoteCIVPort: UInt16 = 50002

    init(host: String, userName: String, password: String, text: String) {
        self.host = host
        self.userName = userName
        self.password = password
        self.text = text.uppercased()
    }

    func start(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        DebugTrace.write("DirectCWSender", "start text=\(text)")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            DebugTrace.write("DirectCWSender", "timeout")
            self?.finish(false)
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 12.0, execute: timeoutWorkItem)
        }

        let control = NWConnection(host: NWEndpoint.Host(host), port: 50001, using: .udp)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            self?.handleControlState(state)
        }
        control.start(queue: queue)
    }

    private func handleControlState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DebugTrace.write("DirectCWSender", "control ready")
            startControlReceive()
            sendControl(PacketBuilder.areYouThere(sendId: controlMyId))
        case .failed(let error):
            DebugTrace.write("DirectCWSender", "control failed error=\(error.localizedDescription)")
            finish(false)
        default:
            break
        }
    }

    private func handleSerialState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DebugTrace.write("DirectCWSender", "serial ready remoteCIVPort=\(remoteCIVPort)")
            startSerialReceive()
            sendSerial(PacketBuilder.areYouThere(sendId: serialMyId))
        case .failed(let error):
            DebugTrace.write("DirectCWSender", "serial failed error=\(error.localizedDescription)")
            finish(false)
        default:
            break
        }
    }

    private func startControlReceive() {
        controlConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                DebugTrace.write("DirectCWSender", "control receive error=\(error.localizedDescription)")
                self.finish(false)
                return
            }
            guard let data, !data.isEmpty else {
                self.startControlReceive()
                return
            }

            let type = data.readUInt16(at: ControlOffset.type)
            DebugTrace.write("DirectCWSender", "control packet type=0x\(String(format: "%04X", type)) bytes=\(data.count)")

            switch type {
            case PacketType.iAmHere:
                self.controlRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendControl(PacketBuilder.areYouReady(sequence: 1, sendId: self.controlMyId, recvId: self.controlRemoteId))

            case PacketType.areYouReady:
                self.sendControlLogin()

            case PacketType.idle:
                self.handleControlIdle(data)

            case PacketType.ping:
                self.handlePing(data, sendId: self.controlMyId, recvId: self.controlRemoteId, sender: self.sendControl)

            default:
                break
            }

            self.startControlReceive()
        }
    }

    private func startSerialReceive() {
        serialConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                DebugTrace.write("DirectCWSender", "serial receive error=\(error.localizedDescription)")
                self.finish(false)
                return
            }
            guard let data, !data.isEmpty else {
                self.startSerialReceive()
                return
            }

            let type = data.readUInt16(at: ControlOffset.type)
            DebugTrace.write("DirectCWSender", "serial packet type=0x\(String(format: "%04X", type)) bytes=\(data.count)")

            switch type {
            case PacketType.iAmHere:
                self.serialRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendSerial(PacketBuilder.areYouReady(sequence: 1, sendId: self.serialMyId, recvId: self.serialRemoteId))

            case PacketType.areYouReady:
                self.sendOpenClose()
                self.sendCW()
                self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    DebugTrace.write("DirectCWSender", "serial send grace elapsed")
                    self?.finish(true)
                }

            case PacketType.idle:
                if data.count > Int(PacketSize.civHeader), data[CIVPacketOffset.cmd] == 0xC1 {
                    let len = Int(data.readUInt16(at: CIVPacketOffset.length))
                    if CIVPacketOffset.data + len <= data.count {
                        let civ = data.subdata(in: CIVPacketOffset.data..<(CIVPacketOffset.data + len))
                        let civHex = civ.map { String(format: "%02X", $0) }.joined(separator: " ")
                        DebugTrace.write("DirectCWSender", "serial civ=[\(civHex)]")
                    }
                }

            case PacketType.ping:
                self.handlePing(data, sendId: self.serialMyId, recvId: self.serialRemoteId, sender: self.sendSerial)

            default:
                break
            }

            self.startSerialReceive()
        }
    }

    private func handleControlIdle(_ data: Data) {
        guard data.count >= Int(PacketSize.token) else { return }
        let code = data.readUInt16(at: TokenOffset.code)
        DebugTrace.write("DirectCWSender", "control idle code=0x\(String(format: "%04X", code))")

        switch code {
        case TokenCode.loginResponse:
            token = data.readUInt32(at: TokenOffset.token)
            sendControlTokenAck()

        case TokenCode.capabilities:
            commCap = data.readUInt16(at: TokenOffset.commCap)
            radioMAC = data.subdata(in: CapabilitiesOffset.macAddr..<(CapabilitiesOffset.macAddr + 6))
            let nameData = data.subdata(in: CapabilitiesOffset.radioName..<(CapabilitiesOffset.radioName + 16))
            radioName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "IC-705"
            sendControlConnInfo()

        case TokenCode.status:
            remoteCIVPort = data.readUInt16BE(at: 0x42)
            if remoteCIVPort == 0 { remoteCIVPort = 50002 }
            DebugTrace.write("DirectCWSender", "status remoteCIVPort=\(remoteCIVPort)")
            startSerialConnection()

        default:
            break
        }
    }

    private func sendControlLogin() {
        innerSequence &+= 1
        let packet = PacketBuilder.login(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            userName: userName,
            password: password,
            computerName: "iPhone"
        )
        sendControl(packet)
    }

    private func sendControlTokenAck() {
        innerSequence &+= 1
        let packet = PacketBuilder.tokenAcknowledge(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            token: token
        )
        sendControl(packet)
    }

    private func sendControlConnInfo() {
        innerSequence &+= 1
        let packet = PacketBuilder.connInfo(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            token: token,
            commCap: commCap,
            macAddr: radioMAC,
            radioName: radioName,
            userName: userName,
            serialPort: 50002,
            audioPort: 50003
        )
        sendControl(packet)
    }

    private func startSerialConnection() {
        guard serialConnection == nil else { return }
        let serial = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: remoteCIVPort)!, using: .udp)
        serialConnection = serial
        serial.stateUpdateHandler = { [weak self] state in
            self?.handleSerialState(state)
        }
        serial.start(queue: queue)
    }

    private func sendOpenClose() {
        let packet = PacketBuilder.openClose(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 1,
            isOpen: true
        )
        DebugTrace.write("DirectCWSender", "sendOpenClose")
        sendSerial(packet)
    }

    private func sendCW() {
        let civFrame = CIV.buildFrame(command: CIV.Command.sendCW, data: Array(text.utf8))
        let packet = PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 2,
            civData: civFrame
        )
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        DebugTrace.write("DirectCWSender", "sendCW frame=[\(civHex)]")
        sendSerial(packet)
    }

    private func handlePing(_ data: Data,
                            sendId: UInt32,
                            recvId: UInt32,
                            sender: (Data) -> Void) {
        guard data.count >= Int(PacketSize.ping), data[PingOffset.request] == 0x00 else { return }
        sender(PacketBuilder.pongReply(from: data, sendId: sendId, recvId: recvId))
    }

    private func nextControlSequence() -> UInt16 {
        controlSequence &+= 1
        return controlSequence
    }

    private func nextSerialSequence() -> UInt16 {
        serialSequence &+= 1
        return serialSequence
    }

    private func sendControl(_ data: Data) {
        controlConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendSerial(_ data: Data) {
        serialConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        DebugTrace.write("DirectCWSender", "finish success=\(success)")

        if token != 0, controlRemoteId != 0 {
            innerSequence &+= 1
            let remove = PacketBuilder.tokenRemove(
                innerSeq: innerSequence,
                sendId: controlMyId,
                recvId: controlRemoteId,
                sequence: nextControlSequence(),
                tokReq: tokReq,
                token: token
            )
            sendControl(remove)
        }

        if serialRemoteId != 0 {
            let close = PacketBuilder.openClose(
                sequence: nextSerialSequence(),
                sendId: serialMyId,
                recvId: serialRemoteId,
                civSequence: 4,
                isOpen: false
            )
            sendSerial(close)
        }

        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }

        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.serialConnection?.cancel()
            self?.controlConnection?.cancel()
            self?.completion?(success)
            self?.completion = nil
        }
    }
}
