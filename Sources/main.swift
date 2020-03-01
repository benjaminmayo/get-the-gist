import Foundation
import NIO
import ArgumentParser

struct GetTheGist : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get the gist", subcommands: [Authenticate.self, Push.self])
}

struct UserOptions : ParsableArguments {
    @Option(name: NameSpecification.customLong("user"), help: ArgumentHelp("A username to associate with Gist Github credentials", discussion: "Gist GitHub credentials are unique per user. Provide a user suitable for the project in which the file resides."))
    var username: String
}

struct Push : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push a file to a Gist. The gist will be updated if it already exists.")
    
    @OptionGroup()
    var options: UserOptions
    
    @Argument(help: ArgumentHelp("A list of file URLs to make gists out of, or update gists if they already exist.", valueName: "file-url"), transform: URL.init(fileURLWithPath:))
    var fileURLs: [URL]
    
    func run() throws {
        CredentialsWorker(forUsername: self.options.username).getCredentials().flatMap { credentials -> EventLoopFuture<Void> in
            let futuresForFileURLs = self.fileURLs.map {
                self.run(forFileAt: $0, with: credentials)
            }
            
            return EventLoopFuture.andAllSucceed(futuresForFileURLs, on: _eventLoopGroup.next())
        }.done()
    }
    
    private func run(forFileAt url: URL, with credentials: Credentials) -> EventLoopFuture<Void> {
        let gistWorker = GistWorker(credentials: credentials)
        let fileManagementWorker = FileManagementWorker()
        
        return fileManagementWorker.gistFile(for: url).and(fileManagementWorker.findMetadata(inFileAt: url)).flatMap { (file, metadata) in
            if let existingURL = metadata.allFound.first(where: { $0.metadata.isSameDeclaration(as: .viewFile(url: "")) })?.metadata.parameter.url, let range = existingURL.range(of: "gist.github.com/") {
                let identifier = existingURL[range.upperBound...].trimmingCharacters(in: .whitespaces)
                
                return gistWorker.updateGist(forID: identifier, with: file).flatMap { result -> EventLoopFuture<Void> in
                    switch result {
                        case .updated(let info):
                            return fileManagementWorker.addMetadata(.viewFile(url: info.webURL), toFileAt: url).map { _ -> () in
                                print("The \"\(file.name)\" gist has been updated. View at \(info.webURL)")
                                
                                return ()
                        }
                        case .unchanged(_):
                            print("The \"\(file.name)\" gist has not been updated as the file content is unchanged.")
                            
                            return gistWorker.eventLoop.makeSucceededFuture(())
                    }
                }
            } else {
                let newGist = Gist(file: file, description: "Uploaded by GetTheGist.", isPublic: false)
                return gistWorker.createGist(newGist).map { result in
                    print("A gist for \"\(file.name)\" has been created. View at \(result.webURL)")
                    
                    return ()
                }
            }
        }
    }
}

struct Authenticate : ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Authenticate with Github.")
    
    @OptionGroup()
    var options: UserOptions
    
//    @Flag(name: .long, help: "Force the authentication flow to happen again, even if existing credentials are found.")
//    var force: Bool
    
    @Option(name: .long, help: "Provide a personal access token made in the GitHub UI.") var token: String
    
    func run() throws {
        let worker = CredentialsWorker(forUsername: self.options.username)
        
        //let authenticatedSuccessfullyMessage = "Authenticated successfully. The token is stored in the Keychain, so you don't need to authenticate in future."
        
        worker.setToken(to: self.token).map {
            print("Updated credentials for \"\(self.options.username)\".")
        }.done()
        
//        if self.force {
//            worker.reauthenticate().map { result in
//                switch result {
//                    case .authenticatedFirstTime:
//                        print(authenticatedSuccessfullyMessage)
//                    case .authenticatedReplacingExistingCredentials:
//                        print("Authenticated successfully. Previously stored credentials were overriden.")
//                }
//            }.done()
//        } else {
//            worker.authenticateIfNeeded().map { result in
//                switch result {
//                    case .alreadyAuthenticated:
//                        print("You are already authenticated. The token is stored in the Keychain. ")
//                    case .authenticated:
//                        print(authenticatedSuccessfullyMessage)
//                }
//            }.done()
//        }
    }
}

GetTheGist.main()
