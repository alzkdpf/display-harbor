import AppKit
import ScreenCaptureKit

enum WindowPreviews {
    @available(macOS 14.0, *)
    static func capture(_ item:WindowItem, from content:SCShareableContent) async throws -> NSImage? {
        let owned=content.windows.filter { $0.owningApplication?.processID==item.pid }
        let cgID=item.id.hasPrefix("cg:") ? UInt32(item.id.dropFirst(3)) : nil
        let matches=owned.filter { window in
            if let cgID { return window.windowID==cgID }
            return WindowDiscovery.sameFrame(window.frame,item.frame)
        }
        guard matches.count==1, let window=matches.first else { return nil }
        let filter=SCContentFilter(desktopIndependentWindow:window)
        let config=SCStreamConfiguration()
        let scale=min(480/max(window.frame.width,1),300/max(window.frame.height,1))
        config.width=max(1,Int(window.frame.width*scale))
        config.height=max(1,Int(window.frame.height*scale))
        config.capturesAudio=false
        config.showsCursor=false
        config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        return NSImage(cgImage:image,size:NSSize(width:CGFloat(config.width),height:CGFloat(config.height)))
    }
}
