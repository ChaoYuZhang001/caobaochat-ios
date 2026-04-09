import SwiftUI

// MARK: - Watch Content View
struct WatchContentView: View {
    @EnvironmentObject var appState: WatchAppState
    
    var body: some View {
        TabView {
            WatchHomeView()
                .tabItem {
                    Image(systemName: "house.fill")
                }
            
            WatchFortuneView()
                .tabItem {
                    Image(systemName: "sparkles")
                }
            
            WatchNewsView()
                .tabItem {
                    Image(systemName: "newspaper.fill")
                }
            
            WatchRoastView()
                .tabItem {
                    Image(systemName: "flame.fill")
                }
            
            WatchDecisionView()
                .tabItem {
                    Image(systemName: "scale.3d")
                }
        }
    }
}

// MARK: - Watch Home View
struct WatchHomeView: View {
    @EnvironmentObject var appState: WatchAppState
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            
            Text("草包")
                .font(.title3)
                .fontWeight(.bold)
            
            Text("毒舌但有用")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            Text(Date().formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchAppState())
}
