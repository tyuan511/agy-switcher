#!/usr/bin/swift
// 打印指定应用最前层匹配窗口的信息："id x y w h"（坐标为屏幕左上角原点），
// 供 `screencapture -l` 与 `-R` 使用。
// 用法：window-id.swift "AGY Switcher" [标题] [最小高度]
// 第二个参数按窗口标题精确匹配（如主窗口「用量」、无标题的菜单栏弹窗 ""）；
// 第三个参数按窗口高度过滤（用于跳过 1px 高的状态栏按钮窗口）。
// 省略标题时保持旧行为：取最前层的普通窗口（layer 0）。
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let name = arguments[1]
let title = arguments.count > 2 ? arguments[2] : nil
let minHeight = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
let options: CGWindowListOption = [.optionOnScreenOnly]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for window in list where window[kCGWindowOwnerName as String] as? String == name {
    if let title, window[kCGWindowName as String] as? String ?? "" != title { continue }
    if title == nil, window[kCGWindowLayer as String] as? Int != 0 { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    if minHeight > 0, bounds["Height"] ?? 0 < minHeight { continue }
    guard let id = window[kCGWindowNumber as String] as? Int,
          let x = bounds["X"], let y = bounds["Y"],
          let width = bounds["Width"], let height = bounds["Height"] else { continue }
    print("\(id) \(Int(x)) \(Int(y)) \(Int(width)) \(Int(height))")
    exit(0)
}
exit(1)
