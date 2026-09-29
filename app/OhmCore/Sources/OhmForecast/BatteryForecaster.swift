import Foundation
import OhmModel

/// Prediction of remaining battery runtime and power draw.
public struct BatteryForecast: Sendable, Codable, Equatable {
    /// Predicted remaining runtime in minutes based on current workload.
    public var remainingMinutes: Double
    /// Lower bound of the confidence band in minutes (pessimistic estimate, higher power).
    public var lowerMinutes: Double
    /// Upper bound of the confidence band in minutes (optimistic estimate, lower power).
    public var upperMinutes: Double
    /// Predicted power draw in Watts.
    public var predictedWatts: Double
    /// Online residual variance of the regression model.
    public var residualVariance: Double
    /// Total number of training samples incorporated into the model.
    public var sampleCount: Int
    /// Whether this prediction is using the fallback P_ref estimate (sampleCount < 30).
    public var isFallback: Bool

    /// Alias for remainingMinutes.
    public var predictedMinutes: Double { remainingMinutes }
    /// Alias for lowerMinutes.
    public var lowerBoundMinutes: Double { lowerMinutes }
    /// Alias for upperMinutes.
    public var upperBoundMinutes: Double { upperMinutes }

    /// Confidence interval range for remaining minutes.
    public var confidenceBand: ClosedRange<Double> {
        let low = min(lowerMinutes, upperMinutes)
        let high = max(lowerMinutes, upperMinutes)
        return low...high
    }

    public init(
        remainingMinutes: Double,
        lowerMinutes: Double,
        upperMinutes: Double,
        predictedWatts: Double,
        residualVariance: Double,
        sampleCount: Int,
        isFallback: Bool
    ) {
        self.remainingMinutes = remainingMinutes
        self.lowerMinutes = lowerMinutes
        self.upperMinutes = upperMinutes
        self.predictedWatts = predictedWatts
        self.residualVariance = residualVariance
        self.sampleCount = sampleCount
        self.isFallback = isFallback
    }
}

/// Persistable snapshot of the BatteryForecaster's online regression state.
public struct BatteryForecasterState: Sendable, Codable, Equatable {
    public var sampleCount: Int
    public var weights: [Double]
    public var covariance: [Double] // Flattened 10x10 matrix (100 elements)
    public var residualVariance: Double
    public var pRef: Double
    public var lambda: Double
    public var totalBatteryEnergyJoules: Double
    public var totalBatteryTimeSeconds: Double
    public var lastBatteryState: BatteryState?
    public var lastFeatures: [Double]?

    public init(
        sampleCount: Int = 0,
        weights: [Double] = Array(repeating: 0.0, count: 10),
        covariance: [Double]? = nil,
        residualVariance: Double = 1.0,
        pRef: Double = 10.0,
        lambda: Double = 0.995,
        totalBatteryEnergyJoules: Double = 0.0,
        totalBatteryTimeSeconds: Double = 0.0,
        lastBatteryState: BatteryState? = nil,
        lastFeatures: [Double]? = nil
    ) {
        self.sampleCount = sampleCount
        self.weights = weights
        if let cov = covariance, cov.count == 100 {
            self.covariance = cov
        } else {
            // Ridge initialization: P = 1000 * I
            var cov = Array(repeating: 0.0, count: 100)
            for i in 0..<10 {
                cov[i * 10 + i] = 1000.0
            }
            self.covariance = cov
        }
        self.residualVariance = residualVariance
        self.pRef = pRef
        self.lambda = lambda
        self.totalBatteryEnergyJoules = totalBatteryEnergyJoules
        self.totalBatteryTimeSeconds = totalBatteryTimeSeconds
        self.lastBatteryState = lastBatteryState
        self.lastFeatures = lastFeatures
    }
}

/// Protocol for battery forecasting actors (ADR 0001 §2).
public protocol BatteryForecasting: Actor {
    func observe(_ tick: SampleTick)
    func forecast() -> BatteryForecast?
}

/// Online linear regression (Recursive Least Squares) predicting battery runtime.
public actor BatteryForecaster: BatteryForecasting {
    private var state: BatteryForecasterState

    public var currentState: BatteryForecasterState { state }
    public var sampleCount: Int { state.sampleCount }
    public var weights: [Double] { state.weights }
    public var pRef: Double { state.pRef }
    public var residualVariance: Double { state.residualVariance }

    public init(
        pRef: Double = 10.0,
        lambda: Double = 0.995,
        ridgeP: Double = 1000.0
    ) {
        var cov = Array(repeating: 0.0, count: 100)
        for i in 0..<10 {
            cov[i * 10 + i] = ridgeP
        }
        self.state = BatteryForecasterState(
            sampleCount: 0,
            weights: Array(repeating: 0.0, count: 10),
            covariance: cov,
            residualVariance: 1.0,
            pRef: pRef,
            lambda: lambda
        )
    }

    public init(state: BatteryForecasterState) {
        self.state = state
    }

    public func reset(pRef: Double = 10.0, lambda: Double = 0.995, ridgeP: Double = 1000.0) {
        var cov = Array(repeating: 0.0, count: 100)
        for i in 0..<10 {
            cov[i * 10 + i] = ridgeP
        }
        self.state = BatteryForecasterState(
            sampleCount: 0,
            weights: Array(repeating: 0.0, count: 10),
            covariance: cov,
            residualVariance: 1.0,
            pRef: pRef,
            lambda: lambda
        )
    }

    public func loadState(_ newState: BatteryForecasterState) {
        self.state = newState
    }

    // MARK: - Feature Construction

    public static func extractFeatures(from tick: SampleTick) -> [Double] {
        let sysPower: Double
        if let load = tick.system.systemLoad, load > 0 {
            sysPower = load
        } else if let mw = tick.battery.systemLoad_mW, mw > 0 {
            sysPower = Double(mw) / 1000.0
        } else if tick.battery.voltage_mV > 0 && tick.battery.amperage_mA != 0 {
            let v = Double(tick.battery.voltage_mV) / 1000.0
            let a = Double(abs(tick.battery.amperage_mA)) / 1000.0
            sysPower = v * a
        } else {
            sysPower = tick.system.cpuP + tick.system.cpuE + (tick.system.gpu ?? 0.0)
        }

        var appEnergyMap: [AppKey: UInt64] = [:]
        for delta in tick.processes {
            appEnergyMap[delta.app, default: 0] += delta.energy_nJ
        }
        let totalAppEnergy = appEnergyMap.values.reduce(0, +)
        let sortedEnergies = appEnergyMap.values.sorted(by: >)

        var shares = Array(repeating: 0.0, count: 8)
        var otherShare = 0.0

        if totalAppEnergy > 0 {
            let totalD = Double(totalAppEnergy)
            for i in 0..<min(8, sortedEnergies.count) {
                shares[i] = Double(sortedEnergies[i]) / totalD
            }
            if sortedEnergies.count > 8 {
                let otherEnergy = sortedEnergies[8...].reduce(0, +)
                otherShare = Double(otherEnergy) / totalD
            }
        }

        return [sysPower] + shares + [otherShare]
    }

    public static func makeFeatures(
        systemPower: Double,
        appShares: [Double],
        otherShare: Double
    ) -> [Double] {
        var shares = Array(repeating: 0.0, count: 8)
        for i in 0..<min(8, appShares.count) {
            shares[i] = appShares[i]
        }
        return [systemPower] + shares + [otherShare]
    }

    public static func remainingEnergyWh(from battery: BatteryState) -> Double? {
        if let raw = battery.rawCurrentCapacity_mAh, raw > 0, battery.voltage_mV > 0 {
            return (Double(raw) * Double(battery.voltage_mV)) / 1_000_000.0
        }
        if let fcc = battery.fullChargeCapacity_mAh, fcc > 0, battery.voltage_mV > 0 {
            let currentMah = Double(fcc) * (Double(battery.percent) / 100.0)
            return (currentMah * Double(battery.voltage_mV)) / 1_000_000.0
        }
        return nil
    }

    // MARK: - Observation

    public func observe(_ tick: SampleTick) {
        let features = Self.extractFeatures(from: tick)
        state.lastFeatures = features
        state.lastBatteryState = tick.battery

        guard tick.battery.source == .battery, !tick.battery.isCharging else {
            return
        }

        let volts = Double(tick.battery.voltage_mV) / 1000.0
        let amps = Double(abs(tick.battery.amperage_mA)) / 1000.0
        let dischargeRateW = volts * amps

        guard dischargeRateW > 0.001 else { return }

        let dur = tick.interval.components
        let dt = max(0.001, Double(dur.seconds) + Double(dur.attoseconds) / 1e18)
        state.totalBatteryTimeSeconds += dt
        state.totalBatteryEnergyJoules += dischargeRateW * dt
        if state.totalBatteryTimeSeconds > 0 {
            state.pRef = state.totalBatteryEnergyJoules / state.totalBatteryTimeSeconds
        }

        updateRLS(features: features, targetW: dischargeRateW)
    }

    public func observe(
        systemPower: Double,
        appShares: [Double],
        otherShare: Double,
        dischargeRate: Double,
        battery: BatteryState? = nil
    ) {
        let features = Self.makeFeatures(systemPower: systemPower, appShares: appShares, otherShare: otherShare)
        state.lastFeatures = features
        if let battery = battery {
            state.lastBatteryState = battery
        }

        guard dischargeRate > 0.001 else { return }

        state.totalBatteryTimeSeconds += 1.0
        state.totalBatteryEnergyJoules += dischargeRate * 1.0
        state.pRef = state.totalBatteryEnergyJoules / state.totalBatteryTimeSeconds

        updateRLS(features: features, targetW: dischargeRate)
    }

    // MARK: - Recursive Least Squares Update

    private func updateRLS(features x: [Double], targetW y: Double) {
        precondition(x.count == 10)
        let d = 10
        let lambda = state.lambda

        // 1. A priori prediction: y_hat = x^T * theta
        var yHat = 0.0
        for j in 0..<d {
            yHat += x[j] * state.weights[j]
        }
        let alpha = y - yHat

        // 2. v = P * x
        var v = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            var sum = 0.0
            let rowOffset = i * d
            for j in 0..<d {
                sum += state.covariance[rowOffset + j] * x[j]
            }
            v[i] = sum
        }

        // 3. gamma = lambda + x^T * v
        var xTv = 0.0
        for i in 0..<d {
            xTv += x[i] * v[i]
        }
        let gamma = lambda + xTv

        guard gamma > 1e-12 else { return }

        // 4. Kalman gain k = v / gamma
        var k = Array(repeating: 0.0, count: d)
        for i in 0..<d {
            k[i] = v[i] / gamma
        }

        // 5. Update weights: theta = theta + k * alpha
        for i in 0..<d {
            state.weights[i] += k[i] * alpha
        }

        // 6. Update covariance: P = (P - k * v^T) / lambda
        var newP = Array(repeating: 0.0, count: d * d)
        let invLambda = 1.0 / lambda
        for i in 0..<d {
            let rowOffset = i * d
            let ki = k[i]
            for j in 0..<d {
                let pVal = (state.covariance[rowOffset + j] - ki * v[j]) * invLambda
                newP[rowOffset + j] = pVal
            }
        }

        // Symmetrize and bound to prevent numerical drift or blow-up
        for i in 0..<d {
            for j in 0..<d {
                var sym = (newP[i * d + j] + newP[j * d + i]) * 0.5
                if i == j && sym > 1e6 {
                    sym = 1e6
                }
                state.covariance[i * d + j] = sym
            }
        }

        // 7. A posteriori residual
        var yPost = 0.0
        for j in 0..<d {
            yPost += x[j] * state.weights[j]
        }
        let e = y - yPost

        // 8. Update residual variance
        state.sampleCount += 1
        let e2 = e * e
        if state.sampleCount == 1 {
            state.residualVariance = max(1e-4, e2)
        } else {
            let updatedVar = lambda * state.residualVariance + (1.0 - lambda) * e2
            state.residualVariance = max(1e-4, updatedVar)
        }
    }

    // MARK: - Prediction

    public func forecast() -> BatteryForecast? {
        guard let battery = state.lastBatteryState else { return nil }
        let features = state.lastFeatures ?? Array(repeating: 0.0, count: 10)
        return forecast(with: battery, features: features)
    }

    public func forecast(with tick: SampleTick) -> BatteryForecast? {
        let features = Self.extractFeatures(from: tick)
        return forecast(with: tick.battery, features: features)
    }

    public func forecast(
        with battery: BatteryState,
        systemPower: Double? = nil,
        appShares: [Double]? = nil,
        otherShare: Double? = nil
    ) -> BatteryForecast? {
        let features: [Double]
        if let sp = systemPower, let apps = appShares, let other = otherShare {
            features = Self.makeFeatures(systemPower: sp, appShares: apps, otherShare: other)
        } else if let last = state.lastFeatures {
            features = last
        } else {
            features = Array(repeating: 0.0, count: 10)
        }
        return forecast(with: battery, features: features)
    }

    private func forecast(with battery: BatteryState, features: [Double]) -> BatteryForecast? {
        guard let remainingWh = Self.remainingEnergyWh(from: battery), remainingWh > 0 else {
            return nil
        }

        let isFallback = state.sampleCount < 30
        let predictedW: Double

        if isFallback {
            predictedW = max(state.pRef, 0.1)
        } else {
            var rawPred = 0.0
            for j in 0..<min(features.count, state.weights.count) {
                rawPred += features[j] * state.weights[j]
            }
            if rawPred > 0.1 {
                predictedW = rawPred
            } else {
                predictedW = max(state.pRef, 0.1)
            }
        }

        // Confidence band from residual variance
        var xPx = 0.0
        let d = 10
        for i in 0..<d {
            var sum = 0.0
            for j in 0..<d {
                sum += state.covariance[i * d + j] * features[j]
            }
            xPx += features[i] * sum
        }
        let predVar = state.residualVariance * (1.0 + max(0.0, xPx))
        let sigmaW = sqrt(max(1e-4, predVar))

        let wUpper = predictedW + 1.96 * sigmaW
        let wLower = max(0.1, predictedW - 1.96 * sigmaW)

        let remainingMinutes = (remainingWh / predictedW) * 60.0
        let lowerMinutes = (remainingWh / wUpper) * 60.0
        let upperMinutes = (remainingWh / wLower) * 60.0

        return BatteryForecast(
            remainingMinutes: remainingMinutes,
            lowerMinutes: lowerMinutes,
            upperMinutes: upperMinutes,
            predictedWatts: predictedW,
            residualVariance: state.residualVariance,
            sampleCount: state.sampleCount,
            isFallback: isFallback
        )
    }
}
