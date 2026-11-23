import SwiftUI

// Apple Music Replay: a year's most played artists, songs and albums with their play
// counts, the year's Replay playlist, and the milestones reached, as music.apple.com/replay shows them.
struct ReplayPage: View {
    @Environment(PlayerStore.self) private var store
    @State private var years: [ReplayYear]?
    @State private var selected: ReplayYear?

    var body: some View {
        Page(id: "replay") {
            HStack(alignment: .bottom, spacing: 16) {
                PageTitle(title: "Replay", subtitle: "Apple Music")
                Spacer(minLength: 0)
                if let years, years.count > 1 {
                    yearPicker(years).padding(.trailing, Layout.gutter).padding(.bottom, 6)
                }
            }
            if let selected {
                Loading(load: { _ in await store.catalog.replay(selected) }, isEmpty: \.isEmpty) { summary in
                    ReplayYearView(year: selected, summary: summary)
                }
                .id(selected.id)
            } else if years == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 320)
            } else {
                Text("No Replay yet. Apple starts one once you've listened for a while this year.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .task {
            guard years == nil else { return }
            let found = await store.catalog.replayYears()
            years = found
            selected = found.first
        }
    }

    private func yearPicker(_ years: [ReplayYear]) -> some View {
        HStack(spacing: 4) {
            ForEach(years) { year in
                let isOn = year == selected
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selected = year }
                } label: {
                    Text(String(year.year))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(isOn ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isOn ? .white : .white.opacity(0.08), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.pointer)
            }
        }
    }
}

private struct ReplayYearView: View {
    let year: ReplayYear
    let summary: ReplaySummary

    @Environment(PlayerStore.self) private var store
    @State private var showsAllSongs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            header
            if !summary.months.isEmpty { months }
            if !summary.artists.isEmpty { artists }
            if !summary.songs.isEmpty { songs }
            if !summary.albums.isEmpty { albums }
        }
    }

    // The year's playlist beside its numbers. Until the year ends Apple only has the
    // milestones, so those stand in for the totals.
    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            if let playlist = year.playlist {
                ItemTile(item: playlist, size: 200)
            }
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(stats, id: \.label) { stat in
                        ReplayStat(value: stat.value, label: stat.label)
                    }
                }
                if let playlist = year.playlist {
                    HStack(spacing: 10) {
                        pill("Play", "play.fill") { store.play(playlist) }
                        pill("Shuffle", "shuffle") { store.play(playlist, shuffle: true) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Layout.gutter)
    }

    private var stats: [(value: String, label: String)] {
        var stats: [(String, String)] = []
        if let minutes = year.minutes {
            stats.append((minutes.formatted(), "Minutes"))
        } else if let last = summary.months.last {
            // Exact to the end of the last finished month.
            stats.append((summary.months.map(\.minutes).reduce(0, +).formatted(), "Minutes through \(last.name)"))
        } else if let minutes = summary.best("listen-time") {
            stats.append((minutes.formatted() + "+", "Minutes"))
        }
        if let songs = year.songCount { stats.append((songs.formatted(), "Songs")) }
        else if let songs = summary.best("song") { stats.append((songs.formatted() + "+", "Songs")) }
        if let artists = year.artistCount { stats.append((artists.formatted(), "Artists")) }
        else if let artists = summary.best("artist") { stats.append((artists.formatted() + "+", "Artists")) }
        if let albums = year.albumCount { stats.append((albums.formatted(), "Albums")) }
        if let genres = year.genreCount { stats.append((genres.formatted(), "Genres")) }
        if let top = summary.artists.first?.minutes {
            stats.append((top.formatted(), "Minutes with \(summary.artists.first!.item.title)"))
        }
        return stats
    }

    // Minutes each month as bars, with that month's song and artist counts beneath.
    private var months: some View {
        let most = max(summary.months.map(\.minutes).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "By Month")
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(summary.months) { month in
                    VStack(spacing: 6) {
                        Text(month.minutes.formatted())
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(month.minutes == most ? 0.9 : 0.35))
                            .frame(height: max(4, 140 * CGFloat(month.minutes) / CGFloat(most)))
                        Text(String(month.name.prefix(3)))
                            .font(.system(size: 11, weight: .bold))
                        Text("\(month.songs.formatted()) songs")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(month.name): \(month.minutes.formatted()) minutes, \(month.songs.formatted()) songs, \(month.artists.formatted()) artists")
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, Layout.gutter)
        }
    }

    private var artists: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Top Artists")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(Array(summary.artists.enumerated()), id: \.offset) { index, entry in
                        VStack(spacing: 4) {
                            ItemTile(item: entry.item, size: 150)
                            Text(caption(index, entry))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, Layout.gutter)
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
        }
    }

    private var songs: some View {
        let shown = showsAllSongs ? summary.songs : Array(summary.songs.prefix(20))
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Top Songs")
            LazyVStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                    ReplaySongRow(entry: entry, rank: index + 1) {
                        store.play(summary.songs.map(\.item), at: index, in: nil)
                    }
                }
            }
            .padding(.horizontal, Layout.gutter - 12)
            if summary.songs.count > 20 {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { showsAllSongs.toggle() }
                } label: {
                    Text(showsAllSongs ? "Show Less" : "Show All \(summary.songs.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(.white.opacity(0.08), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.pointer)
                .padding(.horizontal, Layout.gutter)
            }
        }
    }

    private var albums: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Top Albums")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(Array(summary.albums.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            ItemTile(item: entry.item, size: 170)
                            Text(caption(index, entry))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, Layout.gutter)
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
        }
    }

    private func caption(_ index: Int, _ entry: ReplayEntry) -> String {
        var parts = ["#\(index + 1)", "\(entry.plays.formatted()) plays"]
        if let minutes = entry.minutes { parts.append("\(minutes.formatted()) min") }
        return parts.joined(separator: " · ")
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(.white.opacity(0.1), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.pointer)
    }
}

private struct ReplayStat: View {
    let value: String
    let label: String

    @Environment(\.layoutStyle) private var layoutStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .heavy).monospacedDigit())
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if layoutStyle == .studio {
                Color.clear.studioPanel(cornerRadius: 12)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07))
            }
        }
    }
}

// Rank, cover, song and how often it was played.
private struct ReplaySongRow: View {
    let entry: ReplayEntry
    let rank: Int
    let play: () -> Void

    @Environment(PlayerStore.self) private var store
    @Environment(\.songTheme) private var theme
    @State private var isHovered = false

    private var isCurrent: Bool { store.isCurrent(entry.item) }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 28, alignment: .trailing)
            Artwork(item: entry.item, size: 40, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.item.title).lineLimit(1)
                    if entry.item.isExplicit { ExplicitBadge() }
                }
                .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                .foregroundStyle(isCurrent ? theme.accent : .white)
                Text(entry.item.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoreButton(item: entry.item)
                .opacity(isHovered ? 1 : 0)
            Text("\(entry.plays.formatted()) plays")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isCurrent ? 0.1 : isHovered ? 0.06 : 0))
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .clickable()
        .onTapGesture(perform: play)
        .itemMenu(entry.item)
    }
}
