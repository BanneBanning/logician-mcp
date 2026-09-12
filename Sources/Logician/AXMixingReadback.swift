import Foundation

/// Missing Accessibility values are unknown, never an off switch or a
/// centered pan. These reads decide both compare-and-set and verified no-ops.
enum AXMixingReadback {
    static func toggle(_ raw: String, control: String) throws -> Bool {
        switch raw {
        case LogicUIStrings.Value.on: return true
        case LogicUIStrings.Value.off: return false
        default:
            throw LogicianError.valueNotWritable("the \(control) button exposes no readable on/off value")
        }
    }

    static func panPosition(_ raw: String) throws -> Int {
        guard let position = Int(raw) else {
            throw LogicianError.valueNotWritable("the pan knob exposes no readable position")
        }
        return position
    }
}
