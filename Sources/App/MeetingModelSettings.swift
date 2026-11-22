import Security
import SwiftUI

enum SummaryProvider: String, CaseIterable { case apple = "Apple 智能", custom = "自定义服务" }

enum MeetingKeychain {
    private static func query(_ address: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AirLiveTranslate.MeetingAI",
         kSecAttrAccount as String: address.absoluteString]
    }

    static func read(_ address: URL) throws -> String {
        var query = Self.query(address)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8)
        else { throw PipelineError.message("无法读取此服务的钥匙串凭据。请解锁设备后重试。") }
        return key
    }

    static func write(_ key: String, to address: URL) throws {
        var query = Self.query(address)
        let bytes = Data(key.utf8)
        let update = [kSecValueData as String: bytes] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = bytes
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PipelineError.message("API Key 未能保存到钥匙串。") }
    }

    static func remove(_ address: URL) throws {
        let status = SecItemDelete(query(address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PipelineError.message("未能删除此服务的 API Key。") }
    }
}

@MainActor
final class MeetingModelPreferences: ObservableObject {
    @Published private(set) var provider: SummaryProvider
    @Published private(set) var connection: MeetingConnection
    private let defaults = UserDefaults.standard
    init() {
        provider = SummaryProvider(rawValue: UserDefaults.standard.string(forKey: "minutes.provider") ?? "") ?? .apple
        connection = UserDefaults.standard.data(forKey: "minutes.connection")
            .flatMap { try? JSONDecoder().decode(MeetingConnection.self, from: $0) } ?? MeetingConnection()
    }

    func save(_ selected: SummaryProvider, _ config: MeetingConnection, key: String) throws {
        if selected == .custom {
            let address = try config.endpoint()
            guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineError.message("请选择或填写模型 ID。")
            }
            let data = try JSONEncoder().encode(config)
            if !key.isEmpty { try MeetingKeychain.write(key, to: address) }
            defaults.set(data, forKey: "minutes.connection")
            connection = config
        }
        defaults.set(selected.rawValue, forKey: "minutes.provider")
        provider = selected
    }
}

struct MeetingModelSettings: View {
    @EnvironmentObject private var preferences: MeetingModelPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selected = SummaryProvider.apple
    @State private var config = MeetingConnection()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var fetching: UUID?
    @State private var confirmDelete = false
    @State private var loaded = false

    var body: some View {
        List {
            Picker("总结方式", selection: $selected) {
                ForEach(SummaryProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.font(.headline).surfaceRow()
            if selected == .custom {
                Section {
                    TextField("https://example.com/v1", text: $config.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Base URL")
                    SecureField("API Key（留空沿用此地址已存的 Key）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("移除此地址已存的 Key", role: .destructive) { confirmDelete = true }
                        .disabled((try? config.endpoint()) == nil)
                } header: { AudioSectionTitle("Base URL 与凭据") } footer: {
                    Text("填写服务的 HTTPS API 根地址。Key 按地址保存在本机钥匙串。无需鉴权的服务可留空。")
                }
                .surfaceRow()
                Section {
                    Picker("接口", selection: $config.api) {
                        ForEach(MeetingAPI.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("模型 ID", text: $config.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(fetching == nil ? "获取模型列表" : "正在获取…") { fetching = UUID() }
                        .disabled(fetching != nil || (try? config.endpoint()) == nil)
                    if !models.isEmpty {
                        Menu("从 \(models.count) 个模型中选择") {
                            ForEach(models, id: \.self) { id in Button(id) { config.model = id } }
                        }
                    }
                    Picker("推理强度", selection: $config.effort) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { value in
                            Text(value == .automatic ? "服务默认" : value.rawValue).tag(value)
                        }
                    }
                } header: { AudioSectionTitle("模型") }
                .surfaceRow()
            }
            if !status.isEmpty { Text(status).font(.footnote).surfaceRow() }
            Button {
                do {
                    try preferences.save(selected, config, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
                    key = ""
                    dismiss()
                } catch { status = error.localizedDescription }
            } label: { AudioActionLabel(title: "保存设置", symbol: "checkmark") }
            .buttonStyle(.plain).listRowSeparator(.hidden).surfaceRow()
        }
        .audioList()
        .navigationTitle("AI 模型").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            guard !loaded else { return }
            selected = preferences.provider
            config = preferences.connection
            loaded = true
        }
        .onChange(of: config.baseURL) { _, _ in key = ""; models = []; status = ""; fetching = nil }
        .onChange(of: selected) { _, _ in fetching = nil; status = "" }
        .confirmationDialog("删除此地址的 API Key？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除 Key", role: .destructive) {
                do { try MeetingKeychain.remove(config.endpoint()); key = ""; status = "已清除此地址的 Key。" }
                catch { status = error.localizedDescription }
            }
        }
        .task(id: fetching) {
            guard let token = fetching else { return }
            let configuration = config
            do {
                let address = try configuration.endpoint()
                let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = typed.isEmpty ? try MeetingKeychain.read(address) : typed
                let session = CustomMeetingModel.makeSession()
                defer { session.invalidateAndCancel() }
                let listed = try await CustomMeetingModel(connection: configuration, key: secret, session: session).listModels()
                guard !Task.isCancelled, fetching == token else { return }
                models = listed
                status = listed.isEmpty ? "服务未列出模型，可手动填写模型 ID。" : "已获取模型，请选择或手动填写。"
            } catch {
                guard !Task.isCancelled, fetching == token else { return }
                models = []
                status = error.localizedDescription
            }
            fetching = nil
        }
    }
}
