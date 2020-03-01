import Foundation
import NIO
import KeychainAccess
import AsyncHTTPClient
import NIOHTTP1
import NIOExtras
import AppKit

struct Credentials {
	let oauthToken: String
}

class CredentialsWorker : Worker {
	private let keychain = Keychain(service: "com.anthonymayo.getthegist")
	
	private var channel: Channel?
	private var quiesce: ServerQuiescingHelper?
	
	private let username: String
	private let keychainStoredAPITokenKey: String
	
	init(forUsername username: String) {
		self.username = username
		self.keychainStoredAPITokenKey = "GistAPIKey-\(username)"
	}
	
	func getCredentials() -> EventLoopFuture<Credentials> {
		if let token = self.keychain[string: self.keychainStoredAPITokenKey], !token.isEmpty {
			return self.eventLoop.makeSucceededFuture(Credentials(oauthToken: token))
		} else {
			return self.eventLoop.makeFailedFuture(Error.credentialsNotFound(username: self.username))
		}
	}
	
	func authenticateIfNeeded() -> EventLoopFuture<AuthenticateIfNeededResult> {
		return self.getCredentials().map { _ in
			return .alreadyAuthenticated
		}.flatMapError(where: Error.credentialsNotFound(username: self.username)) {
			return self.performAuthenticationFlow().map { credentials in
				self.saveCredentials(credentials)

				return .authenticated
			}
		}
	}
	
	func reauthenticate() -> EventLoopFuture<ReauthenticateResult> {
		return self.performAuthenticationFlow().flatMap { credentials in
			return self.getCredentials().map { _ in
				self.saveCredentials(credentials)
				
				return .authenticatedReplacingExistingCredentials
			}.flatMapError(where: Error.credentialsNotFound(username: self.username)) {
				self.saveCredentials(credentials)
				
				return self.eventLoop.makeSucceededFuture(.authenticatedFirstTime)
			}
		}
	}
	
	enum AuthenticateIfNeededResult {
		case authenticated
		case alreadyAuthenticated
	}
	
	enum ReauthenticateResult {
		case authenticatedFirstTime
		case authenticatedReplacingExistingCredentials
	}
}

extension CredentialsWorker {
	private func saveCredentials(_ credentials: Credentials) {
		self.keychain[string: self.keychainStoredAPITokenKey] = credentials.oauthToken
	}
	
	private func performAuthenticationFlow() -> EventLoopFuture<Credentials> {
		let clientID = "897c59a7449fe8457108"
		let clientSecret = "76a313c2b7b14b3fce45907fd17a35af610375e2"
		let state = UUID().uuidString
		
		let host = "localhost"
		let port = 8888
		
		let queryItems: [URLQueryItem] = [
			.init(name: "client_id", value: clientID),
			.init(name: "redirect_uri", value: "http://\(host):\(port)"),
			.init(name: "scope", value: "gist"),
			.init(name: "state", value: state)
		]

		var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
		components.queryItems = queryItems
					
		NSWorkspace.shared.open(components.url!) // open the login form for the user
		
		return self.runServerAndAwaitResponse(onHost: host, port: port).flatMapThrowing { response -> EventLoopFuture<Credentials> in
			guard response.state == state else {
				throw Error.notMatchingOAuthState
			}
			
			let queryItems: [URLQueryItem] = [
				.init(name: "client_id", value: clientID),
				.init(name: "client_secret", value: clientSecret),
				.init(name: "code", value: response.code),
				.init(name: "redirect_uri", value: "http://localhost:8888"),
				.init(name: "state", value: state)
			]
			
			var components = URLComponents(string: "https://github.com/login/oauth/access_token")!
			components.queryItems = queryItems

			var headers = HTTPHeaders()
			headers.add(name: "Accept", value: "application/json")
			let request = try HTTPClient.Request(url: components.url?.absoluteString ?? "", method: .POST, headers: headers)

			return self.client.execute(request: request).flatMapThrowing { response in
				try response.decodeJSON(OAuthAccessTokenResponse.self)
			}.map { response in
				return Credentials(oauthToken: response.accessToken)
			}
		}.flatMap { $0 }
	}
	
	private enum Error : Equatable, LocalizedError {
		case credentialsNotFound(username: String)
		case notMatchingOAuthState
		
		var errorDescription: String? {
			switch self {
				case .credentialsNotFound(username: let username):
					return "GetTheGist could not find stored credentials for user \(username)"
				case .notMatchingOAuthState:
					return "There was an internal OAuth error and the operation could not be completed."
			}
		}
	}
	
	struct OAuthAccessTokenResponse : Decodable {
		let accessToken: String
		let tokenType: String
		let scope: String
		
		private enum CodingKeys : String, CodingKey {
			case accessToken = "access_token"
			case tokenType = "token_type"
			case scope = "scope"
		}
	}
	
	struct RedirectOAuthResponse {
		let code: String
		let state: String
		
		init(fromURI uri: String) throws {
			let components = URLComponents(string: uri)
			let queryItems = components?.queryItems ?? []
			
			guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
				throw Error.missingCode
			}
			
			guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
				throw Error.missingState
			}
			
			self.code = code
			self.state = state
		}
		
		enum Error : LocalizedError {
			case missingCode
			case missingState
			
			var errorDescription: String? {
				switch self {
					case .missingCode:
						return "The code was missing when parsing the response."
					case .missingState:
						return "The state was missing when parsing the response."
				}
			}
		}
	}
	
	private func runServerAndAwaitResponse(onHost host: String, port: Int) -> EventLoopFuture<RedirectOAuthResponse> {
		let responsePromise = self.eventLoop.makePromise(of: RedirectOAuthResponse.self)
		
		let responseHandler = RedirectOAuthResponseHandler()
		responseHandler.didFinish = { result in
			self.channel?.close(mode: .all, promise: nil)
			
			responsePromise.completeWith(result)
		}
		
		let quiesce = ServerQuiescingHelper(group: self.eventLoopGroup)
		let boostrap = ServerBootstrap(group: self.eventLoopGroup)
		.serverChannelOption(ChannelOptions.backlog, value: Int32(256))
		.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: SocketOptionValue(1))
		.serverChannelInitializer { channel in
			channel.pipeline.addHandler(quiesce.makeServerChannelHandler(channel: channel))
		}
		.childChannelInitializer { channel in
			channel.pipeline.configureHTTPServerPipeline().flatMap {
				channel.pipeline.addHandler(responseHandler)
			}
		}
		
		return boostrap.bind(host: host, port: port).map { channel in
			self.channel = channel
			self.quiesce = quiesce
		}.flatMap {
			responsePromise.futureResult
		}
	}
	
	final class RedirectOAuthResponseHandler : ChannelInboundHandler {
		typealias InboundIn = HTTPServerRequestPart
		typealias OutboundOut = HTTPServerResponsePart
		
		var didFinish: ((Result<RedirectOAuthResponse, Swift.Error>) -> Void)?
		
		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			let part = self.unwrapInboundIn(data)
			
			switch part {
				case .head(let headers):
					let result = Result { try RedirectOAuthResponse(fromURI: headers.uri) }
					
					let responseText: String
					
					switch result {
						case .success(_):
							responseText = "<p>Authenticated <strong>GetTheGist</strong>. You can now close this tab.</p>"
						case .failure(let error):
							responseText = "<p><strong>Authentication failed</strong>: \(error.localizedDescription)</p>"
					}
					
					let responseData = Data(responseText.utf8)
					
					var headers = HTTPHeaders()
					headers.add(name: "Content-Type", value: "text/html")
					headers.add(name: "Content-Length", value: "\(responseData.count)")
					
					let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)
					
					context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
				
					var buffer = context.channel.allocator.buffer(capacity: responseData.count)
					buffer.writeBytes(responseData)
				
					let body = HTTPServerResponsePart.body(.byteBuffer(buffer))
				
					context.writeAndFlush(self.wrapOutboundOut(body), promise: nil)
				
					self.didFinish?(result)
				default:
					return
			}
		}
	}
}
