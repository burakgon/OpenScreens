import Foundation
import Testing
@testable import OpenScreensCore

/// Picture in Picture, as each computer's connection settings have it.
struct PictureInPictureSettingsTests {
    @Test func aComputerStartsWithTheButtonAtFifteenFramesASecond() {
        // A button to ask for it, and never a window nobody asked for.
        #expect(ConnectionSettings().pictureInPicture == .onDemand)
        #expect(ConnectionSettings().pictureInPictureFrameRate == .fifteen)
    }

    @Test func theChoicesAreKeptWithTheComputer() throws {
        var settings = ConnectionSettings()
        settings.pictureInPicture = .automatic
        settings.pictureInPictureFrameRate = .full
        let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.pictureInPicture == .automatic)
        #expect(decoded.pictureInPictureFrameRate == .full)
    }

    @Test func theyAreStoredUnderStableNames() throws {
        // These names are in every computer's record, and in iCloud.
        var settings = ConnectionSettings()
        settings.pictureInPicture = .off
        settings.pictureInPictureFrameRate = .thirty
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["pictureInPicture"] as? String == "off")
        #expect(object?["pictureInPictureFrameRate"] as? String == "thirty")
    }

    @Test func aRecordFromBeforeTheChoicesExistedMeansTheDefaults() throws {
        let old = Data(#"{"quality":"highPerformance","resolution":"matchWindow","displays":"single"}"#.utf8)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: old)
        #expect(settings.pictureInPicture == .onDemand)
        #expect(settings.pictureInPictureFrameRate == .fifteen)
    }

    @Test func choicesThisVersionDoesNotKnowFallBackToTheDefaults() throws {
        let newer = Data(#"{"quality":"standard","pictureInPicture":"always","pictureInPictureFrameRate":"sixty"}"#.utf8)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: newer)
        // The rest of the record is still read.
        #expect(settings.quality == .standard)
        #expect(settings.pictureInPicture == .onDemand)
        #expect(settings.pictureInPictureFrameRate == .fifteen)
    }

    @Test func theButtonsSendNothingUntilGivenKeys() {
        let keys = ConnectionSettings().pictureInPictureKeys
        #expect(keys == PictureInPictureKeys())
        #expect(!keys.skips)
        #expect(PictureInPictureKeys(skipForward: RemoteShortcut(name: "Forward", key: .function(15))).skips)
        #expect(!PictureInPictureKeys(playPause: RemoteShortcut(name: "Play", key: .function(14))).skips)
    }

    @Test func theButtonsKeysAreKeptWithTheComputer() throws {
        var settings = ConnectionSettings()
        settings.pictureInPictureKeys = PictureInPictureKeys(
            skipBack: RemoteShortcut(name: "Back", key: .function(13)),
            playPause: RemoteShortcut(name: "Play", modifiers: [.control], key: .special(.space)))
        let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.pictureInPictureKeys == settings.pictureInPictureKeys)
        #expect(decoded.pictureInPictureKeys.skipForward == nil)
    }

    @Test func keysThisVersionCannotReadLeaveTheRestOfTheRecord() throws {
        let newer = Data(#"{"quality":"standard","pictureInPictureKeys":{"skipBack":{"chord":[1,2]}}}"#.utf8)
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: newer)
        #expect(settings.quality == .standard)
        #expect(settings.pictureInPictureKeys == PictureInPictureKeys())
    }

    @Test func theFullRateHasNoFixedNumber() {
        #expect(PictureInPictureFrameRate.allCases.map(\.framesPerSecond) == [15, 30, nil])
        #expect(PictureInPictureFrameRate.allCases.map(\.title) == ["15 fps", "30 fps", "Full"])
        #expect(PictureInPictureMode.allCases.map(\.title) == ["On Demand", "Automatically", "Off"])
    }
}
