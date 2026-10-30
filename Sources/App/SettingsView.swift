import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Sections are arranged in the menu bar itself (Cmd-drag), so Settings only
/// holds behaviour, permission status and warnings.
struct SettingsView: View {
    let sections: SectionController
    @Bindable var preferences: Preferences
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var spacing = MenuBarSpacing()
    @State private var spacingMessage: String?
    @State private var spacingError: String?

    @State private var spacingBusy = false
    @State private var pendingSpacing: PendingSpacing?
    private let relauncher = MenuBarAppRelauncher()

    private struct PendingSpacing {
        let reset: Bool
        let targets: [MenuBarAppRelauncher.Target]
    }

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !sections.isAvailable {
                Section {
                    Label("Le masquage nécessite macOS 27 : l’API de MenuBarAgent est introuvable.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if !axTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Autorisation requise", systemImage: "hand.raised.fill").font(.headline)
                        Text("Réglages Système → Confidentialité et sécurité → Contrôle de l’appareil et accès aux données (« Accessibilité » avant macOS 27) : active BetterBar. Sans elle, les clics et le ⌘-glisser ne sont pas reconnus.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Ouvrir les Réglages Système") {
                            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }

            if !unidentifiable.isEmpty {
                Section {
                    ForEach(unidentifiable) { app in
                        HStack {
                            Image(nsImage: app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .application))
                                .resizable().frame(width: 20, height: 20)
                            Text(app.name)
                            Spacer()
                            if let path = app.bundlePath {
                                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                } header: {
                    Label("Apps que macOS ne peut pas identifier", systemImage: "exclamationmark.triangle.fill")
                } footer: {
                    Text("Elles tournent hors de /Applications : macOS 27 masque leurs icônes dès qu’une autre app est masquée. Installe-les dans /Applications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Apparence") {
                Picker("Séparateur des sections", selection: $preferences.separatorStyle) {
                    Text("‹").accessibilityLabel("Chevron gauche").tag(SeparatorStyle.chevron)
                    Text("•").accessibilityLabel("Point").tag(SeparatorStyle.dot)
                    Text("espace").tag(SeparatorStyle.space)
                }
                .pickerStyle(.segmented)
            }

            Section("Comportement") {
                Toggle("Masquer automatiquement quand la souris quitte la barre", isOn: $preferences.autoHideEnabled)
                if preferences.autoHideEnabled {
                    Stepper(value: $preferences.autoHideDelay, in: 1...60, step: 1) {
                        Text("Après \(Int(preferences.autoHideDelay)) s")
                    }
                }
                Toggle("Ouvrir à la connexion", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }

            Section {
                HStack {
                    Text("Espacement des icônes")
                    Spacer()
                    Text(spacing.value == MenuBarSpacing.appleValue
                         ? "Standard Apple"
                         : String(format: "%+.0f", spacing.value - MenuBarSpacing.appleValue))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Text("Réduit").fixedSize()
                    Slider(value: $spacing.value, in: MenuBarSpacing.range, step: 1)
                        .labelsHidden()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Espacement des icônes")
                        .accessibilityValue(spacing.value == MenuBarSpacing.appleValue
                                            ? "Standard Apple"
                                            : String(format: "%+.0f", spacing.value - MenuBarSpacing.appleValue))
                    Text("Augmenté").fixedSize()
                }
                HStack {
                    Button("Réinitialiser") { requestSpacing(reset: true) }
                        .disabled(!spacing.hasOverride && !spacing.hasChanges)
                    Spacer()
                    Button("Appliquer") { requestSpacing(reset: false) }
                }
                if spacingBusy {
                    ProgressView("Application de l’espacement…").controlSize(.small)
                }
                if let spacingError {
                    Text(spacingError).font(.callout).foregroundStyle(.red)
                } else if let spacingMessage {
                    Text(spacingMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Barre des menus")
            } footer: {
                Text("Réglage global. La relance actualise les icônes des apps concernées après confirmation. Les éléments Apple seront actualisés lors de ta prochaine connexion. Réinitialiser restaure les valeurs Apple.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(spacingBusy || pendingSpacing != nil)
            .onChange(of: spacing.value) { _, _ in
                if spacing.hasChanges {
                    spacingMessage = nil
                    spacingError = nil
                }
            }

        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .onReceive(poll) { _ in
            axTrusted = AXIsProcessTrusted()
            sections.refresh()
        }
        .onAppear { sections.refresh() }
        .alert("Quand appliquer l’espacement ?", isPresented: Binding(
            get: { pendingSpacing != nil },
            set: { if !$0 { pendingSpacing = nil } }
        ), presenting: pendingSpacing) { pending in
            Button("Annuler", role: .cancel) { pendingSpacing = nil }
            Button("Attendre leur prochain lancement") {
                pendingSpacing = nil
                applySpacing(reset: pending.reset, targets: [])
            }
            Button("Relancer les apps maintenant", role: .destructive) {
                pendingSpacing = nil
                applySpacing(reset: pending.reset, targets: pending.targets)
            }
        } message: { pending in
            Text("Apps concernées : \(pending.targets.isEmpty ? "aucune" : pending.targets.map(\.name).joined(separator: ", ")).\n\nEnregistre ton travail avant de continuer. Une app qui refuse de quitter restera ouverte.")
        }
    }

    private var unidentifiable: [MenuBarApp] { sections.apps.filter { !$0.isIdentifiable } }

    private func requestSpacing(reset: Bool) {
        guard !spacingBusy, pendingSpacing == nil else { return }
        spacingError = nil
        spacingMessage = nil
        spacingBusy = true
        Task { @MainActor in
            let targets = await relauncher.targets()
            spacingBusy = false
            pendingSpacing = PendingSpacing(reset: reset, targets: targets)
        }
    }

    private func applySpacing(reset: Bool, targets: [MenuBarAppRelauncher.Target]) {
        do {
            if reset { try spacing.reset() } else { try spacing.apply() }
        } catch {
            spacingMessage = nil
            spacingError = error.localizedDescription
            return
        }
        guard !targets.isEmpty else {
            spacingMessage = "Espacement enregistré. Il prendra effet au prochain lancement des apps concernées."
            return
        }
        spacingBusy = true
        Task { @MainActor in
            let failed = await relauncher.relaunch(targets)
            spacingBusy = false
            sections.refresh()
            if failed.isEmpty {
                spacingMessage = "Espacement appliqué. Les apps concernées ont été relancées."
            } else {
                spacingMessage = "Espacement enregistré."
                spacingError = "Relance non effectuée pour : \(failed.joined(separator: ", ")). Leur espacement sera actualisé à leur prochain lancement."
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
