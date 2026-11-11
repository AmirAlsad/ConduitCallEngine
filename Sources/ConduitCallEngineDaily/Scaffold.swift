// Scaffolding: replace when the real Daily transport is moved in.
import ConduitCallEngine
import PipecatClientIOS
import PipecatClientIOSDaily

public enum ConduitCallEngineDailyInfo {
    public static let scaffold = ConduitCallEngineInfo.scaffold
    // Referencing SDK symbols proves resolution and linking.
    static let transportType: Any.Type = DailyTransport.self
    static let clientType: Any.Type = PipecatClient.self
}
