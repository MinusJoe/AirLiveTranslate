import Foundation
import Security

enum WearerVoiceprint {
    // Version the key with the embedding space. A different extractor requires re-enrollment.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AirLive.WearerVoiceprint",
         kSecAttrAccount as String: "wespeaker256-v1"]
    }

    static func read() throws -> [[Float]] {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data,
              let vectors = try? JSONDecoder().decode([[Float]].self, from: data),
              (1...3).contains(vectors.count) else {
            throw PipelineError.message("无法读取本机声纹。请解锁手机，或删除后重新登记。")
        }
        let normalized = vectors.compactMap(VoiceGallery.unit)
        guard normalized.count == vectors.count else { throw PipelineError.message("声纹数据有误，请重新登记。") }
        return normalized
    }

    static func save(_ vector: [Float], additional: Bool) throws {
        guard let normalized = VoiceGallery.unit(vector) else { throw PipelineError.message("声纹样本无效。") }
        var samples = additional ? try read() : []
        guard samples.count < 3 else { throw PipelineError.message("已保存三段声纹。如需替换，请重新登记。") }
        if additional {
            guard (samples.map { VoiceGallery.similarity(normalized, $0) }.max() ?? -1) >= 0.36 else {
                throw PipelineError.message("补录和已有声纹差异较大，请独自说一遍。已有声纹已保留。")
            }
        }
        samples.append(normalized)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(samples),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw PipelineError.message("无法在这台手机保存声纹。") }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PipelineError.message("删除声纹失败，请解锁后重试。") }
    }
}
