import AppKit
import ApplicationServices

struct AppDescriptor {
    let pid: pid_t
    let name: String
}

struct WindowItem: Identifiable {
    let id: String
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect
    let element: AXUIElement?
    let canMove: Bool
    let reason: String
}

struct VisibleWindow {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect
}

struct AccessibleWindow {
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let canMove: Bool
    let reason: String
}

struct WindowScan {
    let items: [WindowItem]
    let summary: String
    let diagnostics: String
    let warning: String?
}

enum WindowDiscovery {
    static func movableItems(_ items:[WindowItem],trusted:Bool) -> [WindowItem] {
        guard trusted else { return [] }
        return items.filter { $0.canMove && $0.element != nil && validFrame($0.frame) }
    }
    // Exclude Apple's composition surfaces, never a third-party app merely
    // named WindowManager. Finder and System Settings remain user applications.
    static func isSystemSurface(bundleID:String?, executablePath:String?) -> Bool {
        bundleID=="com.apple.WindowManager" && executablePath=="/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
    }
    static func value(_ element:AXUIElement, _ key:String) -> CFTypeRef? {
        var result:CFTypeRef?
        return AXUIElementCopyAttributeValue(element,key as CFString,&result) == .success ? result : nil
    }
    static func rect(_ element:AXUIElement) -> CGRect? {
        guard let p = value(element,"AXPosition"), CFGetTypeID(p)==AXValueGetTypeID(),
              let s = value(element,"AXSize"), CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p,to:AXValue.self),.cgPoint,&origin),
              AXValueGetValue(unsafeBitCast(s,to:AXValue.self),.cgSize,&size) else { return nil }
        let frame = CGRect(origin:origin,size:size)
        return validFrame(frame) ? frame : nil
    }
    static func validFrame(_ frame:CGRect) -> Bool {
        [frame.minX,frame.minY,frame.width,frame.height].allSatisfy { $0.isFinite } && frame.width>1 && frame.height>1
    }
    static func validRole(_ role:String) -> Bool {
        ["AXWindow","AXDialog","AXSheet","AXDrawer"].contains(role)
    }
    static func sameFrame(_ a:CGRect,_ b:CGRect) -> Bool {
        abs(a.minX-b.minX)<3 && abs(a.minY-b.minY)<3 && abs(a.width-b.width)<3 && abs(a.height-b.height)<3
    }
    // Never match only by app name/title. Identically placed windows must have a
    // unique match, otherwise the visible row remains read-only.
    static func merge(visible:[VisibleWindow], accessible:[AccessibleWindow], trusted:Bool) -> [WindowItem] {
        var used = Set<Int>()
        var items:[WindowItem] = []
        for cg in visible {
            var candidates = accessible.indices.filter { !used.contains($0) && accessible[$0].pid==cg.pid && sameFrame(accessible[$0].frame,cg.frame) }
            if candidates.count>1 && !cg.title.isEmpty {
                candidates = candidates.filter { accessible[$0].title==cg.title }
            }
            // Ambiguity in the CG source must not pick the wrong window either.
            let duplicateRows = visible.filter { $0.pid==cg.pid && sameFrame($0.frame,cg.frame) &&
                (cg.title.isEmpty || $0.title.isEmpty || $0.title==cg.title) }.count
            if candidates.count==1 && duplicateRows==1, let index = candidates.first {
                used.insert(index)
                let ax=accessible[index]
                items.append(WindowItem(id:"cg:\(cg.id)",pid:cg.pid,app:cg.app,
                    title:cg.title.isEmpty ? ax.title : cg.title,frame:cg.frame,
                    element:ax.element,canMove:ax.canMove,reason:ax.reason))
            } else {
                items.append(WindowItem(id:"cg:\(cg.id)",pid:cg.pid,app:cg.app,
                    title:cg.title.isEmpty ? "창 #\(cg.id)" : cg.title,frame:cg.frame,element:nil,canMove:false,
                    reason:trusted ? "목록만 조회 가능 · macOS 창 제어 정보 없음" : "목록 조회됨 · 이동하려면 손쉬운 사용 권한 필요"))
            }
        }
        // Keep AX-only windows (e.g. minimized or other Spaces) when discovery
        // gave a real window; suppress candidates ambiguous with visible rows.
        for index in accessible.indices where !used.contains(index) {
            let ax=accessible[index]
            if visible.contains(where: { $0.pid==ax.pid && sameFrame($0.frame,ax.frame) }) { continue }
            items.append(WindowItem(id:"ax:\(ax.pid):\(index)",pid:ax.pid,app:ax.app,
                title:ax.title,frame:ax.frame,element:ax.element,canMove:ax.canMove,reason:ax.reason))
        }
        return items.sorted { ($0.app,$0.title,$0.id)<($1.app,$1.title,$1.id) }
    }
    static func visibleWindows(excluding excluded:Set<pid_t>) -> (items:[VisibleWindow], hiddenSystemCount:Int) {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        var hiddenSystemCount=0
        let items:[VisibleWindow] = raw.compactMap { row in
            guard let pid=(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !excluded.contains(pid),
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue==0,
                  let id=(row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds=row[kCGWindowBounds as String] as? NSDictionary,
                  let frame=CGRect(dictionaryRepresentation:bounds), validFrame(frame),
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
            let owner=NSRunningApplication(processIdentifier:pid)
            if isSystemSurface(bundleID:owner?.bundleIdentifier,executablePath:owner?.executableURL?.path) {
                hiddenSystemCount+=1
                return nil
            }
            return VisibleWindow(id:id,pid:pid,app:row[kCGWindowOwnerName as String] as? String ?? "앱",
                title:row[kCGWindowName as String] as? String ?? "",frame:frame)
        }
        return (items,hiddenSystemCount)
    }
    static func scan(apps:[AppDescriptor],excluded:Set<pid_t>,trusted:Bool) -> WindowScan {
        let cg=visibleWindows(excluding:excluded)
        let visible=cg.items
        var accessible:[AccessibleWindow]=[]
        var errors:[Int32:Int]=[:], roles:[String:Int]=[:]
        var candidates=0
        if trusted {
            for app in apps {
                let root=AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(root,1.0)
                var raw:CFTypeRef?
                let error=AXUIElementCopyAttributeValue(root,kAXWindowsAttribute as CFString,&raw)
                if error != .success { errors[error.rawValue,default:0]+=1 }
                var elements = raw as? [AXUIElement] ?? []
                // Standard fallbacks for applications omitting AXWindows.
                for key in ["AXMainWindow","AXFocusedWindow"] {
                    if let ref=value(root,key), CFGetTypeID(ref)==AXUIElementGetTypeID() {
                        let item=unsafeBitCast(ref,to:AXUIElement.self)
                        if !elements.contains(where:{CFEqual($0,item)}) { elements.append(item) }
                    }
                }
                if let children=value(root,"AXChildren") as? [AXUIElement] {
                    for child in children.prefix(64) where !elements.contains(where:{CFEqual($0,child)}) { elements.append(child) }
                }
                for element in elements {
                    AXUIElementSetMessagingTimeout(element,1.0)
                    candidates+=1
                    let role=value(element,"AXRole") as? String ?? "읽기 실패"
                    roles[role,default:0]+=1
                    guard validRole(role), let frame=rect(element) else { continue }
                    // Application-root impostors must never become movement targets.
                    guard !CFEqual(root,element) else { continue }
                    if accessible.contains(where: { $0.pid==app.pid && CFEqual($0.element,element) }) { continue }
                    let title=value(element,"AXTitle") as? String ?? "제목 없는 창"
                    let minimized=(value(element,"AXMinimized") as? Bool)==true
                    let fullscreen=(value(element,"AXFullScreen") as? Bool)==true
                    var settable=DarwinBoolean(false)
                    let writable=AXUIElementIsAttributeSettable(element,kAXPositionAttribute as CFString,&settable) == .success && settable.boolValue
                    let canMove=writable && !minimized && !fullscreen
                    let reason=minimized ? "최소화된 창" : fullscreen ? "전체 화면 창" : writable ? "이동 가능" : "앱에서 위치 변경을 허용하지 않음"
                    accessible.append(AccessibleWindow(pid:app.pid,app:app.name,title:title,frame:frame,element:element,canMove:canMove,reason:reason))
                }
            }
        }
        let discovered=merge(visible:visible,accessible:accessible,trusted:trusted)
        let items=movableItems(discovered,trusted:trusted)
        let summary="이동 가능한 창 \(items.count)개"
        let roleText=roles.keys.sorted().map{"\($0)=\(roles[$0]!)"}.joined(separator:", ")
        let errorText=errors.keys.sorted().map{"\($0)=\(errors[$0]!)"}.joined(separator:", ")
        let warning:String? = visible.count>0 && accessible.isEmpty && trusted ?
            "권한은 허용됐지만 macOS에서 이동 가능한 창 객체를 받지 못했습니다. 표시할 카드가 없으며 창 이동을 실행할 수 없습니다." : nil
        let diagnostic="손쉬운 사용: \(trusted ? "허용" : "미허용")\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n조회 대상 앱: \(apps.count)\n화면 시스템의 앱 창: \(visible.count)\n제외한 macOS 관리용 표면: \(cg.hiddenSystemCount)\n접근성 후보: \(candidates), 유효 창: \(accessible.count)\n역할: \(roleText.isEmpty ? "없음" : roleText)\n앱 조회 오류 코드: \(errorText.isEmpty ? "없음" : errorText)\n이동 제한/제어 정보 없음으로 숨긴 항목: \(discovered.count-items.count)\n\(summary)\n\(warning ?? "지원하지 않는 창은 카드에 표시하지 않습니다.")"
        return WindowScan(items:items,summary:summary,diagnostics:diagnostic,warning:warning)
    }
}
