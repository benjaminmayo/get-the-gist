import Foundation
import NIO
import AsyncHTTPClient

let _eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let _client = HTTPClient(eventLoopGroupProvider: .shared(_eventLoopGroup))

protocol Worker {
	
}

extension Worker {
	var eventLoopGroup: EventLoopGroup {
		return _eventLoopGroup
	}
	
	var eventLoop: EventLoop {
		return self.eventLoopGroup.next()
	}
	
	var client: HTTPClient {
		return _client
	}
}

extension EventLoopFuture {
	func flatMapError<ExpectedError>(where expectedError: ExpectedError, transform: @escaping () -> EventLoopFuture<Value>) -> EventLoopFuture<Value> where ExpectedError : Error, ExpectedError : Equatable {
		return self.flatMapError { error in
			if let error = error as? ExpectedError, error == expectedError {
				return transform()
			} else {
				return self.eventLoop.makeFailedFuture(error)
			}
		}
	}
	
	func done() -> Never {
		let result = Result { try self.wait() }
		
		switch result {
			case .success(_):
				exit(EXIT_SUCCESS)
			case .failure(let error):
				print("Error: \(error)")
				exit(EXIT_FAILURE)
		}
	}
}

extension HTTPClient.Response {
	enum JSONDecodingError : LocalizedError {
		case noBody
		case parseFailed(Error)
		
		var errorDescription: String? {
			switch self {
				case .noBody:
					return "The response had no body, so JSON could not be decoded."
				case .parseFailed(let error):
					return "There was an error decoding the response as JSON: \(error.localizedDescription)"
			}
		}
	}
	enum StringDecodingError : LocalizedError {
		case noBody
		case invalidEncoding
		
		var errorDescription: String? {
			switch self {
				case .noBody:
					return "The response had no body, so a string could not be decoded."
				case .invalidEncoding:
					return "The response could not be decoded as a string as it is in an invalid encoding."
			}
		}
	}
	
	func decodeString() throws -> String {
		guard var body = self.body, body.readableBytes > 0 else { throw StringDecodingError.noBody }
		guard let result = body.readString(length: body.readableBytes) else { throw StringDecodingError.invalidEncoding }
		
		return result
	}
	
	func decodeJSON<T : Decodable>(_ type: T.Type) throws -> T {
		guard var body = self.body else { throw JSONDecodingError.noBody }
		
		do {
			if let decoded = try body.readJSONDecodable(T.self, length: body.readableBytes) {
				return decoded
			} else {
				throw JSONDecodingError.noBody
			}
		} catch let error as DecodingError {
			throw JSONDecodingError.parseFailed(error)
		} catch let error {
			throw error
		}
	}
}
