import CoreGraphics
import Foundation
import Testing
@testable import OpenScreensCore

@Suite("Posture presets")
struct PosturePresetsTests {

    @Test func nothingChosenChangesNothing() {
        let settings = ConnectionSettings(moreSpace: true, touchInput: .trackpad)
        for posture in DevicePosture.allCases {
            #expect(settings.overlaid(for: posture) == settings)
        }
        #expect(PosturePresets().isEmpty)
    }

    @Test func aPostureSaysOnlyWhatItHasAnOpinionAbout() {
        var settings = ConnectionSettings(moreSpace: true, touchInput: .trackpad)
        settings.postures.folded = PosturePresets.Preset(touchInput: .touch)
        let folded = settings.overlaid(for: .folded)
        #expect(folded.touchInput == .touch)
        // The desktop size was not mentioned, so it stays as it was set.
        #expect(folded.moreSpace == true)
        // And the other postures are untouched by this one.
        #expect(settings.overlaid(for: .open).touchInput == .trackpad)
    }

    @Test func theBaselineIsWhatGetsSavedNotWhatIsInForce() {
        // Unfolding must not leave the folded phone's answers behind as
        // though someone had typed them in.
        var settings = ConnectionSettings(touchInput: .trackpad)
        settings.postures.folded = PosturePresets.Preset(touchInput: .touch, moreSpace: true)
        let folded = settings.overlaid(for: .folded)
        #expect(folded.touchInput == .touch)
        #expect(settings.touchInput == .trackpad)
        #expect(settings.postures.folded.touchInput == .touch)
    }

    @Test func theDeckIsNotASettingAndStaysWhereItWasPut() {
        var settings = ConnectionSettings(touchInput: .trackpad)
        settings.postures.halfOpen = PosturePresets.Preset(showsDeck: true)
        // A posture whose only opinion is about the deck changes no setting.
        #expect(settings.overlaid(for: .halfOpen) == settings)
        #expect(settings.postures.halfOpen.showsDeck == true)
    }

    @Test func theDefaultsForAFoldingPhoneAnswerEveryPosture() {
        let presets = PosturePresets.foldableDefaults
        #expect(!presets.isEmpty)
        #expect(presets[.folded].touchInput == .touch)
        #expect(presets[.folded].moreSpace == false)
        #expect(presets[.folded].showsDeck == false)
        #expect(presets[.open].touchInput == .trackpad)
        #expect(presets[.open].moreSpace == true)
        #expect(presets[.halfOpen].touchInput == nil)
        #expect(presets[.halfOpen].showsDeck == true)
    }

    @Test func aPartialRecordIsReadWithTheRestLeftAlone() throws {
        // A library written by a version that had fewer postures, or by hand.
        let decoded = try JSONDecoder().decode(
            PosturePresets.self, from: Data(#"{"folded":{"touchInput":"touch"}}"#.utf8))
        #expect(decoded.folded.touchInput == .touch)
        #expect(decoded.folded.moreSpace == nil)
        #expect(decoded.halfOpen.isEmpty)
        #expect(decoded.open.isEmpty)
    }

    @Test func aTouchModeThisVersionDoesNotKnowIsReadAsTrackpad() throws {
        let decoded = try JSONDecoder().decode(
            [PosturePresets.Preset].self,
            from: Data(#"[{"touchInput":"palmGestures"},{}]"#.utf8))
        #expect(decoded[0].touchInput == .trackpad)
        #expect(decoded[1].isEmpty)
    }

    @Test func settingsCarryTheirPosturesThroughADocument() throws {
        var settings = ConnectionSettings(quality: .standard)
        settings.postures = .foldableDefaults
        let decoded = try JSONDecoder().decode(
            ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func settingsFromBeforeThereWerePosturesStillLoad() throws {
        let old = Data(#"{"quality":"highPerformance","resolution":"matchWindow"}"#.utf8)
        let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: old)
        #expect(decoded.postures.isEmpty)
        #expect(decoded.threeFingerSwipes == .panPicture)
    }
}
