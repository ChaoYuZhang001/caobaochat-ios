import SwiftUI

// MARK: - Login View
struct LoginView: View {
    @StateObject private var authService = AuthService.shared
    @State private var isLoading = false
    @State private var error: String?
    @State private var agreed = false
    @State private var showPrivacyPolicy = false
    @State private var showTerms = false
    
    var body: some View {
        VStack(spacing: 32) {
            // Logo
            VStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                Text("草包")
                    .font(.system(size: 36, weight: .bold))
                
                Text("毒舌但有用的 AI 助手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 16) {
                // Apple 登录
                #if os(iOS) || os(macOS)
                AppleSignInButton(
                    onSuccess: {
                        // 登录成功后会被 AppState 监听到
                    },
                    onError: { errorMsg in
                        error = errorMsg
                    }
                )
                .opacity(agreed ? 1 : 0.5)
                .disabled(!agreed)
                #endif
                
                // 分割线
                HStack {
                    VStack { Divider() }
                    Text("或")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                
                // 游客登录
                Button {
                    Task {
                        isLoading = true
                        error = nil
                        do {
                            try await authService.guestLogin()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        isLoading = false
                    }
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.primary)
                        } else {
                            Image(systemName: "person.fill")
                        }
                        Text("游客模式体验")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!agreed || isLoading)
                .opacity(agreed ? 1 : 0.5)
            }
            .padding(.horizontal, 24)
            
            // 用户协议 - 符合 Apple App Store 审核指南 5.1.1
            VStack(spacing: 8) {
                Button {
                    agreed.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: agreed ? "checkmark.square.fill" : "square")
                            .foregroundStyle(agreed ? .green : .secondary)
                        
                        Text("我已阅读并同意")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // 可点击的协议链接
                HStack(spacing: 4) {
                    Button {
                        showTerms = true
                    } label: {
                        Text("《用户协议》")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .underline()
                    }
                    
                    Text("和")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        showPrivacyPolicy = true
                    } label: {
                        Text("《隐私政策》")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .underline()
                    }
                }
            }
            .padding(.top, 8)
            
            // 错误提示
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            
            Spacer()
            
            // 特性说明
            HStack(spacing: 24) {
                FeatureItem(icon: "bolt.fill", title: "快速响应", color: .green)
                FeatureItem(icon: "shield.fill", title: "隐私安全", color: .orange)
                FeatureItem(icon: "sparkles", title: "毒舌有用", color: .blue)
            }
            
            // 多端支持
            Text("支持 Web、iOS、iPadOS、macOS、Windows")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding()
        #if os(macOS)
        .frame(width: 400, height: 600)
        #endif
        // 隐私政策弹窗 - 原生视图
        .sheet(isPresented: $showPrivacyPolicy) {
            NavigationStack {
                LegalView(type: .privacy)
            }
        }
        // 服务条款弹窗 - 原生视图
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                LegalView(type: .agreement)
            }
        }
    }
}

// MARK: - Feature Item
struct FeatureItem: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    LoginView()
}
