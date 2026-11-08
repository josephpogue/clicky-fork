// clicky-driver: the test Mac's hands for Clicky Fork. Reads the app's accessibility tree, clicks and types, and posts
// the right-Command key the way a keyboard does. Exit codes: 0 done, 1 not found in time, 3 app not running, 64 usage.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appBundleIdentifier = ProcessInfo.processInfo.environment["DRIVER_BUNDLE_ID"] ?? "com.clickyfork.app"
let rightCommandKeyCode: CGKeyCode = 54
let rightCommandDeviceFlag: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK: which Command key is down
let leftCommandKeyCode: CGKeyCode = 55
let leftCommandDeviceFlag: UInt64 = 0x8  // NX_DEVICELCMDKEYMASK

let usageText = """
usage: clicky-driver <command>
  read                          print the app's windows and menu bar item as a tree: role | title | identifier | value
  wait <text-or-identifier> [s] wait until it is on screen (default 30 s); exit 1 on timeout
  click <text-or-identifier>    press the control with that text or identifier (waits up to 10 s)
  type <text>                   type text into the focused field
  menu-bar-click                open the app's menu bar item
  tap-right-command             press and release the right Command key, 80 ms apart
  chord-right-command <key>     hold right Command, press one letter, digit or comma key, release both
  chord-left-command <key>      hold left Command, press one letter, digit or comma key, release both
  click-at <x> <y>              move the pointer to screen point x,y and click it with a real left mouse down and up
  press-key <key>               press and release one letter or digit key with no modifier
  cursor <x> <y>                move the mouse pointer to screen point x,y
  listen [secs]                 print keyboard and mouse events seen by a listen-only tap (default 5 s)
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: - Accessibility helpers

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func childElements(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children
}

func runningAppProcessIdentifier() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).first?.processIdentifier
}

func requireAppElement() -> AXUIElement {
    guard let processIdentifier = runningAppProcessIdentifier() else { fail("app \(appBundleIdentifier) is not running", code: 3) }
    return AXUIElementCreateApplication(processIdentifier)
}

func requireAccessibilityTrust() {
    if !AXIsProcessTrusted() { fail("accessibility is not granted to this process", code: 2) }
}

/// The app's top-level things to search: every window, plus the menu bar item.
func rootElements(_ app: AXUIElement) -> [(label: String, element: AXUIElement)] {
    var roots: [(String, AXUIElement)] = []
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
        for window in list { roots.append(("window", window)) }
    }
    var extras: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success, let bar = extras {
        roots.append(("menu bar item", bar as! AXUIElement))
    }
    return roots
}

func describe(_ element: AXUIElement) -> String {
    let role = stringAttribute(element, kAXRoleAttribute)
    let title = stringAttribute(element, kAXTitleAttribute)
    let description = stringAttribute(element, kAXDescriptionAttribute)
    let identifier = stringAttribute(element, "AXIdentifier")
    let value = stringAttribute(element, kAXValueAttribute)
    return "\(role) | \(title.isEmpty ? description : title) | \(identifier) | \(value)"
}

func printTree(_ element: AXUIElement, depth: Int) {
    print(String(repeating: "  ", count: depth) + describe(element))
    if depth >= 14 { return }
    for child in childElements(element) { printTree(child, depth: depth + 1) }
}

func textsOf(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXIdentifier", kAXHelpAttribute, kAXLabelValueAttribute]
        .map { stringAttribute(element, $0) }.filter { !$0.isEmpty }
}

/// Find the first element whose identifier equals the query, else whose title, description or value equals it, else contains it.
func findElement(_ app: AXUIElement, matching query: String) -> AXUIElement? {
    var all: [AXUIElement] = []
    func collect(_ element: AXUIElement, depth: Int) {
        all.append(element)
        if depth >= 14 { return }
        for child in childElements(element) { collect(child, depth: depth + 1) }
    }
    for root in rootElements(app) { collect(root.element, depth: 0) }
    if let hit = all.first(where: { stringAttribute($0, "AXIdentifier") == query }) { return hit }
    if let hit = all.first(where: { textsOf($0).contains(query) }) { return hit }
    return all.first(where: { textsOf($0).contains(where: { $0.localizedCaseInsensitiveContains(query) }) })
}

func waitForElement(_ app: AXUIElement, matching query: String, seconds: Double) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let hit = findElement(app, matching: query) { return hit }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return nil
}

func canPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return false }
    return list.contains(kAXPressAction as String)
}

func centerOf(_ element: AXUIElement) -> CGPoint? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, let sizeValue else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

func mouseClick(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// Press the element, or the nearest ancestor that can be pressed; fall back to a real mouse click at its center.
func press(_ element: AXUIElement) {
    var current: AXUIElement? = element
    var steps = 0
    while let candidate = current, steps < 6 {
        if canPress(candidate) {
            AXUIElementPerformAction(candidate, kAXPressAction as CFString)
            return
        }
        var parent: CFTypeRef?
        current = AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parent) == .success ? (parent as! AXUIElement?) : nil
        steps += 1
    }
    if let point = centerOf(element) { mouseClick(at: point) }
}

// MARK: - Keyboard

func postCommandKey(keyCode: CGKeyCode, deviceFlag: UInt64, down: Bool, source: CGEventSource?) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
    event.type = .flagsChanged
    event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | deviceFlag) : []
    event.post(tap: .cghidEventTap)
}

func postRightCommand(down: Bool, source: CGEventSource?) {
    postCommandKey(keyCode: rightCommandKeyCode, deviceFlag: rightCommandDeviceFlag, down: down, source: source)
}

/// Holds one Command key, presses and releases `keyCode`, releases the Command key: the way a keyboard chord arrives.
func postCommandChord(commandKeyCode: CGKeyCode, deviceFlag: UInt64, keyCode: CGKeyCode, source: CGEventSource?) {
    postCommandKey(keyCode: commandKeyCode, deviceFlag: deviceFlag, down: true, source: source)
    Thread.sleep(forTimeInterval: 0.04)
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | deviceFlag)
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    postCommandKey(keyCode: commandKeyCode, deviceFlag: deviceFlag, down: false, source: source)
}

let letterKeyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
    "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43,
]

func typeText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

// MARK: - Listen

func listenForEvents(seconds: Double) {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown: print("keyDown keycode=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16))")
        case .keyUp: print("keyUp keycode=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16))")
        case .flagsChanged:
            let down = (event.flags.rawValue & rightCommandDeviceFlag) != 0 && keyCode == 54
            print("flagsChanged keycode=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16)) \(keyCode == 54 ? (down ? "right-command DOWN" : "right-command UP") : "")")
        case .mouseMoved: print("mouseMoved x=\(Int(event.location.x)) y=\(Int(event.location.y))")
        case .leftMouseDown: print("leftMouseDown x=\(Int(event.location.x)) y=\(Int(event.location.y))")
        case .leftMouseUp: print("leftMouseUp x=\(Int(event.location.x)) y=\(Int(event.location.y))")
        default: break
        }
        fflush(stdout)
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: callback, userInfo: nil) else {
        fail("could not install a listen-only event tap (Input Monitoring not granted?)", code: 2)
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("listening for \(seconds) s")
    fflush(stdout)
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

// MARK: - Commands

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usageText, code: 64) }

switch command {
case "read":
    requireAccessibilityTrust()
    let app = requireAppElement()
    let roots = rootElements(app)
    if roots.isEmpty { print("(no windows)") }
    for root in roots {
        print("[\(root.label)]")
        printTree(root.element, depth: 1)
    }
case "wait":
    guard arguments.count >= 2 else { fail(usageText, code: 64) }
    requireAccessibilityTrust()
    let app = requireAppElement()
    let seconds = arguments.count >= 3 ? (Double(arguments[2]) ?? 30) : 30
    if let hit = waitForElement(app, matching: arguments[1], seconds: seconds) {
        print("found: \(describe(hit))")
    } else {
        fail("not found within \(seconds) s: \(arguments[1])", code: 1)
    }
case "click":
    guard arguments.count >= 2 else { fail(usageText, code: 64) }
    requireAccessibilityTrust()
    let app = requireAppElement()
    guard let hit = waitForElement(app, matching: arguments[1], seconds: 10) else { fail("not found: \(arguments[1])", code: 1) }
    let before = describe(hit)
    press(hit)
    print("clicked: \(before)")
case "type":
    guard arguments.count >= 2 else { fail(usageText, code: 64) }
    typeText(arguments.dropFirst().joined(separator: " "))
case "menu-bar-click":
    requireAccessibilityTrust()
    let app = requireAppElement()
    var extras: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success, let bar = extras,
          let item = childElements(bar as! AXUIElement).first else { fail("the app has no menu bar item", code: 1) }
    press(item)
    print("clicked the menu bar item")
case "tap-right-command":
    let source = CGEventSource(stateID: .hidSystemState)
    postRightCommand(down: true, source: source)
    Thread.sleep(forTimeInterval: 0.08)
    postRightCommand(down: false, source: source)
    print("posted right Command down and up")
case "chord-right-command", "chord-left-command":
    guard arguments.count >= 2, let key = arguments[1].lowercased().first, let keyCode = letterKeyCodes[key] else { fail(usageText, code: 64) }
    let isRight = command == "chord-right-command"
    let source = CGEventSource(stateID: .hidSystemState)
    postCommandChord(commandKeyCode: isRight ? rightCommandKeyCode : leftCommandKeyCode,
                     deviceFlag: isRight ? rightCommandDeviceFlag : leftCommandDeviceFlag, keyCode: keyCode, source: source)
    print("posted \(isRight ? "right" : "left") Command + \(key)")
case "click-at":
    guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail(usageText, code: 64) }
    mouseClick(at: CGPoint(x: x, y: y))
    print("clicked at \(Int(x)),\(Int(y))")
case "press-key":
    guard arguments.count >= 2, let key = arguments[1].lowercased().first, let keyCode = letterKeyCodes[key] else { fail(usageText, code: 64) }
    let source = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    print("pressed \(key)")
case "cursor":
    guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail(usageText, code: 64) }
    let point = CGPoint(x: x, y: y)
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    print("cursor at \(Int(x)),\(Int(y))")
case "listen":
    listenForEvents(seconds: arguments.count >= 2 ? (Double(arguments[1]) ?? 5) : 5)
default:
    fail(usageText, code: 64)
}
