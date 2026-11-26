import AppKit
import ApplicationServices

enum WindowMover {
    enum Result: Sendable { case moved, skipped, failed }
    enum Destination: Sendable { case main, external }
    struct ToggleResult: Sendable {
        let result:Result
        let destination:Destination
        let frame:CGRect?
    }
    static func destinationForToggle(window:CGRect,external:CGRect) -> Destination {
        external.contains(CGPoint(x:window.midX,y:window.midY)) ? .main : .external
    }
    private final class Handle: @unchecked Sendable {
        // AX handles are retained immutable references. The caller serializes
        // movement with its busy flag and never uses this handle concurrently.
        let element:AXUIElement
        init(_ element:AXUIElement) { self.element=element }
    }
    static func toggleAsync(_ window:AXUIElement,main:CGRect,external:CGRect) async -> ToggleResult {
        let handle=Handle(window)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                guard let current=WindowDiscovery.rect(handle.element) else {
                    continuation.resume(returning:ToggleResult(result:.skipped,destination:.external,frame:nil))
                    return
                }
                let destination=destinationForToggle(window:current,external:external)
                let result=move(handle.element,to:destination == .main ? main : external)
                continuation.resume(returning:ToggleResult(result:result,destination:destination,frame:WindowDiscovery.rect(handle.element)))
            }
        }
    }
    static func move(_ window:AXUIElement,to frame:CGRect) -> Result {
        var pid:pid_t=0
        if AXUIElementGetPid(window,&pid) == .success && pid==getpid() && !Thread.isMainThread { return .skipped }
        AXUIElementSetMessagingTimeout(window,1.0)
        guard let role=WindowDiscovery.value(window,"AXRole") as? String,
              WindowDiscovery.validRole(role), WindowDiscovery.validFrame(frame) else { return .skipped }
        if (WindowDiscovery.value(window,"AXMinimized") as? Bool)==true ||
           (WindowDiscovery.value(window,"AXFullScreen") as? Bool)==true { return .skipped }
        guard let old=WindowDiscovery.rect(window) else { return .skipped }
        let r=harbor_place(HarborRect(x:old.minX,y:old.minY,width:old.width,height:old.height),
                           HarborRect(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height))
        var point=CGPoint(x:r.x,y:r.y), size=CGSize(width:r.width,height:r.height)
        var canMove=DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&canMove) == .success,
              canMove.boolValue else { return .skipped }
        if abs(old.width-r.width)>1 || abs(old.height-r.height)>1 {
            guard let value=AXValueCreate(.cgSize,&size),
                  AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,value) == .success else { return .failed }
        }
        guard let value=AXValueCreate(.cgPoint,&point),
              AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,value) == .success else { return .failed }
        // Some applications acknowledge before applying their new position.
        for attempt in 0..<6 {
            if let actual=WindowDiscovery.rect(window), abs(actual.minX-r.x)<3,
               abs(actual.minY-r.y)<3, frame.insetBy(dx:-3,dy:-3).contains(actual) { return .moved }
            if attempt<5 { Thread.sleep(forTimeInterval:0.05) }
        }
        return .failed
    }
}
