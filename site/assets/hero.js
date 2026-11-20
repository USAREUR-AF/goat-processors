// Replays one real test vector, packs/correlate-gnn/vectors/04-separation-dissolves.json
// (copied into assets/from-tree/ by site/build.py): its inputs on a plan view drawn to
// scale, its trace records and events in the order the vector lists them.
// Nothing here decides anything; every value shown is read from the vector.
(function () {
  "use strict";

  document.querySelectorAll("button.copy").forEach(function (b) {
    b.addEventListener("click", function () {
      var text = document.getElementById(b.dataset.copy).textContent;
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () {
        b.textContent = "Copied"; setTimeout(function () { b.textContent = "Copy"; }, 1600);
      });
    });
  });

  var svg = document.getElementById("plot"), pre = document.getElementById("trace"), clock = document.getElementById("clock");
  if (!svg || !window.fetch) return;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var W = 520, H = 260, NS = "http://www.w3.org/2000/svg";
  var M_PER_DEG_LAT = 110574, M_PER_DEG_LON = 111320 * Math.cos(Math.PI / 180);
  var LAT0 = 1, LON0 = 1; // the vector's notional reference point

  fetch("assets/from-tree/04-separation-dissolves.json").then(function (r) { return r.json(); }).then(start).catch(function () {});

  function start(vec) {
    var steps = vec.steps, tracks = {}, group = null, lines = [], time = 0;
    var cam = { x: 0, y: 0, s: 1 }, camFrom = null, camTo = null, camT0 = 0;

    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
    function pad(s, n) { s = String(s); while (s.length < n) s += " "; return s; }
    function val(v) {
      if (v === null || v === undefined) return "-";
      if (typeof v !== "number") return String(v);
      if (Number.isInteger(v)) return String(v);
      var a = Math.abs(v); return a < 10 ? v.toFixed(4) : a < 1000 ? v.toFixed(1) : v.toFixed(0);
    }
    function traceLine(t) {
      var res = t.skipped ? '<span class="pass">skipped</span>' : t.pass ? '<span class="pass">pass</span>' : '<span class="fail">fail</span>';
      return esc(pad(t.stage, 8) + pad(t.test, 12) + " " + pad(val(t.value), 8) + " limit " + pad(t.limit === null || t.limit === undefined ? "-" : String(t.limit), 6) + " ") + res;
    }
    function eventLine(e) {
      var s = "-> " + e.ev;
      if (e.group) s += " " + e.group;
      if (e.members) s += " [" + e.members.join(", ") + "]";
      else if (e.entity) s += " " + e.entity;
      if (e.reason) s += " (" + e.reason + ")";
      return '<span class="ev">' + esc(s) + "</span>";
    }
    function push(html) { lines.push(html); if (lines.length > 8) lines.shift(); pre.innerHTML = lines.join("\n"); }

    function bounds() {
      var x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      Object.keys(tracks).forEach(function (k) {
        tracks[k].pts.forEach(function (p) {
          x0 = Math.min(x0, p.x - p.ce); x1 = Math.max(x1, p.x + p.ce);
          y0 = Math.min(y0, p.y - p.ce); y1 = Math.max(y1, p.y + p.ce);
        });
      });
      var cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, sx = Math.max(x1 - x0, 240), sy = Math.max(y1 - y0, 120);
      var s = Math.min((W - 60) / (sx * 1.25), (H - 70) / (sy * 1.25));
      return { x: cx, y: cy, s: s };
    }
    function niceBar(s) {
      var opts = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000], best = opts[0];
      opts.forEach(function (o) { if (o * s <= W * 0.3) best = o; });
      return best;
    }
    function el(name, attrs, text) {
      var n = document.createElementNS(NS, name);
      for (var k in attrs) n.setAttribute(k, attrs[k]);
      if (text !== undefined) n.textContent = text;
      svg.appendChild(n); return n;
    }
    function draw() {
      while (svg.firstChild) svg.removeChild(svg.firstChild);
      var cxp = W / 2, cyp = (H - 30) / 2 + 4;
      function X(x) { return cxp + (x - cam.x) * cam.s; }
      function Y(y) { return cyp - (y - cam.y) * cam.s; }
      var bar = niceBar(cam.s), g0 = Math.floor((cam.x - W / cam.s) / bar) * bar;
      for (var gx = g0; X(gx) < W; gx += bar) if (X(gx) > 0) el("line", { "class": "gridline", x1: X(gx), x2: X(gx), y1: 0, y2: H - 30 });
      var gy0 = Math.floor((cam.y - H / cam.s) / bar) * bar;
      for (var gy = gy0; Y(gy) > 0; gy += bar) if (Y(gy) < H - 30) el("line", { "class": "gridline", x1: 0, x2: W, y1: Y(gy), y2: Y(gy) });
      var keys = Object.keys(tracks).sort(), pos = {};
      keys.forEach(function (k, i) {
        var t = tracks[k], cls = k.indexOf("adsb") === 0 ? "a7" : "t1", last = t.pts[t.pts.length - 1];
        el("polyline", { "class": "trail " + cls + "s", points: t.pts.map(function (p) { return X(p.x) + "," + Y(p.y); }).join(" ") });
        el("circle", { "class": "ce " + cls + "s", cx: X(last.x), cy: Y(last.y), r: Math.max(3, last.ce * cam.s) });
        el("circle", { "class": cls, cx: X(last.x), cy: Y(last.y), r: 4.5 });
        var lx = X(last.x), ly = Y(last.y), up = cls === "a7";
        var anchor = lx > W - 110 ? "end" : "start", dx = anchor === "end" ? -10 : 10;
        el("text", { "class": "lab " + cls, x: lx + dx, y: ly + (up ? -12 : 20), "text-anchor": anchor }, k);
        pos[k] = { x: lx, y: ly };
      });
      if (group && pos[group.members[0]] && pos[group.members[1]]) {
        var a = pos[group.members[0]], b = pos[group.members[1]];
        el("line", { "class": "link", x1: a.x, y1: a.y, x2: b.x, y2: b.y });
        el("text", { "class": "grp", x: (a.x + b.x) / 2, y: Math.max(a.y, b.y) + 30, "text-anchor": "middle" }, "group " + group.id);
      }
      var by = H - 14;
      el("line", { "class": "scale", x1: 14, x2: 14 + bar * cam.s, y1: by, y2: by });
      el("line", { "class": "scale", x1: 14, x2: 14, y1: by - 5, y2: by + 5 });
      el("line", { "class": "scale", x1: 14 + bar * cam.s, x2: 14 + bar * cam.s, y1: by - 5, y2: by + 5 });
      el("text", { x: 22 + bar * cam.s, y: by + 4 }, (bar >= 1000 ? bar / 1000 + " km" : bar + " m"));
      el("text", { x: W - 12, y: by + 4, "text-anchor": "end" }, "dashed circle: reported error (ce)");
    }

    function apply(i) {
      var st = steps[i];
      if (st.ingest) {
        var r = st.ingest, k = r["track.source_id"] + "/" + r.uid;
        time = r.time_ms;
        (tracks[k] = tracks[k] || { pts: [] }).pts.push({ x: (r.lon - LON0) * M_PER_DEG_LON, y: (r.lat - LAT0) * M_PER_DEG_LAT, ce: r.ce });
        push('<span class="in">' + esc("ingest " + k + "  t=" + (time / 1000).toFixed(3) + " s") + "</span>");
      } else if (st.tick !== undefined) {
        time = st.tick;
        push('<span class="in">' + esc("tick  t=" + (time / 1000).toFixed(3) + " s") + "</span>");
      }
      clock.textContent = "step " + (i + 1) + "/" + steps.length + ", " + (time / 1000).toFixed(1) + " s";
    }
    function applyEvents(st) {
      (st.expect || []).forEach(function (e) {
        if (e.ev === "correlate") group = { id: e.group, members: e.members };
        if (e.ev === "dissolve" || e.ev === "leave") group = null;
      });
    }

    if (reduce) {
      for (var i = 0; i <= 2; i++) {
        apply(i);
        (steps[i].trace || []).forEach(function (t) { push(traceLine(t)); });
        (steps[i].expect || []).forEach(function (e) { push(eventLine(e)); });
        applyEvents(steps[i]);
      }
      var b = bounds(); cam = b; draw(); return;
    }

    function tween(now) {
      if (camTo) {
        var u = Math.min(1, (now - camT0) / 700), e = u < .5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
        cam = { x: camFrom.x + (camTo.x - camFrom.x) * e, y: camFrom.y + (camTo.y - camFrom.y) * e, s: camFrom.s * Math.pow(camTo.s / camFrom.s, e) };
        if (u >= 1) camTo = null;
      }
      draw();
      requestAnimationFrame(tween);
    }

    function run(i) {
      if (i === 0) { tracks = {}; group = null; lines = []; pre.innerHTML = ""; }
      apply(i);
      var target = bounds();
      if (i === 0) { cam = target; } else { camFrom = cam; camTo = target; camT0 = performance.now(); }
      var queue = (steps[i].trace || []).map(traceLine), evs = steps[i].expect || [];
      var k = 0;
      (function next() {
        if (k < queue.length) { push(queue[k++]); setTimeout(next, 240); return; }
        evs.forEach(function (e) { push(eventLine(e)); });
        applyEvents(steps[i]);
        if (i + 1 < steps.length) setTimeout(function () { run(i + 1); }, evs.length ? 1500 : 900);
        else setTimeout(function () { run(0); }, 3500);
      })();
    }
    requestAnimationFrame(tween);
    run(0);
  }
})();
