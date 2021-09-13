//
//  CapturePipline.swift
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

import Foundation
import UIKit
import Photos

protocol CapturePipelineDelegate: NSObjectProtocol {
    
    func capturePipeline(_ capturePipeline: CapturePipeline, didStopRunningWithError error: Error)
    
    // Recording
    func capturePipelineRecordingDidStart(_ capturePipeline: CapturePipeline)
    // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func capturePipeline(_ capturePipeline: CapturePipeline, recordingDidFailWithError error: Error)
    func capturePipelineRecordingWillStop(_ capturePipeline: CapturePipeline)
    func capturePipelineRecordingDidStop(_ capturePipeline: CapturePipeline)
}

private enum CapturePiplineRecordingStatus: Int {
    case idle = 0
    case startingRecording
    case recording
    case stoppingRecording
}

class CapturePipeline: NSObject, RecorderDelegate {
    
    private var _recorder:Recorder!
    private var _recordingURL: URL!
    private var _recordingStatus: CapturePiplineRecordingStatus = .idle
    private var _frameSize:CGSize
    private weak var _delegate: CapturePipelineDelegate?
    private var _delegateCallbackQueue: DispatchQueue?
    private var _cachePaths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory,
                                                                  FileManager.SearchPathDomainMask.userDomainMask, true)
    
    init(frameSize:CGSize, delegate: CapturePipelineDelegate, callbackQueue queue: DispatchQueue) {
        _frameSize = frameSize
        _delegate = delegate
        _delegateCallbackQueue = queue
        super.init()
    }
    
    func writeFrame(forTexture texture: MTLTexture) {
        synchronized(self) {
            if _recordingStatus == .recording {
                self._recorder.appendVideoSampleBuffer(forTexture: texture)
            }
        }
    }
    
    func startRecording() {

        synchronized(self) {
            if _recordingStatus != .idle {
                fatalError("Already recording")
            }
            
            self.transitionToRecordingStatus(.startingRecording, error: nil)
        }
        
        let callbackQueue = DispatchQueue(label: "CapturePipeline.RecorderCallback"); // guarantee ordering of callbacks with a serial queue
        let cachePath = _cachePaths[0]
        let uuid = UUID.init()
        let filePath = cachePath.appending("/\(uuid.uuidString).m4v")
        let url = URL(fileURLWithPath: filePath)
        _recordingURL = url
        let recorder = Recorder(url: _recordingURL, frameSize:_frameSize, delegate: self, callbackQueue: callbackQueue)

        _recorder = recorder

        recorder.prepareToRecord()
    }
    
    func stopRecording() {
        
        let returnFlag: Bool = synchronized(self) {
            if _recordingStatus != .recording {
                return true
            }
            self.transitionToRecordingStatus(.stoppingRecording, error: nil)
            return false
        }
        if returnFlag {return}
        
        _recorder.finishRecording() // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
    }
    
    private func transitionToRecordingStatus(_ newStatus: CapturePiplineRecordingStatus, error: Error?) {
        let oldStatus = _recordingStatus
        _recordingStatus = newStatus
        
        if newStatus != oldStatus {
            var delegateCallbackBlock: (()->Void)? = nil;
            
            if let error = error, newStatus == .idle {
                delegateCallbackBlock = {self._delegate?.capturePipeline(self, recordingDidFailWithError: error)}
            } else {
                // only the above delegate method takes an error
                if oldStatus == .startingRecording && newStatus == .recording {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingDidStart(self)}
                } else if oldStatus == .recording && newStatus == .stoppingRecording {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingWillStop(self)}
                } else if oldStatus == .stoppingRecording && newStatus == .idle {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingDidStop(self)}
                }
            }
            
            if let delegateCallbackBlock = delegateCallbackBlock {
                self.invokeDelegateCallbackAsync {
                        delegateCallbackBlock()
                }
            }
        }
    }
    
    private func invokeDelegateCallbackAsync(_ callbackBlock: @escaping ()->Void) {
        _delegateCallbackQueue?.async {
            autoreleasepool {
                callbackBlock()
            }
        }
    }
    
    
    //MARK: Recorder Delegate
    
    func recorderDidFinishPreparing(_ recorder: Recorder) {
        synchronized(self) {
            if _recordingStatus != .startingRecording {
                fatalError("Expected to be in StartingRecording state")
            }
            self.transitionToRecordingStatus(.recording, error: nil)
        }
    }
    
    func recorder(_ recorder: Recorder, didFailWithError error: Error) {
        synchronized(self) {
            _recorder = nil
            self.transitionToRecordingStatus(.idle, error: error)
        }
    }
    
    func recorderDidFinishRecording(_ recorder: Recorder) {
        synchronized(self) {
            if _recordingStatus != .stoppingRecording {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            // No state transition, we are still in the process of stopping.
            // We will be stopped once we save to the assets library.
        }
        
        _recorder = nil
        
        let phLibrary = PHPhotoLibrary.shared()
        phLibrary.performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: self._recordingURL)
        }, completionHandler: {success, error in
            
            do {
                try FileManager.default.removeItem(at: self._recordingURL)
            } catch _ {
            }
            
            synchronized(self) {
                if self._recordingStatus != .stoppingRecording {
                    fatalError("Expected to be in StoppingRecording state")
                }
                self.transitionToRecordingStatus(.idle, error: error)
            }
        })
    }
}
