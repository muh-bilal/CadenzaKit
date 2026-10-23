import SwiftUI

/// A replaceable skin over host-supplied state and actions. Empty mode emits no
/// chrome, padding, background or controls. It does not stop or replace playback.
@MainActor
public struct CadenzaPlayerView: View {
    public var context: PlayerContext
    public var components: PlayerComponents
    public var layout: PlayerLayout
    public var arrangement: PlayerArrangement
    @State private var scrub = PlayerScrub()
    @Environment(\.colorScheme) private var scheme
    public init(context: PlayerContext, components: PlayerComponents = .init(), layout: PlayerLayout = .standard, arrangement: PlayerArrangement = .automatic) {
        self.context = context; self.components = components; self.layout = layout; self.arrangement = arrangement
    }
    private var metrics: PlayerMetrics { context.appearance.metrics }
    private var colors: PlayerColors { context.appearance.colors(for: scheme) }

    public var body: some View {
        if layout == .empty {
            EmptyView()
        } else if let replacement = components.layout {
            replacement(context)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    if arrangement == .horizontal || (arrangement == .automatic && geometry.size.width >= metrics.wideBreakpoint) {
                        VStack(spacing: metrics.spacing) {
                            part(.header)
                            HStack(spacing: metrics.spacing) {
                                part(.artwork).frame(maxWidth: metrics.wideArtworkWidth)
                                VStack(alignment: .leading, spacing: metrics.spacing) {
                                    part(.metadata); part(.transport); part(.accessories); part(.footer)
                                }.frame(maxWidth: metrics.wideContentWidth)
                            }
                            #if os(tvOS)
                            .frame(maxWidth: .infinity).focusSection()
                            #endif
                            part(.progress)
                        }.padding(metrics.padding)
                    } else {
                        VStack(spacing: metrics.spacing) {
                            part(.header); part(.artwork); part(.metadata); part(.progress)
                            part(.transport); part(.accessories); part(.footer)
                        }.padding(metrics.padding).frame(maxWidth: metrics.maximumWidth)
                            .frame(maxWidth: .infinity)
                    }
                }.background { part(.background) }
            }
            .foregroundStyle(colors.foreground)
            .tint(colors.accent)
        }
    }

    @ViewBuilder private func part(_ part: PlayerPart) -> some View {
        if let replacement = components.parts[part] { replacement(context) }
        else {
            #if os(tvOS)
            standard(part).focusSection()
            #else
            standard(part)
            #endif
        }
    }

    @ViewBuilder private func standard(_ part: PlayerPart) -> some View {
        switch part {
        case .background: colors.background
        case .header:
            HStack {
                optional(.back, icon: .back, text: .back)
                Spacer(minLength: metrics.detailSpacing)
                Text(context.state.context.isEmpty ? context.strings.resolve(.nowPlaying) : context.state.context)
                    .font(context.appearance.fonts.context).tracking(metrics.contextTracking)
                Spacer(minLength: metrics.detailSpacing)
                optional(.more, icon: .more, text: .more)
            }
        case .artwork:
            context.images.resolve(.artwork).resizable().scaledToFit()
                .padding(metrics.spacing)
                .frame(maxWidth: metrics.artworkMaximum)
                .aspectRatio(metrics.artworkAspectRatio, contentMode: .fit)
                .background(colors.artworkBackground)
                .clipShape(RoundedRectangle(cornerRadius: metrics.artworkRadius))
                .shadow(color: colors.artworkShadow, radius: metrics.artworkShadowRadius, y: metrics.artworkShadowY)
                .accessibilityLabel(context.strings.resolve(.artwork))
        case .metadata:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: metrics.detailSpacing) {
                    Text(context.state.snapshot.resource?.title ?? context.strings.resolve(.untitled))
                        .font(context.appearance.fonts.title).accessibilityIdentifier("current-title")
                    Text(context.state.subtitle).font(context.appearance.fonts.subtitle).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: metrics.detailSpacing)
                optional(.favorite, icon: .favorite, text: .favorite)
            }
        case .progress:
            VStack(spacing: metrics.detailSpacing) {
                #if os(tvOS)
                ProgressView(value: context.state.position, total: max(1, context.state.duration))
                    .accessibilityLabel(context.strings.resolve(.position))
                #else
                Slider(value: PlayerScrub.binding($scrub, state: context.state), in: 0...max(1, context.state.duration), onEditingChanged: PlayerScrub.editing($scrub, state: context.state, seek: context.actions.seek))
                    .disabled(context.actions.seek == nil || context.state.duration == 0)
                    .accessibilityLabel(context.strings.resolve(.position))
                #endif
                HStack {
                    Text(context.strings.time(scrub.position(in: context.state)))
                    Spacer(minLength: metrics.detailSpacing)
                    Text(context.strings.time(context.state.duration))
                }.font(context.appearance.fonts.caption).foregroundStyle(colors.secondary)
            }
        case .transport:
            HStack(spacing: 0) {
                optional(.shuffle, icon: .shuffle, text: context.state.shuffle ? .shuffleOn : .shuffleOff, selected: context.state.shuffle)
                Spacer(minLength: 0)
                control(.previous, icon: .previous, text: .previous)
                Spacer(minLength: 0)
                control(.playPause, icon: context.state.isPlaying ? .pause : .play, text: context.state.isPlaying ? .pause : .play)
                Spacer(minLength: 0)
                control(.next, icon: .next, text: .next)
                Spacer(minLength: 0)
                optional(.repeatMode, icon: context.state.repeatMode == .one ? .repeatOne : .repeatAll, text: context.state.repeatMode == .off ? .repeatOff : context.state.repeatMode == .one ? .repeatOne : .repeatAll, selected: context.state.repeatMode != .off)
            }
        case .accessories:
            HStack {
                optional(.equalizer, icon: nil, text: .equalizer)
                Spacer(minLength: metrics.detailSpacing)
                optional(.queue, icon: nil, text: .queue)
            }
        case .footer:
            Text(context.state.footer).font(context.appearance.fonts.caption).foregroundStyle(colors.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private func optional(_ role: PlayerControl, icon: PlayerIcon?, text: PlayerText, selected: Bool = false) -> some View {
        if context.actions.controls[role] != nil { control(role, icon: icon, text: text, selected: selected) }
    }

    @ViewBuilder private func control(_ role: PlayerControl, icon: PlayerIcon?, text: PlayerText, selected: Bool = false) -> some View {
        let label = context.strings.resolve(text)
        let enabled = context.actions.controls[role] != nil
        let action = context.actions.callback(for: role)
        if let button = components.button {
            button(PlayerButtonContext(control: role, label: label, icon: icon, selected: selected, enabled: enabled, perform: action))
        } else {
            Button(action: action) {
                Group {
                    if let icon { context.images.resolve(icon).resizable().scaledToFit().frame(width: metrics.iconSize, height: metrics.iconSize) }
                    else { Text(label).font(context.appearance.fonts.button) }
                }
                .frame(minWidth: role == .playPause ? metrics.primarySize : metrics.targetSize,
                       minHeight: role == .playPause ? metrics.primarySize : metrics.targetSize)
                .foregroundStyle(role == .playPause ? colors.onAccent : selected ? colors.accent : colors.foreground)
                .background(role == .playPause ? colors.accent : Color.clear, in: RoundedRectangle(cornerRadius: metrics.primaryRadius))
                .contentShape(Rectangle())
            }
            #if os(tvOS)
            .buttonStyle(.borderless)
            #else
            .buttonStyle(.plain)
            #endif
            .disabled(!enabled)
            .accessibilityLabel(label)
            .accessibilityValue(selected ? context.strings.resolve(text) : "")
            .accessibilityIdentifier(role.rawValue)
        }
    }
}
