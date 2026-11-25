import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerName as String] as? String ?? "").contains("Soma") {
  print(w[kCGWindowNumber as String]!, w[kCGWindowOwnerName as String]!, w[kCGWindowName as String] ?? "", w[kCGWindowBounds as String]!, w[kCGWindowLayer as String]!)
}
