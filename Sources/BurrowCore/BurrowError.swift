import Foundation

public enum BurrowError: LocalizedError, Equatable {
    case machineNotFound(String)
    case nameTaken(String)
    case invalidName(String)
    case machineRunning(String)
    case missingFile(String)
    case unsupported(String)
    case diskCreationFailed(String)
    case snapshotNotFound(String)
    case invalidConfiguration(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .machineNotFound(let name): "No machine named “\(name)”."
        case .nameTaken(let name): "A machine named “\(name)” already exists."
        case .invalidName(let name): "“\(name)” can’t be used as a machine name."
        case .machineRunning(let name): "“\(name)” is running. Shut it down first."
        case .missingFile(let path): "Required file is missing: \(path)"
        case .unsupported(let reason): reason
        case .diskCreationFailed(let reason): "Couldn’t create the disk: \(reason)"
        case .snapshotNotFound(let id): "No snapshot with ID \(id)."
        case .invalidConfiguration(let reason): "Invalid machine configuration: \(reason)"
        case .downloadFailed(let reason): reason
        }
    }
}
