import AppKit

// Reproducible vector artwork; render every macOS icon resolution directly.
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
func render(_ pixels:Int, to path:String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,
        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    let tile = NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:200,yRadius:200)
    NSGradient(starting:NSColor(srgbRed:0.16,green:0.62,blue:1,alpha:1),
               ending:NSColor(srgbRed:0.06,green:0.20,blue:0.78,alpha:1))!.draw(in:tile,angle:-90)
    // The external monitor sits behind the main monitor.
    NSColor.white.withAlphaComponent(0.42).setFill()
    NSBezierPath(roundedRect:NSRect(x:435,y:420,width:380,height:300),xRadius:34,yRadius:34).fill()
    NSColor(srgbRed:0.10,green:0.35,blue:0.84,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:460,y:460,width:330,height:235),xRadius:14,yRadius:14).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect:NSRect(x:180,y:294,width:490,height:350),xRadius:40,yRadius:40).fill()
    NSColor(srgbRed:0.07,green:0.27,blue:0.70,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:208,y:349,width:434,height:267),xRadius:16,yRadius:16).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect:NSRect(x:393,y:229,width:64,height:85),xRadius:10,yRadius:10).fill()
    NSBezierPath(roundedRect:NSRect(x:314,y:208,width:222,height:34),xRadius:17,yRadius:17).fill()
    // A left-pointing arrow means bringing windows home.
    let arrow = NSBezierPath()
    arrow.move(to:NSPoint(x:534,y:484)); arrow.line(to:NSPoint(x:326,y:484))
    arrow.move(to:NSPoint(x:393,y:552)); arrow.line(to:NSPoint(x:325,y:484)); arrow.line(to:NSPoint(x:393,y:416))
    arrow.lineWidth = 27; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(srgbRed:0.61,green:0.92,blue:1,alpha:1).setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}
for size in [16,32,128,256,512] {
    try render(size,to:"\(output)/icon_\(size)x\(size).png")
    try render(size*2,to:"\(output)/icon_\(size)x\(size)@2x.png")
}
