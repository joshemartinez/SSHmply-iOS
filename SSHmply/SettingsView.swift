import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    private let scrollbackOptions = [1000, 5000, 10000, 50000]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(store.t("settingsAppearance"))) {
                    Picker(selection: $store.settings.appTheme, label: Text(store.t("settingsTheme")).lineLimit(1)) {
                        Text(store.t("themeOled")).tag(ThemeChoice.oled)
                        Text(store.t("themeDark")).tag(ThemeChoice.dark)
                        Text(store.t("themeLight")).tag(ThemeChoice.light)
                        Text(store.t("themeSystem")).tag(ThemeChoice.system)
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $store.settings.language, label: Text(store.t("settingsLanguage")).lineLimit(1)) {
                        ForEach(Language.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .themedRow()

                Section(header: Text(store.t("settingsTerminal"))) {
                    Picker(selection: $store.settings.fontFamily, label: Text(store.t("fontFamily")).lineLimit(1)) {
                        ForEach(TerminalFont.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Stepper(value: $store.settings.fontSize, in: 8...28) {
                        HStack {
                            Text(store.t("fontSize")).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 6)
                            Text("\(store.settings.fontSize) pt").foregroundColor(.secondary)
                        }
                    }
                    Picker(selection: $store.settings.cursorStyle, label: Text(store.t("cursorStyle")).lineLimit(1)) {
                        Text(store.t("cursorBlock")).tag(CursorShape.block)
                        Text(store.t("cursorUnderline")).tag(CursorShape.underline)
                        Text(store.t("cursorBar")).tag(CursorShape.bar)
                    }
                    .pickerStyle(.menu)
                    Toggle(store.t("cursorBlink"), isOn: $store.settings.cursorBlink)
                    Picker(selection: $store.settings.scrollback, label: Text(store.t("scrollback")).lineLimit(1).minimumScaleFactor(0.8)) {
                        ForEach(scrollbackOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                .themedRow()

                Section(header: Text(store.t("settingsConnections")), footer: Text(store.t("keepAliveDesc") + "\n\n" + store.t("autoReconnectDesc"))) {
                    Toggle(store.t("keepAliveTitle"), isOn: $store.settings.keepAliveInBackground)
                    Toggle(store.t("autoReconnectTitle"), isOn: $store.settings.autoReconnect)
                }
                .themedRow()

                Section(header: Text(store.t("settingsMonitoring")), footer: Text(store.t("monitoringDescIos"))) {
                    Toggle(store.t("monitoringTitle"), isOn: $store.settings.enableServerMonitoring)
                }
                .themedRow()

                Section(header: Text(store.t("settingsAbout")), footer: Text(store.t("aboutDesc"))) {
                    HStack {
                        Text("SSHmply")
                        Spacer()
                        Text("\(store.t("version")) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                            .foregroundColor(.secondary)
                    }
                }
                .themedRow()
            }
            .hideListBackground()
            .background(store.pal.window.ignoresSafeArea())
            .navigationTitle(store.t("settingsTitle"))
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(.stack)
    }
}
