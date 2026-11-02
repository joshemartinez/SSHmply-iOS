import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    private let scrollbackOptions = [1000, 5000, 10000, 50000]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: store.t("settingsTitle")) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(store.t("settingsAppearance")) {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: store.t("settingsTheme"))
                            Picker("", selection: $store.settings.appTheme) {
                                Text(store.t("themeSystem")).tag(ThemeChoice.system)
                                Text(store.t("themeLight")).tag(ThemeChoice.light)
                                Text(store.t("themeDark")).tag(ThemeChoice.dark)
                                Text(store.t("themeOled")).tag(ThemeChoice.oled)
                            }
                            .pickerStyle(.segmented)
                        }
                        divider
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: store.t("settingsLanguage"))
                            Menu {
                                ForEach(Language.allCases, id: \.self) { l in
                                    Button { store.settings.language = l } label: {
                                        if l == store.settings.language { Label(l.displayName, systemImage: "checkmark") } else { Text(l.displayName) }
                                    }
                                }
                            } label: {
                                menuLabel(store.settings.language.displayName)
                            }
                        }
                    }

                    section(store.t("settingsTerminal")) {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: store.t("fontFamily"))
                            Menu {
                                ForEach(TerminalFont.allCases, id: \.self) { f in
                                    Button { store.settings.fontFamily = f } label: {
                                        if f == store.settings.fontFamily { Label(f.rawValue, systemImage: "checkmark") } else { Text(f.rawValue) }
                                    }
                                }
                            } label: {
                                menuLabel(store.settings.fontFamily.rawValue)
                            }
                        }
                        divider
                        HStack {
                            Text(store.t("fontSize")).foregroundColor(store.pal.textPrimary)
                            Spacer()
                            Stepper("\(store.settings.fontSize) pt", value: $store.settings.fontSize, in: 8...28)
                                .fixedSize()
                                .foregroundColor(store.pal.textSecondary)
                        }
                        divider
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: store.t("cursorStyle"))
                            Picker("", selection: $store.settings.cursorStyle) {
                                Text(store.t("cursorBlock")).tag(CursorShape.block)
                                Text(store.t("cursorUnderline")).tag(CursorShape.underline)
                                Text(store.t("cursorBar")).tag(CursorShape.bar)
                            }
                            .pickerStyle(.segmented)
                        }
                        divider
                        Toggle(store.t("cursorBlink"), isOn: $store.settings.cursorBlink)
                            .foregroundColor(store.pal.textPrimary)
                        divider
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(text: store.t("scrollback"))
                            Picker("", selection: $store.settings.scrollback) {
                                ForEach(scrollbackOptions, id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    section(store.t("settingsMonitoring")) {
                        Toggle(isOn: $store.settings.enableServerMonitoring) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("monitoringTitle")).foregroundColor(store.pal.textPrimary)
                                Text(store.t("monitoringDescIos")).font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
                            }
                        }
                    }

                    section(store.t("settingsAbout")) {
                        HStack {
                            Text("SSHmply").font(.system(size: 17, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                            Spacer()
                            Text("\(store.t("version")) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                                .foregroundColor(store.pal.textTertiary)
                        }
                        Text(store.t("aboutDesc")).font(.system(size: 13)).foregroundColor(store.pal.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(store.pal.border).frame(height: 1)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text).foregroundColor(store.pal.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(store.pal.input)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(store.pal.textSecondary).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }
}
