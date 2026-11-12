import SwiftUI

struct TranscriptionPane: View {
    let env: AppEnvironment
    var body: some View {
        SettingsPage("文字起こし", description: "音声を外部に送らず、このMacで文字にします。") {
            SettingsSection("文字起こしモデル") {
                SettingsRow("Whisper large-v3-turbo", description: "日本語の会話に使用するモデルです。") { modelStatus }
                if env.modelVariantOverridden {
                    SettingsDivider()
                    SettingsRow("検証用のモデル", description: "\(env.modelVariant)（IR_MODEL_VARIANT）。通常のモデル設定は変更していません") { EmptyView() }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("録音を止めると、保存に続いて文字起こしが始まります。").kikimimiText(.body)
                Text("ほかの録音中は待機し、録音が終わると再開します。").kikimimiText(.body)
            }.foregroundStyle(KikimimiColor.secondary)
        }
    }
    @ViewBuilder private var modelStatus: some View {
        switch env.transcription.model {
        case .ready: SettingsStatus(text: "準備完了")
        case .notInstalled:
            VStack(alignment: .trailing, spacing: 8) {
                Text("未ダウンロード").kikimimiText(.small).foregroundStyle(KikimimiColor.secondary)
                installButton("ダウンロード")
            }
        case .downloading(let fraction): ProgressView("モデルをダウンロード中 \(Int(fraction * 100))%", value: fraction).frame(maxWidth: 240)
        case .optimizing: ProgressView("初回の最適化をしています。しばらくお待ちください")
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 8) {
                Text("ダウンロードできませんでした: \(message)").kikimimiText(.small).foregroundStyle(KikimimiColor.danger)
                installButton("再試行")
            }
        }
    }
    private func installButton(_ title: String) -> some View {
        Button(title) { Task { await env.transcription.installModel() } }
            .disabled(env.recorder.phase.isCapturing || env.termination.requested)
    }
}
