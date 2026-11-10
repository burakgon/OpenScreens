import Foundation
import RFBTestServer

// A stand-in VNC server showing a drawn desktop.
//
//     swift run openscreens-demo-server [--port 5999] [--password secret]
//                                       [--style ocean|sunrise|midnight]
//                                       [--size 2560x1600] [--public]
//
// Point OpenScreens at localhost:5999 to try the app, take screenshots or
// run through the interface without a real computer on the other end. It
// only listens on this machine unless --public is given.

var port: UInt16 = 5999
var password: String?
var style = DemoDesktop.Style.ocean
var width = 2560
var height = 1600
var isPublic = false

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String? { arguments.isEmpty ? nil : arguments.removeFirst() }
    switch argument {
    case "--port":
        port = value().flatMap { UInt16($0) } ?? port
    case "--password":
        password = value()
    case "--style":
        switch value() {
        case "sunrise": style = .sunrise
        case "midnight": style = .midnight
        default: style = .ocean
        }
    case "--size":
        let parts = (value() ?? "").split(separator: "x").compactMap { Int($0) }
        if parts.count == 2, parts[0] > 0, parts[1] > 0 {
            (width, height) = (parts[0], parts[1])
        }
    case "--public":
        isPublic = true
    default:
        FileHandle.standardError.write(Data("Unknown option \(argument)\n".utf8))
        exit(64)
    }
}

guard let image = DemoDesktop.image(width: width, height: height, style: style) else {
    FileHandle.standardError.write(Data("Could not draw the demo desktop.\n".utf8))
    exit(1)
}

let server = RFBTestServer(
    image: image,
    configuration: .init(
        name: "Demo Desktop", port: port, password: password, allowsRemoteConnections: isPublic))
do {
    let bound = try await server.start()
    print("Demo desktop (\(width)×\(height)) at vnc://localhost:\(bound)\(password == nil ? "" : " — password required")")
    print("Press Control-C to stop.")
} catch {
    FileHandle.standardError.write(Data("Could not start: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// Serve until interrupted.
while true {
    try await Task.sleep(for: .seconds(3600))
}
