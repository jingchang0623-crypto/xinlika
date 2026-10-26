import Foundation

struct AppConfig: Equatable {
    var apiBase: String
    var supabaseURL: String
    var supabaseAnonKey: String

    var isComplete: Bool {
        validHTTPS(apiBase) && validHTTPS(supabaseURL)
            && !supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load() -> AppConfig {
        let defaults = UserDefaults.standard
        func value(_ defaultsKey: String, _ plistKey: String) -> String {
            if let saved = defaults.string(forKey: defaultsKey), !saved.isEmpty { return saved }
            return Bundle.main.object(forInfoDictionaryKey: plistKey) as? String ?? ""
        }
        return AppConfig(
            apiBase: value("config.apiBase", "ShennaoAPIBase"),
            supabaseURL: value("config.supabaseURL", "ShennaoSupabaseURL"),
            supabaseAnonKey: value("config.supabaseAnonKey", "ShennaoSupabaseAnonKey")
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiBase.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "config.apiBase")
        defaults.set(supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "config.supabaseURL")
        defaults.set(supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "config.supabaseAnonKey")
    }

    var deepBrain: DeepBrainConfig {
        DeepBrainConfig(
            apiBase: apiBase.trimmingCharacters(in: .whitespacesAndNewlines),
            supabaseUrl: supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            supabaseAnonKey: supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func validHTTPS(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme == "https" && url.host != nil
    }
}
