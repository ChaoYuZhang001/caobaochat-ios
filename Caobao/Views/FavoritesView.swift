//
//  FavoritesView.swift
//  Caobao
//
//  Compatibility entry point for the legacy favorites route.
//
//  The production v2 contract does not expose the old online favorites
//  endpoints. Keep this view as a safe wrapper so an older navigation route
//  cannot resurrect a request that will always return 404. The canonical
//  experience is the owner-scoped local quote store shared with QuoteView.
//

import SwiftUI

struct FavoritesView: View {
    var body: some View {
        NavigationStack {
            LocalQuoteFavoritesView()
        }
    }
}

#Preview {
    FavoritesView()
}
