import AppKit
import WebKit

class VisualizationWindowManager {
    static let shared = VisualizationWindowManager()
    private var windows: [NSWindow] = []

    func openVisualization(code: String, title: String = "Pendragon Visualization") {
        DispatchQueue.main.async {
            self.createWindow(code: code, title: title)
        }
    }

    private func createWindow(code: String, title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 250)
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0)

        let config = WKWebViewConfiguration()

        let webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")

        let html = Self.buildHTML(code: code)
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))

        window.contentView?.addSubview(webView)
        window.makeKeyAndOrderFront(nil)

        // Clean up closed windows
        windows.removeAll { !$0.isVisible }
        windows.append(window)
    }

    private static func buildHTML(code: String) -> String {
        // JSON-encode the user code so it can be safely embedded as a JS string literal.
        let jsCodeLiteral: String
        if let data = try? JSONEncoder().encode(code),
           let str = String(data: data, encoding: .utf8) {
            jsCodeLiteral = str
        } else {
            jsCodeLiteral = "\"\""
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #1C1C1E;
                overflow: hidden;
                width: 100vw;
                height: 100vh;
            }
            canvas { display: block; }
            #loading {
                position: absolute;
                top: 50%; left: 50%;
                transform: translate(-50%, -50%);
                color: #888;
                font-family: -apple-system, system-ui, sans-serif;
                font-size: 14px;
            }
            #error-overlay {
                display: none;
                position: absolute;
                top: 0; left: 0; right: 0; bottom: 0;
                background: rgba(28, 28, 30, 0.95);
                color: #FF6B6B;
                font-family: ui-monospace, monospace;
                font-size: 13px;
                padding: 20px;
                white-space: pre-wrap;
                overflow: auto;
                z-index: 100;
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading Three.js...</div>
        <div id="error-overlay"></div>

        <script>
        function showError(text) {
            var l = document.getElementById('loading');
            if (l) l.style.display = 'none';
            var overlay = document.getElementById('error-overlay');
            overlay.style.display = 'block';
            overlay.textContent = text;
        }
        window.onerror = function(msg, url, line, col, error) {
            showError('Error: ' + msg + '\\nLine: ' + line);
            return true;
        };
        window.addEventListener('unhandledrejection', function(e) {
            showError('Error: ' + (e.reason && e.reason.message ? e.reason.message : e.reason));
        });
        </script>

        <!-- Modern Three.js is ES-modules only. Import map maps bare specifiers. -->
        <script type="importmap">
        {
            "imports": {
                "three": "https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js",
                "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/"
            }
        }
        </script>

        <script type="module">
        import * as THREE from 'three';
        import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

        // Expose globally so classic-style user code works
        window.THREE = THREE;
        window.OrbitControls = OrbitControls;

        document.getElementById('loading').style.display = 'none';

        // Auto-resize helper (camera/renderer become global once user code runs as a classic script)
        window.addEventListener('resize', function() {
            if (typeof window.camera !== 'undefined' && typeof window.renderer !== 'undefined') {
                window.camera.aspect = window.innerWidth / window.innerHeight;
                window.camera.updateProjectionMatrix();
                window.renderer.setSize(window.innerWidth, window.innerHeight);
            }
        });

        // Inject the user's code as a CLASSIC script so its top-level vars become
        // globals (so the resize handler above can see `camera`/`renderer`).
        var userCode = \(jsCodeLiteral);
        var s = document.createElement('script');
        s.textContent = userCode;
        document.body.appendChild(s);
        </script>
        </body>
        </html>
        """
    }
}
