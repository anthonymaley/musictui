import ArgumentParser

@main
struct Ceol: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ceol",
        abstract: "Control Apple Music from the terminal.",
        version: "1.0.0",
        subcommands: [
            // Playback
            Play.self,
            Pause.self,
            Skip.self,
            Back.self,
            Stop.self,
            Now.self,
            Shuffle.self,
            Repeat_.self,
            // Speakers & Volume
            Speaker.self,
            Vol.self,
            // Auth
            Auth.self,
            // Catalog
            Search.self,
            Add.self,
            Playlist.self,
            // Discovery
            Similar.self,
            Suggest.self,
            NewReleases.self,
            Mix.self,
        ],
        defaultSubcommand: Now.self
    )
}
