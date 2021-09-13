//
//  RenderState.swift
//  Solutions
//
//  Created by noah on 2021/9/13.
//
import MetalKit

class RenderState {
    static let shared = RenderState()
    var blitTexture: MTLTexture!
}
