# SolvingSlowPerformanceOfGetBytes

This is a demo project showing solutions of slow performance of getBytes(_:bytesPerRow:bytesPerImage:from:mipmapLevel:slice:).

This project can record MTKView's contents as video. You can modify it and check the video (FPS, Image Glitches) to test the performance.

This project is my simple implementation basing on the reply of Feedback. You can checkout different branches to see different solutions.

## Reply

This likely has to do with the internal representation of the texture data, which on certain newer Apple Silicon GPU can be compressed so as to save on bandwidth and power. However, when the CPU needs to make a copy into user memory (ie: via getBytes), it needs to perform decompression, which is what the perf issue you found likely is. 

There is several ways to deal with this, the best one depends on how the texture is being used by your application, which we don’t know, so we’ll just list a few options: 

1) Instead of using getBytes into user memory, allocate a MTLBuffer of the same size and issue a GPU blit from the texture into the buffer right after the texture contents you want to get have been computed on the GPU. Then, instead of calling getBytes, just read through the .contents pointer of the buffer. Additional tips for this case: create and reuse from a pool of MTLBuffer to avoid resource creation and destruction repeatedly. 

2) Keep using getBytes as you already do. However, make the GPU change the representation of the texture to be friendly to the CPU after the texture contents have been computed on the GPU. See https://developer.apple.com/documentation/metal/mtlblitcommandencoder/2966538-optimizecontentsforcpuaccess. This burns some GPU cycles, but is probably the least intrusive change. To avoid burning the GPU cycles, see the next option. 

3) Adjust the texture creation (this assumes you are creating the MTLTexture instance in your code, if it occurs elsewhere outside of your control, this option may not be possible). On the MTLTextureDescriptor, set this property to NO: https://developer.apple.com/documentation/metal/mtltexturedescriptor/2966641-allowgpuoptimizedcontents. This will make the GPU never use compressed internal representation for this texture (and you lose the GPU badwidth/power benefits, but if your usecase involves frequent CPU access, it can be a good tradeoff). 

Since all of these options are essentially performance tradeoffs, you should review the app performance before and after the change to verify you see the expected upside, and no (or acceptable) downsides elsewhere. 

## Branch - main

This is the original version using getBytes.

iPhone XS Max: 1242 * 2688 60FPS

iPhone 12 Pro max: 1284 * 2778 20FPS(Recoding button will be stuck on "Stop Recording" for a while, video image will tear)

## Branch - solution1

Read the .contents pointer of MTLBuffer.

```swift
var maybePixelBuffer: CVPixelBuffer? = nil
let data = RenderState.shared.blitBuffer.contents()
CVPixelBufferCreateWithBytes(nil, videoTexture!.width, videoTexture!.height, kCVPixelFormatType_32BGRA, data, 4 * videoTexture!.width, nil, nil, nil, &maybePixelBuffer)
let frameTime = CACurrentMediaTime() - self._startTimeForVideo
let presentationTime = CMTimeMakeWithSeconds(frameTime, preferredTimescale: 600)
self._videoPixelBufferAdaptor?.append(maybePixelBuffer!, withPresentationTime: presentationTime)
```

iPhone 12 Pro max: 1284 * 2778 60FPS

## Branch - solution2

```swift
let blitEncoder = commandBuffer.makeBlitCommandEncoder()
blitEncoder?.optimizeContentsForCPUAccess(texture: currentDrawable.texture)
blitEncoder?.copy(from: currentDrawable.texture, to: RenderState.shared.blitTexture)
blitEncoder?.endEncoding()
```

iPhone 12 Pro max: 1284 * 2778 60FPS (Some image glitches at beginning, may be my code's problem)

## Branch - solution3

```swift
textureDescriptor.allowGPUOptimizedContents = false
```

iPhone 12 Pro max: 1284 * 2778 60FPS