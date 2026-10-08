/// The script the editor adds to the scene's page in its preview. It lets layers be picked,
/// dragged, resized and turned with the mouse, and reports each change to the app, which owns
/// the scene. It is never written into the wallpaper itself.
enum SceneEditorScript {
    static let source = #"""
    (function () {
      'use strict';
      if (window.wallaeroEditor) return;

      function post(message) { window.webkit.messageHandlers.wallaeroEditor.postMessage(message); }
      function make(tag, className) { var e = document.createElement(tag); e.className = className; return e; }
      function round(value) { return Math.round(value * 100) / 100; }

      var layersHost = document.getElementById('wallaero-layers');
      var sheet = document.createElement('style');
      sheet.textContent =
        '.wallaero-layer { cursor: move; pointer-events: auto; }' +
        '.wallaero-layer * { pointer-events: none; }' +
        '.wallaero-layer:hover { outline: 1px dashed rgba(10, 132, 255, 0.8); }' +
        '#wallaero-editor { position: fixed; left: 0; top: 0; width: 100%; height: 100%; pointer-events: none; z-index: 2147483000; }' +
        '.wallaero-frame { position: absolute; box-sizing: border-box; border: 1.5px solid #0a84ff; display: none; }' +
        '.wallaero-handle { position: absolute; width: 10px; height: 10px; margin: -5px 0 0 -5px; box-sizing: border-box;' +
        '  background: #fff; border: 1.5px solid #0a84ff; border-radius: 2px; pointer-events: auto; }' +
        '.wallaero-handle[data-handle=nw] { left: 0; top: 0; cursor: nwse-resize; }' +
        '.wallaero-handle[data-handle=ne] { left: 100%; top: 0; cursor: nesw-resize; }' +
        '.wallaero-handle[data-handle=sw] { left: 0; top: 100%; cursor: nesw-resize; }' +
        '.wallaero-handle[data-handle=se] { left: 100%; top: 100%; cursor: nwse-resize; }' +
        '.wallaero-handle[data-handle=e] { left: 100%; top: 50%; cursor: ew-resize; }' +
        '.wallaero-handle[data-handle=rotate] { left: 50%; top: -24px; border-radius: 50%; cursor: grab; }' +
        '.wallaero-guide { position: absolute; background: #ff453a; display: none; }' +
        '.wallaero-guide.vertical { left: 50%; top: 0; width: 1px; height: 100%; }' +
        '.wallaero-guide.horizontal { left: 0; top: 50%; width: 100%; height: 1px; }';
      document.head.appendChild(sheet);

      var overlay = make('div', '');
      overlay.id = 'wallaero-editor';
      var guideX = make('div', 'wallaero-guide vertical');
      var guideY = make('div', 'wallaero-guide horizontal');
      var frame = make('div', 'wallaero-frame');
      ['nw', 'ne', 'sw', 'se', 'e', 'rotate'].forEach(function (name) {
        var handle = make('div', 'wallaero-handle');
        handle.dataset.handle = name;
        frame.appendChild(handle);
      });
      overlay.appendChild(guideX);
      overlay.appendChild(guideY);
      overlay.appendChild(frame);
      document.body.appendChild(overlay);

      var selected = null;
      var drag = null;
      var pending = null;

      function box(id) { return id ? layersHost.querySelector('.wallaero-layer[data-layer="' + id + '"]') : null; }
      function data(id) {
        var list = (window.wallaero.scene && window.wallaero.scene.layers) || [];
        for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
        return null;
      }
      function sized(kind) { return kind === 'shape' || kind === 'code'; }

      function placeFrame() {
        var element = box(selected);
        if (!element || element.style.display === 'none') {
          frame.style.display = 'none';
          return;
        }
        frame.style.display = 'block';
        frame.style.left = element.style.left;
        frame.style.top = element.style.top;
        frame.style.width = element.offsetWidth + 'px';
        frame.style.height = element.offsetHeight + 'px';
        frame.style.transform = element.style.transform;
        var layer = data(selected);
        // Only text is worth narrowing on its own; the rest keeps the corner handles.
        frame.querySelector('[data-handle=e]').style.display = layer && layer.kind === 'text' ? 'block' : 'none';
      }

      function select(id, tellApp) {
        selected = id || null;
        placeFrame();
        if (tellApp) post({ type: 'select', id: selected });
      }

      // Moves the layer on the page right away, and tells the app once per frame.
      function apply(id, patch) {
        var layer = data(id), element = box(id);
        if (!layer || !element) return;
        for (var key in patch) layer[key] = patch[key];
        element.style.left = layer.x + '%';
        element.style.top = layer.y + '%';
        element.style.width = layer.width + 'vw';
        if (sized(layer.kind)) element.style.height = layer.height + 'vh';
        element.style.transform = 'translate(-50%, -50%) rotate(' + (layer.rotation || 0) + 'deg)';
        if (layer.kind === 'text' && patch.fontSize !== undefined) element.firstElementChild.style.fontSize = layer.fontSize + 'vh';
        placeFrame();
        if (!pending) {
          pending = {};
          requestAnimationFrame(function () {
            var changes = pending;
            pending = null;
            for (var changed in changes) post({ type: 'change', id: changed, patch: changes[changed] });
          });
        }
        var merged = pending[id] || (pending[id] = {});
        for (var name in patch) merged[name] = patch[name];
      }

      document.addEventListener('pointerdown', function (event) {
        if (event.button !== 0) return;
        var handle = event.target.closest ? event.target.closest('.wallaero-handle') : null;
        var element = handle ? box(selected) : (event.target.closest ? event.target.closest('.wallaero-layer') : null);
        if (!element) {
          select(null, true); // a click on the background
          return;
        }
        var id = element.dataset.layer;
        if (id !== selected) select(id, true);
        var layer = data(id);
        if (!layer) return;
        event.preventDefault();
        drag = {
          id: id,
          mode: handle ? handle.dataset.handle : 'move',
          kind: layer.kind,
          pointerX: event.clientX,
          pointerY: event.clientY,
          x: layer.x, y: layer.y, width: layer.width, height: layer.height,
          rotation: layer.rotation || 0, fontSize: layer.fontSize,
          halfWidth: Math.max(1, element.offsetWidth / 2),
          halfHeight: Math.max(1, element.offsetHeight / 2)
        };
      }, true);

      window.addEventListener('pointermove', function (event) {
        if (!drag) return;
        var width = window.innerWidth, height = window.innerHeight;
        var centerX = drag.x / 100 * width, centerY = drag.y / 100 * height;
        var patch = {};
        if (drag.mode === 'move') {
          var x = drag.x + (event.clientX - drag.pointerX) / width * 100;
          var y = drag.y + (event.clientY - drag.pointerY) / height * 100;
          // The middle of the screen pulls a little, with a line to show it.
          var snapX = Math.abs(x - 50) < 0.8, snapY = Math.abs(y - 50) < 0.8;
          guideX.style.display = snapX ? 'block' : 'none';
          guideY.style.display = snapY ? 'block' : 'none';
          patch.x = snapX ? 50 : round(x);
          patch.y = snapY ? 50 : round(y);
        } else if (drag.mode === 'rotate') {
          var angle = Math.atan2(event.clientY - centerY, event.clientX - centerX) * 180 / Math.PI + 90;
          if (event.shiftKey) {
            angle = Math.round(angle / 15) * 15;
          } else {
            var nearest = Math.round(angle / 90) * 90;
            if (Math.abs(angle - nearest) < 3) angle = nearest; // upright is easy to hit
          }
          angle = ((angle + 180) % 360 + 360) % 360 - 180;
          patch.rotation = round(angle);
        } else {
          // The pointer in the layer's own axes, so a turned layer resizes along its sides.
          var radians = -drag.rotation * Math.PI / 180;
          var px = event.clientX - centerX, py = event.clientY - centerY;
          var alongX = Math.abs(px * Math.cos(radians) - py * Math.sin(radians));
          var alongY = Math.abs(px * Math.sin(radians) + py * Math.cos(radians));
          if (drag.mode === 'e') {
            patch.width = round(Math.max(1, alongX * 2 / width * 100));
          } else if (sized(drag.kind) && !event.shiftKey) {
            patch.width = round(Math.max(1, alongX * 2 / width * 100));
            patch.height = round(Math.max(1, alongY * 2 / height * 100));
          } else {
            var scale = Math.max(0.05, Math.max(alongX / drag.halfWidth, alongY / drag.halfHeight));
            patch.width = round(Math.max(1, drag.width * scale));
            if (sized(drag.kind)) patch.height = round(Math.max(1, drag.height * scale));
            if (drag.kind === 'text') patch.fontSize = round(Math.max(0.5, drag.fontSize * scale));
          }
        }
        apply(drag.id, patch);
      });

      function endDrag() {
        if (!drag) return;
        drag = null;
        guideX.style.display = guideY.style.display = 'none';
        // After the frame that carries the last change.
        requestAnimationFrame(function () { post({ type: 'commit' }); });
      }
      window.addEventListener('pointerup', endDrag);
      window.addEventListener('pointercancel', endDrag);

      document.addEventListener('keydown', function (event) {
        if (!selected) return;
        var layer = data(selected);
        if (!layer) return;
        var step = event.shiftKey ? 1 : 0.1;
        var patch = null;
        if (event.key === 'ArrowLeft') patch = { x: round(layer.x - step) };
        else if (event.key === 'ArrowRight') patch = { x: round(layer.x + step) };
        else if (event.key === 'ArrowUp') patch = { y: round(layer.y - step) };
        else if (event.key === 'ArrowDown') patch = { y: round(layer.y + step) };
        else if (event.key === 'Backspace' || event.key === 'Delete') post({ type: 'delete', id: selected });
        else return;
        event.preventDefault();
        if (patch) apply(selected, patch);
      });

      document.addEventListener('contextmenu', function (event) { event.preventDefault(); });
      document.addEventListener('wallaero:scene', placeFrame);
      window.addEventListener('resize', placeFrame);
      // Text can change size on its own: a clock ticking over, a font arriving late.
      setInterval(placeFrame, 500);

      window.wallaeroEditor = { select: function (id) { select(id, false); } };
      post({ type: 'ready' });
    })();
    """#
}
