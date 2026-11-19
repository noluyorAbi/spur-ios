/* ==========================================================================
   app.js: the whole client side of the page. Vanilla, no dependency, no
   network call. The HTML already holds the finished state of everything, so
   the page reads the same without this file; it only adds motion and the few
   controls that work (the layer switch, the gap buttons, START, the tab bar).
   ========================================================================== */
(function () {
  "use strict";

  var mql = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  var REDUCED = !!(mql && mql.matches);

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  /* Notes that promise a working control ("Both buttons work.") exist only once this script runs. */
  $$("[data-js-only]").forEach(function (el) { el.hidden = false; });

  /* ---------------------------------------------------------------- utm */
  /* One rule for every outbound link to the repository: utm_source=landing,
     utm_medium=<slot>. The same parameters are already in the HTML, so a link
     is tagged without JavaScript too; this keeps runtime links in line. */
  function withUtm(href, slot) {
    if (!/^https?:\/\//i.test(href)) return href;
    try {
      var url = new URL(href, window.location.href);
      if (url.host === window.location.host) return href;
      if (url.searchParams.has("utm_source")) return url.toString();
      url.searchParams.set("utm_source", "landing");
      url.searchParams.set("utm_medium", slot || "link");
      url.searchParams.set("utm_campaign", "spur-ios");
      return url.toString();
    } catch (e) {
      return href;
    }
  }
  $$("a[data-utm-slot]").forEach(function (a) { a.href = withUtm(a.href, a.getAttribute("data-utm-slot")); });

  /* -------------------------------------------------------------- toast */
  var toastTimer = 0;
  function toast(text) {
    var el = $("#toast");
    if (!el) return;
    el.textContent = text;
    el.setAttribute("data-visible", "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.removeAttribute("data-visible"); }, 1800);
  }

  /* --------------------------------------------------------------- copy */
  $$("[data-copy-target]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var src = document.getElementById(btn.getAttribute("data-copy-target"));
      if (!src) return;
      var text = src.textContent.replace(/\\\n\s*/g, "");
      var done = function () {
        var label = $(".copy-label", btn);
        if (label) { label.textContent = "Copied"; setTimeout(function () { label.textContent = "Copy"; }, 1600); }
        toast("Copied to the clipboard");
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () { legacyCopy(text) && done(); });
      } else if (legacyCopy(text)) {
        done();
      }
    });
  });
  function legacyCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.className = "sr-only";
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  /* ------------------------------------------------------------ tab bar */
  var tabbar = $(".tabbar");
  if (tabbar) {
    var tabs = $$(".tab", tabbar);
    var groups = [
      { el: $(".hero"), i: 0 }, { el: $("#demo"), i: 0 }, { el: $("#group-fahrt"), i: 0 },
      { el: $("#group-planen"), i: 1 }, { el: $("#group-historie"), i: 2 }, { el: $("#group-einstellungen"), i: 3 },
    ].filter(function (g) { return g.el; });
    var current = -1;
    var pick = function () {
      var line = window.innerHeight * 0.45, idx = 0;
      groups.forEach(function (g) { if (g.el.getBoundingClientRect().top <= line) idx = g.i; });
      if (idx === current) return;
      current = idx;
      tabbar.style.setProperty("--tab", String(idx));
      tabs.forEach(function (t, k) {
        if (k === idx) t.setAttribute("aria-current", "true"); else t.removeAttribute("aria-current");
      });
    };
    var queued = false;
    window.addEventListener("scroll", function () {
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () { queued = false; pick(); });
    }, { passive: true });
    window.addEventListener("resize", pick);
    pick();
  }

  /* ------------------------------------------------- roads: layer switch */
  var roadsTile = $(".roads-tile");
  if (roadsTile) {
    $$("[data-mode-btn]", roadsTile).forEach(function (btn) {
      btn.addEventListener("click", function () {
        var mode = btn.getAttribute("data-mode-btn");
        roadsTile.setAttribute("data-mode", mode);
        $$("[data-mode-btn]", roadsTile).forEach(function (b) {
          b.setAttribute("aria-pressed", b === btn ? "true" : "false");
        });
      });
    });
  }

  /* ------------------------------------------------------ gap: decisions */
  var gapTile = $(".gap-tile");
  if (gapTile) {
    var gapStatus = $("[data-gap-status]");
    var said = { accepted: "Accepted: the suggestion now shows in the accent colour.", rejected: "Rejected: the suggestion is no longer drawn.", open: "Back to an open suggestion." };
    $$("[data-gap-btn]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var next = btn.getAttribute("data-gap-btn");
        gapTile.setAttribute("data-gap", next);
        if (gapStatus) gapStatus.textContent = said[next];
        var target = $(".gap-" + next + " button", gapTile.nextElementSibling);
        if (target && btn.matches(":focus-visible")) target.focus();
      });
    });
  }

  /* ------------------------------------------------ gallery: two buttons */
  var scroller = $("[data-scroller]");
  $$("[data-scroll]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      if (!scroller) return;
      var shot = $(".shot", scroller);
      var step = shot ? shot.getBoundingClientRect().width + 24 : 280;
      scroller.scrollBy({ left: Number(btn.getAttribute("data-scroll")) * step * 2, behavior: REDUCED ? "auto" : "smooth" });
    });
  });

  /* ------------------------------------------------- demo: play in view */
  var video = $(".demo-video");
  if (video && !REDUCED && "IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting && e.intersectionRatio >= 0.5) {
          var p = video.play();
          if (p && p.catch) p.catch(function () {});
        } else if (!video.paused) {
          video.pause();
        }
      });
    }, { threshold: [0, 0.5] }).observe(video);
  }

  /* Everything below is motion: with reduced motion the finished state stays. */
  if (REDUCED) return;

  function visible(el, cb) {
    if (!("IntersectionObserver" in window)) { cb(true); return; }
    new IntersectionObserver(function (entries) { cb(entries[0].isIntersecting); }).observe(el);
  }

  /* --------------------------------------------- motion: friction circle */
  var gWrap = $(".gcircle");
  if (gWrap) {
    var dot = $(".g-dot", gWrap), trailLine = $(".g-trail", gWrap);
    var vLong = $("[data-glong]"), vLongSub = $("[data-glong-sub]"), vLat = $("[data-glat]"), vLatSub = $("[data-glat-sub]");
    var R = 74, G = 9.81, PER = R / (0.6 * G);
    var bump = function (t, c, w) { var d = (t - c) / w; return Math.exp(-d * d); };
    var sample = function (t) {
      var p = t % 9;
      var lon = 1.9 * bump(p, 1.2, 0.55) - 0.7 * bump(p, 3.4, 0.4) - 2.7 * bump(p, 6.0, 0.55) + 0.12 * Math.sin(t * 7.1);
      var lat = 3.1 * bump(p, 3.4, 0.5) - 2.5 * bump(p, 7.7, 0.45) + 0.1 * Math.sin(t * 5.3 + 1);
      return { lon: lon, lat: lat };
    };
    var place = function (v) {
      var x = -v.lat * PER, y = -v.lon * PER, d = Math.hypot(x, y);
      if (d > R) { x *= R / d; y *= R / d; }
      return [x, y];
    };
    var fmt = function (n, digits) { return n.toFixed(digits).replace(".", ","); };
    var word = function (v, pos, neg) { return Math.abs(v) < 0.3 ? "unsicher" : (v > 0 ? pos : neg); };
    var running = false, t0 = 0, lastText = 0, raf = 0;
    var frame = function (now) {
      if (!running) return;
      var t = (now - t0) / 1000;
      var v = sample(t), p = place(v);
      dot.setAttribute("cx", p[0].toFixed(1));
      dot.setAttribute("cy", p[1].toFixed(1));
      var pts = [];
      for (var k = 20; k >= 0; k -= 1) { var q = place(sample(Math.max(0, t - k * 0.1))); pts.push(q[0].toFixed(1) + "," + q[1].toFixed(1)); }
      trailLine.setAttribute("points", pts.join(" "));
      if (now - lastText > 200) {
        lastText = now;
        vLong.textContent = fmt(Math.abs(v.lon), 1);
        vLongSub.textContent = fmt(Math.abs(v.lon) / G, 2) + " g · " + word(v.lon, "Beschleunigen", "Bremsen");
        vLat.textContent = fmt(Math.abs(v.lat), 1);
        vLatSub.textContent = fmt(Math.abs(v.lat) / G, 2) + " g · " + word(v.lat, "links", "rechts");
      }
      raf = requestAnimationFrame(frame);
    };
    visible(gWrap, function (on) {
      if (on && !running) { running = true; t0 = performance.now() - 5200; raf = requestAnimationFrame(frame); }
      else if (!on && running) { running = false; cancelAnimationFrame(raf); }
    });
  }

  /* ===================================================== hero: the drive */
  var live = $(".live");
  var map = live && $(".hero-map", live);
  var route = map && $("#route", map);
  if (!live || !map || !route || !route.getTotalLength) return;

  var M_PER_UNIT = 1.6;      // the invented city's scale
  var TIME_SCALE = 21;       // simulated seconds per real second
  var TOTAL = route.getTotalLength();
  var trailPaths = $$(".trail path", map);
  var marks = $$(".tm", map).map(function (m) { return { el: m, at: Number(m.getAttribute("data-at")) }; });
  var puck = $(".puck", map), head = $(".puck-head", map);
  var startBtn = $("[data-start]", live), pauseBtn = $("[data-pause]", live), stopBtn = $("[data-stop]", live);
  var elSpeed = $("[data-speed]", live), elDist = $("[data-dist]", live), elDur = $("[data-dur]", live);
  var elClock = $("[data-clock]", live), elLine = $("[data-recline]", live), hint = $("[data-hint]");

  // Route corners and the length at each, for the speed profile.
  var pts = route.getAttribute("d").replace(/[ML]/g, " ").trim().split(/\s+/).map(Number);
  var corners = [], cum = [0], P = [];
  for (var i = 0; i < pts.length; i += 2) P.push([pts[i], pts[i + 1]]);
  for (i = 1; i < P.length; i += 1) cum.push(cum[i - 1] + Math.hypot(P[i][0] - P[i - 1][0], P[i][1] - P[i - 1][1]));
  for (i = 1; i < P.length - 1; i += 1) corners.push(cum[i]);
  // Invented road features: a signal at the second and sixth corner, a stop sign at the eighth.
  var signals = [corners[1], corners[5]], stops = [corners[7]];

  // The edges this drive adds or changes, with the stretches of route that drive along them.
  var edges = {};
  $$(".cv-new .cv-case", map).forEach(function (c) {
    var k = c.getAttribute("data-k");
    var n = c.getAttribute("d").replace(/[ML]/g, " ").trim().split(/\s+/).map(Number);
    edges[k] = {
      k: k, before: c.getAttribute("data-before"), after: c.getAttribute("data-after"),
      order: Number(c.getAttribute("data-order")), a: [n[0], n[1]], b: [n[2], n[3]],
      els: $$(".e-" + k, map), paths: $$("path.e-" + k, map), passes: [],
    };
  });
  var keys = Object.keys(edges).sort(function (x, y) { return edges[x].order - edges[y].order; });
  keys.forEach(function (k) {
    var e = edges[k];
    for (var j = 1; j < P.length; j += 1) {
      var p = P[j - 1], q = P[j];
      var on = function (z) { return Math.abs((q[0] - p[0]) * (z[1] - p[1]) - (q[1] - p[1]) * (z[0] - p[0])) < 0.5 && Math.min(p[0], q[0]) - 0.5 <= z[0] && z[0] <= Math.max(p[0], q[0]) + 0.5 && Math.min(p[1], q[1]) - 0.5 <= z[1] && z[1] <= Math.max(p[1], q[1]) + 0.5; };
      if (on(e.a) && on(e.b)) {
        var da = Math.hypot(e.a[0] - p[0], e.a[1] - p[1]), db = Math.hypot(e.b[0] - p[0], e.b[1] - p[1]);
        e.passes.push(cum[j - 1] + Math.max(da, db)); // the length at which this pass is complete
      }
    }
  });

  function setEdge(e, state) {
    e.els.forEach(function (el) {
      el.classList.remove("s-none", "s-one", "s-both", "s-pair");
      el.classList.add("s-" + state);
    });
    e.state = state;
  }
  function stateAfter(e, s) {
    var n = e.passes.filter(function (end) { return s >= end - 0.5; }).length;
    if (n === 0) return e.before;
    if (n >= 2 || e.before === "one") return "both";
    return "one";
  }

  // The speed readout rolls its digits, like the numeric text transition in the app.
  function Roller(el) {
    el.textContent = "";
    var cols = [0, 1].map(function () {
      var box = document.createElement("span"), strip = document.createElement("span");
      box.className = "dg"; strip.className = "dg-strip";
      for (var d = 0; d <= 9; d += 1) { var s = document.createElement("span"); s.textContent = String(d); strip.appendChild(s); }
      box.appendChild(strip); el.appendChild(box);
      return { box: box, strip: strip };
    });
    return function (v) {
      v = Math.max(0, Math.min(99, Math.round(v)));
      var tens = Math.floor(v / 10), ones = v % 10;
      cols[0].box.classList.toggle("is-off", tens === 0);
      cols[0].strip.style.setProperty("--n", String(tens));
      cols[1].strip.style.setProperty("--n", String(ones));
    };
  }
  var setSpeed = Roller(elSpeed);
  setSpeed(0);

  var fmtKm = function (m) { return (m / 1000).toFixed(2).replace(".", ","); };
  var fmtDur = function (sec) {
    sec = Math.floor(sec);
    if (sec < 60) return sec + " s";
    var m = Math.floor(sec / 60), s = sec % 60;
    if (m < 60) return m + " min " + (s < 10 ? "0" : "") + s + " s";
    var h = Math.floor(m / 60), mm = m % 60;
    return h + " h " + (mm < 10 ? "0" : "") + mm + " min";
  };
  var plural = function (n, one, many) { return n + " " + (n === 1 ? one : many); };

  function speedAt(s) {
    // km/h: pull away from the start, slow for every corner, roll to a stop at the end.
    var m = function (u) { return u * M_PER_UNIT; };
    var v = 52;
    v = Math.min(v, 6 + m(s) * 0.42);
    v = Math.min(v, 1 + m(TOTAL - s) * 0.34);
    corners.forEach(function (c) { v = Math.min(v, 17 + Math.abs(m(c - s)) * 0.36); });
    return Math.max(v, 0);
  }

  var sim = { s: 0, t: 0, running: false, paused: false, inView: true, last: 0, shownSpeed: -1, speedAt: 0, heading: -90, raf: 0 };

  function placePuck(s) {
    var p = route.getPointAtLength(Math.min(s, TOTAL));
    var q = route.getPointAtLength(Math.min(s + 6, TOTAL));
    var want = s + 6 <= TOTAL ? Math.atan2(q.y - p.y, q.x - p.x) * 180 / Math.PI : sim.heading;
    var diff = ((want - sim.heading + 540) % 360) - 180;
    sim.heading += diff * 0.22;
    puck.setAttribute("transform", "translate(" + p.x.toFixed(1) + " " + p.y.toFixed(1) + ")");
    head.setAttribute("transform", "rotate(" + (sim.heading + 90).toFixed(1) + ")");
  }

  function drawTrail(s) {
    trailPaths.forEach(function (p) {
      p.style.strokeDasharray = TOTAL + " " + TOTAL;
      p.style.strokeDashoffset = String(TOTAL - s);
    });
    marks.forEach(function (m) { m.el.classList.toggle("on", s >= m.at); });
  }

  function readouts(force) {
    var meters = sim.s * M_PER_UNIT;
    elDist.textContent = fmtKm(meters);
    elDur.textContent = fmtDur(sim.t);
    elClock.textContent = fmtDur(sim.t);
    var avg = sim.t > 0 ? Math.round(meters / sim.t * 3.6) : 0;
    var nSig = signals.filter(function (x) { return sim.s >= x; }).length;
    var nStop = stops.filter(function (x) { return sim.s >= x; }).length;
    elLine.textContent = "Ø " + avg + " km/h in Fahrt · " + plural(nSig, "Ampel", "Ampeln") + " · " + nStop + " Stopp · 0 schräg";
    var now = performance.now();
    if (force || now - sim.speedAt > 340) {
      var v = Math.round(speedAt(sim.s));
      if (sim.paused || sim.s >= TOTAL) v = 0;
      if (v !== sim.shownSpeed) { setSpeed(v); sim.shownSpeed = v; }
      sim.speedAt = now;
    }
  }

  function tick(now) {
    if (!sim.running) return;
    var dt = sim.last ? Math.min(0.05, (now - sim.last) / 1000) : 0;
    sim.last = now;
    if (!sim.paused && sim.inView && !document.hidden && sim.s < TOTAL) {
      var kmh = Math.max(3, speedAt(sim.s));
      var ms = kmh / 3.6;
      var simDt = dt * TIME_SCALE;
      sim.t += simDt;
      sim.s = Math.min(TOTAL, sim.s + ms * simDt / M_PER_UNIT);
      placePuck(sim.s);
      drawTrail(sim.s);
      readouts(false);
      if (sim.s >= TOTAL) arrive();
    }
    sim.raf = requestAnimationFrame(tick);
  }

  var arriveTimer = 0, holdTimer = 0, autoHold = false;
  function arrive() {
    readouts(true);
    // Parked: the passenger holds Stop for 1.2 s, as in the app.
    arriveTimer = setTimeout(function () {
      autoHold = true;
      stopBtn.classList.add("is-holding");
      holdTimer = setTimeout(stop, 1200);
    }, 700);
  }

  function interactive(on) {
    [startBtn].forEach(function (b) {
      if (on) { b.removeAttribute("aria-hidden"); b.removeAttribute("tabindex"); b.setAttribute("aria-label", "Start the simulated drive again"); }
      else { b.setAttribute("aria-hidden", "true"); b.setAttribute("tabindex", "-1"); }
    });
    [pauseBtn, stopBtn].forEach(function (b) {
      if (on) b.setAttribute("tabindex", "-1"); else b.removeAttribute("tabindex");
    });
    live.classList.toggle("is-interactive", on);
  }

  function reset() {
    keys.forEach(function (k) { setEdge(edges[k], edges[k].before); });
    sim.s = 0; sim.t = 0; sim.heading = -90; sim.shownSpeed = -1; sim.paused = false;
    live.classList.remove("is-paused");
    placePuck(0);
    drawTrail(0);
    readouts(true);
    setSpeed(0);
  }

  function begin() {
    if (sim.running) return;
    interactive(false);
    if (hint) hint.classList.remove("is-on");
    reset();
    startBtn.classList.add("is-pressed");
    setTimeout(function () {
      startBtn.classList.remove("is-pressed");
      live.setAttribute("data-state", "rec");
      live.classList.add("is-driving");
      sim.running = true; sim.last = 0;
      sim.raf = requestAnimationFrame(tick);
      if (document.activeElement === startBtn && pauseBtn) pauseBtn.focus();
    }, 140);
  }

  function stop() {
    if (!sim.running) return;
    // The recording controls hide when the drive ends and take the focus with them: remember it.
    var hadFocus = live.contains(document.activeElement);
    clearTimeout(arriveTimer); clearTimeout(holdTimer); clearTimeout(pressTimer);
    autoHold = false;
    sim.running = false;
    cancelAnimationFrame(sim.raf);
    stopBtn.classList.remove("is-holding");
    live.setAttribute("data-state", "save");
    live.classList.remove("is-driving", "is-paused");
    setSpeed(0);
    // After the stop the trip is matched to the roads: what it drove appears by direction.
    var delay = 380;
    keys.forEach(function (k) {
      var e = edges[k], next = stateAfter(e, sim.s);
      if (next === e.state) return;
      var from = e.state;
      setTimeout(function () {
        setEdge(e, next);
        if (from === "none") {
          e.paths.forEach(function (p) {
            var len = p.getTotalLength();
            p.style.strokeDasharray = len + " " + len;
            var a = p.animate([{ strokeDashoffset: len }, { strokeDashoffset: 0 }], { duration: 300, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
            a.onfinish = function () { p.style.strokeDasharray = ""; };
          });
          e.els.forEach(function (el) {
            if (el.tagName.toLowerCase() === "g") el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, delay: 200, fill: "backwards" });
          });
        }
      }, delay);
      delay += 95;
    });
    setTimeout(function () {
      live.setAttribute("data-state", "idle");
      sim.s = 0; sim.t = 0;
      readouts(true);
      setSpeed(0);
      interactive(true);
      if (hint) hint.classList.add("is-on");
      var lost = document.activeElement === document.body || live.contains(document.activeElement);
      if (hadFocus && lost) startBtn.focus();
    }, delay + 520);
  }

  startBtn.addEventListener("click", function () {
    if (live.classList.contains("is-interactive")) begin();
  });

  pauseBtn.addEventListener("click", function () {
    if (!sim.running) return;
    sim.paused = !sim.paused;
    live.classList.toggle("is-paused", sim.paused);
    pauseBtn.setAttribute("aria-label", sim.paused ? "Resume the simulated drive" : "Pause the simulated drive");
    readouts(true);
  });

  // Stop is press and hold. A keyboard press stops at once, like the accessibility action in the app.
  var pressTimer = 0;
  var release = function () {
    if (!stopBtn.classList.contains("is-holding") || autoHold) return;
    clearTimeout(pressTimer);
    stopBtn.classList.remove("is-holding");
    toast("Halten zum Beenden: press and hold");
  };
  stopBtn.addEventListener("pointerdown", function (e) {
    if (!sim.running || e.button > 0) return;
    stopBtn.classList.add("is-holding");
    clearTimeout(pressTimer);
    pressTimer = setTimeout(stop, 1200);
  });
  ["pointerup", "pointerleave", "pointercancel"].forEach(function (t) { stopBtn.addEventListener(t, release); });
  stopBtn.addEventListener("click", function (e) { if (e.detail === 0) stop(); });
  stopBtn.addEventListener("contextmenu", function (e) { e.preventDefault(); });

  // Rewind to before the drive, then drive once on its own, but only where it can be seen: the
  // route has to be on screen above the tab bar. It starts once most of the route shows and
  // pauses when most of it has left, so a phone that loads with the map below the fold, or a
  // reader who scrolls away, does not miss the drive. It counts pixels of the route, not a share
  // of the whole figure, so a short landscape window still gets there.
  reset();
  var BAR = 92, started = false, watchQueued = false;
  function routeShare() {
    var r = route.getBoundingClientRect();
    if (!r.height) return 0;
    var top = Math.max(r.top, 0), bottom = Math.min(r.bottom, window.innerHeight - BAR);
    return Math.max(0, bottom - top) / r.height;
  }
  function watch() {
    watchQueued = false;
    var share = routeShare();
    sim.inView = sim.inView ? share >= 0.4 : share >= 0.7;
    if (!started && share >= 0.8) { started = true; setTimeout(begin, 900); }
  }
  function queueWatch() {
    if (watchQueued) return;
    watchQueued = true;
    requestAnimationFrame(watch);
  }
  sim.inView = false;
  window.addEventListener("scroll", queueWatch, { passive: true });
  window.addEventListener("resize", queueWatch);
  watch();
})();
