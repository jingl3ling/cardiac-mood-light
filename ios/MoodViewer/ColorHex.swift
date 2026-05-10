import SwiftUI
import UIKit

extension Color {
  init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    self.init(red: r, green: g, blue: b)
  }
}
