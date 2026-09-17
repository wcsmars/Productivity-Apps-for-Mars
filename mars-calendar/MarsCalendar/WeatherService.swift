import CoreLocation
import SwiftUI

/// Fetches a ~16-day daily forecast for the device's location from Open-Meteo
/// (no API key required) and maps it to `DayWeather` values keyed by start of
/// day. In demo mode it serves a deterministic fake forecast instead — no
/// network or location access — so screenshots stay stable.
@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Forecast keyed by `startOfDay`, ~16 days from today.
    @Published private(set) var byDay: [Date: DayWeather] = [:]

    /// User toggle, persisted. Enabling requests when-in-use location access
    /// and fetches; disabling clears the forecast.
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "weatherEnabled")
            if enabled {
                statusText = nil
                fetch()
            } else {
                byDay = [:]
                statusText = nil
                lastFetch = nil
            }
        }
    }

    /// Why nothing is showing ("Location access needed", fetch failures),
    /// surfaced in Settings. nil when everything is fine.
    @Published private(set) var statusText: String?

    let isDemo: Bool

    private let manager = CLLocationManager()
    private let calendar = Calendar.current
    private let defaults = UserDefaults.standard
    private var lastFetch: Date?

    init(demo: Bool = false) {
        isDemo = demo
        var startEnabled = UserDefaults.standard.bool(forKey: "weatherEnabled")
        #if DEBUG
        // Deterministic weather badges for UI-verification screenshots.
        if demo, CommandLine.arguments.contains("-demoWeather") { startEnabled = true }
        #endif
        enabled = startEnabled
        super.init()
        if !demo { manager.delegate = self }
        if enabled { fetch() }
    }

    // MARK: - Public API

    /// Fetches again when enabled, authorized, and the forecast is over
    /// 30 minutes old (demo mode just reseeds, which also survives day changes).
    func refreshIfStale() {
        guard enabled else { return }
        if isDemo {
            seedDemoForecast()
            return
        }
        guard isAuthorized else { return }
        if let lastFetch, Date.now.timeIntervalSince(lastFetch) < 30 * 60 { return }
        manager.requestLocation()
    }

    /// The forecast for a calendar day, if one is loaded.
    func weather(on day: Date) -> DayWeather? {
        byDay[calendar.startOfDay(for: day)]
    }

    // MARK: - Fetch flow

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    private func fetch() {
        guard enabled else { return }
        if isDemo {
            seedDemoForecast()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            statusText = "Location access needed"
        default:
            manager.requestLocation()
        }
    }

    private func loadForecast(latitude: Double, longitude: Double) {
        guard enabled, !isDemo else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var query = [
            // Round before sending: a 0.01-degree grid is sufficient for a
            // local forecast (about 1.1 km in latitude, finer in longitude).
            URLQueryItem(name: "latitude", value: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "16"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        if Self.prefersFahrenheit {
            query.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
        }
        components.queryItems = query
        guard let url = components.url else { return }
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                self?.apply(response)
            } catch {
                guard let self, self.enabled, self.byDay.isEmpty else { return }
                self.statusText = "Couldn't load the forecast"
            }
        }
    }

    private func apply(_ response: OpenMeteoResponse) {
        guard enabled else { return }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"
        var result: [Date: DayWeather] = [:]
        let daily = response.daily
        for (index, dayString) in daily.time.enumerated() {
            guard index < daily.weatherCode.count,
                  index < daily.temperatureMax.count,
                  index < daily.temperatureMin.count,
                  let parsed = parser.date(from: dayString) else { continue }
            result[calendar.startOfDay(for: parsed)] = DayWeather(
                symbol: Self.symbol(forWMO: daily.weatherCode[index]),
                high: Int(daily.temperatureMax[index].rounded()),
                low: Int(daily.temperatureMin[index].rounded())
            )
        }
        guard !result.isEmpty else {
            if byDay.isEmpty { statusText = "Couldn't load the forecast" }
            return
        }
        byDay = result
        lastFetch = .now
        statusText = nil
    }

    /// True for locales that report weather in Fahrenheit (US and friends).
    private static var prefersFahrenheit: Bool {
        UnitTemperature(forLocale: .current, usage: .weather).symbol
            == UnitTemperature.fahrenheit.symbol
    }

    /// WMO weather interpretation code -> SF Symbol name.
    private static func symbol(forWMO code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 58...67: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80...82: "cloud.heavyrain.fill"
        case 95...: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    // MARK: - Demo forecast

    /// Deterministic fake forecast seeded by each day's ordinal, so the same
    /// date always renders the same symbol and temperatures in screenshots.
    private func seedDemoForecast() {
        let symbols = ["sun.max.fill", "cloud.sun.fill", "cloud.rain.fill"]
        let today = calendar.startOfDay(for: .now)
        var result: [Date: DayWeather] = [:]
        for offset in 0..<16 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? offset
            let high = 24 + (ordinal % 8)
            result[day] = DayWeather(symbol: symbols[ordinal % 3], high: high, low: high - 8)
        }
        byDay = result
        lastFetch = .now
        statusText = nil
    }

    // MARK: - CLLocationManagerDelegate (callbacks can arrive off-main — hop)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(to: status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor in self.loadForecast(latitude: latitude, longitude: longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.enabled, !self.isDemo, self.byDay.isEmpty else { return }
            self.statusText = "Couldn't determine your location"
        }
    }

    private func authorizationChanged(to status: CLAuthorizationStatus) {
        guard enabled, !isDemo else { return }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            statusText = nil
            manager.requestLocation()
        case .denied, .restricted:
            byDay = [:]
            statusText = "Location access needed"
        default:
            break
        }
    }
}

// MARK: - Open-Meteo response

private struct OpenMeteoResponse: Decodable {
    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperatureMax: [Double]
        let temperatureMin: [Double]

        enum CodingKeys: String, CodingKey {
            case time
            case weatherCode = "weather_code"
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
        }
    }

    let daily: Daily
}

// MARK: - Badge

/// Compact forecast badge for day headers: symbol + "28° / 19°".
struct WeatherBadge: View {
    let weather: DayWeather

    init(weather: DayWeather) {
        self.weather = weather
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: weather.symbol)
                .font(.caption)
                .foregroundStyle(Theme.rose)
            Text("\(weather.high)° / \(weather.low)°")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
