import Foundation

// MARK: - ControlEvent
//
// Wire format for control events sent between viewer and host over UDP (port 5537).
// All pointer coordinates are normalized to [0, 1] relative to the host display.
//
// Direction:
//   viewer → host : mouseMoved, mouseButton, scroll, keyEvent
//   host → viewer : controlTransfer

enum ControlEvent: Codable {
    case mouseMoved(x: Double, y: Double)
    case mouseButton(x: Double, y: Double, button: MouseButton, down: Bool)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case keyEvent(keyCode: UInt16, modifiers: UInt64, down: Bool)
    /// Sent host → viewer to notify who currently has control of the system cursor.
    case controlTransfer(controller: Controller)

    // MARK: - Nested types

    enum MouseButton: Int, Codable {
        case left   = 0
        case right  = 1
        case other  = 2
    }

    /// Which participant currently drives the real system cursor.
    enum Controller: String, Codable {
        case host
        case viewer
    }

    // MARK: - Codable (manual tagged union)

    private enum CodingKeys: String, CodingKey {
        case type, x, y, button, down, dx, dy, keyCode, modifiers, controller
    }

    private enum EventType: String, Codable {
        case mouseMoved, mouseButton, scroll, keyEvent, controlTransfer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(EventType.self, forKey: .type)
        switch type {
        case .mouseMoved:
            self = .mouseMoved(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y)
            )
        case .mouseButton:
            self = .mouseButton(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                button: try c.decode(MouseButton.self, forKey: .button),
                down: try c.decode(Bool.self, forKey: .down)
            )
        case .scroll:
            self = .scroll(
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                dx: try c.decode(Double.self, forKey: .dx),
                dy: try c.decode(Double.self, forKey: .dy)
            )
        case .keyEvent:
            self = .keyEvent(
                keyCode: try c.decode(UInt16.self, forKey: .keyCode),
                modifiers: try c.decode(UInt64.self, forKey: .modifiers),
                down: try c.decode(Bool.self, forKey: .down)
            )
        case .controlTransfer:
            self = .controlTransfer(
                controller: try c.decode(Controller.self, forKey: .controller)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mouseMoved(let x, let y):
            try c.encode(EventType.mouseMoved, forKey: .type)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .mouseButton(let x, let y, let button, let down):
            try c.encode(EventType.mouseButton, forKey: .type)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(button, forKey: .button)
            try c.encode(down, forKey: .down)
        case .scroll(let x, let y, let dx, let dy):
            try c.encode(EventType.scroll, forKey: .type)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case .keyEvent(let keyCode, let modifiers, let down):
            try c.encode(EventType.keyEvent, forKey: .type)
            try c.encode(keyCode, forKey: .keyCode)
            try c.encode(modifiers, forKey: .modifiers)
            try c.encode(down, forKey: .down)
        case .controlTransfer(let controller):
            try c.encode(EventType.controlTransfer, forKey: .type)
            try c.encode(controller, forKey: .controller)
        }
    }

    // MARK: - Serialization helpers

    func toData() -> Data? { try? JSONEncoder().encode(self) }
    static func from(data: Data) -> ControlEvent? { try? JSONDecoder().decode(ControlEvent.self, from: data) }
}
