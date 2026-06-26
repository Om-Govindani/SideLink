import Foundation
import Network
import OSLog

public protocol NetworkManagerDelegate: AnyObject {
    func didConnectClient(resolutionWidth: UInt32, resolutionHeight: UInt32, fps: UInt8)
    func didDisconnectClient()
    func didReceiveInputEvent(type: UInt8, x: Float, y: Float)
}

public enum ConnectionState {
    case idle
    case listening
    case connected
}

public class NetworkManager {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "Network")
    private let controlPort: UInt16 = 5230
    private let streamPort: UInt16 = 5231
    
    private var controlListener: NWListener?
    private var streamListener: NWListener?
    
    private var controlConnection: NWConnection?
    private var streamConnection: NWConnection?
    
    public private(set) var localIP: String = "127.0.0.1"
    public private(set) var pairingSecret: String = ""
    public private(set) var connectionURI: String = ""
    public private(set) var state: ConnectionState = .idle
    
    public weak var delegate: NetworkManagerDelegate?
    
    public init() {
        self.localIP = getLocalIPAddress() ?? "127.0.0.1"
        self.pairingSecret = generatePairingSecret()
        self.connectionURI = "sidelink://connect?ip=\(localIP)&port=\(controlPort)&secret=\(pairingSecret)"
    }
    
    /// Starts the TCP listeners for both control and video channels.
    public func startServices() {
        guard state == .idle else { return }
        logger.info("Starting SideLink network listeners...")
        
        let parameters = NWParameters.tcp
        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true // Disable Nagle's algorithm for low-latency
        }
        
        do {
            // 1. Setup Control Socket Listener
            let cListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: controlPort)!)
            self.controlListener = cListener
            cListener.stateUpdateHandler = { [weak self] state in
                self?.logger.info("Control listener state updated: \(String(describing: state))")
            }
            cListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewControlConnection(connection)
            }
            cListener.start(queue: .main)
            
            // 2. Setup Stream Socket Listener
            let sListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: streamPort)!)
            self.streamListener = sListener
            sListener.stateUpdateHandler = { [weak self] state in
                self?.logger.info("Stream listener state updated: \(String(describing: state))")
            }
            sListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewStreamConnection(connection)
            }
            sListener.start(queue: .main)
            
            self.state = .listening
            logger.info("Services listening on control port \(self.controlPort) and stream port \(self.streamPort). URI: \(self.connectionURI)")
            
        } catch {
            logger.fault("Failed to bind TCP ports: \(error.localizedDescription)")
            stopServices()
        }
    }
    
    /// Shuts down all active network connections and listeners.
    public func stopServices() {
        logger.info("Shutting down network listeners and active connections...")
        disconnect()
        
        controlListener?.cancel()
        controlListener = nil
        streamListener?.cancel()
        streamListener = nil
        
        self.state = .idle
        logger.info("SideLink network services stopped.")
    }
    
    /// Disconnects the active client.
    public func disconnect() {
        if controlConnection != nil || streamConnection != nil {
            controlConnection?.cancel()
            controlConnection = nil
            streamConnection?.cancel()
            streamConnection = nil
            
            self.state = .listening
            delegate?.didDisconnectClient()
            logger.info("Client disconnected.")
        }
    }
    
    /// Writes H.264 frame packet to the video stream socket.
    public func writeFrameData(_ data: Data) {
        guard let connection = streamConnection else { return }
        
        // Data contains: [4 Bytes length] [NALU payload]. Write it in a single block.
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to stream frame data: \(error.localizedDescription)")
                self?.disconnect()
            }
        })
    }
    
    // MARK: - Connection Handlers
    
    private func handleNewControlConnection(_ connection: NWConnection) {
        logger.info("Incoming connection on control socket...")
        
        if controlConnection != nil {
            logger.warning("Rejecting connection. Another client is already paired.")
            connection.cancel()
            return
        }
        
        self.controlConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("Control socket ready. Waiting for pairing secret handshake...")
                self.readNextPacket(connection: connection)
            case .failed(let error):
                self.logger.error("Control socket failed: \(error.localizedDescription)")
                self.disconnect()
            case .cancelled:
                self.logger.info("Control socket cancelled.")
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
    
    private func handleNewStreamConnection(_ connection: NWConnection) {
        logger.info("Incoming connection on stream socket...")
        
        guard self.state == .connected else {
            logger.warning("Rejecting stream connection. Control channel pairing handshake not completed.")
            connection.cancel()
            return
        }
        
        self.streamConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("Stream socket ready. Commencing frame stream.")
            case .failed(let error):
                self.logger.error("Stream socket failed: \(error.localizedDescription)")
                self.disconnect()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
    
    // MARK: - Packet Reading Pipeline
    
    private func readNextPacket(connection: NWConnection) {
        // Read the packet header: [Length (4 Bytes)] [Type (1 Byte)]
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("Control socket read error: \(error.localizedDescription)")
                self.disconnect()
                return
            }
            
            guard let header = content, header.count == 5 else {
                if isComplete { self.disconnect() }
                return
            }
            
            let length = UInt32(bigEndian: header.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
            let type = header[4]
            
            let payloadLength = Int(length) - 1 // subtract 1 byte representing the type
            if payloadLength > 0 {
                connection.receive(minimumIncompleteLength: payloadLength, maximumLength: payloadLength) { [weak self] payloadContent, _, _, error in
                    guard let self = self else { return }
                    if let error = error {
                        self.logger.error("Control payload read error: \(error.localizedDescription)")
                        self.disconnect()
                        return
                    }
                    if let payload = payloadContent {
                        self.processControlPacket(type: type, payload: payload)
                    }
                    self.readNextPacket(connection: connection)
                }
            } else {
                self.processControlPacket(type: type, payload: Data())
                self.readNextPacket(connection: connection)
            }
        }
    }
    
    private func processControlPacket(type: UInt8, payload: Data) {
        switch type {
        case 0x01: // Handshake Request
            let receivedSecret = String(data: payload, encoding: .utf8) ?? ""
            logger.info("Handshake received. Comparing pairing secrets...")
            
            if receivedSecret == pairingSecret {
                logger.info("Pairing secret verified. Authentication SUCCESS.")
                self.state = .connected
                
                // Send success response: [Length: 2] [Type: 0x02] [Payload: 0x00]
                var responseBytes = Data()
                var length = UInt32(2).bigEndian
                responseBytes.append(Data(bytes: &length, count: 4))
                responseBytes.append(0x02) // Type
                responseBytes.append(0x00) // Payload
                
                controlConnection?.send(content: responseBytes, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        self?.logger.error("Failed to send handshake response: \(error.localizedDescription)")
                        self?.disconnect()
                    }
                })
            } else {
                logger.error("Authentication FAILED. Received secret did not match local pairing code.")
                
                // Send failure response: [Length: 2] [Type: 0x02] [Payload: 0x01]
                var responseBytes = Data()
                var length = UInt32(2).bigEndian
                responseBytes.append(Data(bytes: &length, count: 4))
                responseBytes.append(0x02)
                responseBytes.append(0x01)
                
                controlConnection?.send(content: responseBytes, completion: .contentProcessed { [weak self] _ in
                    self?.disconnect()
                })
            }
            
        case 0x03: // Configure Display Request
            guard payload.count == 9 else { return }
            let reqWidth = UInt32(bigEndian: payload.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
            let reqHeight = UInt32(bigEndian: payload.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) })
            let reqFps = payload[8]
            
            logger.info("Client requested configuration: \(reqWidth)x\(reqHeight) @ \(reqFps) FPS.")
            delegate?.didConnectClient(resolutionWidth: reqWidth, resolutionHeight: reqHeight, fps: reqFps)
            
        case 0x04: // Input Event
            guard payload.count == 9 else { return }
            let touchType = payload[0]
            let rawX = payload.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) }
            let rawY = payload.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }
            
            let floatX = Float(bitPattern: UInt32(bigEndian: rawX))
            let floatY = Float(bitPattern: UInt32(bigEndian: rawY))
            
            delegate?.didReceiveInputEvent(type: touchType, x: floatX, y: floatY)
            
        default:
            logger.warning("Received unknown control packet type: \(type)")
        }
    }
    
    // MARK: - Utilities
    
    private func generatePairingSecret() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<32).map { _ in chars.randomElement()! })
    }
    
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Iterate interfaces, prioritize Wi-Fi (en0) or local Ethernet over loopback
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let status = getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    if status == 0 {
                        address = String(cString: hostname)
                        // If it's Wi-Fi (en0), we found our ideal IP immediately
                        if name == "en0" {
                            break
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
