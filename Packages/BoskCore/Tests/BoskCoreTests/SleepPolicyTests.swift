import Foundation
import Testing
@testable import BoskCore

/// Tab sleep keeps Bosk light. But a sleeping tab reloads, so sleeping the wrong tab
/// stops music, drops a call, or deletes text the user typed.
struct SleepPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hour: TimeInterval = 3600

    func sleep(_ tabs: [SleepPolicy.TabInfo], pressure: SleepPolicy.MemoryPressure = .normal) -> [UUID] {
        SleepPolicy.tabsToSleep(tabs, now: now, idleLimit: hour, pressure: pressure)
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

    @Test("A pinned tab stays awake, because the user keeps that site open and a reload loses their place")
    func pinnedStaysAwake() {
        var pinned = tab(idle: 2 * hour)
        pinned.isPinned = true
        let normal = tab(idle: 2 * hour)
        #expect(sleep([pinned, normal]) == [normal.id])
        #expect(sleep([pinned, normal], pressure: .critical) == [normal.id])
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
        #expect(sleep([tenMinutes, thirtyMinutes, oneMinute], pressure: .warning) == [thirtyMinutes.id])
        #expect(sleep([tenMinutes, oneMinute], pressure: .warning).isEmpty)
        #expect(sleep([tenMinutes, thirtyMinutes, oneMinute], pressure: .critical)
                == [thirtyMinutes.id, tenMinutes.id, oneMinute.id])
    }

    @Test("A memory warning sleeps only the oldest tab idle for half the sleep time, because warnings can come for hours and must not cancel the user's sleep time")
    func warningSleepsOneTab() {
        let tabs = [tab(idle: 600), tab(idle: 2 * hour), tab(idle: 1800), tab(idle: 1799)]
        #expect(sleep(tabs, pressure: .warning) == [tabs[1].id])
        // The media check needs all the tabs that could be the one.
        #expect(SleepPolicy.idleTabs(tabs, now: now, idleLimit: hour, pressure: .warning) == [tabs[1].id, tabs[2].id])
    }

    // MARK: Memory limit

    let gb: UInt64 = 1 << 30

    @Test("A background tab whose process is above 4 GB sleeps, so a runaway page cannot fill memory and swap")
    func runawayBackgroundTabSleeps() {
        let runaway = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        let normal = SleepPolicy.ProcessTab(id: UUID(), pid: 11)
        let result = SleepPolicy.overMemoryLimit([runaway, normal], footprints: [10: 44 * gb, 11: 2 * gb])
        #expect(result.sleep == [runaway.id])
        #expect(result.warn.isEmpty)
    }

    @Test("A heavy page under the limit stays awake, because sleep reloads it and loses the user's place")
    func underLimitStaysAwake() {
        let heavy = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        #expect(SleepPolicy.overMemoryLimit([heavy], footprints: [10: 4 * gb]) == ([], []))
    }

    @Test("The tab on screen is never put to sleep; the user gets a warning and decides")
    func selectedTabGetsWarning() {
        let selected = SleepPolicy.ProcessTab(id: UUID(), pid: 10, isSelected: true)
        #expect(SleepPolicy.overMemoryLimit([selected], footprints: [10: 8 * gb]) == ([], [selected.id]))
    }

    @Test("Background tabs that share the process of the tab on screen stay awake: their sleep frees nothing")
    func sharedProcessWithSelectedTab() {
        let selected = SleepPolicy.ProcessTab(id: UUID(), pid: 10, isSelected: true)
        let popup = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        #expect(SleepPolicy.overMemoryLimit([selected, popup], footprints: [10: 8 * gb]) == ([], [selected.id]))
    }

    @Test("All background tabs of a runaway process sleep, so the process can end")
    func sharedBackgroundProcessSleepsAll() {
        let a = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        let b = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        #expect(SleepPolicy.overMemoryLimit([a, b], footprints: [10: 8 * gb]).sleep == [a.id, b.id])
    }

    @Test("A call in a runaway process keeps its tabs awake, because sleep would end the call")
    func callKeepsProcessAwake() {
        let call = SleepPolicy.ProcessTab(id: UUID(), pid: 10, isCapturing: true)
        let other = SleepPolicy.ProcessTab(id: UUID(), pid: 10)
        #expect(SleepPolicy.overMemoryLimit([call, other], footprints: [10: 8 * gb]) == ([], []))
    }
}
