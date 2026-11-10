import SwiftUI

struct TranscriptionPane: View {
    let env: AppEnvironment
    var body: some View {
        Form {
            Section {
                modelRow
            } header: {
                Text("モデル")
            } footer: {
                Text("書き起こしは Mac の中で行い、音声は外に送りません。")
            }
        }
        .formStyle(.grouped)
    }
    private var modelRow: some View {
        Group {
            LabeledContent("モデル", value: env.modelVariant).textSelection(.enabled)
            if env.modelVariantOverridden {
                Text("検証用のモデルに上書きされています（IR_MODEL_VARIANT）。通常のモデル設定は変更していません")
                    .font(.caption).foregroundStyle(.orange)
            }
            switch env.transcription.model {
            case .notInstalled:
                LabeledContent("状態") {
                    Text("未インストール。録音は可能です").foregroundStyle(.secondary)
                    Spacer()
                    Button("ダウンロード") { Task { await env.transcription.installModel() } }
                        .disabled(env.recorder.phase.isCapturing || env.termination.requested)
                }
            case .downloading(let fraction):
                ProgressView("モデルをダウンロード中 \(Int(fraction * 100))%", value: fraction)
            case .optimizing:
                ProgressView("初回の最適化をしています。しばらくお待ちください")
            case .ready:
                LabeledContent("状態", value: "インストール済み")
            case .failed(let message):
                LabeledContent("状態") {
                    Text("導入できませんでした: \(message)").foregroundStyle(.red)
                    Spacer()
                    Button("再試行") { Task { await env.transcription.installModel() } }
                        .disabled(env.recorder.phase.isCapturing || env.termination.requested)
                }
            }
        }
    }

}
