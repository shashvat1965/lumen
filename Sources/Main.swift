import AppKit

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.isCommand(first) {
            exit(MainActor.assumeIsolated { CLI.main(args) })
        }
        LumenApp.main()
    }
}
