//
//  ViewController.swift
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

import UIKit
import Metal
import MetalKit
import ARKit

let screenBounds = UIScreen.main.bounds
let screenScale = UIScreen.main.scale
let screenSize = CGSize(width: screenBounds.size.width * screenScale, height: screenBounds.size.height * screenScale)

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate, CapturePipelineDelegate {
    
    var renderer: Renderer!
    
    private var capturePipeline: CapturePipeline!
    
    private var isRecording: Bool = false
    
    @IBOutlet weak var recordingButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view to use the default device
        if let view = self.view as? MTKView {
            view.device = MTLCreateSystemDefaultDevice()
            view.backgroundColor = UIColor.clear
            view.delegate = self
            view.framebufferOnly = false
            guard view.device != nil else {
                print("Metal is not supported on this device")
                return
            }
            
            capturePipeline = CapturePipeline(frameSize: screenSize, delegate: self, callbackQueue: DispatchQueue.main)
            
            // Configure the renderer to draw to the view
            renderer = Renderer(capturePipline: capturePipeline, metalDevice: view.device!, renderDestination: view)
            
            renderer.drawRectResized(size: screenSize)
        }
        
       
    
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        

    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
    }
    
    // MARK: Actions
    
    @IBAction func toggleRecordingState(_ sender: Any) {
        if isRecording {
            capturePipeline.stopRecording()
        }else{
            capturePipeline.startRecording()
        }
    }
    
    
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        renderer.update()
    }
    
    // MARK: - CapturePipelineDelegate
    func capturePipeline(_ capturePipeline: CapturePipeline, didStopRunningWithError error: Error) {

    }
    
    func capturePipelineRecordingDidStart(_ capturePipeline: CapturePipeline) {
        recordingButton.isEnabled = true
        recordingButton.setTitle("Stop Recording", for: .normal)
        isRecording = true
    }
    
    func capturePipelineRecordingWillStop(_ capturePipeline: CapturePipeline) {
        recordingButton.isEnabled = false
    }
    
    func capturePipelineRecordingDidStop(_ capturePipeline: CapturePipeline) {
        recordingButton.setTitle("Start Recording", for: .normal)
        recordingButton.isEnabled = true
        isRecording = false
    }
    
    func capturePipeline(_ capturePipeline: CapturePipeline, recordingDidFailWithError error: Error) {

    }
}
