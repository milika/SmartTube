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

// MARK: - MainTabView  (iOS / iPadOS)

struct MainTabView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(SettingsStore.self) private var settingsStore
    @State private var searchVM = SearchViewModel()

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "square.stack.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environment(searchVM)
    }
}

// MARK: - MainSidebarView  (macOS)

struct MainSidebarView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(SettingsStore.self) private var settingsStore
    @State private var searchVM = SearchViewModel()

    @State private var selectedSection: AppSection? = .home

    enum AppSection: String, CaseIterable, Identifiable {
        case home      = "Home"
        case search    = "Search"
        case library   = "Library"
        case settings  = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home:     return "house.fill"
            case .search:   return "magnifyingglass"
            case .library:  return "square.stack.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

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
            switch selectedSection ?? .home {
            case .home:     NavigationStack { HomeView() }
            case .search:   NavigationStack { SearchView() }
            case .library:  NavigationStack { LibraryView() }
            case .settings: NavigationStack { SettingsView() }
            }
        }
        .environment(searchVM)
    }
}
