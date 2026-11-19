import Testing
import UIKit
@testable import Spur

struct TypographyTests {
    @Test func aBundledTypefaceRegistersAndIsUsed() {
        // A font file copied in by scripts/install-font.sh registers at launch and every style
        // uses it; without one (a fresh clone) the styles use the system font.
        let bundled = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        #expect(bundled.isEmpty == (SpurFont.postScriptName == nil), "a bundled font file must register: \(bundled.map(\.lastPathComponent))")
        if let name = SpurFont.postScriptName {
            #expect(UIFont(name: name, size: 12) != nil)
            #expect(Typography.uiFont(12).fontName == name)
        } else {
            #expect(Typography.uiFont(12).fontName == UIFont.systemFont(ofSize: 12).fontName)
        }
    }

    @Test func fallbackNeverReturnsNil() {
        #expect(Typography.uiFont(12).pointSize == 12)
    }
}
