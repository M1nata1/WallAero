import Foundation

/// The folder of a scene wallpaper:
///
///     scene.json   – the scene itself; the editor reads and writes only this
///     index.html   – generated: the page the wallpaper window shows
///     runtime.js   – generated: turns scene.json into the page's elements
///     custom.css   – the user's own styles, loaded after the scene's
///     custom.js    – the user's own script, run after the scene is built
///     media/       – the background and the pictures the layers use
///
/// The generated files are rewritten whenever the app has a newer version of them, so scenes keep
/// up with the app; anything hand-made belongs in the custom files or in a code layer.
public enum SceneProject {
    public static let sceneFileName = "scene.json"
    public static let entryFileName = "index.html"
    public static let mediaFolderName = "media"

    public static func isScene(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(sceneFileName).path)
    }

    public static func read(from folder: URL) throws -> WallpaperScene {
        let data = try Data(contentsOf: folder.appendingPathComponent(sceneFileName))
        return try JSONDecoder().decode(WallpaperScene.self, from: data)
    }

    public static func write(_ scene: WallpaperScene, to folder: URL) throws {
        try encoded(scene, readable: true).write(to: folder.appendingPathComponent(sceneFileName), options: .atomic)
    }

    /// The scene as JSON: indented for the file, compact for handing to the page.
    public static func encoded(_ scene: WallpaperScene, readable: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = readable ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(scene)
    }

    /// Turns the folder into a scene: writes the scene and everything that draws it.
    public static func create(at folder: URL, scene: WallpaperScene) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(mediaFolderName),
                                                withIntermediateDirectories: true)
        try write(scene, to: folder)
        try refreshGeneratedFiles(in: folder)
    }

    /// Brings the generated files up to date and creates the custom ones if they are missing.
    /// Returns whether anything was written, which is when a page already open needs reloading.
    @discardableResult
    public static func refreshGeneratedFiles(in folder: URL) throws -> Bool {
        var changed = false
        for (name, content) in [(entryFileName, indexHTML), ("runtime.js", runtime)] {
            let url = folder.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) != content {
                try content.write(to: url, atomically: true, encoding: .utf8)
                changed = true
            }
        }
        for (name, content) in [("custom.css", customCSS), ("custom.js", customJS)] {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try content.write(to: url, atomically: true, encoding: .utf8)
                changed = true
            }
        }
        return changed
    }

    /// Copies a file into the scene's media folder and returns its path relative to the scene,
    /// ready to be a `source`. On APFS the copy is a clone and takes no extra space.
    public static func addMedia(_ file: URL, to folder: URL, named preferredName: String? = nil) throws -> String {
        let media = folder.appendingPathComponent(mediaFolderName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let fileExtension = file.pathExtension.lowercased()
        // The name ends up in a URL inside the page, so it is kept plain.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let raw = preferredName ?? file.deletingPathExtension().lastPathComponent
        var stem = String(raw.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if stem.isEmpty { stem = "file" }

        var name = fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
        var counter = 2
        while FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path) {
            name = fileExtension.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(fileExtension)"
            counter += 1
        }
        try FileManager.default.copyItem(at: file, to: media.appendingPathComponent(name))
        return "\(mediaFolderName)/\(name)"
    }

    // MARK: - Generated files

    static let customCSS = """
    /* Your own styles for this wallpaper. Loaded after the scene's, never overwritten by the app. */

    """

    static let customJS = """
    // Your own script for this wallpaper. Runs after the scene is built, never overwritten by the app.
    // The scene is rebuilt whenever it is edited; to react to that:
    //
    //     document.addEventListener('wallaero:scene', event => { /* event.detail is the scene */ });
    //
    // To follow the sound the Mac is playing — 64 bands of the left channel, then 64 of the right,
    // low notes first, each from 0 to 1:
    //
    //     window.wallpaperRegisterAudioListener(levels => { /* levels[0] … levels[127] */ });

    """

    static let indexHTML = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>WallAero Engine scene</title>
    <!-- Generated by WallAero Engine and rewritten when the app updates.
         Put your own code in custom.css and custom.js, or in a code layer. -->
    <style>
    html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
    body { font-family: -apple-system, "Helvetica Neue", sans-serif; cursor: default; -webkit-user-select: none; }
    #wallaero-background, #wallaero-layers { position: fixed; left: 0; top: 0; width: 100%; height: 100%; overflow: hidden; }
    .wallaero-media { position: absolute; display: block; }
    .wallaero-layer { position: absolute; box-sizing: border-box; }
    .wallaero-content { box-sizing: border-box; width: 100%; height: 100%; }
    .wallaero-text > .wallaero-content { white-space: pre-wrap; overflow-wrap: break-word; height: auto; }
    .wallaero-image > .wallaero-content { height: auto; }
    .wallaero-image img { display: block; width: 100%; height: auto; -webkit-user-drag: none; }
    @keyframes wallaero-pulse { 50% { transform: scale(1.06); } }
    @keyframes wallaero-float { 50% { transform: translateY(-1.5vh); } }
    @keyframes wallaero-spin { to { transform: rotate(360deg); } }
    @keyframes wallaero-blink { 50% { opacity: 0.25; } }
    </style>
    <link rel="stylesheet" href="custom.css">
    </head>
    <body>
    <div id="wallaero-background"></div>
    <div id="wallaero-layers"></div>
    <script src="runtime.js"></script>
    <script src="custom.js"></script>
    </body>
    </html>

    """#

    static let runtime = #"""
    // WallAero Engine scene runtime: turns scene.json into the page.
    // Generated and rewritten when the app updates; put your own code in custom.js.
    (function () {
      'use strict';

      var background = document.getElementById('wallaero-background');
      var layers = document.getElementById('wallaero-layers');
      var scene = null;
      var backgroundKey = null;
      var built = {}; // layer id -> { json, element }
      var clock = null;

      // A length given for a 1080-pixel-high screen, as a CSS length that follows the screen.
      function px(value) { return ((Number(value) || 0) / 10.8) + 'vh'; }
      function number(value, fallback) { return typeof value === 'number' && isFinite(value) ? value : fallback; }
      function pad(value) { return value < 10 ? '0' + value : '' + value; }

      var locale = navigator.language || 'en';
      var tokens = {
        HH: function (d) { return pad(d.getHours()); },
        H: function (d) { return '' + d.getHours(); },
        hh: function (d) { return pad(d.getHours() % 12 || 12); },
        h: function (d) { return '' + (d.getHours() % 12 || 12); },
        mm: function (d) { return pad(d.getMinutes()); },
        ss: function (d) { return pad(d.getSeconds()); },
        ampm: function (d) { return d.getHours() < 12 ? 'AM' : 'PM'; },
        weekday: function (d) { return d.toLocaleDateString(locale, { weekday: 'long' }); },
        // The day with its month, in the form the language needs: "7 октября", "October 7".
        date: function (d) { return d.toLocaleDateString(locale, { day: 'numeric', month: 'long' }); },
        day: function (d) { return '' + d.getDate(); },
        dd: function (d) { return pad(d.getDate()); },
        month: function (d) { return d.toLocaleDateString(locale, { month: 'long' }); },
        MM: function (d) { return pad(d.getMonth() + 1); },
        year: function (d) { return '' + d.getFullYear(); },
        yy: function (d) { return pad(d.getFullYear() % 100); }
      };

      function fillTokens(text, now) {
        return String(text || '').replace(/\{(\w+)\}/g, function (whole, name) {
          return Object.prototype.hasOwnProperty.call(tokens, name) ? tokens[name](now) : whole;
        });
      }

      function hasTokens(text) {
        return /\{(\w+)\}/.test(text || '') && fillTokens(text, new Date(0)) !== text;
      }

      var genericFamilies = ['-apple-system', 'system-ui', 'serif', 'sans-serif', 'monospace', 'cursive',
                             'ui-rounded', 'ui-serif', 'ui-monospace', 'ui-sans-serif'];
      function fontFamily(name) {
        if (!name) return '-apple-system, sans-serif';
        var family = genericFamilies.indexOf(name) >= 0 ? name : '"' + String(name).replace(/["\\]/g, '') + '"';
        return family + ', -apple-system, sans-serif';
      }

      // --- Background -------------------------------------------------------

      function showBackground(bg) {
        background.style.backgroundColor = bg.color || '#000';
        var key = (bg.kind || 'color') + '|' + (bg.source || '');
        var media = background.firstElementChild;
        if (key !== backgroundKey) {
          // Only a new file restarts the video; changing a filter must not.
          backgroundKey = key;
          background.textContent = '';
          media = null;
          if (bg.kind === 'video' && bg.source) {
            media = document.createElement('video');
            media.loop = true;
            media.muted = true;
            media.playsInline = true;
            media.setAttribute('muted', '');
            media.src = bg.source;
          } else if (bg.kind === 'image' && bg.source) {
            media = document.createElement('img');
            media.src = bg.source;
          }
          if (media) {
            media.className = 'wallaero-media';
            background.appendChild(media);
          }
          if (media && bg.kind === 'video') {
            // In the app the video is started by the app: in Low Power Mode the web engine
            // leaves a video marked `autoplay` standing and draws a start button over it.
            var host = window.__wallaeroHost;
            if (host && host.autoplay) host.autoplay(media);
            else media.autoplay = true;
          }
        }
        if (!media) return;

        var blur = Math.max(0, number(bg.blur, 0));
        media.style.objectFit = bg.fit || 'cover';
        // A blurred picture fades out at its edges; drawing it a little larger hides that.
        var spill = px(blur * 2);
        media.style.left = media.style.top = 'calc(-1 * ' + spill + ')';
        media.style.width = media.style.height = 'calc(100% + 2 * ' + spill + ')';
        var filters = [];
        if (blur > 0) filters.push('blur(' + px(blur) + ')');
        if (number(bg.brightness, 100) !== 100) filters.push('brightness(' + number(bg.brightness, 100) + '%)');
        if (number(bg.contrast, 100) !== 100) filters.push('contrast(' + number(bg.contrast, 100) + '%)');
        if (number(bg.saturation, 100) !== 100) filters.push('saturate(' + number(bg.saturation, 100) + '%)');
        if (number(bg.hue, 0) !== 0) filters.push('hue-rotate(' + number(bg.hue, 0) + 'deg)');
        media.style.filter = filters.join(' ');
      }

      // --- Layers -----------------------------------------------------------

      function buildLayer(layer) {
        var box = document.createElement('div');
        box.className = 'wallaero-layer wallaero-' + layer.kind;
        box.dataset.layer = layer.id;
        var content = document.createElement('div');
        content.className = 'wallaero-content';
        box.appendChild(content);

        var style = box.style;
        style.left = number(layer.x, 50) + '%';
        style.top = number(layer.y, 50) + '%';
        style.width = number(layer.width, 30) + 'vw';
        if (layer.kind === 'shape' || layer.kind === 'code') style.height = number(layer.height, 30) + 'vh';
        style.transform = 'translate(-50%, -50%) rotate(' + number(layer.rotation, 0) + 'deg)';
        style.opacity = number(layer.opacity, 100) / 100;
        style.mixBlendMode = layer.blendMode || 'normal';
        // The app sets `wallaeroStill` when it renders the picture for the lock screen; layers
        // marked as not shown there are left out of it.
        if (layer.isVisible === false || (window.wallaeroStill && layer.showsOnLockScreen === false)) style.display = 'none';

        if (layer.animation && layer.animation !== 'none') {
          content.style.animation = 'wallaero-' + layer.animation + ' ' +
            Math.max(0.1, number(layer.animationDuration, 4)) + 's ' +
            (layer.animation === 'spin' ? 'linear' : 'ease-in-out') + ' infinite';
        }

        var shadow = null;
        if (number(layer.shadowBlur, 0) > 0 || number(layer.shadowX, 0) !== 0 || number(layer.shadowY, 0) !== 0) {
          shadow = px(layer.shadowX) + ' ' + px(layer.shadowY) + ' ' + px(layer.shadowBlur) + ' ' + (layer.shadowColor || '#000');
        }

        var inner = content.style;
        if (layer.kind === 'text') {
          inner.fontFamily = fontFamily(layer.fontFamily);
          inner.fontSize = number(layer.fontSize, 12) + 'vh';
          inner.fontWeight = number(layer.fontWeight, 400);
          inner.fontStyle = layer.isItalic ? 'italic' : 'normal';
          inner.color = layer.color || '#fff';
          inner.textAlign = layer.alignment || 'center';
          inner.letterSpacing = number(layer.letterSpacing, 0) + 'em';
          inner.lineHeight = number(layer.lineHeight, 1.1);
          if (shadow) inner.textShadow = shadow;
          content.dataset.template = layer.text || '';
          content.textContent = fillTokens(layer.text, new Date());
        } else if (layer.kind === 'image') {
          if (layer.source) {
            var image = document.createElement('img');
            image.src = layer.source;
            content.appendChild(image);
          }
          if (shadow) inner.filter = 'drop-shadow(' + shadow + ')';
        } else if (layer.kind === 'shape') {
          inner.background = layer.fill || 'transparent';
          inner.borderRadius = layer.shape === 'ellipse' ? '50%' : px(layer.cornerRadius);
          if (number(layer.borderWidth, 0) > 0) inner.border = px(layer.borderWidth) + ' solid ' + (layer.borderColor || '#fff');
          if (shadow) inner.boxShadow = shadow;
        } else if (layer.kind === 'code') {
          if (layer.css) {
            var sheet = document.createElement('style');
            sheet.textContent = layer.css;
            box.appendChild(sheet);
          }
          content.innerHTML = layer.html || '';
          if (shadow) inner.filter = 'drop-shadow(' + shadow + ')';
          if (layer.javaScript) {
            // Run once the element is on the page, so the script can measure it. It gets the
            // layer's element and the whole scene.
            box.wallaeroStart = function () {
              // What the script registers with the app, a sound listener for one, is dropped
              // when this element leaves the page.
              var host = window.__wallaeroHost;
              if (host) host.owner = box;
              try {
                new Function('layer', 'scene', layer.javaScript)(content, scene);
              } catch (error) {
                console.error('WallAero layer "' + layer.name + '":', error);
              }
              if (host) host.owner = null;
            };
          }
        }
        return box;
      }

      function showLayers(list) {
        var seen = {};
        var previous = null;
        list.forEach(function (layer) {
          var json = JSON.stringify(layer);
          var entry = built[layer.id];
          if (!entry || entry.json !== json) {
            // Untouched layers keep their elements, so their animations and scripts carry on.
            if (entry) entry.element.remove();
            entry = built[layer.id] = { json: json, element: buildLayer(layer) };
          }
          seen[layer.id] = true;
          var next = previous ? previous.nextSibling : layers.firstChild;
          if (entry.element !== next) layers.insertBefore(entry.element, next); // later layers go on top
          if (entry.element.wallaeroStart) {
            var start = entry.element.wallaeroStart;
            entry.element.wallaeroStart = null;
            start();
          }
          previous = entry.element;
        });
        Object.keys(built).forEach(function (id) {
          if (!seen[id]) {
            built[id].element.remove();
            delete built[id];
          }
        });
      }

      // --- Clock ------------------------------------------------------------

      function tick() {
        var now = new Date();
        var nodes = layers.querySelectorAll('.wallaero-text > .wallaero-content');
        for (var i = 0; i < nodes.length; i++) {
          var text = fillTokens(nodes[i].dataset.template, now);
          if (nodes[i].textContent !== text) nodes[i].textContent = text;
        }
      }

      function restartClock() {
        if (clock) {
          clearTimeout(clock);
          clock = null;
        }
        var needed = (scene.layers || []).some(function (layer) {
          return layer.kind === 'text' && layer.isVisible !== false && hasTokens(layer.text);
        });
        if (!needed) return;
        (function schedule() {
          tick();
          clock = setTimeout(schedule, 1000 - (Date.now() % 1000) + 5); // just after each full second
        })();
      }

      // --- Scene ------------------------------------------------------------

      function setScene(next) {
        scene = next || {};
        showBackground(scene.background || {});
        showLayers(scene.layers || []);
        restartClock();
        document.dispatchEvent(new CustomEvent('wallaero:scene', { detail: scene }));
      }

      window.wallaero = {
        version: 1,
        setScene: setScene,
        tokens: tokens,
        get scene() { return scene; }
      };

      if (window.wallaeroScene) {
        setScene(window.wallaeroScene);
      } else {
        // Opened outside the app, from a local web server for instance.
        fetch('scene.json').then(function (response) { return response.json(); }).then(setScene).catch(function (error) {
          console.error('WallAero: cannot read scene.json', error);
        });
      }
    })();

    """#
}
