import Foundation
import Testing
@testable import BoskCore

/// Tab sleep keeps Bosk light. But a sleeping tab reloads, so sleeping the wrong tab
/// stops music, drops a call, or deletes text the user typed.
struct SleepPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hour: TimeInterval = 3600

    func sleep(_ tabs: [SleepPolicy.TabInfo], pressure: SleepPolicy.MemoryPressure = .normal) -> [UUID] {
        SleepPolicy.tabsToSleep(tabs, now: now, idleLimit: hour, pressureIdleLimit: 300, pressure: pressure)
    }

    func tab(idle: TimeInterval) -> SleepPolicy.TabInfo {
        .init(id: UUID(), lastActive: now.addingTimeInterval(-idle))
    }

    @Test("A tab idle for 60 minutes sleeps; a tab idle for 59 minutes stays awake")
    func idleLimit() {
        let old = tab(idle: hour)
        let recent = tab(idle: hour - 60)
        #expect(sleep([old, recent]) == [old.id])
    }

    @Test("The tab on screen never sleeps, because the user is looking at it")
    func selectedStaysAwake() {
        var selected = tab(idle: 5 * hour)
        selected.isSelected = true
        #expect(sleep([selected], pressure: .critical).isEmpty)
    }

    @Test("A tab playing media stays awake, because sleep would stop the user's music")
    func mediaStaysAwake() {
        var music = tab(idle: 5 * hour)
        music.isPlayingMedia = true
        #expect(sleep([music], pressure: .critical).isEmpty)
    }

    @Test("A tab using the camera or mic stays awake, because sleep would end the call")
    func callStaysAwake() {
        var call = tab(idle: 5 * hour)
        call.isCapturing = true
        #expect(sleep([call], pressure: .critical).isEmpty)
    }

    @Test("A tab with unsent typed text stays awake, because the reload would delete the text")
    func typedTextStaysAwake() {
        var draft = tab(idle: 5 * hour)
        draft.hasUnsentInput = true
        #expect(sleep([draft], pressure: .critical).isEmpty)
    }

    @Test("A tab that is already asleep is not put to sleep again")
    func asleepIsSkipped() {
        var asleep = tab(idle: 5 * hour)
        asleep.isAsleep = true
        #expect(sleep([asleep]).isEmpty)
    }

    @Test("Under memory pressure, tabs sleep sooner, and the oldest go first")
    func pressureSleepsSooner() {
        let tenMinutes = tab(idle: 600)
        let thirtyMinutes = tab(idle: 1800)
        let oneMinute = tab(idle: 60)
        #expect(sleep([tenMinutes, thirtyMinutes, oneMinute]).isEmpty)
        #expect(sleep([tenMinutes, thirtyMinutes, oneMinute], pressure: .warning) == [thirtyMinutes.id, tenMinutes.id])
        #expect(sleep([tenMinutes, thirtyMinutes, oneMinute], pressure: .critical)
                == [thirtyMinutes.id, tenMinutes.id, oneMinute.id])
    }
}
