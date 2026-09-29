import Foundation
import Testing
import OhmModel
@testable import OhmForecast

/// Deterministic pseudo-random number generator for reproducible tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
        return z ^ (z &>> 31)
    }
}

struct OhmForecastTests {

    // MARK: - 1. Convergence on Synthetic Linear Data

    @Test func testConvergesOnSyntheticLinearData() async {
        let forecaster = BatteryForecaster()

        // 10 feature weights: [P_sys, s0...s7, s_other]
        let trueWeights: [Double] = [1.08, 0.85, 0.65, 0.45, 0.35, 0.25, 0.15, 0.10, 0.05, 0.20]
        var rng = SplitMix64(seed: 42)

        for _ in 0..<200 {
            let sysPower = Double.random(in: 5.0...30.0, using: &rng)
            let rawShares = (0..<9).map { _ in Double.random(in: 0.1...1.0, using: &rng) }
            let sumShares = rawShares.reduce(0, +)
            let shares = rawShares.map { $0 / sumShares }
            let appShares = Array(shares[0..<8])
            let otherShare = shares[8]

            let x = [sysPower] + appShares + [otherShare]
            var targetW = 0.0
            for i in 0..<10 {
                targetW += x[i] * trueWeights[i]
            }

            await forecaster.observe(
                systemPower: sysPower,
                appShares: appShares,
                otherShare: otherShare,
                dischargeRate: targetW
            )
        }

        // Test on 25 unseen test cases
        for _ in 0..<25 {
            let testSysPower = Double.random(in: 8.0...28.0, using: &rng)
            let rawShares = (0..<9).map { _ in Double.random(in: 0.1...1.0, using: &rng) }
            let sumShares = rawShares.reduce(0, +)
            let shares = rawShares.map { $0 / sumShares }
            let appShares = Array(shares[0..<8])
            let otherShare = shares[8]

            let x = [testSysPower] + appShares + [otherShare]
            var expectedW = 0.0
            for i in 0..<10 {
                expectedW += x[i] * trueWeights[i]
            }

            let battery = BatteryState(
                source: .battery,
                percent: 80,
                voltage_mV: 12000,
                amperage_mA: -1500,
                fullChargeCapacity_mAh: 5000
            )

            let forecast = await forecaster.forecast(
                with: battery,
                systemPower: testSysPower,
                appShares: appShares,
                otherShare: otherShare
            )

            #expect(forecast != nil)
            if let forecast = forecast {
                let errorPct = abs(forecast.predictedWatts - expectedW) / expectedW
                #expect(errorPct < 0.02, "Expected error < 2%, got \(errorPct * 100)%")
            }
        }
    }

    // MARK: - 2. Adapts After a Regime Change (Forgetting Factor)

    @Test func testAdaptsAfterRegimeChange() async {
        let forecaster = BatteryForecaster(lambda: 0.995)
        var rng = SplitMix64(seed: 123)

        // Regime 1: base discharge rate (e.g. standard screen brightness)
        for _ in 0..<150 {
            let sysPower = Double.random(in: 10.0...20.0, using: &rng)
            let rawShares = (0..<9).map { _ in Double.random(in: 0.1...1.0, using: &rng) }
            let sumShares = rawShares.reduce(0, +)
            let shares = rawShares.map { $0 / sumShares }
            let appShares = Array(shares[0..<8])
            let otherShare = shares[8]
            let target = 1.0 * sysPower + 0.5 * appShares[0]

            await forecaster.observe(
                systemPower: sysPower,
                appShares: appShares,
                otherShare: otherShare,
                dischargeRate: target
            )
        }

        // Regime 2: max brightness + high drain peripherals attached
        for _ in 0..<450 {
            let sysPower = Double.random(in: 10.0...20.0, using: &rng)
            let rawShares = (0..<9).map { _ in Double.random(in: 0.1...1.0, using: &rng) }
            let sumShares = rawShares.reduce(0, +)
            let shares = rawShares.map { $0 / sumShares }
            let appShares = Array(shares[0..<8])
            let otherShare = shares[8]
            let target = 1.8 * sysPower + 1.6 * appShares[0]

            await forecaster.observe(
                systemPower: sysPower,
                appShares: appShares,
                otherShare: otherShare,
                dischargeRate: target
            )
        }

        let testSys = 15.0
        let testRawShares = (0..<9).map { _ in Double.random(in: 0.1...1.0, using: &rng) }
        let testSum = testRawShares.reduce(0, +)
        let testShares = testRawShares.map { $0 / testSum }
        let testAppShares = Array(testShares[0..<8])
        let testOther = testShares[8]

        let expectedRegime2 = 1.8 * testSys + 1.6 * testAppShares[0]
        let expectedRegime1 = 1.0 * testSys + 0.5 * testAppShares[0]

        let battery = BatteryState(
            source: .battery,
            percent: 50,
            voltage_mV: 12000,
            amperage_mA: -2000,
            fullChargeCapacity_mAh: 5000
        )

        let forecast = await forecaster.forecast(
            with: battery,
            systemPower: testSys,
            appShares: testAppShares,
            otherShare: testOther
        )

        #expect(forecast != nil)
        if let forecast = forecast {
            let diffRegime2 = abs(forecast.predictedWatts - expectedRegime2)
            let diffRegime1 = abs(forecast.predictedWatts - expectedRegime1)
            #expect(diffRegime2 < 1.0, "Expected model to adapt to regime 2 within 1.0 W, got diff \(diffRegime2)")
            #expect(diffRegime2 < diffRegime1, "Model should be significantly closer to regime 2 than regime 1")
        }
    }

    // MARK: - 3. Fallback Before 30 Samples

    @Test func testFallbackBefore30Samples() async {
        let forecaster = BatteryForecaster(pRef: 12.0)

        let battery = BatteryState(
            source: .battery,
            percent: 80,
            voltage_mV: 12000,
            amperage_mA: -1000,
            fullChargeCapacity_mAh: 5000
        )
        // 5000 mAh * 80% = 4000 mAh -> 4.0 Ah * 12 V = 48.0 Wh.
        // At 12.0 W, remaining minutes = (48.0 / 12.0) * 60 = 240.0 minutes.

        // Sample 0 (no observations yet)
        let f0 = await forecaster.forecast(with: battery)
        #expect(f0 != nil)
        #expect(f0?.isFallback == true)
        #expect(f0?.predictedWatts == 12.0)
        #expect(abs((f0?.remainingMinutes ?? 0) - 240.0) < 0.01)

        // Samples 1 through 29 must all report isFallback == true
        for i in 1...29 {
            await forecaster.observe(
                systemPower: 14.0,
                appShares: [0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                otherShare: 0.0,
                dischargeRate: 14.0,
                battery: battery
            )
            let count = await forecaster.sampleCount
            #expect(count == i)

            let f = await forecaster.forecast()
            #expect(f?.isFallback == true)
        }

        // Sample 30: transitions to regression model
        await forecaster.observe(
            systemPower: 14.0,
            appShares: [0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            otherShare: 0.0,
            dischargeRate: 14.0,
            battery: battery
        )
        let count30 = await forecaster.sampleCount
        #expect(count30 == 30)

        let f30 = await forecaster.forecast()
        #expect(f30 != nil)
        #expect(f30?.isFallback == false)
    }

    // MARK: - 4. Codable Round-Trip

    @Test func testCodableRoundTrip() async throws {
        let forecaster = BatteryForecaster(pRef: 11.5)

        let battery = BatteryState(
            source: .battery,
            percent: 90,
            voltage_mV: 12000,
            amperage_mA: -1200,
            rawCurrentCapacity_mAh: 4500,
            fullChargeCapacity_mAh: 5000
        )

        for _ in 0..<40 {
            await forecaster.observe(
                systemPower: 12.0,
                appShares: [0.6, 0.2, 0.1, 0.1, 0.0, 0.0, 0.0, 0.0],
                otherShare: 0.0,
                dischargeRate: 12.5,
                battery: battery
            )
        }

        let originalForecast = await forecaster.forecast()
        #expect(originalForecast != nil)
        #expect(originalForecast?.isFallback == false)

        let state = await forecaster.currentState
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        let decodedState = try decoder.decode(BatteryForecasterState.self, from: data)

        #expect(state == decodedState)

        let restoredForecaster = BatteryForecaster(state: decodedState)
        let restoredForecast = await restoredForecaster.forecast()

        #expect(restoredForecast != nil)
        #expect(restoredForecast?.isFallback == false)
        #expect(restoredForecast?.sampleCount == originalForecast?.sampleCount)
        #expect(abs((restoredForecast?.remainingMinutes ?? 0) - (originalForecast?.remainingMinutes ?? 0)) < 1e-6)
        #expect(abs((restoredForecast?.predictedWatts ?? 0) - (originalForecast?.predictedWatts ?? 0)) < 1e-6)
        #expect(abs((restoredForecast?.residualVariance ?? 0) - (originalForecast?.residualVariance ?? 0)) < 1e-6)
        #expect(abs((restoredForecast?.lowerMinutes ?? 0) - (originalForecast?.lowerMinutes ?? 0)) < 1e-6)
        #expect(abs((restoredForecast?.upperMinutes ?? 0) - (originalForecast?.upperMinutes ?? 0)) < 1e-6)
    }

    // MARK: - 5. Synthetic 4-Hour Day Replay Test (MAE < 20 min)

    @Test func testSynthetic4HourDayReplayMAEUnder20Minutes() async {
        let forecaster = BatteryForecaster()

        // Battery setup: 70.0 Wh full capacity
        let fullCapacityWh = 70.0
        let voltage_mV = 12000
        var remainingWh = fullCapacityWh

        // 4 hours = 240 minutes, 1 minute per tick
        var totalAbsErrorMinutes = 0.0
        var evaluationCount = 0

        var rng = SplitMix64(seed: 999)

        for minute in 0..<240 {
            // Workload phases across the 4-hour day:
            // 0..60 min: Heavy development (IDE, compiling) ~ 15 W
            // 60..120 min: Lightweight browsing / document reading ~ 8 W
            // 120..180 min: Video call / conferencing ~ 13 W
            // 180..240 min: Mixed productivity ~ 10 W
            let sysPower: Double
            let appShares: [Double]
            let otherShare: Double
            let baseFactor: Double

            if minute < 60 {
                sysPower = 14.5 + Double.random(in: -0.5...0.5, using: &rng)
                appShares = [0.65, 0.20, 0.10, 0.05, 0.0, 0.0, 0.0, 0.0]
                otherShare = 0.0
                baseFactor = 1.03
            } else if minute < 120 {
                sysPower = 7.5 + Double.random(in: -0.5...0.5, using: &rng)
                appShares = [0.50, 0.30, 0.15, 0.05, 0.0, 0.0, 0.0, 0.0]
                otherShare = 0.0
                baseFactor = 1.02
            } else if minute < 180 {
                sysPower = 12.5 + Double.random(in: -0.5...0.5, using: &rng)
                appShares = [0.70, 0.15, 0.10, 0.05, 0.0, 0.0, 0.0, 0.0]
                otherShare = 0.0
                baseFactor = 1.04
            } else {
                sysPower = 9.5 + Double.random(in: -0.5...0.5, using: &rng)
                appShares = [0.40, 0.30, 0.20, 0.10, 0.0, 0.0, 0.0, 0.0]
                otherShare = 0.0
                baseFactor = 1.02
            }

            let dischargeRateW = baseFactor * sysPower + 0.2 * appShares[0]

            // Battery state at current minute
            let currentMah = Int((remainingWh * 1_000_000.0) / Double(voltage_mV))
            let percent = max(1, min(100, Int((remainingWh / fullCapacityWh) * 100.0)))
            let amperage_mA = -Int((dischargeRateW / (Double(voltage_mV) / 1000.0)) * 1000.0)

            let battery = BatteryState(
                source: .battery,
                percent: percent,
                voltage_mV: voltage_mV,
                amperage_mA: amperage_mA,
                rawCurrentCapacity_mAh: currentMah,
                fullChargeCapacity_mAh: Int((fullCapacityWh * 1_000_000.0) / Double(voltage_mV))
            )

            // Evaluate forecast for current app mix and battery
            if minute >= 30 {
                if let forecast = await forecaster.forecast(
                    with: battery,
                    systemPower: sysPower,
                    appShares: appShares,
                    otherShare: otherShare
                ) {
                    let groundTruthRemainingMinutes = (remainingWh / dischargeRateW) * 60.0
                    let error = abs(forecast.remainingMinutes - groundTruthRemainingMinutes)
                    totalAbsErrorMinutes += error
                    evaluationCount += 1
                }
            }

            // Observe tick and drain battery for 1 minute
            await forecaster.observe(
                systemPower: sysPower,
                appShares: appShares,
                otherShare: otherShare,
                dischargeRate: dischargeRateW,
                battery: battery
            )

            let energyDrainedWh = dischargeRateW * (1.0 / 60.0)
            remainingWh = max(0.1, remainingWh - energyDrainedWh)
        }

        #expect(evaluationCount > 0)
        let mae = totalAbsErrorMinutes / Double(evaluationCount)
        #expect(mae < 20.0, "Expected MAE < 20 minutes, got \(mae) minutes")
    }

    // MARK: - 6. SampleTick Integration

    @Test func testSampleTickIntegration() async {
        let forecaster = BatteryForecaster()

        let appA = AppKey(kind: .bundleID, value: "com.apple.dt.Xcode")
        let appB = AppKey(kind: .bundleID, value: "com.apple.Safari")

        let delta1 = ProcessDelta(
            identity: ProcessIdentity(pid: 1001, startAbsTime: 10),
            app: appA,
            energy_nJ: 6_000_000_000, // 6 J
            pEnergy_nJ: 4_000_000_000,
            cpuTime_ns: 500_000_000
        )
        let delta2 = ProcessDelta(
            identity: ProcessIdentity(pid: 1002, startAbsTime: 20),
            app: appB,
            energy_nJ: 2_000_000_000, // 2 J
            pEnergy_nJ: 1_000_000_000,
            cpuTime_ns: 200_000_000
        )

        let tick = SampleTick(
            wallClock: Date(),
            interval: .seconds(1),
            system: SystemPower(cpuP: 5.0, cpuE: 2.0, gpu: 1.0, systemLoad: 12.0),
            battery: BatteryState(
                source: .battery,
                percent: 75,
                voltage_mV: 12000,
                amperage_mA: -1000, // 12 W
                rawCurrentCapacity_mAh: 4000,
                fullChargeCapacity_mAh: 5333
            ),
            thermal: .nominal,
            processes: [delta1, delta2],
            unreadable: UnreadableSummary(readableCount: 2, unreadableCount: 0)
        )

        // Features extraction check
        let features = BatteryForecaster.extractFeatures(from: tick)
        #expect(features.count == 10)
        #expect(features[0] == 12.0) // SystemLoad
        #expect(abs(features[1] - 0.75) < 1e-4) // appA share: 6 / 8 = 0.75
        #expect(abs(features[2] - 0.25) < 1e-4) // appB share: 2 / 8 = 0.25

        await forecaster.observe(tick)
        let count = await forecaster.sampleCount
        #expect(count == 1)

        let forecast = await forecaster.forecast()
        #expect(forecast != nil)
        #expect(forecast?.isFallback == true) // sampleCount < 30
        #expect(forecast?.remainingMinutes ?? 0 > 0)
    }
}
