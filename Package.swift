// swift-tools-version:5.2

import PackageDescription

let package = Package(
    name: "GetTheGist",
	platforms: [.macOS(.v10_15)],
	products: [.executable(name: "GetTheGist", targets: ["GetTheGist"])],
    dependencies: [
		.package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
		.package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.4.0"),
		.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.1.0"),
		.package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.0.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "0.0.1")
	],
    targets: [
		.target(name: "GetTheGist", dependencies: [
			.product(name: "NIO", package: "swift-nio"),
			.product(name: "NIOHTTP1", package: "swift-nio"),
			.product(name: "NIOExtras", package: "swift-nio-extras"),
			.product(name: "AsyncHTTPClient", package: "async-http-client"),
			.product(name: "KeychainAccess", package: "KeychainAccess"),
			.product(name: "ArgumentParser", package: "swift-argument-parser")
		], path: "Sources"),
        .testTarget(name: "GetTheGistTests", dependencies: ["GetTheGist"])
    ]
)
