import Foundation
@testable import LodestoneCore
import XCTest

final class ShortcutStoreTests: XCTestCase {
    let left = KeyCombo(keyCode: 123, modifiers: 6144)
    let right = KeyCombo(keyCode: 124, modifiers: 6144)
    let custom = KeyCombo(keyCode: 0, modifiers: 256)
    var suite: UserDefaults!
    var suiteName: String!

    override func setUp() {
        suiteName = "lodestone-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
    }

    func makeStore() -> ShortcutStore {
        ShortcutStore(defaults: [.leftHalf: left, .rightHalf: right], storage: suite)
    }

    func testDefaults() {
        let store = makeStore()
        XCTAssertEqual(store.combo(for: .leftHalf), left)
        XCTAssertNil(store.combo(for: .maximize))
        XCTAssertEqual(store.action(for: right), .rightHalf)
    }

    func testChangesPersist() {
        makeStore().set(custom, for: .maximize)
        makeStore().set(nil, for: .leftHalf)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.combo(for: .maximize), custom)
        XCTAssertNil(reloaded.combo(for: .leftHalf))
        XCTAssertEqual(reloaded.combo(for: .rightHalf), right)
    }

    func testAssigningATakenComboMovesIt() {
        let store = makeStore()
        store.set(left, for: .maximize)
        XCTAssertEqual(store.combo(for: .maximize), left)
        XCTAssertNil(store.combo(for: .leftHalf))
        XCTAssertNil(makeStore().combo(for: .leftHalf))
    }

    func testReset() {
        let store = makeStore()
        store.set(custom, for: .leftHalf)
        store.resetToDefaults()
        XCTAssertEqual(store.combo(for: .leftHalf), left)
        XCTAssertEqual(makeStore().combo(for: .leftHalf), left)
    }

    func testSettingTheDefaultBackDropsTheOverride() {
        let store = makeStore()
        store.set(custom, for: .leftHalf)
        store.set(left, for: .leftHalf)
        XCTAssertNil(suite.data(forKey: "shortcuts"))
    }
}
