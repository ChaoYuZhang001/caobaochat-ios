//
//  WebView.swift
//  Caobao
//
//  通用 WebView 组件
//

import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - WebView 组件
struct WebView: NSUIViewRepresentable {
    let url: URL
    let onLoadComplete: (() -> Void)?
    
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.dataDetectorTypes = [.link, .phoneNumber]
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    #elseif os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    #endif
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadComplete: onLoadComplete)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let onLoadComplete: (() -> Void)?
        
        init(onLoadComplete: (() -> Void)?) {
            self.onLoadComplete = onLoadComplete
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadComplete?()
        }
    }
}

// MARK: - 跨平台类型别名
#if os(iOS)
typealias NSUIViewRepresentable = UIViewRepresentable
#elseif os(macOS)
typealias NSUIViewRepresentable = NSViewRepresentable
#endif

// MARK: - 预览
#Preview {
    WebView(url: URL(string: "https://example.com")!, onLoadComplete: nil)
}
