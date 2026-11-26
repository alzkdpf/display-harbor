import AppKit
import ApplicationServices

@main enum DiscoveryTests {
    static func main() {
        let frame=CGRect(x:-1440,y:25,width:900,height:700)
        let visible=VisibleWindow(id:42,pid:123,app:"Fixture",title:"",frame:frame)
        // Regression: malformed AXApplication entries must not erase CG windows.
        assert(!WindowDiscovery.validRole("AXApplication"))
        assert(WindowDiscovery.validRole("AXWindow"))
        let cgOnly=WindowDiscovery.merge(visible:[visible],accessible:[],trusted:true)
        assert(cgOnly.count==1 && cgOnly[0].id=="cg:42")
        assert(cgOnly[0].element==nil && !cgOnly[0].canMove && cgOnly[0].title=="창 #42")
        print("PASS malformed AX data retains visible window")

        let denied=WindowDiscovery.merge(visible:[visible],accessible:[],trusted:false)
        assert(denied.count==1 && denied[0].reason.contains("권한"))
        print("PASS permission denial retains read-only list")

        // This object is a placeholder for merge tests, never sent movement calls.
        let placeholder=AXUIElementCreateApplication(getpid())
        let ax=AccessibleWindow(pid:123,app:"Fixture",title:"Example",frame:frame,element:placeholder,canMove:true,reason:"이동 가능")
        let matched=WindowDiscovery.merge(visible:[visible],accessible:[ax],trusted:true)
        assert(matched.count==1 && matched[0].canMove && matched[0].title=="Example")
        print("PASS unique pid and negative-coordinate frame match")

        let duplicate=WindowDiscovery.merge(visible:[visible],accessible:[ax,ax],trusted:true)
        assert(duplicate.count==1 && !duplicate[0].canMove)
        print("PASS ambiguous AX match stays read-only")

        let otherRow=VisibleWindow(id:43,pid:123,app:"Fixture",title:"",frame:frame)
        let ambiguousCG=WindowDiscovery.merge(visible:[visible,otherRow],accessible:[ax],trusted:true)
        assert(ambiguousCG.count==2 && ambiguousCG.allSatisfy{!$0.canMove})
        print("PASS ambiguous visible windows stay read-only")

        let otherPID=VisibleWindow(id:44,pid:456,app:"Fixture",title:"Example",frame:frame)
        let unmatched=WindowDiscovery.merge(visible:[otherPID],accessible:[ax],trusted:true)
        assert(unmatched.first(where:{$0.id=="cg:44"})?.canMove==false)
        print("PASS same title and frame across processes does not match")

        assert(!WindowDiscovery.validFrame(.zero))
        assert(!WindowDiscovery.validFrame(CGRect(x:CGFloat.infinity,y:0,width:100,height:100)))
        assert(WindowDiscovery.validFrame(frame))
        print("PASS invalid geometry rejected")
        assert(WindowDiscovery.isSystemSurface(bundleID:"com.apple.WindowManager",executablePath:"/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"))
        assert(!WindowDiscovery.isSystemSurface(bundleID:"com.example.WindowManager",executablePath:"/Applications/WindowManager.app/Contents/MacOS/WindowManager"))
        assert(!WindowDiscovery.isSystemSurface(bundleID:"com.apple.WindowManager",executablePath:"/Applications/WindowManager.app/Contents/MacOS/WindowManager"))
        assert(!WindowDiscovery.isSystemSurface(bundleID:"com.apple.finder",executablePath:"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
        assert(!WindowDiscovery.isSystemSurface(bundleID:nil,executablePath:nil))
        print("PASS exclude Apple WindowManager without hiding third-party apps or Finder")
        assert(WindowDiscovery.movableItems(cgOnly,trusted:true).isEmpty)
        assert(WindowDiscovery.movableItems(matched,trusted:false).isEmpty)
        assert(WindowDiscovery.movableItems(matched,trusted:true).count==1)
        let restricted=WindowItem(id:"restricted",pid:123,app:"Fixture",title:"Blocked",frame:frame,element:placeholder,canMove:false,reason:"최소화/전체화면/이동 미지원")
        assert(WindowDiscovery.movableItems(matched+[restricted]+cgOnly,trusted:true).map(\.id)==["cg:42"])
        let missingHandle=WindowItem(id:"missing",pid:123,app:"Fixture",title:"No handle",frame:frame,element:nil,canMove:true,reason:"")
        assert(WindowDiscovery.movableItems([missingHandle],trusted:true).isEmpty)
        assert(WindowDiscovery.movableItems([],trusted:true).isEmpty)
        print("PASS only movable valid windows enter cards; unsupported and windowless apps omitted")
        let ext=CGRect(x:1440,y:0,width:1920,height:1080)
        assert(WindowMover.destinationForToggle(window:CGRect(x:100,y:100,width:500,height:400),external:ext) == .external)
        assert(WindowMover.destinationForToggle(window:CGRect(x:1500,y:100,width:500,height:400),external:ext) == .main)
        assert(WindowMover.destinationForToggle(window:CGRect(x:1100,y:100,width:500,height:400),external:ext) == .external)
        assert(WindowMover.destinationForToggle(window:CGRect(x:1300,y:100,width:500,height:400),external:ext) == .main)
        let left=CGRect(x:-1920,y:0,width:1920,height:1080)
        assert(WindowMover.destinationForToggle(window:CGRect(x:-1800,y:50,width:500,height:400),external:left) == .main)
        assert(WindowMover.destinationForToggle(window:CGRect(x:100,y:100,width:500,height:400),external:left) == .external)
        print("PASS toggle direction uses current frame, including negative origins and straddling windows")
        print("Discovery tests: 10 passed")
    }
}
