#!/usr/bin/env swift
//
// Rasterizes an SVG to PNG at a given size using WebKit.
//
// Used to build the .icns from Resources/icon.svg so the icon stays a
// version-controlled vector source rather than a pile of binary PNGs.
//
// Usage: rasterize.swift <input.svg> <output.png> <size>
//
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let size = Int(arguments[3]) else {
    FileHandle.standardError.write(
        Data("usage: rasterize.swift <input.svg> <output.png> <size>\n".utf8)
    )
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let svg = try? String(contentsOf: inputURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

// A transparent page with the SVG scaled to fill it exactly.
let html = """
<!doctype html>
<html><head><meta charset="utf-8"><style>
  html,body { margin:0; padding:0; background:transparent; }
  svg { display:block; width:\(size)px; height:\(size)px; }
</style></head><body>\(svg)</body></html>
"""

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let size: Int
    let outputURL: URL

    init(size: Int, outputURL: URL) {
        self.size = size
        self.outputURL = outputURL
        let config = WKWebViewConfiguration()
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: size, height: size),
            configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A short delay lets WebKit finish laying out gradients before snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: self.size, height: self.size)
            self.webView.takeSnapshot(with: config) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    FileHandle.standardError.write(
                        Data("snapshot failed: \(error?.localizedDescription ?? "unknown")\n".utf8)
                    )
                    exit(1)
                }
                do {
                    try png.write(to: self.outputURL)
                } catch {
                    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                    exit(1)
                }
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let renderer = Renderer(size: size, outputURL: outputURL)
renderer.webView.loadHTMLString(html, baseURL: nil)
app.run()
