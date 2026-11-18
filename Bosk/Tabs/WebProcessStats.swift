import Darwin
import Foundation

/// Memory and CPU of WebKit's helper processes. WebKit starts them through launchd, so they are
/// not child processes of Bosk. The `_…Identifier` properties are private WebKit API; when WebKit
/// removes one, `pid` gives nil and the tab manager and the memory limit see no process.
enum WebProcessStats {
    struct Usage {
        /// Physical footprint, the "Memory" column of Activity Monitor. It includes compressed and swapped memory.
        var footprint: UInt64
        /// CPU time used since the process started.
        var cpuNanoseconds: UInt64
    }

    static func pid(_ object: NSObject, _ key: String = "_webProcessIdentifier") -> Int32? {
        guard object.responds(to: NSSelectorFromString(key)),
              let value = object.value(forKey: key) as? NSNumber, value.int32Value > 0 else { return nil }
        return value.int32Value
    }

    static func usage(_ pid: Int32) -> Usage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        // The CPU times are in Mach time units, not nanoseconds, on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(footprint: info.ri_phys_footprint,
                     cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()
}
