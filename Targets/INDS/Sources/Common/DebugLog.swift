import Foundation

func debugLog(_ message: String) {
    #if DEBUG
    print("[eDuo] \(message)")
    #endif
}
