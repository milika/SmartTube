import SwiftUI

// MARK: - RootView
//
// Entry point that decides whether to show the main tab UI or the
// sign-in screen.  On macOS it uses a sidebar-based navigation.

public struct RootView: View {
    @Environment(AuthService.self) private var auth

    public init() {}

    public var body: some View {
        Group {
            #if os(macOS)
            MainSidebarView()
            #else
            MainTabView()
            #endif
        }
        .sheet(isPresented: .constant(!auth.isSignedIn && requiresAuth)) {
            // Sign-in prompt is shown as a dismissible sheet so users
            // can still browse without being signed in.
            SignInView()
        }
    }

    private var requiresAuth: Bool { false }   // guest browsing is allowed
}

// MARK: - AppSection

enum AppSection: String, CaseIterable, Identifiable {
    case home      = "Home"
    case search    = "Search"
    case library   = "Library"
    case settings  = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home:     return AppSymbol.home
        case .search:   return AppSymbol.search
        case .library:  return AppSymbol.library
        case .settings: return AppSymbol.settings
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .home:     HomeView()
        case .search:   SearchView()
        case .library:  LibraryView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - MainTabView  (iOS / iPadOS)

struct MainTabView: View {
    @State private var searchVM = SearchViewModel()

    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination }
                    .tabItem { Label(section.rawValue, systemImage: section.icon) }
            }
        }
        .environment(searchVM)
    }
}

// MARK: - MainSidebarView  (macOS)

struct MainSidebarView: View {
    @Environment(AuthService.self) private var auth
    @State private var searchVM = SearchViewModel()

    @State private var selectedSection: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("SmartTube")
            if auth.isSignedIn {
                Divider()
                HStack {
                    AsyncImage(url: auth.accountAvatarURL) { img in img.resizable() } placeholder: { Color.gray }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                    Text(auth.accountName ?? "Account")
                        .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        } detail: {
            NavigationStack { (selectedSection ?? .home).destination }
        }
        .environment(searchVM)
    }
}
