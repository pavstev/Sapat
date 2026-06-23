import AppKit
import SwiftUI

/// In-popover searchable history of past translations (JSON-backed HistoryStore).
struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @State private var search = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search translations", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var filtered: [TranslationRecord] {
        guard !search.isEmpty else { return store.records }
        return store.records.filter {
            $0.english.localizedCaseInsensitiveContains(search) ||
            $0.serbian.localizedCaseInsensitiveContains(search)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(store.records.isEmpty ? "No translations yet" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func row(_ item: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.english)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.serbian.isEmpty {
                Text(item.serbian)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(item.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { copy(item.english) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("Copy English")
                Button { store.delete(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.small).help("Delete")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
