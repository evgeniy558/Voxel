import SwiftUI

struct WelcomeView: View {
    let isEnglish: Bool
    let accent: Color
    var onAuthenticated: () -> Void

    @State private var selectedFeature: Int = 0
    @State private var showAuthSheet = false

    private let startButtonBlue = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)

    private var headline: String {
        isEnglish
            ? "Sphere — your guide to the world of music"
            : "Sphere — твой проводник в мир музыки"
    }

    private var whyUsTitle: String { isEnglish ? "Why us" : "Почему мы" }

    private var startTitle: String { isEnglish ? "Get started" : "Начать" }

    private var featurePages: [(title: String, text: String)] {
        if isEnglish {
            return [
                (
                    "Multi-server",
                    "Listen to music from several services at once with a single Sphere account."
                ),
                (
                    "Convenience",
                    "We combined a simple interface with ease of use."
                ),
                (
                    "Security",
                    "Your data is stored securely on our servers."
                ),
            ]
        }
        return [
            (
                "Мультисерверность",
                "Слушайте музыку сразу с нескольких сервисов, используя один аккаунт нашего приложения."
            ),
            (
                "Удобство",
                "Мы совместили простоту интерфейса и удобство в использовании."
            ),
            (
                "Безопасность",
                "Ваши данные надёжно хранятся на наших серверах."
            ),
        ]
    }

    var body: some View {
        ZStack {
            WelcomeBackgroundView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    Text(headline)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)

                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 180, height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                        .padding(.bottom, 24)

                    Text(whyUsTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)

                    TabView(selection: $selectedFeature) {
                        ForEach(featurePages.indices, id: \.self) { i in
                            featureSlide(title: featurePages[i].title, body: featurePages[i].text)
                                .padding(.horizontal, 28)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .frame(height: 260)
                    .padding(.top, 20)
                }
                .frame(maxWidth: .infinity)
                .opacity(showAuthSheet ? 0 : 1)
                .animation(.easeInOut(duration: 0.45), value: showAuthSheet)

                Spacer(minLength: 0)

                Button {
                    withAnimation(.spring(response: 0.85, dampingFraction: 0.86)) {
                        showAuthSheet = true
                    }
                } label: {
                    Text(startTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(startButtonBlue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .opacity(showAuthSheet ? 0 : 1)
                .animation(.easeInOut(duration: 0.35), value: showAuthSheet)
            }

            // Custom dark glass bottom sheet — slower animation, no swipe-to-dismiss.
            if showAuthSheet {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)

                AuthSheetView(
                    isEnglish: isEnglish,
                    accent: accent,
                    onAuthenticated: {
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                            showAuthSheet = false
                        }
                        onAuthenticated()
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                            showAuthSheet = false
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func featureSlide(title: String, body: String) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 16))
                .foregroundStyle(Color.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
