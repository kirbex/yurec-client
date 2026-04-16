import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProfilesTabView()
                .tabItem {
                    Label("Profiles", systemImage: "doc.text")
                }

            GeneralTabView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }
}
