import SwiftUI

/// 折叠态里的一枚圆圈。
struct DockItem: Identifiable {
    let id: String
    let short: String        // 短名：WB / Claude / Codex
    let text: String         // 圈内文字：2.1k / 12.4 / --
    let tint: Color
    let ok: Bool
    /// 额度类账户的进度（0...1）；余额类为 nil，表示只描边不画弧
    let progress: Double?
}

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var refreshing = false
    @Published var items: [DockItem] = []
    @Published var accounts: [AccountQuota] = []
    @Published var statusLine = "尚未查询"
    var onToggle: (() -> Void)?
}

struct RootView: View {
    @ObservedObject var state: UIState

    var body: some View {
        Group {
            if state.expanded {
                ExpandedView(state: state)
            } else {
                CollapsedView(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 折叠态

struct CollapsedView: View {
    @ObservedObject var state: UIState
    private var t: Palette { Theme.current }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(state.items) { item in
                CircleBadge(item: item)
            }
            if state.items.isEmpty {
                Text("无账户")
                    .font(.system(size: 11))
                    .foregroundColor(t.tx3)
                    .frame(width: 120, height: 44)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(t.bg.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(t.isDark ? Color.white.opacity(0.08) : t.border, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { state.onToggle?() }
    }
}

struct CircleBadge: View {
    let item: DockItem
    private var t: Palette { Theme.current }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .strokeBorder(t.trackRing, lineWidth: 2)
                if let progress = item.progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .stroke(item.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .strokeBorder(item.tint, lineWidth: 2)
                }
                Text(item.text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(item.ok ? item.tint : t.tx3)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
            .frame(width: 44, height: 44)

            Text(item.short)
                .font(.system(size: 9))
                .foregroundColor(t.tx3)
                .lineLimit(1)
                .frame(width: 48)
        }
        .opacity(item.ok ? 1 : 0.55)
    }
}

// MARK: - 展开态（骨架，后续填真实列表）

struct ExpandedView: View {
    @ObservedObject var state: UIState
    private var t: Palette { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TokenPanel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(t.tx)
                Spacer()
                if state.refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button {
                        state.onToggle?()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(t.tx3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().overlay(t.line)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(state.accounts) { account in
                        AccountRow(account: account)
                        Divider().overlay(t.line).padding(.leading, 14)
                    }
                }
            }

            Divider().overlay(t.line)

            HStack {
                Text(state.statusLine)
                    .font(.system(size: 10))
                    .foregroundColor(t.foot)
                Spacer()
                Text("v" + AppInfo.version)
                    .font(.system(size: 10))
                    .foregroundColor(t.foot)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(t.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(t.isDark ? Color.white.opacity(0.08) : t.border, lineWidth: 0.5)
                )
        )
        .padding(6)
    }
}

struct AccountRow: View {
    let account: AccountQuota
    private var t: Palette { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.ok ? account.tint : t.tx3)
                    .frame(width: 6, height: 6)
                Text(account.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(t.tx)
                Spacer()
                Text(account.primaryText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(account.ok ? account.tint : t.tx3)
            }
            ForEach(account.tiers) { tier in
                HStack {
                    Text(tier.name)
                        .font(.system(size: 10))
                        .foregroundColor(t.tx3)
                    Spacer()
                    Text(tier.display)
                        .font(.system(size: 10))
                        .foregroundColor(t.tx2)
                }
            }
            if let error = account.errorText {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(t.am)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
