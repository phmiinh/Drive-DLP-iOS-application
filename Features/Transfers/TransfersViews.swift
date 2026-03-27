import SwiftUI

struct TransfersView: View {
    @ObservedObject var queueService: TransferQueueService

    var body: some View {
        Group {
            if queueService.records.isEmpty {
                EmptyStateCard(
                    title: "No Transfers",
                    message: "Upload and download requests queued from the browser will appear here.",
                    systemImage: "tray"
                )
            } else {
                List(queueService.records) { record in
                    TransferRowView(record: record, queueService: queueService)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Clear Finished") {
                    Task {
                        await queueService.clearCompleted()
                    }
                }

                Button {
                    Task {
                        await queueService.reload()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            await queueService.reload()
        }
    }
}

private struct TransferRowView: View {
    let record: TransferRecord
    @ObservedObject var queueService: TransferQueueService

    @State private var previewURL: URL?
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(record.displayName, systemImage: record.kind == .upload ? "square.and.arrow.up" : "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusTint.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusTint)
            }

            HStack {
                Text(record.localURL?.lastPathComponent ?? record.stateID ?? "Pending remote target")
                Spacer()
                Text(formattedDate(record.updatedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let total = record.bytesTotal, total > 0 {
                ProgressView(value: Double(record.bytesTransferred), total: Double(total))
                Text("\(formattedBytes(record.bytesTransferred)) of \(formattedBytes(total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = record.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if canPreviewOrShare || canRetry || canCancel {
                HStack(spacing: 12) {
                    if canPreviewOrShare, let localFileURL {
                        Button("Preview") {
                            previewURL = localFileURL
                        }
                        Button("Share") {
                            shareURL = localFileURL
                        }
                    }

                    if canRetry {
                        Button("Retry") {
                            Task {
                                await queueService.retry(id: record.id)
                            }
                        }
                    }

                    if canCancel {
                        Button("Cancel", role: .destructive) {
                            Task {
                                await queueService.cancel(id: record.id)
                            }
                        }
                    }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
        .sheet(
            isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { previewURL = nil } }
            )
        ) {
            if let previewURL {
                QuickLookPreviewSheet(fileURL: previewURL)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )
        ) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    private var statusTint: Color {
        switch record.status {
        case .queued:
            return .orange
        case .locallyCached:
            return .teal
        case .processing:
            return .blue
        case .paused:
            return .gray
        case .cancelled:
            return .secondary
        case .done:
            return .green
        case .error:
            return .red
        }
    }

    private var statusLabel: String {
        switch record.status {
        case .locallyCached:
            return "Cached"
        default:
            return record.status.rawValue.capitalized
        }
    }

    private var localFileURL: URL? {
        guard record.kind == .download,
              let localURL = record.localURL,
              FileManager.default.fileExists(atPath: localURL.path) else {
            return nil
        }
        return localURL
    }

    private var canPreviewOrShare: Bool {
        localFileURL != nil && (record.status == .done || record.status == .locallyCached)
    }

    private var canRetry: Bool {
        record.status == .error || record.status == .cancelled
    }

    private var canCancel: Bool {
        record.status == .queued || record.status == .processing
    }
}

