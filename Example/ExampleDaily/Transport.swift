import ConduitCallEngine
import ConduitCallEngineDaily

@MainActor
func makeTransport() -> any CallTransport {
    PipecatDailyTransport()
}
