# 演示数据 Builder 与 App 截图模式

让截图里的路径与心率/配速曲线一眼可信，且不依赖真实授权（HealthKit）。

## 1. App 截图模式开关
在 `@main` App 冷启时读 `UserDefaults`：

```swift
import SwiftUI

@main
struct RouteLensApp: App {
    @StateObject private var store = WorkoutStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task {
                    if SnapshotSupport.isEnabled {
                        store.seedDemoData()   // 注入确定性演示数据
                        store.loadFromCache()   // 跳过真实 HealthKit 授权
                    } else {
                        store.requestAuthorization()
                    }
                }
        }
    }
}
```

`SnapshotSupport.swift`：

```swift
import Foundation

enum SnapshotSupport {
    /// UI 测试在启动时设 FASTLANE_SNAPSHOT=true 触发。
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "FASTLANE_SNAPSHOT")
    }

    /// 可选：-snapshotDestination trend|settings 直达指定 tab，避免截图动画闪过。
    static var destination: String? {
        UserDefaults.standard.string(forKey: "snapshotDestination")
    }
}
```

## 2. DemoDataBuilder：真实生理曲线

### 2.1 确定性随机（同种子同结果）
```swift
/// mulberry32：小、快、确定性。
func mulberry32(_ seed: UInt32) -> () -> Double {
    var a = seed
    return {
        a &=* 0xFFFFFF
        a = a &+ 0x6D2B79F5
        var t = Double(a)
        t = (t ^ (t >> 15)) * (1.0 / Double(0x100000000))
        return t
    }
}
```

### 2.2 有机环形路径（Catmull-Rom 闭合样条）
```swift
struct RoutePoint { let lat: Double; let lon: Double }

func catmullRomClosed(_ cps: [RoutePoint], samples: Int = 200) -> [RoutePoint] {
    guard cps.count >= 3 else { return cps }
    var out: [RoutePoint] = []
    let n = cps.count
    for i in 0..<n {
        let p0 = cps[(i - 1 + n) % n], p1 = cps[i], p2 = cps[(i + 1) % n], p3 = cps[(i + 2) % n]
        for j in 0..<samples {
            let t = Double(j) / Double(samples)
            let t2 = t * t, t3 = t2 * t
            let lat = 0.5 * ((2*p1.lat) + (-p0.lat + p2.lat)*t
                + (2*p0.lat - 5*p1.lat + 4*p2.lat - p3.lat)*t2
                + (-p0.lat + 3*p1.lat - 3*p2.lat + p3.lat)*t3)
            let lon = 0.5 * ((2*p1.lon) + (-p0.lon + p2.lon)*t
                + (2*p0.lon - 5*p1.lon + 4*p2.lon - p3.lon)*t2
                + (-p0.lon + 3*p1.lon - 3*p2.lon + p3.lon)*t3)
            out.append(RoutePoint(lat: lat, lon: lon))
        }
    }
    return out
}
```

### 2.3 心率：热身-稳态-冷身
```swift
func heartRateSeries(seconds: Int, peak: Double = 165, rng: () -> Double) -> [Double] {
    (0..<seconds).map { i in
        let p = Double(i) / Double(seconds)
        let ramp = min(1, p / 0.15) * (1 - min(1, max(0, (p - 0.85) / 0.15)))
        let base = 95 + (peak - 95) * ramp
        return base + (rng() - 0.5) * 4
    }
}
```

### 2.4 配速与坡度负相关
```swift
func paceSeconds(grade: Double, base: Double = 300) -> Double {
    base * (1 + max(0, grade) * 1.5 - min(0, grade) * 0.5)
}
```

### 2.5 组装多条不同运动类型
```swift
func buildDemoWorkouts() -> [Workout] {
    let seeds: [(String, UInt32, Double)] = [
        ("Morning Run", 1, 165),
        ("Evening Ride", 2, 150),
        ("Trail Hike", 3, 130),
        ("Interval Session", 4, 178),
    ]
    return seeds.map { name, seed, peak in
        let rng = mulberry32(seed)
        let cps = (0..<6).map { _ in
            RoutePoint(lat: 37.33 + (rng()-0.5)*0.02, lon: -122.03 + (rng()-0.5)*0.02)
        }
        let path = catmullRomClosed(cps)
        let hr = heartRateSeries(seconds: 1800, peak: peak, rng: rng)
        return Workout(name: name, route: path, heartRate: hr, kind: .cycling)
    }
}
```

## 3. UI 测试截图导航
在 `ScreenshotsTests.swift` 按序调用 `snapshot("01Records")`、`snapshot("02RouteDetail")` 等，导航到详情/趋势/设置 tab。截图命名由 `SnapshotHelper.swift`（fastlane 自带）处理。

## 4. 失败分支
- `isEnabled` 为 false 且无真实授权 → App 走空态；截图应设 `FASTLANE_SNAPSHOT=true`。
- 曲线仍显假 → 提高 `samples`、校准 `peak` 与噪声幅度。
