import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage presentation", .serialized)
struct AgentUsagePresentationTests {
    @Test func tokenUsageAndRefreshStatesRenderAtStandardAndAccessibleSizes() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("usage-496-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for refreshing in [false, true] {
            let report = try AgentUsageFixture.tokenReport(refreshing: refreshing)
            for accessible in [false, true] {
                let controller = UIHostingController(rootView:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Usage").font(.title2.bold())
                        AgentUsageContent(state: .available(report))
                    }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                controller.safeAreaRegions = []
                let size = controller.sizeThatFits(in: CGSize(width: 390, height: 5_000))
                let bounds = CGRect(origin: .zero, size: size)
                controller.view.frame = bounds
                let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
                }
                #expect(image.size.width == 390)
                let filename = "tokens-refreshing-\(refreshing)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
        }
    }

    @Test func hostStatesRenderAtStandardAndAccessibleSizes() throws {
        let states: [(String, AgentUsageStore.State)] = [
            ("old-plugin", .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
            ("windows", .unsupportedPlatform),
            ("runtime-missing", .runtimeMissing),
            ("no-data", .available(try AgentUsageFixture.noDataReport())),
            ("update", .updateRequired),
        ]
        let directory = URL.documentsDirectory.appendingPathComponent("usage-495-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, state) in states {
            var heights: [CGFloat] = []
            for accessible in [false, true] {
                let renderer = ImageRenderer(content:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Usage").font(.title2.bold())
                        AgentUsageContent(state: state)
                    }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                renderer.scale = 2
                let image = try #require(renderer.uiImage)
                #expect(image.size.width == 390)
                #expect(image.size.height > 60)
                heights.append(image.size.height)
                let filename = "\(name)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
            #expect(heights[1] > heights[0], "The full guidance must grow with Dynamic Type.")
        }
    }
}
