import Foundation
import SwiftUI
import AuthenticationServices

// MARK: - Notification Names
extension Notification.Name {
    static let loginSuccess = Notification.Name("loginSuccess")
    static let logoutSuccess = Notification.Name("logoutSuccess")
}

// MARK: - Auth Service
class AuthService: ObservableObject {
    static let shared = AuthService()
    
    @Published var isLoggedIn: Bool = false
    @Published var user: User?
    @Published var token: String?
    
    private let tokenKey = "caobao_token"
    private let userKey = "caobao_user"
    
    private init() {
        loadSession()
    }
    
    // MARK: - Load Session
    func loadSession() {
        if let token = UserDefaults.standard.string(forKey: tokenKey) {
            self.token = token
            if let userData = UserDefaults.standard.data(forKey: userKey),
               let user = try? JSONDecoder().decode(User.self, from: userData) {
                self.user = user
                self.isLoggedIn = true
            }
        }
    }
    
    // MARK: - Guest Login
    func guestLogin() async throws {
        let response = try await APIService.shared.guestLogin()
        
        if response.success, let token = response.token, let user = response.user {
            await MainActor.run {
                self.token = token
                self.user = user
                self.isLoggedIn = true
                UserDefaults.standard.set(token, forKey: tokenKey)
                if let userData = try? JSONEncoder().encode(user) {
                    UserDefaults.standard.set(userData, forKey: userKey)
                }
            }
            // 发送登录成功通知，触发云端同步
            NotificationCenter.default.post(name: .loginSuccess, object: nil)
        } else {
            throw AuthError.loginFailed(response.error ?? "登录失败")
        }
    }
    
    // MARK: - Apple Login
    #if os(iOS) || os(macOS)
    func handleAppleSignIn(result: ASAuthorization) async throws {
        guard let appleIDCredential = result.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthError.invalidCredential
        }
        
        // 获取原始 identityToken (JWT 字符串)，不要 base64 编码
        let identityToken = appleIDCredential.identityToken.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let authorizationCode = appleIDCredential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let userIdentifier = appleIDCredential.user
        let email = appleIDCredential.email
        let fullName = appleIDCredential.fullName
        
        print("🔐 Apple Sign-In - identityToken length: \(identityToken.count)")
        
        // 发送到后端验证
        let response = try await APIService.shared.appleLogin(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            userIdentifier: userIdentifier,
            email: email,
            fullName: fullName.map { "\($0.givenName ?? "") \($0.familyName ?? "")".trimmingCharacters(in: .whitespaces) }
        )
        
        if response.success, let token = response.token, let user = response.user {
            await MainActor.run {
                self.token = token
                self.user = user
                self.isLoggedIn = true
                UserDefaults.standard.set(token, forKey: tokenKey)
                if let userData = try? JSONEncoder().encode(user) {
                    UserDefaults.standard.set(userData, forKey: userKey)
                }
            }
            // 发送登录成功通知，触发云端同步
            NotificationCenter.default.post(name: .loginSuccess, object: nil)
        } else {
            throw AuthError.loginFailed(response.error ?? "Apple 登录失败")
        }
    }
    #endif
    
    // MARK: - Logout
    func logout() {
        token = nil
        user = nil
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        // 发送登出通知
        NotificationCenter.default.post(name: .logoutSuccess, object: nil)
    }
    
    // MARK: - Guest Upgrade
    /// 游客升级为正式用户
    /// - Parameters:
    ///   - provider: 登录方式 (apple, google, github, email)
    ///   - identityToken: Apple/Google 的 identity token
    ///   - authorizationCode: Apple 的 authorization code
    ///   - email: 邮箱（邮箱登录时需要）
    ///   - verifyCode: 验证码（邮箱登录时需要）
    /// - Returns: 升级结果
    func guestUpgrade(
        provider: String,
        identityToken: String? = nil,
        authorizationCode: String? = nil,
        email: String? = nil,
        verifyCode: String? = nil
    ) async throws -> GuestUpgradeResult {
        guard let guestToken = token else {
            throw AuthError.notLoggedIn
        }
        
        let response = try await APIService.shared.guestUpgrade(
            guestToken: guestToken,
            provider: provider,
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            email: email,
            verifyCode: verifyCode
        )
        
        if response.success, let newToken = response.token, let user = response.user {
            await MainActor.run {
                self.token = newToken
                self.user = user
                UserDefaults.standard.set(newToken, forKey: tokenKey)
                if let userData = try? JSONEncoder().encode(user) {
                    UserDefaults.standard.set(userData, forKey: userKey)
                }
            }
            
            return GuestUpgradeResult(success: true, message: response.message ?? "升级成功", upgraded: true)
        } else {
            throw AuthError.loginFailed(response.error ?? "升级失败")
        }
    }
    
    // MARK: - Check if can upgrade
    var canUpgrade: Bool {
        guard let user = user else { return false }
        return user.isGuest == true
    }
    
    // MARK: - Delete Account
    func deleteAccount(confirmation: String, reason: String? = nil) async throws -> DeleteAccountResult {
        guard let token = token else {
            throw AuthError.notLoggedIn
        }
        
        let response = try await APIService.shared.deleteAccount(
            token: token,
            confirmation: confirmation,
            reason: reason
        )
        
        if response.success {
            // 清除本地数据
            await MainActor.run {
                self.token = nil
                self.user = nil
                self.isLoggedIn = false
                UserDefaults.standard.removeObject(forKey: tokenKey)
                UserDefaults.standard.removeObject(forKey: userKey)
            }
            
            return DeleteAccountResult(success: true, message: response.message ?? "账号已成功注销")
        } else {
            throw AuthError.deleteFailed(response.error ?? "注销失败")
        }
    }
    
    // MARK: - Export Data
    func exportData() async throws -> ExportDataResult {
        guard let token = token else {
            throw AuthError.notLoggedIn
        }
        
        let response = try await APIService.shared.exportData(token: token)
        
        if response.success {
            return ExportDataResult(
                success: true,
                data: response.data,
                exportedAt: response.exportedAt
            )
        } else {
            throw AuthError.exportFailed(response.error ?? "导出失败")
        }
    }
}

// MARK: - Auth Error
enum AuthError: LocalizedError {
    case loginFailed(String)
    case invalidCredential
    case networkError
    case notLoggedIn
    case deleteFailed(String)
    case exportFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .loginFailed(let message):
            return message
        case .invalidCredential:
            return "无效的凭证"
        case .networkError:
            return "网络错误"
        case .notLoggedIn:
            return "未登录"
        case .deleteFailed(let message):
            return message
        case .exportFailed(let message):
            return message
        }
    }
}

// MARK: - Result Models
struct DeleteAccountResult: Codable {
    let success: Bool
    let message: String?
}

struct ExportDataResult: Codable {
    let success: Bool
    let data: [String: String]?
    let exportedAt: String?
}

struct GuestUpgradeResult: Codable {
    let success: Bool
    let message: String?
    let upgraded: Bool?
}

// MARK: - Apple Sign In Button (iOS/macOS)
#if os(iOS) || os(macOS)
struct AppleSignInButton: View {
    let onSuccess: () -> Void
    let onError: (String) -> Void
    
    var body: some View {
        SignInWithAppleButton(
            .signIn,
            onRequest: { request in
                request.requestedScopes = [.fullName, .email]
            },
            onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task {
                        do {
                            try await AuthService.shared.handleAppleSignIn(result: authorization)
                            await MainActor.run {
                                onSuccess()
                            }
                        } catch {
                            await MainActor.run {
                                onError(error.localizedDescription)
                            }
                        }
                    }
                case .failure(let error):
                    onError(error.localizedDescription)
                }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
