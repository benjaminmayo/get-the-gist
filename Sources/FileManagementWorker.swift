import Foundation
import NIO

class FileManagementWorker : Worker {
	init() {
		
	}
	
	func gistFile(for url: URL) -> EventLoopFuture<Gist.File> {
		return self.eventLoop.submit {
			let fileContent = try String(contentsOf: url)
			
			let result = self.findMetadata(inFileContent: fileContent)
			
			var lines = fileContent.split(separator: "\n")
			
			for metadata in result.allFound.reversed() {
				lines.remove(at: metadata.lineIndex)
			}
			
			let fileContentWithMetadataRemoved = lines.joined(separator: "\n")
			
			return Gist.File(name: url.lastPathComponent, content: fileContentWithMetadataRemoved)
		}
	}
	
	func findMetadata(inFileAt url: URL) -> EventLoopFuture<FindMetadataResult> {
		return self.eventLoop.submit {
			let fileContent = try String(contentsOf: url)
			let result = self.findMetadata(inFileContent: fileContent)
			
			return result
		}
	}
	
	func addMetadata(_ addingMetadata: Metadata, toFileAt url: URL) -> EventLoopFuture<AddMetadataResult> {
		return self.eventLoop.submit {
			let fileContent = try String(contentsOf: url)
			let result = self.findMetadata(inFileContent: fileContent)
			
			if result.allFound.map({ $0.metadata }).contains(addingMetadata) {
				return .metadataWasAlreadyInFile
			}
			
			let metadataToRemove: [FindMetadataResult.FoundMetadata]
			
			if addingMetadata.isLimitedToOneDeclarationPerFile {
				metadataToRemove = result.allFound.filter { $0.metadata.isSameDeclaration(as: addingMetadata) }
			} else {
				metadataToRemove = []
			}
			
			let addingLineIndex: Int
			
			let startingCommentSyntax = self.preferredStartingCommentSyntax(forFileContent: fileContent, inFileAt: url)
			
			if metadataToRemove.isEmpty {
				// if no removals, insert at end of existing metadata
				let highestLineIndex = result.allFound.map { $0.lineIndex }.max() ?? 0
				addingLineIndex = highestLineIndex
			} else {
				// else, replace at first instance of removed metadata
				addingLineIndex = metadataToRemove.first!.lineIndex
			}
			
			var lines = fileContent.split(separator: "\n")
			
			// insert the new metadata
			let newLine = self.formattedMetadataLine(for: addingMetadata, startingCommentSyntax: startingCommentSyntax)
			lines.insert(Substring(newLine), at: min(addingLineIndex, lines.endIndex))
			
			for lineIndexToRemove in metadataToRemove.map({ $0.lineIndex }).reversed() {
				// we have to add 1 to account for the already added line index
				lines.remove(at: lineIndexToRemove >= addingLineIndex ? lineIndexToRemove + 1 : lineIndexToRemove)
			}
			
			let newFileContent = lines.joined(separator: "\n")
			
			let data = Data(newFileContent.utf8)
			try data.write(to: url)
			
			return .added
		}
	}
	
	enum Metadata : Equatable {
		case viewFile(url: String)
		
		func isSameDeclaration(as other: Metadata) -> Bool {
			switch (self, other) {
				case (.viewFile(url: _), .viewFile(url: _)):
					return true
			}
		}
		
		var isLimitedToOneDeclarationPerFile: Bool {
			return true
		}
		
		var prefix: Prefix {
			switch self {
				case .viewFile(url: _):
					return .viewFile
			}
		}
		
		var parameter: Parameter {
			switch self {
				case .viewFile(url: let url):
					return .url(url)
			}
		}
		
		var formatted: String {
			return "\(self.prefix.formatted): \(self.parameter.formatted)"
		}
		
		enum Kind {
			case viewFile
		}
		
		enum Prefix : CaseIterable {
			case viewFile
			
			var formatted: String {
				switch self {
					case .viewFile:
						return "Uploaded to gist"
				}
			}
		}
		
		enum Parameter {
			case url(String)
			
			var formatted: String {
				switch self {
					case .url(let url):
						return "\(url)"
				}
			}
			
			var url: String {
				switch self {
					case .url(let url):
						return url
				}
			}
		}
		
		// "You can view this file at the gist: [url]" [GetTheGist]
	}
	
	enum FindMetadataResult {
		case found([FoundMetadata])
		case foundNoMetadata
		
		var allFound: [FoundMetadata] {
			switch self {
				case .found(let all):
					return all
				case .foundNoMetadata:
					return []
			}
		}
		
		struct FoundMetadata {
			let metadata: Metadata
			
			let lineIndex: Int
			let columnRange: Range<String.Index>
		}
	}
	
	enum AddMetadataResult {
		case added
		case metadataWasAlreadyInFile
	}
	
	private let metadataLineMarker: String = " [GetTheGist]"
	fileprivate let possibleStartingCommentSyntax: Set<String> = ["//", "#"]
}

extension FileManagementWorker {
	private func formattedMetadataLine(for metadata: Metadata, startingCommentSyntax: String) -> String {
		return "\(startingCommentSyntax) \(metadata.formatted)\(self.metadataLineMarker)"
	}
	
	private func findMetadata(inFileContent fileContent: String) -> FindMetadataResult {
		let lines = fileContent.split(separator: "\n")
		let notWhitespace = CharacterSet.whitespaces.inverted
		
		var foundMetadata = [FindMetadataResult.FoundMetadata]()
		
		for (index, line) in lines.enumerated() {
			// look for the marker on the line
			guard let range = line.range(of: self.metadataLineMarker, options: .backwards) else { continue }
			
			// check that there is only whitespace after the marker
			guard line[range.upperBound...].rangeOfCharacter(from: notWhitespace) == nil else { continue }
					
			// find the start of the metadata
			guard let commentRange = self.rangeOfCommentTrivia(in: line) else { continue }
			
			let metadataStart = commentRange.upperBound
			let metadataEnd = range.lowerBound
			
			let metadataRange = metadataStart ..< metadataEnd
			
			let rawMetadataString = line[metadataRange]
			
			let parsedMetadata: Metadata? = {
				for prefix in Metadata.Prefix.allCases {
					let formattedPrefix = prefix.formatted
					guard rawMetadataString.hasPrefix(formattedPrefix) else { continue }
					
					let parameterString = rawMetadataString.dropFirst(formattedPrefix.count).dropFirst(2)
					
					switch prefix {
						case .viewFile:
							if parameterString.contains("http") {
								return .viewFile(url: String(parameterString))
							}
					}
				}
				
				return nil
			}()
			
			if let parsedMetadata = parsedMetadata {
				let found = FindMetadataResult.FoundMetadata(metadata: parsedMetadata, lineIndex: index, columnRange: range)
				foundMetadata.append(found)
			}
		}
		
		if foundMetadata.isEmpty {
			return .foundNoMetadata
		} else {
			return .found(foundMetadata)
		}
	}
	
	private func preferredStartingCommentSyntax(forFileContent fileContent: String, inFileAt url: URL) -> String {
		let lines = fileContent.split(separator: "\n")
		
		for line in lines {
			for startingSyntax in self.possibleStartingCommentSyntax {
				if line.range(of: startingSyntax + " ") != nil {
					return startingSyntax
				}
			}
		}
		
		return self.possibleStartingCommentSyntax.first!
	}
	
	private func rangeOfCommentTrivia<S : StringProtocol>(in line: S) -> Range<String.Index>? {
		let notWhitespace = CharacterSet.whitespaces.inverted
		
		for syntax in self.possibleStartingCommentSyntax {
			// look for a comment starter
			guard let startRange = line.range(of: syntax) else { continue }
			
			// check it is actually at the start of the line
			guard line[..<startRange.lowerBound].rangeOfCharacter(from: notWhitespace) == nil else { continue }
			
			// find the end of the whitespace following the syntax
			guard let endRange = line[startRange.upperBound...].rangeOfCharacter(from: notWhitespace) else { continue }
			
			return startRange.lowerBound..<endRange.lowerBound
		}
		
		return nil
	}
}
