import MapKit
import SwiftUI
import UIKit

/// Cached map snapshots for the history list (`thumb.png` in the trip folder). Disk reads,
/// drawing and PNG encoding run off the main actor (`@concurrent`, so they do not inherit the
/// caller's main actor); decoded images stay in a memory cache.
nonisolated enum Thumbnails {
    static let size = CGSize(width: 72, height: 72)
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    /// Memory cache first, then the file, else renders from the trip's preview line. Light and dark
    /// are kept apart (`thumb-light.png`, `thumb.png`): the thumbnail follows the map style.
    @concurrent static func image(for record: TripRecord, store: TripStore, light: Bool) async -> UIImage? {
        let key = "\(record.id.uuidString)-\(light ? "light" : "dark")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = store.thumbURL(record.id, light: light)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            let ready = await image.byPreparingForDisplay() ?? image
            cache.setObject(ready, forKey: key)
            return ready
        }
        guard let lines = record.preview, !lines.isEmpty, !record.isRecording else { return nil }
        guard let image = await render(lines: lines, light: light) else { return nil }
        if let png = image.pngData() {
            try? png.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        cache.setObject(image, forKey: key)
        return image
    }

    @concurrent static func render(lines: [[LatLon]], light: Bool = false) async -> UIImage? {
        let all = lines.flatMap { $0 }
        guard let first = all.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in all {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        // Square frame around the track with generous padding (longitude scaled by latitude).
        let midLat = (minLat + maxLat) / 2
        let lonScale = max(0.2, cos(midLat * .pi / 180))
        let side = max(0.006, max(maxLat - minLat, (maxLon - minLon) * lonScale) * 1.7)
        let span = MKCoordinateSpan(latitudeDelta: side, longitudeDelta: side / lonScale)
        let center = CLLocationCoordinate2D(latitude: midLat, longitude: (minLon + maxLon) / 2)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        // Rendered on a canvas three times the thumbnail at 1x, so place labels come out at a third
        // of their usual size instead of filling the tiny tile.
        options.size = CGSize(width: size.width * 3, height: size.height * 3)
        options.traitCollection = await MainActor.run {
            UITraitCollection { traits in
                traits.userInterfaceStyle = light ? .light : .dark
                traits.displayScale = 1
            }
        }
        options.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: light ? .default : .muted)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 3
            return f
        }())
        let shrink = size.width / options.size.width
        return renderer.image { ctx in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for line in lines where line.count >= 2 {
                let path = UIBezierPath()
                for (k, p) in line.enumerated() {
                    let raw = snapshot.point(for: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    let pt = CGPoint(x: raw.x * shrink, y: raw.y * shrink)
                    if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                if light {
                    // On the light map: the casing and the deeper accent, as on the live map.
                    Theme.rgb(0x3A3D42).setStroke()
                    path.lineWidth = 4
                    path.stroke()
                    Theme.rgb(0x1A5FC0).setStroke()
                    path.lineWidth = 2.2
                    path.stroke()
                } else {
                    // The accent and its light tint (Theme.accent, Theme.accentLight).
                    UIColor(red: 0x1C / 255, green: 0x69 / 255, blue: 0xD4 / 255, alpha: 0.35).setStroke()
                    path.lineWidth = 5
                    path.stroke()
                    UIColor(red: 0x6F / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1).setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
            }
        }
    }
}

/// A trip's thumbnail with a calm placeholder while it renders.
struct TripThumbnail: View {
    var record: TripRecord
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: record.isRecording ? "record.circle" : "map")
                    .font(.system(size: 18))
                    .foregroundStyle(record.isRecording ? Theme.Status.bad : Theme.Text.tertiary)
            }
        }
        .frame(width: Thumbnails.size.width, height: Thumbnails.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .task(id: "\(record.id)-\(scheme == .light)") {
            let loaded = await Thumbnails.image(for: record, store: model.store, light: scheme == .light)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
