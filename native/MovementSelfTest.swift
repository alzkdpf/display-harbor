import AppKit
import ApplicationServices

// Standalone fixture test. Compile separately; this is not part of the app.
@MainActor final class FixtureDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard let screen=NSScreen.screens.first else { exit(1) }
        let f=screen.visibleFrame
        window=NSWindow(contentRect:NSRect(x:f.minX+40,y:f.maxY-300,width:320,height:220),
            styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Display Harbor movement fixture"
        window.makeKeyAndOrderFront(nil)
        let top=screen.frame.maxY
        let wholeMain=CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height)
        let main:CGRect
        let external:CGRect
        let realExternal=NSScreen.screens.dropFirst().first
        if let second=realExternal {
            main=wholeMain
            let v=second.visibleFrame
            external=CGRect(x:v.minX,y:top-v.maxY,width:v.width,height:v.height)
        } else {
            main=CGRect(x:wholeMain.minX,y:wholeMain.minY,width:wholeMain.width/2,height:wholeMain.height)
            external=CGRect(x:wholeMain.midX,y:wholeMain.minY,width:wholeMain.width/2,height:wholeMain.height)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            Task { @MainActor in
                let root=AXUIElementCreateApplication(getpid())
                let windows=WindowDiscovery.value(root,"AXWindows") as? [AXUIElement] ?? []
                guard let element=windows.first(where:{(WindowDiscovery.value($0,"AXTitle") as? String)=="Display Harbor movement fixture"}),
                      let old=WindowDiscovery.rect(element) else {
                    print("MOVE_FIXTURE failed: own AX window unavailable")
                    exit(1)
                }
                let firstDirection=WindowMover.destinationForToggle(window:old,external:external)
                let first=WindowMover.move(element,to:firstDirection == .external ? external : main)
                guard let away=WindowDiscovery.rect(element) else { exit(1) }
                let secondDirection=WindowMover.destinationForToggle(window:away,external:external)
                let second=WindowMover.move(element,to:secondDirection == .main ? main : external)
                let actual=WindowDiscovery.rect(element)
                let passed=first == .moved && second == .moved && firstDirection == .external && secondDirection == .main &&
                    external.contains(CGPoint(x:away.midX,y:away.midY)) && actual != nil &&
                    main.contains(CGPoint(x:actual!.midX,y:actual!.midY)) &&
                    !external.contains(CGPoint(x:actual!.midX,y:actual!.midY))
                print("MOVE_FIXTURE physicalExternal=\(realExternal != nil) outward=\(first) return=\(second) roundTripVerified=\(passed)")
                exit(passed ? 0 : 1)
            }
        }
    }
}
@main enum MovementSelfTest {
    @MainActor static func main() {
        let app=NSApplication.shared
        let delegate=FixtureDelegate()
        app.setActivationPolicy(.regular)
        app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
