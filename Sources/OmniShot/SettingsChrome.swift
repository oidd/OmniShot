import AppKit
import SwiftUI

/// The pages of the settings window, in the order they appear in the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case permissions, shortcuts, output, translate, ocr, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permissions: return "权限设置"
        case .shortcuts: return "快捷键"
        case .output: return "保存"
        case .translate: return "翻译"
        case .ocr: return "文字识别"
        case .general: return "通用"
        case .about: return "关于"
        }
    }

    /// The project owner's own set, kept for the sidebar alone — see `Icons/settings`.
    var icon: Icon.Asset {
        switch self {
        case .permissions: return .settingsPermissions
        case .shortcuts: return .settingsShortcuts
        case .output: return .settingsOutput
        case .translate: return .settingsTranslate
        case .ocr: return .settingsOCR
        case .general: return .settingsGeneral
        case .about: return .settingsAbout
        }
    }
}

// MARK: - Icons

/// An icon from the app's own set. `Icon.image` hands back a template, so the surrounding foreground
/// style tints it the same way the toolbar's do.
struct SettingsIcon: View {
    let asset: Icon.Asset
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Icon.image(asset, size: size))
            .renderingMode(.template)
            .interpolation(.high)
    }
}

// MARK: - Page furniture

/// One card: a rounded box whose rows are separated by hairlines the caller places itself.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, 3)
        }
    }
}

/// The hairline between two rows of a card.
struct SettingsRowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

/// A row: a title with an optional second line, and a control on the right.
///
/// No leading icon. The cards used to have one per row, and the rows that had none read as a different kind of
/// thing; the owner had them all removed so every row in a card looks the same.
struct SettingsRow<Control: View>: View {
    private let title: String
    private let detail: String?
    private let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The common case: a title, a line of explanation, and a switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Permissions

/// One permission: what it is for, whether it is granted, and the two ways to change that.
struct SettingsPermissionCard: View {
    let title: String
    var detail: String? = nil
    let isGranted: Bool
    /// Missing permissions the app cannot work without get the louder treatment.
    var isRequired = true
    let grantTitle: String
    let grant: () -> Void
    let openSettings: () -> Void

    private var tint: Color { isGranted ? .green : (isRequired ? .orange : .secondary) }

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                SettingsIcon(asset: isGranted ? .granted : .missing, size: 22)
                    .foregroundStyle(tint)
                    .frame(width: 26, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("打开系统设置", action: openSettings)
                        .controlSize(.small)
                    if !isGranted {
                        Button(grantTitle, action: grant)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("已开启")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}

// MARK: - Sidebar

/// The sidebar is hand-drawn rather than a `List`: the selection is a capsule that slides between rows
/// and an accent wash that unfolds behind the label, neither of which a `List` row will do.
///
/// Kept in the same shape as DockMinimize's sidebar: a clear background over the split view's material,
/// 8pt side/top padding, 4pt row spacing, and 36pt rows.
struct SettingsSidebar: View {
    @Binding var pane: SettingsPane
    @Namespace private var indicator

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { item in
                    SettingsSidebarRow(pane: item, selection: $pane, indicator: indicator)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(.clear)
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    @Binding var selection: SettingsPane
    let indicator: Namespace.ID

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    /// How far the accent wash has unfolded, 0 → 1.
    @State private var bgProgress: CGFloat = 0

    private var isSelected: Bool { selection == pane }

    private var backgroundFill: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.15)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The capsule only exists on the selected row; `matchedGeometryEffect` is what makes it
            // travel between rows instead of blinking out on one and in on the other.
            HStack(spacing: 0) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .matchedGeometryEffect(id: "settings.sidebar.indicator", in: indicator)
                } else {
                    Spacer().frame(width: 3)
                }
                Spacer()
            }
            .padding(.leading, 4)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? backgroundFill : Color.clear)
                    .frame(width: geo.size.width * bgProgress,
                           height: geo.size.height,
                           alignment: .leading)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)

            HStack(spacing: 11) {
                SettingsIcon(asset: pane.icon, size: 17)
                    .foregroundStyle(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.85) : Color.secondary))
                    .frame(width: 22, alignment: .center)
                Text(pane.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture {
            guard !isSelected else { return }
            // The capsule uses a spring, the wash uses easeOut.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selection = pane }
        }
        .onChange(of: isSelected) { _, newValue in
            if newValue {
                bgProgress = 0
                withAnimation(.easeOut(duration: 0.32)) { bgProgress = 1 }
            } else {
                // The row on its way out just fades; only the arriving row unfolds.
                withAnimation(.easeIn(duration: 0.12)) { bgProgress = 0 }
            }
        }
        .onAppear { bgProgress = isSelected ? 1 : 0 }
        // Hover feedback on the rows that are not selected.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered && !isSelected ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.leading, 12)
                .padding(.trailing, 4)
        )
    }
}
