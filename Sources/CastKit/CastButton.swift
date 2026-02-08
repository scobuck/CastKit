import SwiftUI

/// Traditional Google Cast icon drawn as a SwiftUI shape.
public struct CastIcon: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let lineW = w * 0.08

        // Screen outline: bottom-left corner up the left side, across the top, down the right, partial bottom
        path.move(to: CGPoint(x: 0, y: h * 0.82))
        path.addLine(to: CGPoint(x: 0, y: h * 0.12))
        path.addQuadCurve(to: CGPoint(x: w * 0.12, y: 0),
                          control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w * 0.88, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: h * 0.12),
                          control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.68))
        path.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.8),
                          control: CGPoint(x: w, y: h * 0.8))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.8))

        let screenPath = path.strokedPath(StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
        path = screenPath

        // Bottom-left dot
        let dotR = w * 0.06
        path.addEllipse(in: CGRect(x: -dotR, y: h - dotR, width: dotR * 2, height: dotR * 2))

        // Concentric arcs from bottom-left
        for i in 1...3 {
            let radius = CGFloat(i) * w * 0.16
            var arc = Path()
            arc.addArc(center: CGPoint(x: 0, y: h),
                       radius: radius,
                       startAngle: .degrees(-90),
                       endAngle: .degrees(0),
                       clockwise: false)
            let strokedArc = arc.strokedPath(StrokeStyle(lineWidth: lineW, lineCap: .round))
            path.addPath(strokedArc)
        }

        return path
    }
}

public struct CastButton: View {
    @EnvironmentObject var castManager: CastManager
    @State private var showDevicePicker = false

    public init() {}

    public var body: some View {
        Button(action: {
            showDevicePicker = true
        }) {
            CastIcon()
                .fill(castManager.isConnected ? Color.blue : Color.primary)
                .frame(width: 20, height: 16)
        }
        .sheet(isPresented: $showDevicePicker) {
            CastDevicePickerSheet()
                .environmentObject(castManager)
        }
    }
}

public struct CastDevicePickerSheet: View {
    @EnvironmentObject var castManager: CastManager
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if castManager.availableDevices.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for Cast devices…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(castManager.availableDevices, id: \.id) { device in
                        let isActive = castManager.isConnected && castManager.connectedDeviceName == device.name

                        Button(action: {
                            if isActive {
                                castManager.disconnect()
                            } else {
                                castManager.connect(to: device)
                            }
                            dismiss()
                        }) {
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "tv")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                            .foregroundColor(.primary)
                                        Text(device.modelName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if isActive {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }

                                if isActive {
                                    HStack(spacing: 8) {
                                        Image(systemName: "speaker.fill")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Slider(value: Binding(
                                            get: { castManager.castVolume },
                                            set: { castManager.setCastVolume($0) }
                                        ), in: 0...1)
                                        Image(systemName: "speaker.wave.3.fill")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 8)
                                    .onTapGesture { }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cast to Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            castManager.startScanning()
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
