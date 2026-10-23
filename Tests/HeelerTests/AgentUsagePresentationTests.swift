import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage presentation", .serialized)
struct AgentUsagePresentationTests {
    @Test func hostStatesRenderAtStandardAndAccessibleSizes() throws {
        let states: [(String, AgentUsageStore.State)] = [
            ("old-plugin", .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
            ("windows", .unsupportedPlatform),
            ("runtime-missing", .runtimeMissing),
            ("no-data", .available(try AgentUsageFixture.report())),
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
