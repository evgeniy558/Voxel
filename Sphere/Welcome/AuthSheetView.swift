import SwiftUI

/// Log in / Sign up sheet content (second step after Welcome "Get started").
/// Designed as a custom dark-glass bottom sheet (presented from `WelcomeView`).
struct AuthSheetView: View {
    let isEnglish: Bool
    let accent: Color
    var onAuthenticated: () -> Void
    var onDismiss: () -> Void

    @StateObject private var authService = AuthService.shared

    @State private var mode: AuthMode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var rememberMe = true
    @State private var isPasswordVisible = false
    @State private var hasAttemptedSubmit = false
    @State private var isSigningInWithEmail = false
    @State private var isSigningInWithGoogle = false
    @State private var isSendingSignupCode = false
    @State private var signupMessage: String?
    @State private var showVerifyCode = false
    @State private var showTwoFactorSheet = false
    @State private var twoFAChallengeId: String?
    @State private var twoFAMethods: [String] = []
    @State private var twoFAMethod = "email"
    @State private var twoFACode = ""
    @State private var showForgotPassword = false
    @State private var showQRLogin = false

    private enum AuthMode: Hashable {
        case login
        case signup
    }

    private var signInButtonTitle: String { isEnglish ? "Log in" : "Войти" }
    private var signUpButtonTitle: String { isEnglish ? "Sign up" : "Создать аккаунт" }
    private var emailPlaceholder: String { isEnglish ? "Email" : "Почта" }
    private var passwordPlaceholder: String { isEnglish ? "Password" : "Пароль" }
    private var nicknamePlaceholder: String { isEnglish ? "Nickname" : "Никнейм" }
    private var orLabel: String { isEnglish ? "Or" : "Или" }
    private var googleTitle: String { isEnglish ? "Continue with Google" : "Продолжить с Google" }
    private var rememberTitle: String { isEnglish ? "Remember me" : "Запомнить меня" }
    private var forgotTitle: String { isEnglish ? "Forgot password?" : "Забыли пароль?" }
    private var title: String { isEnglish ? "Get Started now" : "Начни сейчас" }
    private var subtitle: String {
        isEnglish
            ? "Create an account or log in to explore Sphere!"
            : "Создай аккаунт или войди, чтобы исследовать Sphere!"
    }

    private var formIsValidLogin: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private var passwordStrength: SpherePasswordStrength { SpherePasswordStrength.evaluate(password) }

    private var formIsValidSignup: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && email.contains("@")
            && passwordStrength.isAcceptableForRegister
    }

    private let rememberEmailKey = "welcomeAuthRememberedEmail"
    private let primaryBlueGradient = LinearGradient(
        colors: [
            Color(red: 52 / 255, green: 130 / 255, blue: 1),
            Color(red: 0 / 255, green: 102 / 255, blue: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack(alignment: .top) {
            // Tall dark glass card that fills almost the entire screen.
            darkGlassCard
                .padding(.horizontal, 12)
                .padding(.top, 36)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .preferredColorScheme(.dark)
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: rememberEmailKey), !saved.isEmpty {
                email = saved
            }
        }
        .fullScreenCover(isPresented: $showVerifyCode) {
            VerifyEmailCodeView(
                isEnglish: isEnglish,
                isDarkMode: true,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                avatarColorIndex: 0,
                customAvatarImage: nil,
                onDone: {
                    showVerifyCode = false
                    if authService.isSignedIn { onAuthenticated() }
                },
                onCancel: { showVerifyCode = false }
            )
        }
        .sheet(isPresented: $showTwoFactorSheet) {
            Group {
                if #available(iOS 16.4, *) {
                    twoFactorSheet
                        .presentationBackground(.thinMaterial)
                } else {
                    twoFactorSheet
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showForgotPassword) {
            Group {
                if #available(iOS 16.4, *) {
                    ForgotPasswordSheetContent(
                        isEnglish: isEnglish,
                        accent: accent,
                        onDismiss: { showForgotPassword = false }
                    )
                    .presentationDetents([.fraction(0.42)])
                    .presentationBackground(.thinMaterial)
                } else {
                    ForgotPasswordSheetContent(
                        isEnglish: isEnglish,
                        accent: accent,
                        onDismiss: { showForgotPassword = false }
                    )
                    .presentationDetents([.fraction(0.42)])
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showQRLogin) {
            QRLoginSignInSheet(
                isEnglish: isEnglish,
                accent: accent,
                onAuthenticated: {
                    showQRLogin = false
                    onAuthenticated()
                },
                onDismiss: { showQRLogin = false }
            )
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Dark glass card

    private var darkGlassCard: some View {
        VStack(spacing: 0) {
            // Top header with title + close handle.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    segmentedSwitcher
                        .padding(.horizontal, 18)
                        .padding(.top, 4)

                    if let err = authService.authError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.red.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                    }

                    formFields
                        .padding(.horizontal, 18)

                    submitButton
                        .padding(.horizontal, 18)
                        .padding(.top, 4)

                    orDivider
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)

                    googleButton
                        .padding(.horizontal, 18)

                    qrSignInButton
                        .padding(.horizontal, 18)

                    if let signupMessage {
                        Text(signupMessage)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                    }

                    Color.clear.frame(height: 28)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                // Dark glass effect: thinMaterial tinted dark to be readable.
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        )
        .overlay(alignment: .top) {
            // Drag handle (visual only — actual swipe-to-dismiss is disabled).
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 4)
                .padding(.top, 8)
        }
    }

    // MARK: - Segmented switcher

    private var segmentedSwitcher: some View {
        HStack(spacing: 4) {
            segmentButton(title: isEnglish ? "Log In" : "Вход", isSelected: mode == .login) {
                withAnimation(.easeInOut(duration: 0.2)) { mode = .login }
            }
            segmentButton(title: isEnglish ? "Sign Up" : "Регистрация", isSelected: mode == .signup) {
                withAnimation(.easeInOut(duration: 0.2)) { mode = .signup }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func segmentButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fields

    @ViewBuilder
    private var formFields: some View {
        VStack(spacing: 14) {
            labeledField(title: isEnglish ? "Email/username" : "Почта/логин") {
                DarkGlassTextField(
                    text: $email,
                    placeholder: emailPlaceholder,
                    leadingSystemImage: "envelope"
                ) {
                    TextField("", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
            }

            if mode == .signup {
                labeledField(title: isEnglish ? "Nickname" : "Никнейм") {
                    DarkGlassTextField(
                        text: $nickname,
                        placeholder: nicknamePlaceholder,
                        leadingSystemImage: "person"
                    ) {
                        TextField("", text: $nickname)
                            .textContentType(.nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                    }
                }
            }

            labeledField(title: isEnglish ? "Password" : "Пароль") {
                DarkGlassTextField(
                    text: $password,
                    placeholder: passwordPlaceholder,
                    leadingSystemImage: "lock",
                    trailing: {
                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(Color.white.opacity(0.65))
                        }
                    }
                ) {
                    Group {
                        if isPasswordVisible {
                            TextField("", text: $password)
                        } else {
                            SecureField("", text: $password)
                        }
                    }
                    .textContentType(mode == .login ? .password : .newPassword)
                    .foregroundStyle(.white)
                }
            }

            if mode == .signup, (hasAttemptedSubmit || !password.isEmpty) {
                Text(passwordStrengthSummary(passwordStrength))
                    .font(.caption)
                    .foregroundStyle(passwordStrength.isAcceptableForRegister ? Color.white.opacity(0.7) : Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if mode == .login {
                HStack {
                    Button {
                        rememberMe.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: rememberMe ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundStyle(rememberMe ? accent : Color.white.opacity(0.5))
                            Text(rememberTitle)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(forgotTitle) {
                        showForgotPassword = true
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 70 / 255, green: 145 / 255, blue: 1))
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Buttons

    private var submitButton: some View {
        Button(action: submitPrimary) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                }
                Text(mode == .login ? signInButtonTitle : signUpButtonTitle)
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(primaryBlueGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.blue.opacity(0.30), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            Text(orLabel)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.55))
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
        }
    }

    private var googleButton: some View {
        Button(action: signInGoogle) {
            HStack(spacing: 12) {
                if isSigningInWithGoogle {
                    ProgressView().tint(.white)
                } else {
                    Image("google")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                Text(googleTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSigningInWithGoogle)
    }

    private var qrSignInButton: some View {
        Button {
            showQRLogin = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(isEnglish ? "Sign in with QR" : "Войти по QR-коду")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 2FA sheet content

    @ViewBuilder
    private var twoFactorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if twoFAMethods.count > 1 {
                        Picker("", selection: $twoFAMethod) {
                            Text(isEnglish ? "Email" : "Почта").tag("email")
                            Text(isEnglish ? "Authenticator" : "Приложение").tag("totp")
                        }
                        .pickerStyle(.segmented)
                    }
                    SecureField(isEnglish ? "Code" : "Код", text: $twoFACode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if let err = authService.authError, !err.isEmpty {
                        Text(err)
                            .foregroundStyle(Color.red)
                            .font(.caption)
                    }
                }
                Section {
                    Button(isEnglish ? "Continue" : "Продолжить") {
                        Task { @MainActor in
                            guard let cid = twoFAChallengeId else { return }
                            let ok = await authService.completeBackendTwoFactor(
                                challengeId: cid,
                                method: twoFAMethod,
                                code: twoFACode,
                                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password
                            )
                            if ok {
                                showTwoFactorSheet = false
                                persistRememberedEmail()
                                onAuthenticated()
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(isEnglish ? "Two-factor" : "Двухфакторный вход")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Cancel" : "Отмена") {
                        showTwoFactorSheet = false
                    }
                }
            }
        }
    }

    private var isBusy: Bool { isSigningInWithEmail || isSendingSignupCode }

    private func persistRememberedEmail() {
        if rememberMe {
            UserDefaults.standard.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: rememberEmailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: rememberEmailKey)
        }
    }

    private func submitPrimary() {
        signupMessage = nil
        switch mode {
        case .login:
            guard formIsValidLogin else {
                hasAttemptedSubmit = true
                return
            }
            Task { @MainActor in
                isSigningInWithEmail = true
                authService.authError = nil
                let result = await authService.signInWithBackendEmailPassword(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                isSigningInWithEmail = false
                switch result {
                case .success:
                    persistRememberedEmail()
                    onAuthenticated()
                case .needsTwoFactor(let cid, let methods):
                    twoFAChallengeId = cid
                    twoFAMethods = methods
                    twoFAMethod = methods.contains("email") ? "email" : (methods.first ?? "totp")
                    twoFACode = ""
                    showTwoFactorSheet = true
                case .failure:
                    break
                }
            }
        case .signup:
            guard formIsValidSignup else {
                hasAttemptedSubmit = true
                return
            }
            Task {
                await sendSignupCode()
            }
        }
    }

    private func sendSignupCode() async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.contains("@") else {
            await MainActor.run {
                signupMessage = isEnglish ? "Enter a valid email" : "Введите корректную почту"
            }
            return
        }
        guard passwordStrength.isAcceptableForRegister else {
            await MainActor.run {
                signupMessage = isEnglish ? "Password is too weak" : "Слишком слабый пароль"
            }
            return
        }
        await MainActor.run {
            isSendingSignupCode = true
            signupMessage = nil
        }
        defer { Task { @MainActor in isSendingSignupCode = false } }
        do {
            try await SphereAPIClient.shared.sendSignupCode(email: e)
            await MainActor.run { showVerifyCode = true }
        } catch {
            await MainActor.run { signupMessage = error.localizedDescription }
        }
    }

    private func signInGoogle() {
        Task {
            isSigningInWithGoogle = true
            await authService.signInWithGoogle()
            isSigningInWithGoogle = false
            if authService.isSignedIn {
                persistRememberedEmail()
                onAuthenticated()
            }
        }
    }

    private func passwordStrengthSummary(_ s: SpherePasswordStrength) -> String {
        let label: String
        switch s.labelKey {
        case "strong": label = isEnglish ? "Strong" : "Сильный"
        case "good": label = isEnglish ? "Good" : "Хороший"
        case "fair": label = isEnglish ? "Medium" : "Средний"
        default: label = isEnglish ? "Weak" : "Слабый"
        }
        return isEnglish
            ? "Strength: \(label) · \(s.score)/100"
            : "Сложность: \(label) · \(s.score)/100"
    }

    private func labeledField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
            content()
        }
    }
}

// MARK: - Dark glass field

private struct DarkGlassTextField<Content: View, Trailing: View>: View {
    @Binding var text: String
    let placeholder: String
    let leadingSystemImage: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder var field: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: leadingSystemImage)
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 20)
            ZStack(alignment: .leading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                field()
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private extension DarkGlassTextField where Trailing == EmptyView {
    init(
        text: Binding<String>,
        placeholder: String,
        leadingSystemImage: String,
        @ViewBuilder field: @escaping () -> Content
    ) {
        self._text = text
        self.placeholder = placeholder
        self.leadingSystemImage = leadingSystemImage
        self.trailing = { EmptyView() }
        self.field = field
    }
}

// MARK: - QR sign-in sheet

/// Shown from the login screen. Generates a `/auth/qr/start` session, displays the
/// QR code, and long-polls `/auth/qr/poll` for approval from another logged-in
/// device (which scans the QR via Privacy → "Approve QR login").
struct QRLoginSignInSheet: View {
    let isEnglish: Bool
    let accent: Color
    var onAuthenticated: () -> Void
    var onDismiss: () -> Void

    @StateObject private var authService = AuthService.shared

    @State private var qrPayload: String?
    @State private var sessionId: String?
    @State private var statusMessage: String?
    @State private var isStarting = false
    @State private var isExpired = false
    @State private var pollTask: Task<Void, Never>?

    private var titleText: String { isEnglish ? "Sign in with QR" : "Вход по QR-коду" }
    private var instructionsText: String {
        isEnglish
            ? "Open Sphere on a logged-in device → Settings → Privacy → \"Approve QR login\" and scan this code."
            : "Откройте Sphere на устройстве, где вы уже вошли → Настройки → Конфиденциальность → «Подтвердить вход по QR» и отсканируйте этот код."
    }
    private var refreshTitle: String { isEnglish ? "New QR" : "Новый QR" }
    private var waitingText: String {
        isEnglish ? "Waiting for approval…" : "Ожидаем подтверждение…"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.06, green: 0.07, blue: 0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 22) {
                    Text(instructionsText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                        .padding(.top, 8)

                    qrCodeBox

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(isExpired ? Color.red.opacity(0.9) : Color.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                    } else if qrPayload != nil {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(waitingText)
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }

                    if isExpired || (qrPayload == nil && !isStarting) {
                        Button(refreshTitle) {
                            Task { await startSession() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(accent.opacity(0.85))
                        )
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEnglish ? "Close" : "Закрыть") {
                        pollTask?.cancel()
                        onDismiss()
                    }
                    .tint(.white)
                }
            }
        }
        .task {
            await startSession()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var qrCodeBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
                .frame(width: 280, height: 280)
                .shadow(color: Color.black.opacity(0.4), radius: 18, x: 0, y: 10)
            if let payload = qrPayload {
                SphereQRLoginQRImage(payload: payload)
                    .opacity(isExpired ? 0.25 : 1.0)
            } else if isStarting {
                ProgressView().tint(.black)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 64))
                    .foregroundStyle(.black.opacity(0.5))
            }
        }
    }

    private func startSession() async {
        await MainActor.run {
            isStarting = true
            isExpired = false
            statusMessage = nil
            qrPayload = nil
            sessionId = nil
        }
        defer {
            Task { @MainActor in isStarting = false }
        }
        do {
            let resp = try await SphereAPIClient.shared.qrLoginStart()
            await MainActor.run {
                qrPayload = resp.qrPayload
                sessionId = resp.sessionId
            }
            startPolling(sessionId: resp.sessionId)
        } catch {
            await MainActor.run {
                statusMessage = isEnglish
                    ? "Could not start QR session: \(error.localizedDescription)"
                    : "Не удалось создать QR: \(error.localizedDescription)"
            }
        }
    }

    private func startPolling(sessionId: String) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Each `qrLoginPollOnce` long-polls up to ~55s. Loop until approved,
            // gone (expired/cancelled), or the user dismisses the sheet.
            while !Task.isCancelled {
                do {
                    let result = try await SphereAPIClient.shared.qrLoginPollOnce(sessionId: sessionId)
                    if Task.isCancelled { return }
                    switch result {
                    case .approved(let auth):
                        // qrLoginPollOnce already persisted the JWT inside SphereAPIClient.
                        // Just fan the backend user into the local profile.
                        authService.applyBackendUser(auth.user)
                        Task { await authService.refreshBackendAccountFromServer() }
                        statusMessage = isEnglish ? "Signed in" : "Вход выполнен"
                        onAuthenticated()
                        return
                    case .pending:
                        continue
                    case .gone:
                        isExpired = true
                        statusMessage = isEnglish
                            ? "QR expired — tap \"New QR\" to try again."
                            : "QR-код истёк — нажмите «Новый QR»."
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    statusMessage = error.localizedDescription
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }
}
