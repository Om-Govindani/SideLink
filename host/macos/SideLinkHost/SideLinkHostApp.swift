import SwiftUI
import CoreMedia
import CoreGraphics
import CoreImage.CIFilterBuiltins
import OSLog

@main
struct SideLinkHostApp: App {
    @StateObject private var controller = HostAppController()
    
    var body: some Scene {
        WindowGroup {
            MainControlView()
                .environmentObject(controller)
                .frame(width: 480, height: 420)
                .onAppear {
                    controller.startServices()
                }
                .onDisappear {
                    controller.stopServices()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - App Controller

class HostAppController: NSObject, ObservableObject, NetworkManagerDelegate, ScreenCaptureManagerDelegate, VideoEncoderDelegate {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "AppController")
    
    // Core Managers
    private let networkManager = NetworkManager()
    private let displayManager = VirtualDisplayManager()
    private var captureManager: ScreenCaptureManager?
    private let encoder = VideoEncoder()
    private var inputInjector: InputInjector?
    
    // Published states for UI
    @Published var connectionURI: String = ""
    @Published var localIP: String = ""
    @Published var clientStatus: String = "Disconnected"
    @Published var clientInfo: String = ""
    @Published var isStreaming: Bool = false
    
    override init() {
        super.init()
        networkManager.delegate = self
        encoder.delegate = self
        
        self.connectionURI = networkManager.connectionURI
        self.localIP = networkManager.localIP
    }
    
    public func startServices() {
        networkManager.startServices()
        self.connectionURI = networkManager.connectionURI
    }
    
    public func stopServices() {
        stopStreamingPipeline()
        networkManager.stopServices()
    }
    
    public func disconnect() {
        networkManager.disconnect()
    }
    
    private func stopStreamingPipeline() {
        logger.info("Stopping capture and encoding pipeline...")
        captureManager?.stopCapture()
        captureManager = nil
        encoder.stopSession()
        displayManager.destroyDisplay()
        inputInjector = nil
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.clientStatus = "Listening for client..."
            self.clientInfo = ""
        }
    }
    
    // MARK: - NetworkManagerDelegate
    
    func didConnectClient(resolutionWidth: UInt32, resolutionHeight: UInt32, fps: UInt8) {
        logger.info("Network handshake successful. Creating virtual screen: \(resolutionWidth)x\(resolutionHeight) @ \(fps) FPS")
        
        // 1. Create the virtual display
        let success = displayManager.createDisplay(
            name: "SideLink Monitor",
            width: resolutionWidth,
            height: resolutionHeight
        )
        
        guard success, let displayID = displayManager.displayID else {
            logger.fault("Failed to register display. Terminating connection.")
            networkManager.disconnect()
            return
        }
        
        // 2. Start H.264 Encoder session
        guard encoder.startSession(width: Int32(resolutionWidth), height: Int32(resolutionHeight), fps: Int32(fps)) else {
            logger.fault("Failed to initialize hardware encoder. Terminating connection.")
            networkManager.disconnect()
            return
        }
        
        // 3. Initialize Input Injector
        inputInjector = InputInjector(displayID: displayID)
        
        // 4. Initialize and start frame capture
        let capture = ScreenCaptureManager(displayID: displayID)
        capture.delegate = self
        self.captureManager = capture
        capture.startCapture(width: Int(resolutionWidth), height: Int(resolutionHeight))
        
        DispatchQueue.main.async {
            self.isStreaming = true
            self.clientStatus = "Connected"
            self.clientInfo = "Screen size: \(resolutionWidth)x\(resolutionHeight) | FPS: \(fps)"
        }
    }
    
    func didDisconnectClient() {
        logger.warning("Active client disconnected.")
        stopStreamingPipeline()
    }
    
    func didReceiveInputEvent(type: UInt8, x: Float, y: Float) {
        inputInjector?.injectEvent(type: type, x: x, y: y)
    }
    
    // MARK: - ScreenCaptureManagerDelegate
    
    func didCaptureFrame(_ pixelBuffer: CVPixelBuffer) {
        let timestamp = CMTime(value: Int64(mach_absolute_time()), timescale: 1_000_000_000)
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp)
    }
    
    // MARK: - VideoEncoderDelegate
    
    func didEncodeFrame(data: Data) {
        networkManager.writeFrameData(data)
    }
}

// MARK: - UI Views

struct MainControlView: View {
    @EnvironmentObject var controller: HostAppController
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("SideLink Host")
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
                Circle()
                    .fill(controller.isStreaming ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(controller.clientStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 20)
            
            Divider()
            
            if !controller.isStreaming {
                VStack(spacing: 12) {
                    Text("Scan to Connect")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Open SideLink on your Android device and scan the QR code to extend your display.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    if let qrImage = generateQRCode(from: controller.connectionURI) {
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                    } else {
                        ProgressView()
                            .frame(width: 180, height: 180)
                    }
                    
                    Text("IP Address: \(controller.localIP)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "tv.and.ipad")
                        .font(.system(size: 64))
                        .foregroundColor(.accentColor)
                        .padding(.top, 20)
                    
                    Text("Streaming Active")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(controller.clientInfo)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                    
                    Spacer()
                    
                    Button(action: {
                        controller.disconnect()
                    }) {
                        Text("Disconnect Client")
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 20)
                }
            }
            
            Spacer()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        
        guard let outputImage = filter.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
