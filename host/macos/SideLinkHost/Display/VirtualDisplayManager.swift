import Foundation
import CoreGraphics
import OSLog

public class VirtualDisplayManager {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "VirtualDisplay")
    private var virtualDisplay: CGVirtualDisplay?
    private let displayQueue = DispatchQueue(label: "com.sidelink.displayqueue", qos: .userInteractive)
    
    public private(set) var displayID: CGDirectDisplayID?
    
    public init() {}
    
    /// Creates and registers a virtual display on macOS.
    /// - Parameters:
    ///   - name: The name of the display shown in System Settings.
    ///   - width: Width of the primary mode (default 1920).
    ///   - height: Height of the primary mode (default 1080).
    /// - Returns: True if display was successfully created.
    public func createDisplay(name: String = "SideLink Monitor", width: UInt32 = 1920, height: UInt32 = 1080) -> Bool {
        guard virtualDisplay == nil else {
            logger.warning("Virtual display already exists.")
            return true
        }
        
        logger.info("Initializing virtual display descriptor for '\(name)'...")
        
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        // A standard 27-inch physical monitor dimension (597mm x 336mm) helps CoreGraphics map resolution densities correctly.
        descriptor.sizeInMillimeters = CGSize(width: 597, height: 336)
        descriptor.vendorID = 0x51DE  // "SIDE" placeholder vendor ID
        descriptor.productID = 0x0001
        descriptor.serialNum = 12345
        descriptor.queue = displayQueue
        descriptor.terminationHandler = { [weak self] _, error in
            self?.logger.error("Virtual display terminated with error code: \(error.rawValue)")
            self?.destroyDisplay()
        }
        
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            logger.fault("Failed to allocate CGVirtualDisplay.")
            return false
        }
        
        self.virtualDisplay = display
        self.displayID = display.displayID
        logger.info("CGVirtualDisplay allocated successfully. Assigned Display ID: \(display.displayID)")
        
        // Define supported display modes:
        // We configure standard Retina HiDPI scale (2x) and standard 1x modes.
        let mode1080p = CGVirtualDisplayMode(width: width, height: height, refreshRate: 60.0)
        let mode720p = CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60.0)
        let mode1440p = CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60.0)
        
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode1080p, mode720p, mode1440p]
        settings.hiDPI = 1 // Enable HiDPI scaling (Retina equivalent)
        
        guard display.apply(settings) else {
            logger.fault("Failed to apply settings to the virtual display.")
            destroyDisplay()
            return false
        }
        
        logger.info("Virtual display settings applied. Ready for screen capture.")
        return true
    }
    
    /// Destroys and cleans up the virtual display.
    public func destroyDisplay() {
        guard virtualDisplay != nil else { return }
        logger.info("Tearing down virtual display...")
        virtualDisplay = nil
        displayID = nil
        logger.info("Virtual display released.")
    }
    
    deinit {
        destroyDisplay()
    }
}
