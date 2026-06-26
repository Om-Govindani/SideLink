import Foundation
import CoreGraphics
import OSLog

public class InputInjector {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "InputInjector")
    private let displayID: CGDirectDisplayID
    
    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }
    
    /// Processes and injects a touch event.
    /// - Parameters:
    ///   - type: Touch action type (0: Down, 1: Move, 2: Up, 3: Secondary Click).
    ///   - x: Normalized X coordinate [0.0 - 1.0].
    ///   - y: Normalized Y coordinate [0.0 - 1.0].
    public func injectEvent(type: UInt8, x: Float, y: Float) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.size.width > 0 && bounds.size.height > 0 else {
            logger.error("Virtual display bounds are invalid or display is not active.")
            return
        }
        
        // Map normalized client coordinates [0.0 - 1.0] to host screen pixels:
        let targetX = bounds.origin.x + CGFloat(x) * bounds.size.width
        let targetY = bounds.origin.y + CGFloat(y) * bounds.size.height
        let position = CGPoint(x: targetX, y: targetY)
        
        logger.debug("Injecting event type \(type) at normalized (\(x), \(y)) -> absolute (\(position.x), \(position.y))")
        
        switch type {
        case 0x00: // Down (Left click down)
            postMouseEvent(type: .leftMouseDown, position: position, button: .left)
        case 0x01: // Move (Left mouse drag)
            postMouseEvent(type: .leftMouseDragged, position: position, button: .left)
        case 0x02: // Up (Left click up)
            postMouseEvent(type: .leftMouseUp, position: position, button: .left)
        case 0x03: // Secondary Click (Right click down + up)
            postMouseEvent(type: .rightMouseDown, position: position, button: .right)
            postMouseEvent(type: .rightMouseUp, position: position, button: .right)
        default:
            logger.warning("Unknown touch event type received: \(type)")
        }
    }
    
    private func postMouseEvent(type: CGEventType, position: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: button
        ) else {
            logger.error("Failed to construct CGEvent.")
            return
        }
        
        // Post the event into the macOS HID event tap (simulates real hardware input)
        event.post(tap: .cghidEventTap)
    }
}
