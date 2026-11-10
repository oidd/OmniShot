import AppKit
import SwiftUI

/// One app in the About page's 作者的奇思妙想 list.
struct RecommendedTool: Identifiable {
    /// Stable across renders — `UUID()` would make SwiftUI rebuild the row (and drop its hover) every time.
    var id: String { iconName }
    let name: String
    let slogan: String
    let iconName: String
    let url: String
}

enum RecommendedTools {
    /// The list from DockMinimize's About page, plus DockMinimize itself. The icons live in
    /// `Sources/OmniShot/Recommends` and are copied into the app's resource bundle by SwiftPM.
    static let all: [RecommendedTool] = [
        RecommendedTool(
            name: "PathTrace",
            slogan: "无需翻找，我知道你想保存在这里。",
            iconName: "pathtrace",
            url: "https://ivean.com/pathtrace/"
        ),
        RecommendedTool(
            name: "EdgeClip",
            slogan: "让刚刚复制的内容，留在手边。",
            iconName: "edgeclip",
            url: "https://www.ivean.com/edgeclip/"
        ),
        RecommendedTool(
            name: "流光倒计时",
            slogan: "一按一拉，静待流光。让时间流逝成为一种桌面美学。",
            iconName: "flux_timer",
            url: "https://ivean.com/fluxtimer/"
        ),
        RecommendedTool(
            name: "SideBar",
            slogan: "将屏幕边缘的魔法收纳术带给所有的第三方应用。拖拽吸附，悬停弹射，纯粹且静谧。",
            iconName: "sidebar",
            url: "https://www.ivean.com/sidebar/"
        ),
        RecommendedTool(
            name: "快速搜索",
            slogan: "选中文本，双击快捷键，在页面上瞬间切换搜索方式。",
            iconName: "quick_search",
            url: "https://www.ivean.com/quicksearch/"
        ),
        RecommendedTool(
            name: "多词高亮查找",
            slogan: "告别低效，开启专业的多词批量高亮检索新纪元。",
            iconName: "highlighter",
            url: "https://ivean.com/highlighter/"
        ),
        RecommendedTool(
            name: "极致护眼",
            slogan: "为你的眼睛，挑选一种舒适。全方位的护眼计划。",
            iconName: "eyecare",
            url: "https://www.ivean.com/eyecarepro"
        ),
        RecommendedTool(
            name: "DockMinimize",
            slogan: "在 macOS 上实现类似 Windows 系统的单击隐藏和显示窗口。",
            iconName: "dockminimize",
            url: "https://ivean.com/dockminimize/"
        ),
    ]
}

/// A full-colour app icon, a name and one line of slogan — the same row DockMinimize uses on its About page.
struct RecommendationRow: View {
    let tool: RecommendedTool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var icon: NSImage? {
        Icon.recommendationImage(named: tool.iconName, dark: colorScheme == .dark)
    }

    var body: some View {
        Button {
            if let url = URL(string: tool.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary.opacity(0.25))
                            .padding(9)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(tool.slogan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovered ? Color.primary.opacity(0.1) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

/// The About page's 作者的奇思妙想 section. It is deliberately not a SettingsCard: DockMinimize's list
/// reads as a run of app rows on the page, not as another settings group.
struct RecommendationsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("作者的奇思妙想")
                .font(.footnote)
                .bold()
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 12) {
                ForEach(RecommendedTools.all) { tool in
                    RecommendationRow(tool: tool)
                }
            }
        }
    }
}
