import SwiftUI

struct LogView: View {
    @ObservedObject var logbook: Logbook
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logbook.entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: logbook.entries.count) { _ in
                    if autoScroll, let last = logbook.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: 620, height: 420)
    }

    private var toolbar: some View {
        HStack {
            Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.checkbox)
            Spacer()
            Text("\(logbook.entries.count) lines").font(.caption).foregroundStyle(.secondary)
            Button("Clear") { logbook.clear() }
        }
        .padding(8)
    }

    private func row(_ e: Logbook.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(logbook.timeString(e))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(e.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color(e.level))
                .frame(width: 52, alignment: .leading)
            Text(e.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func color(_ level: Logbook.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .cmd: return .blue
        case .action: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}
