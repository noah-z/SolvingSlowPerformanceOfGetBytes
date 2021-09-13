//
//  Recorder.swift
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

import Foundation
import AVFoundation

protocol RecorderDelegate: NSObjectProtocol {
    func recorderDidFinishPreparing(_ recorder: Recorder)
    func recorder(_ recorder: Recorder, didFailWithError error: Error)
    func recorderDidFinishRecording(_ recorder: Recorder)
}

private enum RecorderStatus: Int {
    case idle = 0
    case preparingToRecord
    case recording
    // waiting for inflight buffers to be appended
    case finishingRecordingPart1
    // calling finish writing on the asset writer
    case finishingRecordingPart2
    // terminal state
    case finished
    // terminal state
    case failed
}   // internal state machine

class Recorder: NSObject {
    
    private var _status: RecorderStatus = .idle
    private var _writingQueue: DispatchQueue
    private var _url: URL
    private var _frameSize: CGSize
    
    private var _videoInput: AVAssetWriterInput?
    private var _videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var _assetWriter: AVAssetWriter?
    
    private var _startTimeForVideo = TimeInterval(0)
    
    private weak var _delegate: RecorderDelegate?
    private var _delegateCallbackQueue: DispatchQueue
    
    init(url: URL, frameSize:CGSize, delegate: RecorderDelegate, callbackQueue queue: DispatchQueue) {
        _writingQueue = DispatchQueue(label: "com.apple.sample.movierecorder.writing", attributes: [])
        _url = url
        _frameSize = frameSize
        _delegate = delegate
        _delegateCallbackQueue = queue
        super.init()
    }
    
    func prepareToRecord() {
        synchronized(self) {
            if _status != .idle {
                fatalError("Already prepared, cannot prepare again")
            }
            self.transitionToStatus(.preparingToRecord, error: nil)
        }
        
        DispatchQueue.global(qos: .background).async {
            
            autoreleasepool {
                var error: Error? = nil
                do {
                    // AVAssetWriter will not write over an existing file.
                    try FileManager.default.removeItem(at: self._url)
                } catch _ {
                }
                
                do {
                    self._assetWriter = try AVAssetWriter(outputURL: self._url, fileType: AVFileType.m4v)
                    
                    //Video
                    try self.setupAssetWriterVideoInput()
                
                    let success = self._assetWriter?.startWriting() ?? false
                    if !success {
                        error = self._assetWriter?.error
                    }
                    
                    self._assetWriter?.startSession(atSourceTime: CMTime.zero)
                    self._startTimeForVideo = CACurrentMediaTime()
                } catch let error1 {
                    error = error1
                }
                
                synchronized(self) {
                    if let error = error {
                        self.transitionToStatus(.failed, error: error)
                    } else {
                        self.transitionToStatus(.recording, error: nil)
                    }
                }
            }
        }
    }
    
    func finishRecording() {
        synchronized(self) {
            var shouldFinishRecording = false
            switch _status {
            case .idle,
                 .preparingToRecord,
                 .finishingRecordingPart1,
                 .finishingRecordingPart2,
                 .finished:
                fatalError("Not recording")
            case .failed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                NSLog("Recording has failed, nothing to do")
            case .recording:
                shouldFinishRecording = true
            }
            
            if shouldFinishRecording {
                self.transitionToStatus(.finishingRecordingPart1, error: nil)
            } else {
                return
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                    if self._status != .finishingRecordingPart1 {
                        return
                    }
                    
                    // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                    // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
                    // check func appendSampleBuffer
                    self.transitionToStatus(.finishingRecordingPart2, error: nil)
                }
                
                self._assetWriter?.finishWriting {
                    synchronized(self) {
                        print("-------- finishWriting ---------")
                        if let error = self._assetWriter?.error {
                            self.transitionToStatus(.failed, error: error)
                        } else {
                            self.transitionToStatus(.finished, error: nil)
                        }
                    }
                }
            }
        }
    }
    
    private func setupAssetWriterVideoInput() throws {
        let compressionProperties: NSDictionary = [
            AVVideoExpectedSourceFrameRateKey : 60,
            AVVideoMaxKeyFrameIntervalKey : 60]
        
        let outputSetting:[String:Any] = [AVVideoCodecKey : AVVideoCodecType.h264,
                                          AVVideoWidthKey : _frameSize.width,
                                          AVVideoHeightKey : _frameSize.height,
                                          AVVideoCompressionPropertiesKey : compressionProperties
        ]
        
        if _assetWriter?.canApply(outputSettings: outputSetting, forMediaType: AVMediaType.video) ?? false {
            _videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: outputSetting)
            _videoInput!.expectsMediaDataInRealTime = true
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String : Int(_frameSize.width),
                kCVPixelBufferHeightKey as String : Int(_frameSize.height) ]
            _videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: _videoInput!, sourcePixelBufferAttributes: sourcePixelBufferAttributes)
            
            if _assetWriter?.canAdd(_videoInput!) ?? false {
                _assetWriter!.add(_videoInput!)
            } else {
                throw type(of: self).cannotSetupInputError()
            }
        } else {
            throw type(of: self).cannotSetupInputError()
        }
    }
    
    func appendVideoSampleBuffer(forTexture texture: MTLTexture) {
        self.appendSampleBuffer(videoTexture: texture, ofMediaType: AVMediaType.video)
    }
    
    private func appendSampleBuffer(videoTexture:MTLTexture?, ofMediaType mediaType: AVMediaType) {
        
        synchronized(self) {
            if _status.rawValue < RecorderStatus.recording.rawValue {
                fatalError("Not ready to record yet")
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                    // Because of this we are lenient when samples are appended and we are no longer recording.
                    // Instead of throwing an exception we just release the sample buffers and return.
                    // Here means finished failed
                    if self._status.rawValue > RecorderStatus.finishingRecordingPart1.rawValue {
                        return
                    }
                }
                
                var maybePixelBuffer: CVPixelBuffer? = nil
                let data = RenderState.shared.blitBuffer.contents()
                CVPixelBufferCreateWithBytes(nil, videoTexture!.width, videoTexture!.height, kCVPixelFormatType_32BGRA, data, 4 * videoTexture!.width, nil, nil, nil, &maybePixelBuffer)
                let frameTime = CACurrentMediaTime() - self._startTimeForVideo
                let presentationTime = CMTimeMakeWithSeconds(frameTime, preferredTimescale: 600)
                self._videoPixelBufferAdaptor?.append(maybePixelBuffer!, withPresentationTime: presentationTime)
                
            }
        }
    }
    
    private func transitionToStatus(_ newStatus: RecorderStatus, error: Error?) {
        var shouldNotifyDelegate = false
        
        if newStatus != _status {
            // terminal states
            if newStatus == .finished || newStatus == .failed {
                shouldNotifyDelegate = true
                // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
                
                _writingQueue.async{
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .failed {
                        do {
                            try FileManager.default.removeItem(at: self._url)
                        } catch _ {
                        }
                    }
                }
            } else if newStatus == .recording {
                shouldNotifyDelegate = true
            }
            
            _status = newStatus
        }
        
        if shouldNotifyDelegate {
            _delegateCallbackQueue.async {
                
                autoreleasepool {
                    switch newStatus {
                    case .recording:
                        self._delegate?.recorderDidFinishPreparing(self)
                    case .finished:
                        self._delegate?.recorderDidFinishRecording(self)
                    case .failed:
                        self._delegate?.recorder(self, didFailWithError: error!)
                    default:
                        fatalError("Unexpected recording status (\(newStatus)) for delegate callback")
                    }
                }
            }
        }
    }
    
    private func teardownAssetWriterAndInputs() {
        _videoInput = nil
        _assetWriter = nil
    }
    
    private class func cannotSetupInputError() -> NSError {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment: "")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment: "")
        let errorDict: [String: Any] = [NSLocalizedDescriptionKey : localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }
}
