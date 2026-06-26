import Foundation
import VideoToolbox
import CoreMedia
import OSLog

public protocol VideoEncoderDelegate: AnyObject {
    /// Callback triggered when a new H.264 NAL unit or frame packet is encoded.
    /// - Parameter data: Length-prefixed NAL unit binary block.
    func didEncodeFrame(data: Data)
}

public class VideoEncoder {
    private let logger = Logger(subsystem: "com.sidelink.host", category: "VideoEncoder")
    private var compressionSession: VTCompressionSession?
    
    public weak var delegate: VideoEncoderDelegate?
    
    public init() {}
    
    /// Initializes the VideoToolbox compression session.
    public func startSession(width: Int32, height: Int32, fps: Int32 = 60) -> Bool {
        logger.info("Initializing H.264 VideoToolbox session at \(width)x\(height) @ \(fps) FPS...")
        
        let encoderSpecification: CFDictionary? = nil
        let imageBufferAttributes: CFDictionary? = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12 compatibility
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let compressionSession = session else {
            logger.fault("Failed to create VTCompressionSession. Error: \(status)")
            return false
        }
        
        self.compressionSession = compressionSession
        
        // Configure low-latency real-time stream properties
        configureProperty(key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        configureProperty(key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // No B-Frames
        configureProperty(key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        configureProperty(key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        configureProperty(key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 4) as CFNumber) // I-frame every 4 seconds
        
        // H.264 bitrate limits: e.g., target 6 Mbps, max 8 Mbps
        let averageBitrate = 6_000_000
        configureProperty(key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrate as CFNumber)
        let maxDataRate = averageBitrate * 4 / 3
        let maxDataRateBytes = maxDataRate / 8
        configureProperty(key: kVTCompressionPropertyKey_DataRateLimits, value: [maxDataRateBytes, 1] as CFArray)
        
        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        if prepStatus != noErr {
            logger.fault("Failed to prepare VTCompressionSession. Error: \(prepStatus)")
            stopSession()
            return false
        }
        
        logger.info("VTCompressionSession prepared and running.")
        return true
    }
    
    /// Encodes a single CVPixelBuffer.
    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = compressionSession else { return }
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            logger.error("Failed to encode frame. Error: \(status)")
        }
    }
    
    /// Shuts down the encoder session.
    public func stopSession() {
        guard let session = compressionSession else { return }
        logger.info("Tearing down VideoToolbox session...")
        VTCompressionSessionInvalidate(session)
        self.compressionSession = nil
        logger.info("VideoToolbox session release complete.")
    }
    
    private func configureProperty(key: CFString, value: AnyObject) {
        guard let session = compressionSession else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            logger.warning("Failed to configure encoder property \(key as String). Error: \(status)")
        }
    }
    
    // MARK: - Internal Frame Processing
    
    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // 1. Check if the frame is a keyframe (needs parameter set extraction)
        let isKeyframe = isSampleBufferKeyframe(sampleBuffer)
        
        if isKeyframe {
            extractAndSendSpsPps(from: sampleBuffer)
        }
        
        // 2. Extract raw H.264 slice data (AVCC format)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            logger.error("Failed to extract block buffer pointer. Error: \(status)")
            return
        }
        
        // Write the H.264 frame payload (which is a series of length-prefixed NAL units) directly to the stream.
        let frameData = Data(bytes: pointer, count: totalLength)
        delegate?.didEncodeFrame(data: frameData)
    }
    
    private func isSampleBufferKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [CFDictionary],
              !attachments.isEmpty else {
            return false
        }
        let dict = attachments[0]
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        if CFDictionaryContainsKey(dict, key) {
            let notSyncValue = CFDictionaryGetValue(dict, key)
            let notSync = Unmanaged<CFBoolean>.fromOpaque(notSyncValue!).takeUnretainedValue()
            return !CFBooleanGetValue(notSync)
        }
        return true // Default to true if key is absent
    }
    
    private func extractAndSendSpsPps(from sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        
        guard status == noErr else {
            logger.error("Failed to read parameter set counts. Error: \(status)")
            return
        }
        
        for index in 0..<parameterSetCount {
            var paramPointer: UnsafePointer<UInt8>?
            var paramSize = 0
            
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &paramPointer,
                parameterSetSizeOut: &paramSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            
            if status == noErr, let pointer = paramPointer {
                // Pack this SPS/PPS block as a standard packet payload:
                // Prepend with a 4-byte length header to conform to the custom length-prefixed framing format.
                var lengthBytes = UInt32(paramSize).bigEndian
                var packetData = Data(bytes: &lengthBytes, count: 4)
                packetData.append(pointer, count: paramSize)
                
                logger.info("Extracted parameter set [\(index)]. Size: \(paramSize) bytes. Queueing to pipeline.")
                delegate?.didEncodeFrame(data: packetData)
            } else {
                logger.error("Failed to read parameter set at index \(index). Error: \(status)")
            }
        }
    }
}

// MARK: - C Callback for VTCompressionSession

private func encodingOutputCallback(
    _ outputCallbackRefCon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer = sampleBuffer else {
        return
    }
    
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedSampleBuffer(sampleBuffer)
}
