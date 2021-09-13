//
//  ObjC.swift
//  Solutions
//
//  Created by Noah on 2021/9/11.
//

import Foundation

func synchronized(_ object: AnyObject, block: () -> Void) {
    objc_sync_enter(object)
    block()
    objc_sync_exit(object)
}
func synchronized<T>(_ object: AnyObject, block: () -> T) -> T {
    objc_sync_enter(object)
    let result: T = block()
    objc_sync_exit(object)
    return result
}
