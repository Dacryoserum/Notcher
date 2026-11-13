import XCTest
import AppKit
import NotcherCore
@testable import Notcher

final class FeatureTests: XCTestCase {
    // MARK: WebP

    private func decode(_ data: Data) -> (width: Int, height: Int, pixels: [UInt32])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = straightARGB(image) else { return nil }
        return (image.width, image.height, pixels)
    }
    func testLosslessWebPIsReadBackExactlyByTheSystemDecoder() throws {
        var seed: UInt64 = 7
        func random() -> UInt32 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt32(truncatingIfNeeded: seed >> 33) }
        let cases: [(Int, Int, (Int, Int) -> UInt32)] = [
            (1, 1, { _, _ in 0xff12_3456 }),
            (33, 17, { _, _ in 0xff33_66cc }),
            (120, 80, { x, y in 0xff00_0000 | UInt32(x * 2) << 16 | UInt32(y * 3) << 8 | UInt32((x + y) & 0xff) }),
            (61, 47, { _, _ in 0xff00_0000 | (random() & 0xff_ffff) }),
            (513, 9, { x, y in 0xff00_0000 | UInt32((x * 5 + y) & 0xff) << 8 })
        ]
        for (width, height, make) in cases {
            var pixels = [UInt32](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width { pixels[y * width + x] = make(x, y) } }
            let data = try XCTUnwrap(WebPLossless.encode(width: width, height: height, pixels: pixels))
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(data.count % 2, 0)
            let decoded = try XCTUnwrap(decode(data), "\(width)×\(height) could not be decoded")
            XCTAssertEqual(decoded.width, width); XCTAssertEqual(decoded.height, height)
            XCTAssertEqual(decoded.pixels, pixels, "\(width)×\(height) differs")
        }
    }
    func testWebPKeepsTransparencyAndRefusesImpossibleSizes() throws {
        let pixels: [UInt32] = [0xffff_0000, 0x0000_0000, 0xff00_ff00, 0x8000_00ff]
        let decoded = try XCTUnwrap(decode(try XCTUnwrap(WebPLossless.encode(width: 2, height: 2, pixels: pixels))))
        XCTAssertEqual(decoded.pixels[0], 0xffff_0000); XCTAssertEqual(decoded.pixels[2], 0xff00_ff00)
        XCTAssertEqual(decoded.pixels[1] >> 24, 0)
        XCTAssertEqual(decoded.pixels[3] >> 24, 0x80)
        XCTAssertNil(WebPLossless.encode(width: 2, height: 2, pixels: [0]))
        XCTAssertNil(WebPLossless.encode(width: 0, height: 4, pixels: []))
        XCTAssertNil(WebPLossless.encode(width: 20_000, height: 1, pixels: [UInt32](repeating: 0, count: 20_000)))
    }

    // MARK: Apple Notes

    func testSheetBecomesASafeAppleNote() throws {
        let titled = try XCTUnwrap(NotesService.appleNote(title: "Réunion", text: "Point 1\n\n<script>alert(1)</script> & co"))
        XCTAssertEqual(titled.name, "Réunion")
        XCTAssertEqual(titled.body, "<div>Point 1</div><div><br></div><div>&lt;script&gt;alert(1)&lt;/script&gt; &amp; co</div>")
        // An untitled sheet takes its first line as title, and that line leaves the body.
        let untitled = try XCTUnwrap(NotesService.appleNote(title: "Sans titre", text: "\n  Idée du jour  \nLe détail"))
        XCTAssertEqual(untitled.name, "Idée du jour")
        XCTAssertEqual(untitled.body, "<div>Le détail</div>")
        XCTAssertNil(NotesService.appleNote(title: "Sans titre", text: "  \n \n"))
        XCTAssertNil(NotesService.appleNote(title: "", text: ""))
        XCTAssertNotNil(NotesService.appleNote(title: "Titre seul", text: ""))
    }

    // MARK: Headphones

    func testConnectedHeadphonesAreReadFromTheBluetoothReport() throws {
        let report = Data(#"""
        {"SPBluetoothDataType":[{"controller_properties":{},"device_connected":[
          {"Clavier":{"device_minorType":"Keyboard","device_batteryLevelMain":"64%"}},
          {"AirPods Pro de Léo":{"device_minorType":"Headphones","device_productID":"0x2014","device_vendorID":"0x004C",
            "device_batteryLevelLeft":"85%","device_batteryLevelRight":"78%","device_batteryLevelCase":"40%"}}],
          "device_not_connected":[{"Vieux casque":{"device_minorType":"Headphones"}}]}]}
        """#.utf8)
        let info = try XCTUnwrap(Accessory.parse(report, name: "airpods pro de leo"))
        XCTAssertEqual(info.productID, 0x2014)
        XCTAssertEqual(info.summary, 78)
        XCTAssertEqual(info.details.count, 3)
        XCTAssertEqual(Accessory.symbol(productID: info.productID, name: "x"), "airpodspro")
        // An unknown name falls back to the connected headphones, never to another kind of device.
        XCTAssertEqual(Accessory.parse(report, name: "Autre nom")?.productID, 0x2014)
        let single = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Casque":{"device_minorType":"Headphones","device_batteryLevelMain":"55%"}}]}]}"#.utf8)
        let headset = try XCTUnwrap(Accessory.parse(single, name: "Casque"))
        XCTAssertEqual(headset.summary, 55); XCTAssertTrue(headset.details.isEmpty)
        XCTAssertEqual(Accessory.symbol(productID: nil, name: "Casque"), "headphones")
        XCTAssertNil(Accessory.parse(Data("{}".utf8), name: "x"))
        XCTAssertNil(Accessory.parse(Data(#"{"SPBluetoothDataType":[{"device_not_connected":[]}]}"#.utf8), name: "x"))
    }

    // MARK: Awake timer

    @MainActor func testEachPressAddsTimeToTheAwakePeriod() async throws {
        let system = SystemService(client: .init { _ in throw CommandError.unavailable })
        defer { system.stop() }
        XCTAssertNil(system.awakeRemaining)
        system.extendAwake(minutes: 15)
        XCTAssertTrue(system.awake)
        XCTAssertEqual(try XCTUnwrap(system.awakeRemaining), 900, accuracy: 2)
        system.extendAwake(minutes: 15); system.extendAwake(minutes: 30)
        XCTAssertEqual(try XCTUnwrap(system.awakeRemaining), 3600, accuracy: 2)
        system.extendAwake(minutes: 0); system.extendAwake(minutes: -5)
        XCTAssertEqual(try XCTUnwrap(system.awakeRemaining), 3600, accuracy: 2)
        // The cup switches everything off; switched on alone it has no deadline, and "+15" then starts one from now.
        system.toggleAwake()
        XCTAssertFalse(system.awake); XCTAssertNil(system.awakeUntil)
        system.toggleAwake()
        XCTAssertTrue(system.awake); XCTAssertNil(system.awakeRemaining)
        system.extendAwake(minutes: 15)
        XCTAssertEqual(try XCTUnwrap(system.awakeRemaining), 900, accuracy: 2)
    }

    // MARK: Covers

    func testPlainHttpCoverAddressIsUpgradedNeverUsedAsIs() {
        var track = NowPlaying(title: "T", artist: "A", album: "B", application: "Spotify", bundleIdentifier: "com.spotify.client", playing: true, duration: 10, elapsed: 0, artwork: nil)
        track.artworkURL = "http://i.scdn.co/image/abc"
        XCTAssertEqual(track.remoteArtworkURL?.absoluteString, "https://i.scdn.co/image/abc")
        track.artworkURL = "ftp://i.scdn.co/image/abc"; XCTAssertNil(track.remoteArtworkURL)
        track.artworkURL = "http://"; XCTAssertNil(track.remoteArtworkURL)
    }
}
