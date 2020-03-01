import Foundation
import NIO
import ArgumentParser

struct GetTheGist : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "`GetTheGist` makes it super simple to upload a single file out of a larger project as a GitHub gist. The gist means you can keep the rest of your codebase private, whilst bringing just that one file into public domain for teaching purposes. ", discussion: "You need to run the `authenticate` command before using `push`.", subcommands: [Authenticate.self, Push.self])
}

struct UserOptions : ParsableArguments {
    @Option(name: .customLong("user"), help: ArgumentHelp("A username to associate with Gist Github credentials", discussion: "Gist GitHub credentials are unique per user. Provide a user suitable for the project in which the file resides."))
    var username: String
}

struct Push : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push a file to a Gist. The gist will be updated if it already exists.")
    
    @OptionGroup()
    var options: UserOptions
    
    @Argument(help: ArgumentHelp("A list of file URLs to make gists out of, or update gists if they already exist.", valueName: "file-url"), transform: URL.init(fileURLWithPath:))
    var fileURLs: [URL]
    
    func run() throws {
        RunnerWorker(username: self.options.username).push(forFileURLs: self.fileURLs)
    }
}

struct Authenticate : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Authenticate with Github.")
    
    @OptionGroup()
    var options: UserOptions
    
    @Option(help: "Provide a personal access token made in the GitHub UI.")
    var token: String
    
    func run() throws {
        RunnerWorker(username: self.options.username).authenticate(withToken: self.token)
    }
}

GetTheGist.main()
