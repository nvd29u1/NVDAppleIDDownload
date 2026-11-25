#if os(iOS)
import SwiftUI
import UIKit

enum SignTheme {
    // Plum palette, to match the NVD app (was coral/rose in SayoSign).
    static let coral = Color(red: 0.48, green: 0.13, blue: 0.28)
    static let rose = Color(red: 0.38, green: 0.10, blue: 0.22)
    static let peach = Color(red: 1.0, green: 0.85, blue: 0.90)
    static let cream = Color(red: 0.98, green: 0.94, blue: 0.96)
    static let ribbon = Color(red: 0.55, green: 0.12, blue: 0.30)
    // Near-flat fills for a clean, ESign-style look (no heavy gradients).
    static let gradient = LinearGradient(colors: [coral, rose], startPoint: .top, endPoint: .bottom)
    static let soft = LinearGradient(colors: [coral.opacity(0.14), coral.opacity(0.10)], startPoint: .top, endPoint: .bottom)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            )
    }
}

struct AppIconView: View {
    let image: UIImage?
    var url: String? = nil
    var size: CGFloat = 54
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable()
            } else if let s = url, let u = URL(string: s), !s.isEmpty {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    var placeholder: some View {
        ZStack {
            SignTheme.gradient
            Image(.pigLogo).resizable().padding(size * 0.14)
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = SignTheme.coral
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundColor(color)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SignTheme.coral))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SmallButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundColor(filled ? .white : SignTheme.rose)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(filled ? AnyShapeStyle(SignTheme.coral) : AnyShapeStyle(SignTheme.coral.opacity(0.14))))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 14) {
            Image(.pigLogo).resizable().frame(width: 64, height: 64)
            Text(title).font(.title3.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(.pigLogo).resizable().frame(width: 20, height: 20)
            Text(text).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(SignTheme.gradient).shadow(color: SignTheme.rose.opacity(0.35), radius: 14, y: 6))
        .padding(.horizontal, 20)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension View {
    @ViewBuilder func glassy() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(SignTheme.coral.opacity(0.15)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #endif
    }
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()
#endif
