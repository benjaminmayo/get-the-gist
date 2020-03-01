import Foundation
import NIO

class RunnerWorker : Worker {
    let username: String
    
    init(username: String) {
        self.username = username
    }
    
    func push(forFileURLs fileURLs: [URL]) {
        CredentialsWorker(forUsername: self.username).getCredentials().flatMap { credentials -> EventLoopFuture<Void> in
            let futuresForFileURLs = fileURLs.map {
                self.push(forFileAt: $0, with: credentials)
            }
                   
            return EventLoopFuture.andAllSucceed(futuresForFileURLs, on: self.eventLoop)
        }.done()
    }
    
    func authenticate(withToken token: String) {
        CredentialsWorker(forUsername: self.username).setToken(to: token).map {
            print("Updated credentials for \"\(self.username)\".")
        }.done()
        
        // maybe reimplement this when underyling worker is reimplemented
        //    @Flag(help: "Force the authentication flow to happen again, even if existing credentials are found.")
        //    var force: Bool
            
        // let authenticatedSuccessfullyMessage = "Authenticated successfully. The token is stored in the Keychain, so you don't need to authenticate in future."
        // if self.force {
        //     worker.reauthenticate().map { result in
        //         switch result {
        //             case .authenticatedFirstTime:
        //                 print(authenticatedSuccessfullyMessage)
        //             case .authenticatedReplacingExistingCredentials:
        //                 print("Authenticated successfully. Previously stored credentials were overriden.")
        //         }
        //     }.done()
        // } else {
        //     worker.authenticateIfNeeded().map { result in
        //         switch result {
        //             case .alreadyAuthenticated:
        //                 print("You are already authenticated. The token is stored in the Keychain. ")
        //             case .authenticated:
        //                 print(authenticatedSuccessfullyMessage)
        //         }
        //     }.done()
        // }
    }
}

extension RunnerWorker {
    private func push(forFileAt url: URL, with credentials: Credentials) -> EventLoopFuture<Void> {
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
