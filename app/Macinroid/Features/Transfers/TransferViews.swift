import SwiftUI

/// The progress of the running transfer, shown along the bottom of the window.
struct TransferBar: View {
    @Environment(AppModel.self) private var app
    @State private var showsHint = false

    var body: some View {
        if let job = app.transfers.active {
            HStack(alignment: .center, spacing: 14) {
                (job.direction == .upload ? Symbol.upload : Symbol.download).image
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.title)
                            .font(.headline)
                        if !app.transfers.waiting.isEmpty {
                            Text("\(app.transfers.waiting.count) more waiting")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(trailingDetail(job))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    progressBar(job)

                    Text(detail(job))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    showsHint.toggle()
                } label: {
                    Symbol.help.image
                }
                .buttonStyle(.borderless)
                .help("If a transfer stalls")
                .popover(isPresented: $showsHint, arrowEdge: .top) {
                    Text("If the progress stops for a long time, cancel the transfer, reconnect the cable and try again. Keep the phone unlocked while files are being copied.")
                        .frame(width: 260)
                        .padding()
                }

                Button {
                    app.transfers.cancel(job.id)
                } label: {
                    Symbol.stop.image
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .disabled(job.phase == .cancelling)
                .help("Cancel the transfer")
                .accessibilityLabel("Cancel Transfer")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .floatingPanel(cornerRadius: 18)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func progressBar(_ job: TransferJob) -> some View {
        switch job.phase {
        case .copying:
            // overall progress when the total is known, the current file's otherwise
            ProgressView(value: job.progress.fraction ?? job.progress.fileFraction)
                .animation(.linear(duration: 0.15), value: job.progress.bytesDone)
        default:
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private func detail(_ job: TransferJob) -> String {
        switch job.phase {
        case .waiting, .preparing:
            return "Checking for items that already exist…"
        case .counting:
            return job.countedFiles > 0
                ? "Found \(Format.items(job.countedFiles)) so far (\(Format.bytes(job.countedBytes)))"
                : "Counting items…"
        case .copying:
            return "\(job.itemsSummary) · \(job.progress.currentName)"
        case .cancelling:
            return "Stopping after the current step…"
        case .finished, .cancelled, .failed:
            return job.itemsSummary
        }
    }

    private func trailingDetail(_ job: TransferJob) -> String {
        guard job.phase == .copying else { return "" }
        var parts = [job.bytesSummary]
        if job.speed > 0 { parts.append(Format.rate(job.speed)) }
        if let remaining = job.remaining { parts.append("\(Format.remaining(remaining)) left") }
        return parts.joined(separator: " · ")
    }
}

/// The running, waiting and recent transfers, in a popover of the toolbar.
struct TransfersPopover: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let transfers = app.transfers
        let jobs = [transfers.active].compactMap { $0 } + transfers.waiting + transfers.recent

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Button("Clear") { transfers.clearRecent() }
                    .disabled(transfers.recent.isEmpty)
            }
            .padding(12)

            Divider()

            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers", symbol: .transfers)
                } description: {
                    Text("Files you copy between your Mac and your phone appear here.")
                }
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobs) { job in
                            row(job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 360)
    }

    private func row(_ job: TransferJob) -> some View {
        HStack(spacing: 10) {
            statusIcon(job)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .lineLimit(1)
                Text(subtitle(job))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !job.phase.isOver {
                Button {
                    app.transfers.cancel(job.id)
                } label: {
                    Symbol.stop.image
                }
                .buttonStyle(.borderless)
                .disabled(job.phase == .cancelling)
                .help("Cancel")
            } else if job.direction == .download, job.phase == .finished {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: job.request.destination, isDirectory: true))
                } label: {
                    Symbol.search.image
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusIcon(_ job: TransferJob) -> some View {
        switch job.phase {
        case .finished:
            Symbol.success.image.foregroundStyle(.green)
        case .failed:
            Symbol.failure.image.foregroundStyle(.orange)
        case .cancelled:
            Symbol.cancelled.image.foregroundStyle(.secondary)
        case .waiting:
            Symbol.waiting.image.foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func subtitle(_ job: TransferJob) -> String {
        switch job.phase {
        case .waiting:
            return Format.items(job.request.sources.count)
        case .failed(let error):
            return "\(error.title). \(error.suggestion)"
        case .finished, .cancelled:
            return "\(job.itemsSummary) · \(Format.bytes(job.progress.bytesDone)) · \(Format.elapsed(job.elapsed))"
        default:
            return "\(job.itemsSummary) · \(job.bytesSummary)"
        }
    }
}
