import Flutter
import UIKit
import AVFoundation
import Accelerate
import CoreMotion
import HaishinKit
import os
import ReplayKit
import VideoToolbox

@objc
public class FlutterRTMPStreaming : NSObject {
    private var rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream!
    private var url: String? = nil
    private var name: String? = nil
    private var retries: Int = 0
    private let eventSink: FlutterEventSink
    private let myDelegate = MyRTMPStreamQoSDelagate()
    
    @objc
    public init(sink: @escaping FlutterEventSink) {
        eventSink = sink
    }
    
    @objc
    public func open(url: String, width: Int, height: Int, bitrate: Int) {
        rtmpStream = RTMPStream(connection: rtmpConnection)
        rtmpStream.sessionPreset = AVCaptureSession.Preset.inputPriority
        rtmpStream.videoCapture(for: 0)?.preferredVideoStabilizationMode = .auto
        rtmpStream.videoCapture(for: 0)?.device?.exposureMode = .continuousAutoExposure
        rtmpStream.videoCapture(for: 0)?.device?.focusMode = .continuousAutoFocus

//        rtmpStream.captureSettings = [
//            .sessionPreset: AVCaptureSession.Preset.hd1280x720,
//            .continuousAutofocus: true,
//            .continuousExposure: true
//        ]
        rtmpConnection.addEventListener(.rtmpStatus, selector:#selector(rtmpStatusHandler), observer: self)
        rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
        
        let uri = URL(string: url)
        self.name = uri?.pathComponents.last
        var bits = url.components(separatedBy: "/")
        bits.removeLast()
        self.url = bits.joined(separator: "/")
        
        rtmpStream.videoSettings = VideoCodecSettings(videoSize: CGSize.init(width: width, height: height),
profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String,maxKeyFrameIntervalDuration: Int32(2)        )
        rtmpStream.videoSettings.bitRate = bitrate

        
//
//        rtmpStream.videoSettings = VideoCodecSettings(videoSize: VideoSize(width: Int32(width), height: Int32(height)),
//                                                      profileLevel:kVTProfileLevel_H264_Baseline_AutoLevel as String,
//                                                      bitRate: UInt32(bitrate),
//                                                      maxKeyFrameIntervalDuration: Int32(2)
//        )
        
//        [
//            self.width: width,
//            .height: height,
//            .profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
//            .maxKeyFrameIntervalDuration: 2,
//            .bitrate: bitrate
//        ]
        
//        rtmpStream.captureSettings = [
//            .fps: 30
//        ]
        rtmpStream.frameRate = 30
        rtmpConnection.delegate = myDelegate
        self.retries = 0
        // Run this on the ui thread.
        DispatchQueue.main.async {
            if let orientation = DeviceUtil.videoOrientation(by:  UIApplication.shared.statusBarOrientation) {
                self.rtmpStream.videoOrientation = orientation
                print(String(format:"Orient %d", orientation.rawValue))
                switch (orientation) {
                case .landscapeLeft, .landscapeRight:
                    
                    
                    self.rtmpStream.videoSettings.videoSize = CGSize.init(width:width, height: height);
                    break;
                default:
                    break;
                }
            }
            self.rtmpConnection.connect(self.url ?? "frog")
        }
    }
    
    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        print(e)
        
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            rtmpStream.publish(name)
            retries = 0
            break
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retries <= 3 else {
                eventSink(["event" : "error",
                           "errorDescription" : "connection failed " + e.type.rawValue])
                return
            }
            retries += 1
            Thread.sleep(forTimeInterval: pow(2.0, Double(retries)))
            rtmpConnection.connect(url!)
            eventSink(["event" : "rtmp_retry",
                       "errorDescription" : "connection failed " + e.type.rawValue])
            break
        default:
            break
        }
    }
    
    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        if #available(iOS 10.0, *) {
            os_log("%s", notification.name.rawValue)
        }
        guard retries <= 3 else {
            eventSink(["event" : "rtmp_stopped",
                       "errorDescription" : "rtmp disconnected"])
            return
        }
        retries+=1
        Thread.sleep(forTimeInterval: pow(2.0, Double(retries)))
        rtmpConnection.connect(url!)
        eventSink(["event" : "rtmp_retry",
                   "errorDescription" : "rtmp disconnected"])
        
    }
    
    @objc
    public func pauseVideoStreaming() {
        rtmpStream.paused = true
    }
    
    @objc
    public func resumeVideoStreaming() {
        rtmpStream.paused = false
    }
    
    @objc
    public func isPaused() -> Bool{
        return rtmpStream.paused
    }
    
    
    @objc
    public func getStreamStatistics() -> NSDictionary {
        let ret: NSDictionary = [
            "paused": isPaused(),
            "bitrate": rtmpStream.videoSettings.bitRate,
            "width": rtmpStream.videoSettings.videoSize.width,
            "height": rtmpStream.videoSettings.videoSize.height,
            "fps": (rtmpStream.frameRate as NSNumber).floatValue,
            "orientation": rtmpStream.videoOrientation.rawValue
        ]
        //ret["cacheSize"] = rtmpConnection.bandWidth
        //ret["sentAudioFrames"] = rtmpCamera!!.sentAudioFrames
        //        ret["sentVideoFrames"] = rtmpCamera!!.sentVideoFrames
        //if (rtmpCamera!!.droppedAudioFrames == null) {
        //ret["droppedAudioFrames"] = 0
        //} else {
        //ret["droppedAudioFrames"] = rtmpCamera!!.droppedAudioFrames
        //}
        //ret["droppedVideoFrames"] = rtmpCamera!!.droppedVideoFrames
        //ret["isAudioMuted"] = rtmpCamera!!.isAudioMuted
        return ret
    }
    
    @objc
    public func addVideoData(buffer: CMSampleBuffer) {
        if let description = CMSampleBufferGetFormatDescription(buffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            
//            rtmpStream.videoSettings =      VideoCodecSettings(videoSize: VideoSize(width: Int32(dimensions.width), height: Int32(dimensions.height)),
//                                                          profileLevel:kVTProfileLevel_H264_Baseline_AutoLevel as String,
//                                                          bitRate: UInt32(1200 * 1024),
//                                                          maxKeyFrameIntervalDuration: Int32(2))
            
            rtmpStream.videoSettings = VideoCodecSettings(videoSize: CGSize.init(width: Int(dimensions.width), height: Int(dimensions.height)),
    profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String,maxKeyFrameIntervalDuration: Int32(2)        )
            rtmpStream.frameRate = 24
            rtmpStream.videoSettings.bitRate = 1200 * 1024
//            rtmpStream.videoSettings = [
//                .width: dimensions.width,
//                .height: dimensions.height,
//                .profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
//                .maxKeyFrameIntervalDuration: 2,
//                .bitrate: 1200 * 1024
//            ]
//            rtmpStream.captureSettings = [
//                .fps: 24
//            ]
        }
        rtmpStream.append(buffer)
    }
    
    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        rtmpStream.append( buffer)
    }
    
    @objc
    public func close() {
        rtmpConnection.close()
    }
}


class MyRTMPStreamQoSDelagate: RTMPConnectionDelegate {
    func connection(_ connection: HaishinKit.RTMPConnection, publishInsufficientBWOccured stream: HaishinKit.RTMPStream) {
        
        guard let videoBitrate = stream.videoSettings.bitRate as? Int else { return }
            
            var         newVideoBitrate = videoBitrate / 2
            if newVideoBitrate < minBitrate {
                newVideoBitrate = minBitrate
            }
            print("didPublishInsufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
        stream.videoSettings.bitRate = newVideoBitrate
       
   
    }
    
    func connection(_ connection: HaishinKit.RTMPConnection, publishSufficientBWOccured stream: HaishinKit.RTMPStream) {
        
            
             let videoBitrate = stream.videoSettings.bitRate
            
            var newVideoBitrate = videoBitrate + Int(incrementBitrate)
            if newVideoBitrate > maxBitrate {
                newVideoBitrate = maxBitrate
            }
            print("didPublishSufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
            stream.videoSettings.bitRate = newVideoBitrate
        
    }
    
    func connection(_ connection: HaishinKit.RTMPConnection, updateStats stream: HaishinKit.RTMPStream) {
        
    }
    
    let minBitrate: Int = 300 * 1024
    let maxBitrate: Int = 2500 * 1024
    let incrementBitrate: Int = 512 * 1024
    
//    func didPublishSufficientBW(_ stream: RTMPStream, withConnection: RTMPConnection) {
//        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
//        
//        var newVideoBitrate = videoBitrate + incrementBitrate
//        if newVideoBitrate > maxBitrate {
//            newVideoBitrate = maxBitrate
//        }
//        print("didPublishSufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
//        stream.videoSettings[.bitrate] = newVideoBitrate
//    }
//    
//    
//    // detect upload insufficent BandWidth
//    func didPublishInsufficientBW(_ stream:RTMPStream, withConnection:RTMPConnection) {
//        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
//        
//        var         newVideoBitrate = UInt32(videoBitrate / 2)
//        if newVideoBitrate < minBitrate {
//            newVideoBitrate = minBitrate
//        }
//        print("didPublishInsufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
//        stream.videoSettings[.bitrate] = newVideoBitrate
//    }
//    
//    func clear() {
//    }
}
