import SwiftUI
import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor final class Harbor: ObservableObject {
    @Published var enabled = false
    @Published var status = "자동 처리 꺼짐 · 수동으로 검토할 수 있습니다."
    @Published var windows: [WindowItem] = []
    @Published var screens: [NSScreen] = []
    @Published var selectedDisplay: UInt32 = 0
    @Published var trusted = false
    @Published var busy = false
    @Published var history: [String] = []
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var scanSummary = "창 새로고침으로 열려 있는 창을 확인하세요."
    @Published var scanDiagnostics = "아직 조회하지 않았습니다."
    @Published var controlWarning: String?
    @Published var previewEnabled = false
    @Published var previews: [String:NSImage] = [:]
    @Published var previewStatus = "앱 아이콘으로 표시 중 · 실제 화면 미리보기는 선택해서 켤 수 있습니다."
    @Published var movingID: String?
    @Published var lastMoved: [String:String] = [:]
    @Published var appIcons: [pid_t:NSImage] = [:]
    private var previewTask: Task<Void,Never>?
    private var previewRevision = UUID()
    private var timer: Timer?
    private var candidate = ""
    private var stableTicks = 0
    private var applied = ""
    private var activationObserver: NSObjectProtocol?

    init() {
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NotificationCenter.default.addObserver(
            forName:NSApplication.didBecomeActiveNotification, object:nil, queue:.main
        ) { [weak self] _ in Task { @MainActor in self?.recheckPermission(manual:false) } }
    }

    func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var mainScreen: NSScreen? { screens.first { displayID($0) == CGMainDisplayID() } }
    var external: [NSScreen] { screens.filter { displayID($0) != CGMainDisplayID() } }
    func onlineIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count))).sorted()
    }
    func signature() -> String {
        onlineIDs().map { id in
            let r = CGDisplayBounds(id)
            return "\(id):\(CGDisplayMirrorsDisplay(id)):\(r)"
        }.joined(separator: "|")
    }
    func log(_ message: String) {
        status = message
        history.insert("\(Date().formatted(date: .omitted, time: .standard))  \(message)", at: 0)
        history = Array(history.prefix(30))
    }
    func refresh() {
        screens = NSScreen.screens
        updateTrust()
        if !external.contains(where: { displayID($0) == selectedDisplay }) {
            selectedDisplay = external.first.map(displayID) ?? 0
        }
    }
    func updateTrust() {
        let previous = trusted
        trusted = AXIsProcessTrusted()
        if trusted && !previous {
            applied = ""; stableTicks = 0
            log("손쉬운 사용 권한 확인됨 · 창 목록을 새로고침할 수 있습니다.")
        } else if previous && !trusted {
            windows=[]
            previews=[:]
            previewTask?.cancel()
            previewRevision=UUID()
            log("손쉬운 사용 권한이 해제되었습니다. 권한을 다시 확인해 주세요.")
        }
    }
    func recheckPermission(manual:Bool = true) {
        let wasTrusted = trusted
        refresh()
        if trusted {
            if !busy && (manual || !wasTrusted || !hasScanned) { scanWindows() }
        } else if manual {
            log("현재 실행 파일에는 권한이 없습니다. 이미 허용했다면 ‘권한 다시 연결’로 현재 앱을 등록해 주세요.")
        }
    }
    func reconnectPermission() {
        let alert = NSAlert()
        alert.messageText = "현재 앱의 권한을 다시 연결합니다"
        alert.informativeText = "시스템 설정에 같은 이름의 이전 빌드가 남아 있을 수 있습니다.\n\n1. 손쉬운 사용 목록에서 기존 Display Harbor 항목을 −로 제거합니다.\n2. Finder에 표시되는 현재 앱을 +로 추가하고 켭니다.\n3. 이 앱으로 돌아와 ‘권한 다시 확인’을 누릅니다. 계속 권한 필요라면 ‘앱 다시 시작’을 누르세요.\n\n현재 앱: \(Bundle.main.bundleURL.path)\n\n다른 앱의 권한은 변경하지 않습니다."
        alert.addButton(withTitle:"설정 및 현재 앱 위치 열기")
        alert.addButton(withTitle:"취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func restart() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:config) { _, error in
            Task { @MainActor in
                if let error { self.log("재시작 실패: \(error.localizedDescription)") }
                else { NSApp.terminate(nil) }
            }
        }
    }
    func tick() {
        refresh()
        guard !busy, !scanning else { return }
        let next = signature()
        if next != candidate { candidate = next; stableTicks = 0; return }
        stableTicks += 1
        let count = onlineIDs().filter { $0 != CGMainDisplayID() }.count
        if stableTicks >= 2 && harbor_should_run(enabled, trusted, UInt32(count), applied != next) {
            applied = next // Do not retry errors every second.
            arrange()
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if value { applied = ""; stableTicks = 0; log("연결 감시 중 · 화면 구성이 안정되면 한 번 정리합니다.") }
        else { log("자동 처리 꺼짐") }
    }
    func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updateTrust()
        if !trusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            log("시스템 설정에서 허용 후 ‘권한 다시 확인’을 누르세요. 이미 허용했다면 ‘권한 다시 연결’을 사용하세요.")
        }
    }
    func scanWindows() {
        guard !scanning, !busy else { return }
        Task { @MainActor in _ = await scanWindowsAsync() }
    }
    @discardableResult func scanWindowsAsync() async -> Bool {
        guard !scanning else { return false }
        refresh()
        scanning=true
        scanSummary="창 목록을 읽는 중…"
        let running=NSWorkspace.shared.runningApplications
        let excluded=Set(running.filter { $0.bundleIdentifier==Bundle.main.bundleIdentifier }.map(\.processIdentifier))
            .union([ProcessInfo.processInfo.processIdentifier])
        let apps=running.filter { $0.activationPolicy == .regular && !excluded.contains($0.processIdentifier) && !$0.isTerminated }
            .filter { !WindowDiscovery.isSystemSurface(bundleID:$0.bundleIdentifier,executablePath:$0.executableURL?.path) }
            .map { AppDescriptor(pid:$0.processIdentifier,name:$0.localizedName ?? "앱") }
        let allowed=trusted
        let report:WindowScan = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                continuation.resume(returning:WindowDiscovery.scan(apps:apps,excluded:excluded,trusted:allowed))
            }
        }
        windows=report.items
        appIcons=[:]
        for pid in Set(windows.map(\.pid)) {
            if let icon=NSRunningApplication(processIdentifier:pid)?.icon { appIcons[pid]=icon }
        }
        previews=[:]
        lastMoved=[:]
        scanSummary=report.summary
        scanDiagnostics=report.diagnostics
        controlWarning=report.warning
        scanning=false
        hasScanned=true
        log(report.summary)
        if previewEnabled { startPreviews() }
        return true
    }
    func setPreviewEnabled(_ value:Bool) {
        previewTask?.cancel()
        previewRevision=UUID()
        previews=[:]
        guard value else {
            previewEnabled=false
            previewStatus="앱 아이콘으로 표시 중"
            return
        }
        guard #available(macOS 14.0, *) else {
            previewStatus="실제 화면 미리보기는 macOS 14 이상에서 지원합니다."
            return
        }
        // Only this explicit user action may trigger the screen permission prompt.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            previewEnabled=false
            previewStatus="화면 기록 권한 허용 후 실제 창 미리보기를 다시 켜 주세요."
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        previewEnabled=true
        startPreviews()
    }
    func startPreviews() {
        previewTask?.cancel()
        previewRevision=UUID()
        let revision=previewRevision
        guard previewEnabled, !windows.isEmpty else { return }
        let items=Array(windows.prefix(48))
        previewStatus="미리보기 준비 중…"
        previewTask=Task { @MainActor in
            guard #available(macOS 14.0, *) else { return }
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                var count=0
                for item in items {
                    guard !Task.isCancelled, previewEnabled, revision==previewRevision else { return }
                    if let image=try? await WindowPreviews.capture(item,from:content) {
                        guard !Task.isCancelled, revision==previewRevision else { return }
                        previews[item.id]=image
                        count+=1
                    }
                }
                guard !Task.isCancelled, revision==previewRevision else { return }
                previewStatus="실제 창 미리보기 \(count)개 · 캡처할 수 없는 창은 앱 아이콘으로 표시합니다."
            } catch {
                guard !Task.isCancelled, revision==previewRevision else { return }
                previewStatus="미리보기를 가져오지 못했습니다. 앱 아이콘으로 표시합니다."
            }
        }
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scanDiagnostics,forType:.string)
    }
    func usableRect(_ screen: NSScreen) -> CGRect {
        let top = screens.first(where: { displayID($0) == CGMainDisplayID() })?.frame.maxY ?? 0
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }
    typealias MoveResult = WindowMover.Result
    func move(_ window: AXUIElement, to screen: NSScreen) -> MoveResult {
        WindowMover.move(window,to:usableRect(screen))
    }
    func extend() throws {
        let mirrored = onlineIDs().filter { CGDisplayMirrorsDisplay($0) != 0 }
        guard !mirrored.isEmpty else { return }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw NSError(domain:"Display",code:Int(begin.rawValue)) }
        var nextX = onlineIDs().filter { !mirrored.contains($0) }.map { CGDisplayBounds($0).maxX }.max() ?? 0
        for id in mirrored {
            let result = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            guard result == .success else {
                CGCancelDisplayConfiguration(config)
                throw NSError(domain:"Display",code:Int(result.rawValue))
            }
            let originResult = CGConfigureDisplayOrigin(config, id, Int32(nextX), 0)
            guard originResult == .success else {
                CGCancelDisplayConfiguration(config)
                throw NSError(domain:"Display",code:Int(originResult.rawValue))
            }
            nextX += CGDisplayBounds(id).width
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        guard result == .success else { throw NSError(domain:"Display",code:Int(result.rawValue)) }
    }
    func arrange() {
        refresh()
        guard !busy, !scanning else { return }
        guard trusted else { log("권한이 없어 실행하지 않았습니다. 권한 허용 후 수동 정리해 주세요."); return }
        // Manual collection also works with one screen; automatic runs still require two.
        busy = true
        log("확장 화면 전환 및 안정화 대기 중…")
        do { try extend() }
        catch { busy = false; log("확장 전환 실패: \(error). 시스템 설정에서 확장을 선택해 주세요."); return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refresh()
            guard let screen = mainScreen else {
                busy = false; applied = signature(); log("화면 구성이 바뀌어 정리를 중단했습니다."); return
            }
            guard await scanWindowsAsync() else { busy=false; log("창 목록 조회 중입니다. 잠시 후 다시 시도하세요."); return }
            var moved = 0, skipped = 0, failed = 0, unavailable = 0
            for item in windows {
                guard let element=item.element, item.canMove else { unavailable+=1; continue }
                switch move(element, to: screen) {
                case .moved: moved += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                }
            }
            applied = signature(); candidate = applied; stableTicks = 0; busy = false
            log("창 \(windows.count)개 · 이동 확인 \(moved), 건너뜀 \(skipped), 제어 불가 \(unavailable), 실패 \(failed) · 대기 중")
        }
    }
    func send(_ item: WindowItem) {
        refresh()
        guard trusted, !busy, !scanning, let element=item.element, item.canMove,
            let target = external.first(where: { displayID($0) == selectedDisplay }), let main=mainScreen else {
            log("권한과 외장 모니터 연결 상태를 확인해 주세요."); return
        }
        let mainFrame=usableRect(main), externalFrame=usableRect(target)
        busy=true
        movingID=item.id
        Task { @MainActor in
        let toggle=await WindowMover.toggleAsync(element,main:mainFrame,external:externalFrame)
        let destinationName=toggle.destination == .main ? "메인 화면" : target.localizedName
        busy=false
        movingID=nil
        switch toggle.result {
        case .moved:
            lastMoved[item.id]=destinationName
            if let frame=toggle.frame, let index=windows.firstIndex(where:{$0.id==item.id}) {
                windows[index]=WindowItem(id:item.id,pid:item.pid,app:item.app,title:item.title,frame:frame,
                    element:item.element,canMove:item.canMove,reason:item.reason)
            }
            log("\(item.app) · \(item.title) → \(destinationName) · 다시 클릭하면 반대 화면으로 이동합니다.")
        case .skipped:
            windows.removeAll { $0.id==item.id }
            previews.removeValue(forKey:item.id)
            log("이동할 수 없게 된 창을 카드에서 제외했습니다.")
        case .failed:
            log("창 이동을 확인하지 못했습니다. 창 새로고침 후 다시 선택해 주세요.")
        }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Harbor!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Harbor()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:680),
                          styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Display Harbor"
        if let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns") {
            NSApp.applicationIconImage = NSImage(contentsOf:url)
        }
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:HarborView(model:model).preferredColorScheme(.light).tint(.blue))
        window.center()
        let menu = NSMenu()
        for (title,action) in [("설정 창 열기",#selector(show)),("메인 화면으로 정리",#selector(arrange)),("자동 처리 켜기 / 끄기",#selector(toggle)),("종료",#selector(quit))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:"")
            item.target = self
            menu.addItem(item)
        }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"display.2",accessibilityDescription:"Display Harbor")
        statusItem.menu = menu
        show()
        if ProcessInfo.processInfo.arguments.contains("--scan-test") {
            Task { @MainActor in
                // Avoid activating an automatic permission scan at the same time.
                while model.scanning { try? await Task.sleep(nanoseconds:100_000_000) }
                _ = await model.scanWindowsAsync()
                print(model.scanDiagnostics)
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
                print("SMOKE version=\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "unknown") windowVisible=\(window.isVisible) contentView=\(window.contentView != nil) screens=\(model.screens.count) accessibility=\(model.trusted) automatic=\(model.enabled) icon=\(Bundle.main.url(forResource:"AppIcon",withExtension:"icns") != nil)")
                NSApp.terminate(nil)
            }
        }
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func arrange() { model.arrange() }
    @objc func toggle() { model.setEnabled(!model.enabled) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
}

@main enum DisplayHarborApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

struct HarborView: View {
    @ObservedObject var model: Harbor
    var body: some View {
        ScrollView {
        VStack(alignment:.leading, spacing:16) {
            HStack {
                Image(systemName:"display.2").font(.largeTitle)
                VStack(alignment:.leading) {
                    Text("Display Harbor").font(.title2.bold())
                    Text("연결하고, 모으고, 대기합니다.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("연결 시 자동 처리", isOn:Binding(get:{model.enabled},set:{model.setEnabled($0)})).toggleStyle(.switch)
            }
            GroupBox("모니터") {
                VStack(alignment:.leading,spacing:8) {
                    Text("연결 감지 \(model.onlineIDs().count)대 · 사용 가능한 확장 화면 \(model.external.count)대").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.screens,id:\.self) { screen in
                        HStack {
                            Image(systemName:model.displayID(screen)==CGMainDisplayID() ? "laptopcomputer" : "display")
                            Text(screen.localizedName)
                            Spacer()
                            Text(model.displayID(screen)==CGMainDisplayID() ? "메인" : "확장").foregroundStyle(.secondary)
                        }
                    }
                    if model.external.isEmpty { Text("확장 화면이 없습니다. 메인 화면 정리는 가능하며 미러링 상태라면 확장 전환을 시도합니다.").foregroundStyle(.secondary) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
            }
            HStack {
                Button("손쉬운 사용 권한 설정") { model.permission() }
                Label(model.trusted ? "허용됨" : "권한 필요",systemImage:model.trusted ? "checkmark.circle" : "lock")
                Spacer()
                Button("확장 전환 + 메인으로 모으기") { model.arrange() }.buttonStyle(.borderedProminent).disabled(model.busy || model.scanning || !model.trusted)
            }
            Text(model.status).font(.callout).textSelection(.enabled)
            HStack {
                Button("권한 다시 확인") { model.recheckPermission() }.disabled(model.busy)
                Button("권한 다시 연결") { model.reconnectPermission() }
                Button("앱 다시 시작") { model.restart() }.disabled(model.busy)
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")").foregroundStyle(.secondary)
            }.controlSize(.small)
            Divider()
            HStack {
                Text("선택한 창만 확장 화면으로").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("창 새로고침") { model.scanWindows() }.disabled(model.busy || model.scanning)
            }
            Text(model.scanSummary).font(.caption).foregroundStyle(.secondary)
            if let warning=model.controlWarning {
                Label(warning,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                Link("동일 증상의 공개 보고",destination:URL(string:"https://github.com/Hammerspoon/hammerspoon/issues/3914")!).font(.caption)
            }
            Picker("보낼 화면",selection:$model.selectedDisplay) {
                Text("선택 없음").tag(UInt32(0))
                ForEach(model.external,id:\.self) { screen in Text(screen.localizedName).tag(model.displayID(screen)) }
            }
            if model.external.isEmpty {
                Label("외장 모니터를 연결하면 카드를 클릭해 바로 이동할 수 있습니다.",systemImage:"display").foregroundStyle(.secondary)
            } else {
                Text("카드를 클릭하면 외장 화면으로, 다시 클릭하면 메인 화면으로 돌아옵니다.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("실제 창 미리보기",isOn:Binding(get:{model.previewEnabled},set:{model.setPreviewEnabled($0)}))
                .toggleStyle(.switch).controlSize(.small)
                .help("화면 기록 권한을 사용합니다. 미리보기 이미지는 저장하거나 전송하지 않습니다.")
            Text(model.previewStatus).font(.caption).foregroundStyle(.secondary)
            if model.windows.isEmpty {
                VStack(spacing:8) {
                    Image(systemName:"macwindow").font(.largeTitle)
                    Text(model.scanning ? "이동 가능한 창을 찾는 중…" : !model.hasScanned ? "‘창 새로고침’을 눌러 창을 확인하세요." : !model.trusted ? "손쉬운 사용 권한을 허용하면 이동 가능한 창이 표시됩니다." : "이동 가능한 창이 없습니다.")
                    Text("지원되지 않는 창과 이동 제한 항목은 표시하지 않습니다.").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,35)
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:190,maximum:300),spacing:12)],spacing:12) {
                    ForEach(model.windows) { item in WindowCard(model:model,item:item) }
                }
            }
            DisclosureGroup("창 조회 진단") {
                HStack(alignment:.top) {
                    Text(model.scanDiagnostics).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Button("진단 복사") { model.copyDiagnostics() }
                }
            }
            DisclosureGroup("최근 처리 기록") {
                ScrollView { VStack(alignment:.leading) { ForEach(Array(model.history.enumerated()),id:\.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(height:85)
            }
            DisclosureGroup("현재 실행 중인 앱 위치") {
                Text(Bundle.main.bundleURL.path).font(.caption).textSelection(.enabled)
            }
            Text("연결 시 한 번만 정리합니다. 이후 직접 이동한 창은 유지됩니다. 앱을 종료하면 감시도 끝납니다.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth:.infinity)
        }.frame(minWidth:660,minHeight:640).background(Color(nsColor:.windowBackgroundColor))
    }
}

struct WindowCard: View {
    @ObservedObject var model:Harbor
    let item:WindowItem
    var body:some View {
        Button { model.send(item) } label: {
            VStack(alignment:.leading,spacing:10) {
                ZStack {
                    RoundedRectangle(cornerRadius:8).fill(Color(nsColor:.controlBackgroundColor))
                    if let preview=model.previews[item.id] {
                        Image(nsImage:preview).resizable().scaledToFit().padding(4).accessibilityHidden(true)
                    } else {
                        VStack(spacing:8) {
                            if let icon=model.appIcons[item.pid] {
                                Image(nsImage:icon).resizable().scaledToFit().frame(width:48,height:48).accessibilityHidden(true)
                            } else { Image(systemName:"macwindow").font(.largeTitle) }
                            Text("앱 아이콘 미리보기").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height:120)
                Text(item.app).font(.headline).lineLimit(1)
                Text(item.title.isEmpty ? "제목 없는 창" : item.title).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(height:34,alignment:.topLeading)
                HStack {
                    if model.movingID==item.id {
                        ProgressView().controlSize(.small)
                        Text("이동 중…")
                    } else if let destination=model.lastMoved[item.id] {
                        Image(systemName:"checkmark.circle.fill").foregroundStyle(.blue)
                        Text("\(destination) 이동 확인 ↔").lineLimit(1)
                    } else {
                        Image(systemName:model.external.isEmpty ? "display" : "arrow.up.right")
                        Text(model.external.isEmpty ? "외장 모니터 연결 대기" : "클릭하여 화면 전환")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(model.lastMoved[item.id] != nil ? Color.blue : Color(nsColor:.separatorColor),lineWidth:1))
        }.buttonStyle(.plain)
            .disabled(model.selectedDisplay==0 || model.busy || model.scanning || !model.trusted)
            .accessibilityLabel("\(item.app), \(item.title). 클릭하여 메인과 선택한 외장 화면 사이 이동")
    }
}
