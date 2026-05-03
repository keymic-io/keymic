import CoreGraphics
import Foundation

@main
struct KeyMappingManagerTestRunner {
    static func main() {
        let defaults = UserDefaults(suiteName: "KeyMappingManagerTests-\(UUID().uuidString)")!
        defer {
            if let name = defaults.volatileDomainNames.first(where: { $0.hasPrefix("KeyMappingManagerTests-") }) {
                defaults.removePersistentDomain(forName: name)
            }
        }

        let manager = KeyMappingManager(userDefaults: defaults)

        expect(manager.mappings.count == 3, "default mappings count mismatch")
        expect(manager.mappings[0].fromKeyCode == 0x36, "first mapping source mismatch")
        expect(manager.mappings[0].fromFlag == .maskCommand, "first mapping source flag mismatch")
        expect(manager.mappings[0].toKeyCode == 0x75, "first mapping target mismatch")
        expect(manager.mappings[0].toFlag == nil, "first mapping target flag mismatch")
        expect(manager.mappings[1].fromKeyCode == 0x3c, "second mapping source mismatch")
        expect(manager.mappings[1].fromFlag == .maskShift, "second mapping source flag mismatch")
        expect(manager.mappings[1].toKeyCode == 0x39, "second mapping target mismatch")
        expect(manager.mappings[1].toFlag == .maskAlphaShift, "second mapping target flag mismatch")
        expect(manager.mappings[2].fromKeyCode == 0x39, "third mapping source mismatch")
        expect(manager.mappings[2].fromFlag == .maskAlphaShift, "third mapping source flag mismatch")
        expect(manager.mappings[2].toKeyCode == 0x3b, "third mapping target mismatch")
        expect(manager.mappings[2].toFlag == .maskControl, "third mapping target flag mismatch")

        manager.isEnabled = true
        expect(manager.targetKeyCode(for: 0x36) == 0x75, "right command should map to delete forward")
        expect(manager.targetKeyCode(for: 0x3c) == 0x39, "right shift should map to caps lock")
        expect(manager.targetKeyCode(for: 0x39) == 0x3b, "caps lock should map to left control")
        expect(manager.mapping(for: 0x39)?.toFlag == .maskControl, "caps lock target should carry control flag")

        manager.isEnabled = false
        expect(manager.targetKeyCode(for: 0x36) == nil, "disabled mappings should not remap")

        print("KeyMappingManagerTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
