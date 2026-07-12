import Foundation

struct CLIArguments: Equatable, Sendable {
    enum Output: Equatable, Sendable {
        case automatic
        case json
        case table
    }

    var providerID: String?
    var output: Output = .automatic
    var launchApp = true
    var showHelp = false
    var showVersion = false

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var parsed = CLIArguments()
        for argument in arguments {
            switch argument {
            case "--json": parsed.output = .json
            case "--table": parsed.output = .table
            case "--no-launch": parsed.launchApp = false
            case "-h", "--help": parsed.showHelp = true
            case "-v", "--version": parsed.showVersion = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown option: \(argument)")
                }
                guard parsed.providerID == nil else {
                    throw CLIError.usage("Only one provider can be requested at a time.")
                }
                parsed.providerID = argument.lowercased()
            }
        }
        return parsed
    }
}

enum CLIError: Error, Equatable {
    case usage(String)
    case appUnavailable
    case request(String)
}
