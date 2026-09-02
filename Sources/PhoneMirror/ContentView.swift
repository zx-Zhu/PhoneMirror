import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = MirrorStore()
    @State private var showHelp = false
    @State private var showSchemaLauncher = false
    @State private var showExperimentEditor = false
    @State private var showDeviceCommand = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 252, maxWidth: 290)
            workspace
                .frame(minWidth: 500)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 800, minHeight: 620)
        .task { store.start() }
        .background(WindowConfigurator(alwaysOnTop: store.alwaysOnTop))
        .sheet(isPresented: $showHelp) {
            HelpView(hdcPath: store.hdcPath, adbPath: store.adbPath, iosPath: store.iosPath)
        }
        .sheet(isPresented: $showSchemaLauncher) {
            SchemaLauncherView(store: store)
        }
        .sheet(isPresented: $showExperimentEditor) {
            ExperimentEditorView(store: store)
        }
        .sheet(isPresented: $showDeviceCommand) {
            DeviceCommandView(store: store)
        }
        .onChange(of: store.alwaysOnTop) { value in
            NSApp.keyWindow?.level = value ? .floating : .normal
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.refreshIOSPermissionAfterActivation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.shutdown()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PhoneMirror")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("手机桌面投屏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)

            HStack {
                Text("设备")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refreshDevices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新设备")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 7)

            if store.devices.isEmpty {
                EmptyDeviceView(showHelp: $showHelp)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.devices) { device in
                            DeviceRow(
                                device: device,
                                isSelected: device.id == store.selectedDeviceID,
                                action: {
                                    guard device.state.isConnected else { return }
                                    Task { await store.selectDevice(device.id) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label(store.availableToolsLabel, systemImage: "cable.connector")
                Text("Android、HarmonyOS 与 iOS。画面仅在设备链路与本机处理。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                LinearGradient(
                    colors: [Color(nsColor: .underPageBackgroundColor), Color.black.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if store.hasDisplaySurface {
                    MirrorStage(
                        store: store,
                        showHelp: $showHelp,
                        showSchemaLauncher: $showSchemaLauncher,
                        showExperimentEditor: $showExperimentEditor
                    )
                } else {
                    WelcomeView(
                        state: store.state,
                        toolAvailable: store.hdcPath != nil || store.adbPath != nil || store.iosPath != nil,
                        hasDevice: store.selectedDeviceID != nil,
                        isIOSDevice: store.selectedPlatform == .ios,
                        startAction: store.toggleStreaming,
                        helpAction: { showHelp = true },
                        showIOSPermissionAction: store.selectedPlatform == .ios
                            && store.iosCameraPermissionNeedsSettings,
                        iosPermissionAction: store.requestIOSCameraPermission
                    )
                }

                if case .failed(let message) = store.state, store.hasDisplaySurface {
                    VStack {
                        StatusBanner(icon: "exclamationmark.triangle.fill", text: message, color: .orange)
                            .padding(.top, 18)
                        Spacer()
                    }
                } else if store.state == .paused, store.hasDisplaySurface {
                    VStack {
                        StatusBanner(icon: "pause.fill", text: "画面已暂停", color: .secondary)
                            .padding(.top, 18)
                        Spacer()
                    }
                }

                if let clipboardMessage = store.clipboardMessage {
                    VStack {
                        Spacer()
                        StatusBanner(icon: "doc.on.clipboard.fill", text: clipboardMessage, color: .primary)
                            .padding(.bottom, 18)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedDevice == nil ? "等待设备" : store.details.model)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(store.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if store.selectedPlatform == .ios {
                    Label("只读投屏", systemImage: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondary)
                } else if let platform = store.selectedPlatform {
                    Label(platform == .android ? "拖入 APK 可安装并启动" : "拖入 HAP 可安装并启动",
                          systemImage: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(minWidth: 150, alignment: .leading)

            Spacer()

            if store.selectedDeviceID != nil {
                Picker("清晰度", selection: $store.quality) {
                    ForEach(StreamQuality.allCases) { quality in Text(quality.title).tag(quality) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 92)
            }

            Button { showDeviceCommand = true } label: {
                Label("指令", systemImage: "terminal")
                    .frame(height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(!store.canRunDeviceCommand)
            .help("自定义 ADB / HDC 指令")

            Button { showHelp = true } label: {
                Label("帮助", systemImage: "questionmark.circle")
                    .frame(height: 30)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(.bar)
    }

    private var statusColor: Color {
        switch store.state {
        case .streaming: return .green
        case .connecting: return .yellow
        case .failed: return .orange
        case .idle, .paused: return .secondary
        }
    }
}

private struct MirrorStage: View {
    @ObservedObject var store: MirrorStore
    @Binding var showHelp: Bool
    @Binding var showSchemaLauncher: Bool
    @Binding var showExperimentEditor: Bool
    @State private var isPackageDropTargeted = false

    var body: some View {
        GeometryReader { proxy in
            let contentSize = store.image?.size ?? store.displaySize
            let layout = MirrorStageLayout.calculate(container: proxy.size, contentSize: contentSize)

            HStack(spacing: 18) {
                Group {
                    if store.usesH264Stream {
                        H264MirrorCanvas(store: store)
                    } else if store.usesIOSCapture {
                        IOSMirrorCanvas(store: store)
                    } else {
                        MirrorCanvas(store: store)
                    }
                }
                    .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(isPackageDropTargeted ? Color.accentColor : .white.opacity(0.16),
                                        lineWidth: isPackageDropTargeted ? 3 : 1)
                            if let message = packageOverlayMessage {
                                VStack(spacing: 10) {
                                    if store.packageInstallState.isInstalling {
                                        ProgressView().controlSize(.large)
                                    } else {
                                        Image(systemName: packageOverlaySymbol)
                                            .font(.system(size: 34, weight: .semibold))
                                    }
                                    Text(message)
                                        .font(.headline)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(20)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 15))
                                .padding(18)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                    .shadow(color: .black.opacity(0.42), radius: 26, y: 12)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard store.acceptsPackageDrop, let url = urls.first else { return false }
                        store.installPackage(at: url)
                        return true
                    } isTargeted: { targeted in
                        isPackageDropTargeted = targeted && store.acceptsPackageDrop
                    }

                MirrorControlRail(
                    store: store,
                    showHelp: $showHelp,
                    showSchemaLauncher: $showSchemaLauncher,
                    showExperimentEditor: $showExperimentEditor
                )
                    .frame(width: layout.railWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var packageOverlayMessage: String? {
        if isPackageDropTargeted {
            return store.selectedPlatform == .android ? "松开以安装 APK" : "松开以安装 HAP"
        }
        return store.packageInstallState.message
    }

    private var packageOverlaySymbol: String {
        if case .failed = store.packageInstallState { return "exclamationmark.triangle.fill" }
        if case .succeeded = store.packageInstallState { return "checkmark.circle.fill" }
        return "square.and.arrow.down"
    }
}

private struct MirrorControlRail: View {
    @ObservedObject var store: MirrorStore
    @Binding var showHelp: Bool
    @Binding var showSchemaLauncher: Bool
    @Binding var showExperimentEditor: Bool

    var body: some View {
        VStack(spacing: 6) {
            ControlButton(symbol: "chevron.backward", help: "返回（Esc / 右键）", enabled: store.selectedPlatform != .ios) { store.send(.namedKey("Back")) }
            ControlButton(symbol: "circle", help: "主页（鼠标中键）", enabled: store.selectedPlatform != .ios) { store.send(.namedKey("Home")) }
            ControlButton(symbol: "square.on.square", help: "多任务", enabled: store.selectedPlatform != .ios) { store.send(.keyCode(2210)) }
            ControlButton(symbol: "lock", help: "锁屏 / 电源", enabled: store.selectedPlatform != .ios) { store.send(.namedKey("Power")) }
            ControlButton(symbol: "link", help: "Schema 跳转", enabled: store.canLaunchSchema) {
                showSchemaLauncher = true
            }
            ControlButton(symbol: "switch.2", help: "实验 / Settings", enabled: store.canEditExperiments) {
                showExperimentEditor = true
            }

            RailDivider()

            ControlButton(
                symbol: store.isStreaming ? "pause.fill" : "play.fill",
                help: store.isStreaming ? "暂停画面" : "继续投屏",
                enabled: !(store.selectedPlatform == .ios && store.isSystemRecording)
            ) { store.toggleStreaming() }
            RecordingButton(store: store)
            ControlButton(symbol: "camera", help: "截图文件复制到剪贴板") { store.copyScreenshotToClipboard() }

            RailDivider()

            ControlButton(
                symbol: store.alwaysOnTop ? "pin.fill" : "pin",
                help: "窗口置顶",
                active: store.alwaysOnTop
            ) { store.alwaysOnTop.toggle() }
            ControlButton(symbol: "questionmark.circle", help: "连接帮助") { showHelp = true }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct DeviceCommandView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MirrorStore
    @State private var command = ""
    @State private var timeout = 30
    @State private var running = false
    @State private var execution: DeviceCommandExecution?
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设备指令").font(.title2.bold())
                    Text(deviceDescription).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("ADB / HDC 指令").font(.headline)
                    Spacer()
                    Picker("超时", selection: $timeout) {
                        Text("10 秒").tag(10)
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 92)
                }
                ZStack(alignment: .topLeading) {
                    if command.isEmpty {
                        Text(commandPlaceholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $command)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(2)
                        .focused($inputFocused)
                }
                .frame(minHeight: 105)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                Text("可粘贴完整命令或只输入子命令；PhoneMirror 会自动绑定当前设备。不会调用 Mac shell。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("实际执行") {
                Text(commandPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(previewError == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("输出").font(.headline)
                    Spacer()
                    if execution != nil {
                        Button("复制输出") { copyOutput() }
                            .buttonStyle(.borderless)
                    }
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(outputText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(outputColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(9)
                }
                .frame(minHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }

            HStack {
                Text("非交互式执行；持续日志等命令会在所选超时时间后结束。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") { command = ""; execution = nil; errorMessage = nil }
                    .disabled(running || (command.isEmpty && execution == nil && errorMessage == nil))
                Button("关闭") { dismiss() }
                Button { execute() } label: {
                    if running {
                        ProgressView().controlSize(.small).frame(minWidth: 58)
                    } else {
                        Text("执行").frame(minWidth: 58)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || previewError != nil || !store.canRunDeviceCommand)
            }
        }
        .padding(24)
        .frame(width: 760, height: 650)
        .onAppear { inputFocused = true }
        .onChange(of: command) { _ in errorMessage = nil }
        .onChange(of: store.selectedDeviceID) { _ in execution = nil; errorMessage = nil }
    }

    private var deviceDescription: String {
        guard let platform = store.selectedPlatform, let device = store.selectedDevice else {
            return "未选择设备"
        }
        return "\(store.details.model) · \(platform.title) · \(device.shortID)"
    }

    private var commandPlaceholder: String {
        store.selectedPlatform == .harmonyOS
            ? "例如：hdc shell param get const.product.model"
            : "例如：adb shell getprop ro.product.model"
    }

    private var parsedRequest: Result<DeviceCommandRequest, Error> {
        guard let platform = store.selectedPlatform else {
            return .failure(DeviceCommandError.malformed("未选择设备"))
        }
        return Result { try DeviceCommandRequest.parse(command, platform: platform) }
    }

    private var previewError: String? {
        if case .failure(let error) = parsedRequest { return error.localizedDescription }
        return nil
    }

    private var commandPreview: String {
        guard let platform = store.selectedPlatform, let device = store.selectedDevice else {
            return "未选择设备"
        }
        switch parsedRequest {
        case .success(let request):
            return DeviceCommandRequest.displayCommand(
                platform: platform, deviceID: device.serial, arguments: request.arguments
            )
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private var outputText: String {
        if let errorMessage { return errorMessage }
        if let execution { return execution.transcript }
        return "执行后将在这里显示 stdout、stderr、退出码和耗时。"
    }

    private var outputColor: Color {
        if errorMessage != nil || execution?.succeeded == false { return .orange }
        return execution == nil ? .secondary : .primary
    }

    private func execute() {
        guard !running, previewError == nil else { return }
        running = true
        execution = nil
        errorMessage = nil
        let input = command
        let commandTimeout = TimeInterval(timeout)
        Task {
            do {
                execution = try await store.runDeviceCommand(input, timeout: commandTimeout)
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }

    private func copyOutput() {
        guard let execution else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(execution.transcript, forType: .string)
    }
}

private struct SchemaLauncherView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MirrorStore
    @AppStorage("lastSchemaLink") private var schema = ""
    @State private var isLaunching = false
    @State private var result: SchemaLaunchResult?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schema 跳转").font(.title2.bold())
                    Text(deviceDescription).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("完整 Schema").font(.headline)
                ZStack(alignment: .topLeading) {
                    if schema.isEmpty {
                        Text("例如：app://page/path?key=value")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $schema)
                        .font(.system(size: 14, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 2)
                        .focused($isInputFocused)
                }
                .frame(minHeight: 96)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                Text("支持自定义协议和 HTTP(S) 链接，参数会原样发送到当前设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result {
                Label(resultMessage(result), systemImage: resultSymbol(result))
                    .font(.subheadline)
                    .foregroundStyle(resultColor(result))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button { launch() } label: {
                    if isLaunching {
                        ProgressView().controlSize(.small).frame(minWidth: 52)
                    } else {
                        Text("跳转").frame(minWidth: 52)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLaunching || SchemaLink.normalized(schema) == nil || !store.canLaunchSchema)
            }
        }
        .padding(26)
        .frame(width: 640)
        .onAppear { isInputFocused = true }
        .onChange(of: schema) { _ in result = nil }
    }

    private var deviceDescription: String {
        guard let platform = store.selectedPlatform else { return "未选择设备" }
        return "发送到 \(store.details.model) · \(platform.title)"
    }

    private func launch() {
        guard !isLaunching, SchemaLink.normalized(schema) != nil, store.canLaunchSchema else { return }
        isLaunching = true
        result = nil
        Task {
            result = await store.launchSchema(schema)
            isLaunching = false
        }
    }

    private func resultMessage(_ result: SchemaLaunchResult) -> String {
        switch result {
        case .succeeded(let message), .failed(let message): return message
        }
    }

    private func resultSymbol(_ result: SchemaLaunchResult) -> String {
        switch result {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func resultColor(_ result: SchemaLaunchResult) -> Color {
        switch result {
        case .succeeded: return .green
        case .failed: return .orange
        }
    }
}

private struct ExperimentEditorView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case experiments
        case settings

        var id: String { rawValue }
        var title: String { self == .experiments ? "实验" : "Settings" }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MirrorStore
    @AppStorage("androidExperimentPackage") private var androidPackage = "com.phoenix.read"
    @AppStorage("harmonyExperimentPackage") private var harmonyPackage = "com.dragon.read.next"
    @State private var mode: Mode = .experiments
    @State private var catalog: ExperimentCatalog?
    @State private var selection: String?
    @State private var search = ""
    @State private var draftKey = ""
    @State private var draftValue = ""
    @State private var valueType: ExperimentValueType = .json
    @State private var restart = true
    @State private var temporary = false
    @State private var busy = false
    @State private var message: (text: String, failed: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "switch.2")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("实验 / Settings").font(.title2.bold())
                    Text(platformDescription).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            HStack(spacing: 8) {
                Picker("配置类型", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(store.selectedPlatform != .android)
                TextField("应用包名", text: packageBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button { load() } label: {
                    if busy && catalog == nil { ProgressView().controlSize(.small) }
                    else { Label("读取\(mode.title)", systemImage: "arrow.clockwise") }
                }
                .disabled(busy || normalizedPackage == nil)
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("搜索\(mode.title) Key", text: $search)
                        .textFieldStyle(.roundedBorder)
                    List(filteredEntries, selection: $selection) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.key).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Spacer()
                                if entry.overridden && store.selectedPlatform == .android {
                                    Text("已覆盖").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text(entry.value.replacingOccurrences(of: "\n", with: " "))
                                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(entry.key)
                    }
                    Text(catalog?.summary ?? "读取后显示\(mode.title)列表")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 270, idealWidth: 310)

                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        TextField("\(mode.title) Key", text: $draftKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(store.selectedPlatform == .harmonyOS || mode == .settings)
                        Picker("类型", selection: $valueType) {
                            ForEach(ExperimentValueType.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 105)
                    }

                    ZStack(alignment: .topLeading) {
                        if draftValue.isEmpty {
                            Text("输入\(mode.title)值").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                        }
                        TextEditor(text: $draftValue)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden).padding(2)
                    }
                    .frame(minHeight: 235)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)) }

                    if let entry = selectedEntry, let vid = entry.vid {
                        Text("vid：\(vid)（写入时保留）").font(.caption).foregroundStyle(.secondary)
                    } else if store.selectedPlatform == .android, let server = selectedEntry?.serverValue {
                        Text("服务端值：\(server)").lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    }

                    if mode == .experiments {
                        HStack(spacing: 14) {
                            Toggle("写入后重启 App", isOn: $restart)
                                .disabled(temporary)
                            Toggle("仅当前运行", isOn: $temporary)
                                .onChange(of: temporary) { enabled in if enabled { restart = true } }
                            Spacer()
                        }
                        .toggleStyle(.checkbox)
                    }

                    if mode == .settings {
                        Label("仅修改 App 进程内存，不写 MMKV、不重启；退出 App 后自动失效。只展示同时经过 SsConfigMgr 的 Settings。", systemImage: "memorychip")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if store.selectedPlatform == .harmonyOS {
                        Label("通过 App 已有 DevTool/HDP 写入 common_abtest；只允许修改已有实验。重启后服务端刷新仍可能覆盖。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("仅支持 debuggable 包。写入前自动备份 MMKV，失败时自动回滚。", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let message {
                        Label(message.text, systemImage: message.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(message.failed ? Color.orange : Color.green)
                            .textSelection(.enabled)
                    }

                    HStack {
                        if mode == .experiments {
                            Button("恢复快照") { restore() }
                                .disabled(busy || catalog?.hasBackup != true)
                        }
                        if catalog?.canRemove == true, selectedEntry?.overridden == true {
                            Button("移除覆盖", role: .destructive) { remove() }.disabled(busy)
                        }
                        Spacer()
                        Button("格式化") { formatValue() }.disabled(busy || draftValue.isEmpty)
                        Button { save() } label: {
                            if busy { ProgressView().controlSize(.small).frame(minWidth: 62) }
                            else { Text("保存\(mode.title)").frame(minWidth: 76) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || normalizedPackage == nil)
                    }
                }
                .padding(.leading, 12)
                .frame(minWidth: 430)
            }
        }
        .padding(24)
        .frame(width: 900, height: 610)
        .onAppear { load() }
        .onChange(of: mode) { _ in resetAndLoad() }
        .onChange(of: selection) { key in select(key) }
        .onChange(of: store.selectedDeviceID) { _ in
            if store.selectedPlatform != .android { mode = .experiments }
            resetAndLoad()
        }
    }

    private var packageBinding: Binding<String> {
        store.selectedPlatform == .harmonyOS ? $harmonyPackage : $androidPackage
    }

    private var normalizedPackage: String? { ExperimentInput.normalizedPackage(packageBinding.wrappedValue) }
    private var platformDescription: String {
        guard let platform = store.selectedPlatform else { return "未选择设备" }
        return "\(store.details.model) · \(platform.title) · 零业务源码改动"
    }
    private var filteredEntries: [ExperimentEntry] {
        guard let entries = catalog?.entries else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.key.localizedCaseInsensitiveContains(query) }
    }
    private var selectedEntry: ExperimentEntry? { catalog?.entries.first(where: { $0.key == selection }) }

    private func select(_ key: String?) {
        guard let key, let entry = catalog?.entries.first(where: { $0.key == key }) else { return }
        draftKey = entry.key
        draftValue = entry.value
        valueType = ExperimentValueType.inferred(from: entry.value)
        message = nil
    }

    private func load(preferredKey: String? = nil) {
        guard !busy, let package = normalizedPackage else { return }
        busy = true; message = nil
        Task {
            do {
                let result = try await loadCatalog(package: package)
                catalog = result
                let target = preferredKey.flatMap { key in result.entries.contains(where: { $0.key == key }) ? key : nil }
                    ?? selection.flatMap { key in result.entries.contains(where: { $0.key == key }) ? key : nil }
                    ?? result.entries.first?.key
                selection = target
                select(target)
            } catch {
                catalog = nil
                message = (error.localizedDescription, true)
            }
            busy = false
        }
    }

    private func save() {
        guard !busy, let package = normalizedPackage else { return }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; message = nil
        Task {
            do {
                let result: String
                if mode == .settings {
                    result = try await store.setSetting(
                        packageID: package, key: key, value: draftValue, type: valueType
                    )
                } else {
                    result = try await store.setExperiment(
                        packageID: package, key: key, value: draftValue, type: valueType,
                        restart: restart, temporary: temporary
                    )
                }
                message = (result, false)
                catalog = try await loadCatalog(package: package)
                selection = key; select(key)
                message = (result, false)
            } catch { message = (error.localizedDescription, true) }
            busy = false
        }
    }

    private func remove() {
        guard !busy, let package = normalizedPackage, let key = selection else { return }
        busy = true; message = nil
        Task {
            do {
                let result: String
                if mode == .settings {
                    result = try await store.clearSetting(packageID: package, key: key)
                } else {
                    result = try await store.removeExperiment(packageID: package, key: key, restart: restart)
                }
                catalog = try await loadCatalog(package: package)
                selection = catalog?.entries.contains(where: { $0.key == key }) == true
                    ? key : catalog?.entries.first?.key
                select(selection)
                message = (result, false)
            } catch { message = (error.localizedDescription, true) }
            busy = false
        }
    }

    private func restore() {
        guard !busy, let package = normalizedPackage else { return }
        busy = true; message = nil
        Task {
            do {
                let result = try await store.restoreExperimentBackup(packageID: package, restart: restart)
                catalog = try await loadCatalog(package: package)
                selection = catalog?.entries.first?.key; select(selection)
                message = (result, false)
            } catch { message = (error.localizedDescription, true) }
            busy = false
        }
    }

    private func formatValue() {
        guard let object = try? valueType.jsonObject(from: draftValue),
              valueType == .json, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return }
        draftValue = value
    }

    private func loadCatalog(package: String) async throws -> ExperimentCatalog {
        mode == .settings
            ? try await store.loadSettings(packageID: package)
            : try await store.loadExperiments(packageID: package)
    }

    private func resetAndLoad() {
        catalog = nil
        selection = nil
        draftKey = ""
        draftValue = ""
        temporary = false
        load()
    }
}

private struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 30, height: 1)
            .padding(.vertical, 2)
    }
}

private struct RecordingButton: View {
    @ObservedObject var store: MirrorStore

    var body: some View {
        Button { store.toggleSystemRecording() } label: {
            VStack(spacing: 2) {
                Image(systemName: store.isSystemRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 18, weight: .medium))
                if store.isSystemRecording {
                    Text(store.recordingTimeLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(store.isSystemRecording ? Color.red : Color.primary)
            .frame(width: 44, height: store.isSystemRecording ? 48 : 44)
            .background(store.isSystemRecording ? Color.red.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!store.recordingState.canToggle)
        .help(recordingHelp)
    }

    private var recordingHelp: String {
        if store.selectedPlatform == .ios {
            return store.isSystemRecording ? "停止 Mac 端录制并复制 MOV 文件" : "录制 iPhone USB 画面"
        }
        return store.isSystemRecording ? "停止系统录屏并复制 MP4 文件" : "开始手机系统录屏"
    }
}

private struct DeviceRow: View {
    let device: MirrorDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? platformColor : Color.secondary.opacity(0.14))
                        .frame(width: 31, height: 42)
                    Image(systemName: device.platform.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.advertisedModel ?? device.shortID)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    Text(device.state.isConnected
                         ? "\(device.platform.title) · \(device.transport) · \(device.shortID)"
                         : "\(device.platform.title) · 离线")
                        .font(.caption)
                        .foregroundStyle(device.state.isConnected ? Color.secondary : Color.orange)
                }
                Spacer()
                Circle()
                    .fill(device.state.isConnected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .disabled(!device.state.isConnected)
    }

    private var platformColor: Color {
        switch device.platform {
        case .android: return .green
        case .harmonyOS: return .blue
        case .ios: return .indigo
        }
    }
}

private struct EmptyDeviceView: View {
    @Binding var showHelp: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.secondary)
            Text("未发现在线设备")
                .font(.subheadline.weight(.medium))
            Text("连接 USB，并在手机上允许调试")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("查看连接方法") { showHelp = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 25)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WelcomeView: View {
    let state: MirrorState
    let toolAvailable: Bool
    let hasDevice: Bool
    let isIOSDevice: Bool
    let startAction: () -> Void
    let helpAction: () -> Void
    let showIOSPermissionAction: Bool
    let iosPermissionAction: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 92, height: 92)
                Image(systemName: toolAvailable ? "iphone.gen3.radiowaves.left.and.right" : "wrench.and.screwdriver")
                    .font(.system(size: 39, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                if showIOSPermissionAction {
                    Button { iosPermissionAction() } label: {
                        Label("开启相机权限", systemImage: "camera.badge.ellipsis")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if hasDevice {
                    if showIOSPermissionAction {
                        Button(isIOSDevice ? "开始 iOS 只读投屏" : "开始投屏", action: startAction)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    } else {
                        Button(isIOSDevice ? "开始 iOS 只读投屏" : "开始投屏", action: startAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                Button("连接帮助", action: helpAction).buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(40)
    }

    private var title: String {
        if !toolAvailable { return "需要设备连接工具" }
        if case .failed = state { return "等待设备恢复" }
        return hasDevice ? "设备已就绪" : "连接手机"
    }

    private var subtitle: String {
        if !toolAvailable { return "Android 需要 ADB，HarmonyOS 需要 HDC，iOS 需要 libimobiledevice。" }
        if case .failed(let message) = state { return message }
        if hasDevice && isIOSDevice {
            return showIOSPermissionAction
                ? "macOS 已阻止 USB 屏幕采集，请前往相机权限设置开启；PhoneMirror 不使用麦克风。"
                : "使用 QuickTime USB 只读投屏。首次开始时 macOS 会申请一次相机权限，PhoneMirror 不使用麦克风。"
        }
        return hasDevice ? "点击开始后即可在 Mac 上查看手机。" : "使用 USB 数据线连接手机并完成调试或信任授权。"
    }
}

private struct StatusBanner: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(color)
            .shadow(radius: 8)
    }
}

private struct ControlButton: View {
    let symbol: String
    let help: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .background(active ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .help(help)
    }
}

private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    let hdcPath: String?
    let adbPath: String?
    let iosPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                AppMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接手机").font(.title2.bold())
                    Text("Android / HarmonyOS / iOS · USB 连接").foregroundStyle(.secondary)
                }
                Spacer()
            }

            StepRow(number: "1", title: "连接并授权", detail: "Android / HarmonyOS 开启 USB 调试；iPhone 解锁后点“信任此电脑”。")
            StepRow(number: "2", title: "按需允许画面采集", detail: "只有主动开始 iOS 投屏时才会请求一次 macOS 相机权限；它实际用于 USB 屏幕源。PhoneMirror 不请求麦克风权限。")
            StepRow(number: "3", title: "开始投屏", detail: "iOS 为只读投屏，不安装设备端 App，也不会向设备发送点击或手势。")

            GroupBox {
                HStack(alignment: .top) {
                    Image(systemName: hdcPath == nil && adbPath == nil && iosPath == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(hdcPath == nil && adbPath == nil && iosPath == nil ? .orange : .green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接工具").fontWeight(.medium)
                        Text("HDC：\(hdcPath ?? "未找到")\nADB：\(adbPath ?? "未找到")\niOS：\(iosPath ?? "未找到")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(4)
            }

            HStack {
                Text("提示：支付、密码、DRM 等受保护页面可能无法截取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
    }
}

private struct StepRow: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = alwaysOnTop ? .floating : .normal
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
        }
    }
}
