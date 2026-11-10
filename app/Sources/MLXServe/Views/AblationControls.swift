import SwiftUI

/// The menu bar's Ablation control on the resident chat model's row: one capsule (switch, a profile menu holding the
/// cache toggle, strength) and the server's sentence when the setting cannot run. An edit writes only the model's
/// `ablation` key, which the server applies from the next request.
struct AblationMenuBarControl: View {
    /// The model's `model-settings.json` key; nil when the app does not know the resident model's folder.
    let modelPath: String?
    let modelId: String
    let profiles: [AblationProfile]
    let status: AblationStatus?
    @State private var setting: AblationSetting?
    @State private var failure: String?

    var body: some View {
        let control = AblationControl(profiles: profiles, setting: setting, status: status, modelId: modelId)
        VStack(alignment: .leading, spacing: 3) {
            if control.showsControls, modelPath != nil {
                capsule(control)
            }
            if let message = failure ?? control.error {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: message)
                        .font(.app(.caption2))
                        .foregroundStyle(failure == nil ? Color.orange : Color.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The way out when the controls cannot fix it (no profile fits any more).
                    if control.error != nil, modelPath != nil {
                        Button { write(nil) } label: {
                            Image(systemName: "xmark.circle").font(.app(.caption2))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove this model's ablation setting")
                    }
                }
            }
        }
        .onAppear(perform: reload)
        // Another app or the Model Settings sheet may have written the file.
        .onChange(of: status) { _, _ in reload() }
        .onChange(of: modelPath) { _, _ in reload() }
    }

    private func capsule(_ c: AblationControl) -> some View {
        HStack(spacing: 4) {
            Toggle(isOn: Binding(get: { c.isOn }, set: { write(c.turnedOn($0)) })) {
                Text("Ablation").font(.app(.caption2).weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            Menu {
                Picker(selection: Binding(get: { c.profile }, set: { write(c.choosing($0)) })) {
                    ForEach(c.choices, id: \.self) { Text(verbatim: $0).tag($0) }
                } label: {
                    Text("Profile")
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reuse prefix cache", isOn: Binding(get: { c.reusesPrefixCache },
                                                           set: { write(c.reusingPrefixCache($0)) }))
            } label: {
                Text(verbatim: AblationControl.menuTitle(c.profile)).font(.app(.caption2))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(c.profile)
            AblationStrengthField(strength: c.strength, maxStrength: c.maxStrength) { write(c.withStrength($0)) }
                .textFieldStyle(.plain)
                .font(.app(.caption2).monospaced())
                .frame(width: 32)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .foregroundStyle(c.isOn ? Color.orange : Color.secondary)
        .background((c.isOn ? Color.orange : Color.secondary).opacity(0.15))
        .clipShape(Capsule())
        .help("Applies to every request to this model, from any app. Profiles in ~/.mlx-serve/ablation load when the server starts.")
    }

    private func reload() {
        setting = modelPath.flatMap { ModelSettingsFile.load().override(for: $0)?.ablation }
    }

    private func write(_ new: AblationSetting?) {
        guard let modelPath else { return }
        var file = ModelSettingsFile.load()
        file.setAblation(new, for: modelPath)
        do {
            try file.save()
            setting = new
            failure = nil
        } catch {
            failure = "Could not write model-settings.json: \(error.localizedDescription)"
        }
    }
}

/// Model Settings' Ablation rows. Edits stay in the sheet until Save, which keeps the per-request plan (no reload).
struct AblationSection: View {
    @Binding var setting: AblationSetting?
    let profiles: [AblationProfile]
    let status: AblationStatus?
    let modelId: String

    var body: some View {
        let c = AblationControl(profiles: profiles, setting: setting, status: status, modelId: modelId)
        Section("Ablation") {
            Toggle("Enabled", isOn: Binding(get: { c.isOn }, set: { setting = c.turnedOn($0) }))
            Picker("Profile", selection: Binding(get: { c.profile }, set: { setting = c.choosing($0) })) {
                ForEach(c.choices, id: \.self) { Text(verbatim: $0).font(.app(.body)).tag($0) }
            }
            LabeledContent("Strength") {
                // The sheet saves as a whole, so a typed value lands without Return.
                AblationStrengthField(strength: c.strength, maxStrength: c.maxStrength, commitsWhileTyping: true) { setting = c.withStrength($0) }
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.body).monospacedDigit())
                    .frame(width: 60)
            }
            Toggle("Reuse prefix cache", isOn: Binding(get: { c.reusesPrefixCache }, set: { setting = c.reusingPrefixCache($0) }))
            if let error = c.error {
                Text(verbatim: error).font(.app(.caption)).foregroundStyle(.orange)
            }
            Text("Applies to every request to this model, from any app. Profiles in ~/.mlx-serve/ablation load when the server starts.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }
}

/// The strength box: a value the server would refuse turns red and is never committed. The menu bar commits on
/// Return or when the box loses focus, since every commit writes the file.
struct AblationStrengthField: View {
    let strength: Double
    /// The profile's measured ceiling (`AblationProfile.maxStrength`), which the server enforces too.
    var maxStrength: Double = AblationControl.maxStrength
    var commitsWhileTyping = false
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .foregroundStyle(AblationControl.parseStrength(text, max: maxStrength) == nil ? Color.red : Color.primary)
            .onSubmit(send)
            .onChange(of: text) { _, _ in if commitsWhileTyping { send() } }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                if AblationControl.parseStrength(text, max: maxStrength) == nil { text = AblationControl.format(strength) } else { send() }
            }
            .onChange(of: strength) { _, value in if !focused { text = AblationControl.format(value) } }
            .onAppear { text = AblationControl.format(strength) }
            .help("Strength from 0 to \(AblationControl.format(maxStrength)); 0 is off. The profile's manifest bounds it.")
    }

    private func send() {
        if let value = AblationControl.parseStrength(text, max: maxStrength), value != strength { commit(value) }
    }
}
