#if os(iOS)
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var state: SignAppState
    @State private var adding = false
    @State private var newURL = ""
    @State private var search = ""
    @State private var filter: UUID?

    var allApps: [RepoApp] {
        let apps = state.sources.filter { filter == nil || $0.id == filter }.flatMap { $0.apps }
        if search.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) || $0.developer.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(nil, title: L("All"))
                            ForEach(state.sources) { s in chip(s.id, title: s.name) }
                        }
                        .padding(.vertical, 4)
                    }
                    if state.sources.isEmpty {
                        EmptyState(title: L("No sources"), subtitle: L("Add an AltStore, SideStore, Feather or ESign repository URL to browse apps."))
                    } else if allApps.isEmpty {
                        EmptyState(title: L("Nothing found"), subtitle: L("Try another search or refresh your sources."))
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(allApps) { app in
                            NavigationLink(destination: RepoAppDetail(app: app)) {
                                RepoAppRow(app: app)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L("Sources"))
            .searchable(text: $search, prompt: L("Search apps"))
            .refreshable { await state.refreshSources() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus.circle.fill").font(.title2).symbolRenderingMode(.hierarchical) }.nvdBorderBeam(shape: .rounded(10))
                }
            }
            .alert(L("Add source"), isPresented: $adding) {
                TextField("https://example.com/repo.json", text: $newURL)
                Button(L("Cancel"), role: .cancel) { newURL = "" }
                Button(L("Add")) {
                    let u = newURL
                    newURL = ""
                    Task { await state.addSource(u) }
                }
            } message: {
                Text(L("Paste a repository link"))
            }
        }
        .navigationViewStyle(.stack)
    }

    func chip(_ id: UUID?, title: String) -> some View {
        let on = filter == id
        return Button { filter = id } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(on ? AnyShapeStyle(SignTheme.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
                .foregroundColor(on ? .white : .primary)
        }
        .buttonStyle(.plain)
        .nvdBorderBeam(shape: .capsule)
        .contextMenu {
            if let id = id, let s = state.sources.first(where: { $0.id == id }) {
                Button { UIPasteboard.general.string = s.url } label: { Label(L("Copy link"), systemImage: "doc.on.doc") }
                Button(role: .destructive) { state.removeSource(s); filter = nil } label: { Label(L("Remove"), systemImage: "trash") }
            }
        }
    }
}

struct RepoAppRow: View {
    @EnvironmentObject var state: SignAppState
    let app: RepoApp
    var body: some View {
        Card {
            HStack(spacing: 12) {
                AppIconView(image: nil, url: app.iconURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text(app.subtitle.isEmpty ? app.developer : app.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if !app.version.isEmpty { Pill(text: "v" + app.version) }
                        if app.size > 0 { Pill(text: formatSize(app.size), color: .secondary) }
                    }
                }
                Spacer(minLength: 6)
                Button(L("Get")) {
                    if let u = URL(string: app.downloadURL) {
                        Task { await state.download(u, name: app.name) }
                        state.show(LF("Downloading %@", app.name))
                    }
                }
                .buttonStyle(SmallButtonStyle())
                .nvdBorderBeam(shape: .rounded(9))
            }
        }
    }
}

struct RepoAppDetail: View {
    @EnvironmentObject var state: SignAppState
    let app: RepoApp
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    AppIconView(image: nil, url: app.iconURL, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.title2.weight(.bold))
                        Text(app.developer).foregroundColor(.secondary)
                        Button(L("Get")) {
                            if let u = URL(string: app.downloadURL) {
                                Task { await state.download(u, name: app.name) }
                                state.tab = 0
                            }
                        }
                        .buttonStyle(SmallButtonStyle())
                        .nvdBorderBeam(shape: .rounded(9))
                    }
                }
                HStack(spacing: 8) {
                    if !app.version.isEmpty { Pill(text: "v" + app.version) }
                    if app.size > 0 { Pill(text: formatSize(app.size), color: .secondary) }
                    if !app.bundleID.isEmpty { Pill(text: app.bundleID, color: .secondary) }
                }
                if !app.screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.screenshots, id: \.self) { s in
                                AsyncImage(url: URL(string: s)) { p in
                                    if let i = p.image { i.resizable().scaledToFit() } else { Color(.secondarySystemFill) }
                                }
                                .frame(height: 380)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                }
                if !app.description.isEmpty {
                    Text(app.description).font(.body)
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
