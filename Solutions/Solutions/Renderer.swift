//
//  Renderer.swift
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

import Foundation
import MetalKit

protocol RenderDestinationProvider {
    var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
    var currentDrawable: CAMetalDrawable? { get }
    var colorPixelFormat: MTLPixelFormat { get set }
    var depthStencilPixelFormat: MTLPixelFormat { get set }
    var sampleCount: Int { get set }
}

// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 3

// The max number anchors our uniform buffer will hold
let kMaxAnchorInstanceCount: Int = 64

// The 16 byte aligned size of our uniform structures
let kAlignedSharedUniformsSize: Int = (MemoryLayout<SharedUniforms>.size & ~0xFF) + 0x100
let kAlignedInstanceUniformsSize: Int = ((MemoryLayout<InstanceUniforms>.size * kMaxAnchorInstanceCount) & ~0xFF) + 0x100

// Vertex data for an image plane
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
]


class Renderer {
    
    let device: MTLDevice
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    var renderDestination: RenderDestinationProvider
    
    // Metal objects
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var imagePlaneVertexBuffer: MTLBuffer!
    var sharedUniformBuffer: MTLBuffer!
    var sharedUniformBufferOffset: Int = 0
    var sharedUniformBufferAddress: UnsafeMutableRawPointer!
    var uniformBufferIndex: Int = 0
    
    // CapturePipeline
    var capturePipline: CapturePipeline
    
    // The current viewport size
    var viewportSize: CGSize = CGSize()
    
    // Flag for viewport size changes
    var viewportSizeDidChange: Bool = false
    

    // Time
    var startTime = Date()
    
    
    init(capturePipline:CapturePipeline, metalDevice device: MTLDevice, renderDestination: RenderDestinationProvider) {
        self.capturePipline = capturePipline
        self.device = device
        self.renderDestination = renderDestination
        loadMetal()
    }
    
    func drawRectResized(size: CGSize) {
        viewportSize = size
        viewportSizeDidChange = true
    }
    
    func update() {
        // Wait to ensure only kMaxBuffersInFlight are getting processed by any stage in the Metal
        //   pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        if let commandBuffer = commandQueue.makeCommandBuffer() {
            commandBuffer.label = "MyCommand"
            let texture = renderDestination.currentDrawable?.texture
            commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.inFlightSemaphore.signal()
                    strongSelf.capturePipline.writeFrame(forTexture: texture!)
                }
            }
            updateBufferStates()
            if let renderPassDescriptor = renderDestination.currentRenderPassDescriptor, let currentDrawable = renderDestination.currentDrawable, let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "MyRenderEncoder"
                renderEncoder.setRenderPipelineState(pipelineState)
                renderEncoder.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: Int(kBufferIndexMeshPositions.rawValue))
                renderEncoder.setFragmentBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
                renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                renderEncoder.popDebugGroup()
                renderEncoder.endEncoding()
                commandBuffer.present(currentDrawable)
            }
            
            // Finalize rendering here & push the command buffer to the GPU
            commandBuffer.commit()
        }
    }
    
    // MARK: - Private
    
    func loadMetal() {
    
        renderDestination.depthStencilPixelFormat = .depth32Float
        renderDestination.colorPixelFormat = .bgra8Unorm
        renderDestination.sampleCount = 1
        
        let sharedUniformBufferSize = kAlignedSharedUniformsSize * kMaxBuffersInFlight
        sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize, options: .storageModeShared)
        sharedUniformBuffer.label = "SharedUniformBuffer"
        
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        imagePlaneVertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
        
        // Load all the shader files with a metal file extension in the project
        let defaultLibrary = device.makeDefaultLibrary()!
        
        let vertexFunction = defaultLibrary.makeFunction(name: "vertex_001")!
        let fragmentFunction = defaultLibrary.makeFunction(name: "fragment_001")!
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        vertexDescriptor.layouts[0].stride = 16
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.label = "ShaderPipeline"
        pipelineStateDescriptor.sampleCount = renderDestination.sampleCount
        pipelineStateDescriptor.vertexFunction = vertexFunction
        pipelineStateDescriptor.fragmentFunction = fragmentFunction
        pipelineStateDescriptor.vertexDescriptor = vertexDescriptor
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        pipelineStateDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        do {
            try pipelineState = device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
        commandQueue = device.makeCommandQueue()
        
    }
    
    func updateBufferStates() {
        uniformBufferIndex = (uniformBufferIndex + 1) % kMaxBuffersInFlight
        sharedUniformBufferOffset = kAlignedSharedUniformsSize * uniformBufferIndex
        sharedUniformBufferAddress = sharedUniformBuffer.contents().advanced(by: sharedUniformBufferOffset)
        
        let uniforms = sharedUniformBufferAddress.assumingMemoryBound(to: SharedUniforms.self)
        // Time
        uniforms.pointee.time = Float(Date().timeIntervalSince(startTime))
        // Res
        let res: vector_float2 = vector2(Float(viewportSize.width), Float(viewportSize.height))
        uniforms.pointee.res = res
    }
}
