// Scaffolding: replace when the real LiveKit transport is moved in.
import ConduitCallEngine
import LiveKit

public enum ConduitCallEngineLiveKitInfo {
    public static let scaffold = ConduitCallEngineInfo.scaffold
    // Referencing an SDK symbol proves resolution and linking.
    static let roomType: Any.Type = Room.self
}
