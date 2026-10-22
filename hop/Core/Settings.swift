import Foundation
import Observation

struct SettingsData: Codable, Equatable {
    var sensitivity: Sensitivity = .high
    var popToRootSeconds: Int = 90
    var hyperKeyEnabled = false
    var wireguardShowFlag = true
    var keepass = KeePassSettings()

    struct KeePassSettings: Codable, Equatable {
        var databasePath: String = ""
        var keyFilePath: String = ""
        var passwordless = false
        var rememberPassword = true
        /// Minutes of inactivity before locking; -1 never.
        var lockAfterMinutes = 10
        var cliPathOverride: String = ""
    }

    init() {}

    // Tolerate files written by older versions with missing keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsData()
        sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? d.sensitivity
        popToRootSeconds = try c.decodeIfPresent(Int.self, forKey: .popToRootSeconds) ?? d.popToRootSeconds
        hyperKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hyperKeyEnabled) ?? d.hyperKeyEnabled
        wireguardShowFlag = try c.decodeIfPresent(Bool.self, forKey: .wireguardShowFlag) ?? d.wireguardShowFlag
        keepass = try c.decodeIfPresent(KeePassSettings.self, forKey: .keepass) ?? d.keepass
    }
}

extension SettingsData.KeePassSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        databasePath = try c.decodeIfPresent(String.self, forKey: .databasePath) ?? d.databasePath
        keyFilePath = try c.decodeIfPresent(String.self, forKey: .keyFilePath) ?? d.keyFilePath
        passwordless = try c.decodeIfPresent(Bool.self, forKey: .passwordless) ?? d.passwordless
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? d.rememberPassword
        lockAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .lockAfterMinutes) ?? d.lockAfterMinutes
        cliPathOverride = try c.decodeIfPresent(String.self, forKey: .cliPathOverride) ?? d.cliPathOverride
    }
}

/// App settings, persisted to `settings.json` on every change.
@Observable
final class AppSettings {
    var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            store.save(data)
            onChange?(oldValue, data)
        }
    }

    @ObservationIgnored var onChange: ((SettingsData, SettingsData) -> Void)?
    @ObservationIgnored private let store: JSONStore<SettingsData>

    init(store: JSONStore<SettingsData> = JSONStore(url: AppPaths.file("settings.json"))) {
        self.store = store
        data = store.load() ?? SettingsData()
    }
}
