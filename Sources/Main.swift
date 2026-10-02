import AppKit

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        #if LUMEN_CLI
        // Standalone CLI build: never launches the menu-bar app.
        exit(MainActor.assumeIsolated { CLI.main(args.isEmpty ? ["help"] : args) })
        #endif
        if let first = args.first, CLI.isCommand(first) {
            exit(MainActor.assumeIsolated { CLI.main(args) })
        }
        LumenApp.main()
    }
}
