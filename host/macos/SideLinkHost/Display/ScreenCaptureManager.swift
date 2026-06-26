import Foundation
import CoreGraphics
import QuartzCore
import CoreVideo
import OSLog

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

public protocol ScreenCaptureManagerDelegate: AnyObject {
    func didCaptureFrame(_ pixelBuffer: CVPixelBuffer)
}

public class ScreenCaptureManager: NSObject {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "ScreenCapture")
    private let displayID: CGDirectDisplayID
    private let captureQueue = DispatchQueue(label: "com.sidelink.capturequeue", qos: .userInteractive)
    
    public weak var delegate: ScreenCaptureManagerDelegate?
    
    // macOS 12.3+ ScreenCaptureKit stream
    private var scStream: NSObject? // Typed as NSObject? to compile safely on older SDK configurations
    private var scOutput: Any?      // Holds the SCStreamOutput delegate helper
    
    // macOS 11.0 - 12.2 Legacy CGDisplayStream stream
    private var displayStream: CGDisplayStream?
    
    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()
    }
    
    public func startCapture(width: Int, height: Int) {
        logger.info("Starting frame capture pipeline for Display \(self.displayID) (Target: \(width)x\(height))...")
        
        if #available(macOS 12.3, *) {
            setupScreenCaptureKit(width: width, height: height)
        } else {
            setupCGDisplayStream(width: width, height: height)
        }
    }
    
    public func stopCapture() {
        logger.info("Stopping frame capture pipeline...")
        
        if #available(macOS 12.3, *) {
            if let stream = scStream as? SCStream {
                stream.stopCapture { error in
                    if let error = error {
                        self.logger.error("ScreenCaptureKit stop capture failed: \(error.localizedDescription)")
                    }
                }
            }
            scStream = nil
            scOutput = nil
        }
        
        if let stream = displayStream {
            SLDisplayStreamStop(stream)
            displayStream = nil
        }
        
        logger.info("Capture pipeline stopped.")
    }
    
    // MARK: - Legacy CGDisplayStream (macOS 11.0 - 12.2)
    
    private func setupCGDisplayStream(width: Int, height: Int) {
        logger.info("Using legacy CGDisplayStream fallback capture path.")
        
        // We capture in BiPlanar YpCbCr 8-bit (NV12), which matches VideoToolbox hardware encoder expectations directly.
        let pixelFormat = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        
        let stream = SLDisplayStreamCreate(
            displayID,
            width,
            height,
            pixelFormat,
            captureQueue
        ) { [weak self] status, displayTime, frameBuffer in
            guard let self = self else { return }
            
            switch status {
            case 0: // CGDisplayStreamFrameStatusFrameComplete
                if let ioSurface = frameBuffer {
                    var unmanagedPixelBufferOut: Unmanaged<CVPixelBuffer>?
                    let status = CVPixelBufferCreateWithIOSurface(
                        kCFAllocatorDefault,
                        ioSurface,
                        nil,
                        &unmanagedPixelBufferOut
                    )
                    if status == kCVReturnSuccess, let unmanagedBuffer = unmanagedPixelBufferOut {
                        let pixelBuffer = unmanagedBuffer.takeRetainedValue()
                        self.delegate?.didCaptureFrame(pixelBuffer)
                    }
                }
            case 1: // CGDisplayStreamFrameStatusFrameIdle
                // No change in frame content, we can choose to skip or repeat.
                break
            case 2: // CGDisplayStreamFrameStatusFrameBlank
                self.logger.debug("Captured a blank frame.")
            case 3: // CGDisplayStreamFrameStatusStopped
                self.logger.info("CGDisplayStream capture stopped by system.")
            default:
                break
            }
        }
        
        guard let displayStream = stream else {
            logger.fault("Failed to create CGDisplayStream for Display ID \(self.displayID)")
            return
        }
        
        self.displayStream = displayStream
        let err = SLDisplayStreamStart(displayStream)
        if err == kCGErrorSuccess {
            logger.info("CGDisplayStream successfully started.")
        } else {
            logger.fault("Failed to start CGDisplayStream. Error: \(err)")
        }
    }
    
    // MARK: - Modern ScreenCaptureKit (macOS 12.3+)
    
    @available(macOS 12.3, *)
    private func setupScreenCaptureKit(width: Int, height: Int) {
        logger.info("Using modern ScreenCaptureKit capture path.")
        
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("Failed to fetch SCShareableContent: \(error.localizedDescription)")
                return
            }
            
            guard let shareableContent = content else { return }
            
            // Find the display matching our display ID
            guard let targetDisplay = shareableContent.displays.first(where: { $0.displayID == self.displayID }) else {
                self.logger.error("Display ID \(self.displayID) not found in shareable content list.")
                return
            }
            
            let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
            
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12
            configuration.queueDepth = 3
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60) // Target 60 FPS
            configuration.showsCursor = true
            
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            
            let outputHandler = SCKitOutputHandler { [weak self] buffer in
                self?.delegate?.didCaptureFrame(buffer)
            }
            
            do {
                try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.scStream = stream
                self.scOutput = outputHandler
                
                stream.startCapture { error in
                    if let error = error {
                        self.logger.error("Failed to start ScreenCaptureKit stream: \(error.localizedDescription)")
                    } else {
                        self.logger.info("ScreenCaptureKit stream started successfully.")
                    }
                }
            } catch {
                self.logger.error("Failed to configure ScreenCaptureKit output: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ScreenCaptureKit Helper

@available(macOS 12.3, *)
private class SCKitOutputHandler: NSObject, SCStreamOutput {
    let callback: (CVPixelBuffer) -> Void
    
    init(callback: @escaping (CVPixelBuffer) -> Void) {
        self.callback = callback
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        callback(pixelBuffer)
    }
}
