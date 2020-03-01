import Foundation
import AsyncHTTPClient
import NIO
import NIOHTTP1

struct Gist {
    let file: File
    
    let description: String
    let isPublic: Bool
    
    struct File {
        let name: String
        let content: String
    }
}

class GistWorker : Worker {
    let credentials: Credentials
    
    init(credentials: Credentials) {
        self.credentials = credentials
    }
    
    func createGist(_ gist: Gist) -> EventLoopFuture<GistInfo> {
        struct CreateGistBody : Encodable {
            let files: [String : [String : String]]
            let description: String
            let `public`: Bool
        }
        
        let body = CreateGistBody(
            files: [gist.file.name : ["content" : gist.file.content]],
            description: gist.description,
            public: gist.isPublic
        )
        
        let request = POSTAPIRequest("gists", body, CreateOrUpdateGistResponse.self)
        
        return self.execute(request).map { response in
            return response.asGistInfo
        }
    }
    
    func updateGist(forID id: String, with newFile: Gist.File) -> EventLoopFuture<UpdateGistResult> {
        return self.getExtendedGistInfo(forID: id).flatMap { info -> EventLoopFuture<UpdateGistResult> in
            var shouldUpdate: Bool = false
            
            if info.files.count != 1 {
                shouldUpdate = true
            } else if let file = info.files.first {
                if file.key != newFile.name {
                    shouldUpdate = true
                } else if file.value.content != newFile.content {
                    shouldUpdate = true
                }
            }
            
            if !shouldUpdate {
                return self.eventLoop.makeSucceededFuture(.unchanged(info.asGistInfo))
            }
            
            struct UpdateGistBody : Encodable {
                let files: [String : [String : String]?]
            }
            
            var files = [String : [String : String]?]()
            
            if newFile.content != info.files[newFile.name]?.content {
                files[newFile.name] = ["content" : newFile.content]
            }
            
            for otherFilename in info.files.keys.filter({ $0 != newFile.name }) {
                files[otherFilename] = nil
            }
            
            let body = UpdateGistBody(files: files)
            
            let request = self.PATCHAPIRequest("gists/\(id)", body, CreateOrUpdateGistResponse.self)
            
            return self.execute(request).map { response in
                return .updated(response.asGistInfo)
            }
        }
    }
    
    struct GistInfo {
        let id: String
        let webURL: String
    }
    
    enum UpdateGistResult {
        case updated(GistInfo)
        case unchanged(GistInfo)
    }
    
    private let baseURL = "https://api.github.com"
}

extension Never : Encodable {
    public func encode(to encoder: Encoder) throws {
        
    }
}

extension GistWorker {
    fileprivate struct CreateOrUpdateGistResponse : Decodable {
        let id: String
        let url: String
        
        var asGistInfo: GistInfo {
            return GistInfo(id: self.id, webURL: self.url)
        }
        
        private enum CodingKeys : String, CodingKey {
            case id
            case url = "html_url"
        }
    }
    
    fileprivate struct ExtendedGistInfo : Decodable {
        let id: String
        let url: String
        
        let files: [String : FullGistFile]
        
        var asGistInfo: GistInfo {
            return GistInfo(id: self.id, webURL: self.url)
        }
        
        struct FullGistFile : Decodable {
            let size: Int
            let content: String
        }
        
        private enum CodingKeys : String, CodingKey {
            case id
            case url = "html_url"
            case files = "files"
        }
    }
    
    fileprivate func getExtendedGistInfo(forID id: String) -> EventLoopFuture<ExtendedGistInfo> {
        let request = GETAPIRequest("gists/\(id)", ExtendedGistInfo.self)
        
        return self.execute(request)
    }
    
    func GETAPIRequest<Response>(_ endpoint: String, _ response: Response.Type) -> APIRequest<Never, Response> {
        APIRequest<Never, Response>(endpoint: endpoint, method: .GET, body: nil)
    }
    
    func POSTAPIRequest<Body, Response>(_ endpoint: String, _ body: Body, _ response: Response.Type) -> APIRequest<Body, Response> {
        APIRequest<Body, Response>(endpoint: endpoint, method: .POST, body: body)
    }
    
    func PATCHAPIRequest<Body, Response>(_ endpoint: String, _ body: Body, _ response: Response.Type) -> APIRequest<Body, Response> {
        APIRequest<Body, Response>(endpoint: endpoint, method: .PATCH, body: body)
    }
    
    typealias GetAPIRequest<Response : Decodable> = APIRequest<Never, Response>
    
    struct APIRequest<Body, Response> where Body : Encodable, Response : Decodable {
        var endpoint: String
        var method: HTTPMethod
        var body: Body? = nil
    }
    
    private func execute<Body, Response>(_ request: APIRequest<Body, Response>) -> EventLoopFuture<Response> {
        let url = "\(self.baseURL)/\(request.endpoint)"
        
        let body: HTTPClient.Body?
        
        if let requestBody = request.body {
            let data = try! JSONEncoder().encode(requestBody)
            
            body = .data(data)
        } else {
            body = nil
        }
        
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "token \(self.credentials.oauthToken)")
        headers.add(name: "User-Agent", value: "GetTheGist")
        headers.add(name: "Content-Type", value: "application/json")
        
        let request = try! HTTPClient.Request(url: url, method: request.method, headers: headers, body: body)
        
        return self.client.execute(request: request).flatMapThrowing { response -> Response in
            return try response.decodeJSON(Response.self)
        }
    }
}
