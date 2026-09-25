// The shim script. Ported from Search by Office Commun (https://github.com/driceroland/Search,
// ExtensionShims.swift), with names changed from "search" to "bosk" and Search's passkey patch
// left out.
//
// MIT License
//
// Copyright (c) 2026 Office Commun
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

extension ExtensionShim {
    /// Defines only what is missing, so the day WebKit implements an API, WebKit's is used.
    static let script = #"""
    (() => {
      const root = globalThis;
      // Taken now, not looked up at each use: a sandbox that later locks
      // the globals away (MetaMask's LavaMoat) would break the shim's own
      // code that needs them — every fetch of a Request, every import.
      const { URL, FileReader, Response, Blob, File, DOMException, HTMLImageElement, HTMLAnchorElement, Element } = root;
      const chrome = root.chrome || root.browser;
      // A page's own world, where an extension's MAIN-world script runs with
      // this before it, has no extension APIs. Nothing to mend there, and
      // nothing may be left there for a page to see: Safari leaves nothing.
      const ours = (() => { try { return !!(chrome && chrome.runtime && chrome.runtime.id); } catch (e) { return false; } })();
      if (!ours || root.__boskShim) return;
      // WebKit reverted `requestIdleCallback` after a page-load regression
      // (bug 287681), leaving Proton Pass's form detection without it.
      const nativeIdle = typeof root.requestIdleCallback === "function"
        ? root.requestIdleCallback.bind(root) : null;
      const nativeCancelIdle = typeof root.cancelIdleCallback === "function"
        ? root.cancelIdleCallback.bind(root) : null;
      if (!nativeIdle || !nativeCancelIdle) {
        const idle = new Map();
        let idleId = 0;
        root.requestIdleCallback = (callback, options) => {
          const id = ++idleId;
          if (nativeIdle) {
            const nativeId = nativeIdle((deadline) => {
              if (!idle.delete(id)) return;
              callback(deadline);
            }, options);
            idle.set(id, { nativeId });
          } else {
            // Let the requesting script finish first. Chrome's maximum
            // idle deadline is 50 ms; this fallback uses the full budget.
            const timer = setTimeout(() => {
              if (!idle.delete(id)) return;
              const start = Date.now();
              callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
            }, 1);
            idle.set(id, { timer });
          }
          return id;
        };
        root.cancelIdleCallback = (id) => {
          const request = idle.get(id);
          if (request === undefined) {
            if (nativeCancelIdle) nativeCancelIdle(id);
            return;
          }
          idle.delete(id);
          if (request.timer !== undefined) clearTimeout(request.timer);
          else if (nativeCancelIdle) nativeCancelIdle(request.nativeId);
        };
      }
      // Keep the first credentials container alive so extension hooks
      // survive WebKit replacing an unreferenced container.
      const credentials = root.navigator && root.navigator.credentials;
      if (credentials && !Object.prototype.hasOwnProperty.call(root, "__boskCredentials")) {
        Object.defineProperty(root, "__boskCredentials", { value: credentials });
      }
      Object.defineProperty(root, "__boskShim", { value: true });
      // WebKit finds a page's extension APIs through the `chrome` and
      // `browser` globals when it delivers an event. A sandbox that locks
      // every global away (MetaMask's LavaMoat) cuts it off: nothing arrives
      // any more. Made fixed accessors, they can't be taken away, and code
      // that assigns its own polyfill to them still can.
      for (const key of ["browser", "chrome"]) {
        const d = Object.getOwnPropertyDescriptor(root, key);
        if (!d || !d.configurable) continue;
        let value = root[key];
        // A replacement that hides the APIs — a Proxy some extensions put
        // there to keep them from other code (Proton Pass) — would hide them
        // from WebKit too, and nothing would reach the extension again. A
        // replacement that still carries them is taken.
        const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
        try { Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => value, set: (v) => { if (carries(v)) value = v; } }); } catch (e) {}
      }
      // On a web page this is a content script: only Chrome's behaviour is
      // mended there, no API that Chrome doesn't give content scripts either.
      const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
      // One of the extension's pages in a frame of a website — Vimium's bar,
      // the list iCloud Passwords opens under a field. WebKit runs it in the
      // website's process, which it trusts with no more than a content
      // script: a single call to tabs, windows, scripting… and WebKit takes
      // the process for compromised and ends it. The page reloads, and a
      // frame that makes the call as it loads reloads it for ever. Chrome
      // gives such a frame everything, so here the worker makes those calls
      // for it (see `__boskCall`).
      const embedded = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
        try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
        try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
      })();
      const runtime = chrome.runtime;

      // WebKit's objects are kept — WebKit finds an extension's listeners
      // through them, and a replacement would hide them. Members are set on
      // them instead: a method lives on the prototype, so an own property of
      // the same name takes its place.
      // WebKit's namespace and event objects are wrappers it doesn't keep
      // alive: once no script holds one, it is collected, and the next
      // `chrome.tabs` is a fresh object without what was set on it. So every
      // object touched here is held for good.
      const kept = new Set();
      try { Object.defineProperty(root, "__boskKept", { value: kept }); } catch (e) {}
      const put = (target, key, value) => {
        if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
        try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
        catch (e) { try { target[key] = value; } catch (e2) {} }
      };
      // Held from the start, before the extension's own code runs — its
      // polyfills set things on these objects too.
      const spaces = new Set(Object.keys(chrome));
      for (let o = Object.getPrototypeOf(chrome); o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => spaces.add(k));
      for (const space of spaces) {
        let ns; try { ns = chrome[space]; } catch (e) { continue; }
        if (!ns || typeof ns !== "object") continue;
        kept.add(ns);
        // And the same object every time it is asked for: WebKit can hand
        // out a fresh one, without what was set on the last.
        if (!Object.prototype.hasOwnProperty.call(chrome, space) || Object.getOwnPropertyDescriptor(chrome, space).get) {
          try { Object.defineProperty(chrome, space, { value: ns, configurable: true, writable: true, enumerable: true }); } catch (e) {}
        }
        for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
          for (const key of Object.getOwnPropertyNames(o)) {
            if (!/^on[A-Z]/.test(key)) continue;
            try { const ev = ns[key]; if (ev && typeof ev === "object") kept.add(ev); } catch (e) {}
          }
        }
        for (const sub of ["local", "sync", "session", "managed"]) { try { if (ns[sub] && typeof ns[sub] === "object") kept.add(ns[sub]); } catch (e) {} }
      }
      const withLastError = (error, callback) => {
        put(runtime, "lastError", { message: String(error && error.message || error) });
        try { callback(); } finally { try { delete runtime.lastError; } catch (e) {} }
      };
      const native = (api, args) =>
        runtime.sendNativeMessage("bosk", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
          .then((reply) => {
            if (reply && reply.error) throw new Error(reply.error);
            return reply ? reply.value : undefined;
          });
      // Chrome's APIs take a callback last, or return a promise without one.
      const call = (api) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = native(api, args);
        if (!callback) return promise;
        promise.then((value) => callback(value), (error) => withLastError(error, callback));
      };
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f),
          hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
          listeners,
        };
      };

      // Several onMessage listeners: WebKit takes the first one's return —
      // usually undefined — as the answer, where Chrome waits for whichever
      // calls sendResponse or returns true. So the extension's listeners are
      // gathered behind a single one of WebKit's that follows Chrome's rule.
      const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
      // The extension's background, whichever WebKit runs: the worker, or a
      // page — it picks the page when a manifest names scripts as well.
      const background = worker || (!inContent && typeof document !== "undefined" && (() => {
        try { return chrome.extension && typeof chrome.extension.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
        catch (e) { return false; }
      })());
      // A script a worker imports that isn't there: Chrome throws at once.
      // WebKit goes looking for it first, and while it does, runs the
      // promises already waiting — code that notes "still starting" until
      // its first promise settles (Tampermonkey) then thinks startup is
      // over, and refuses its own listeners. The extension's files are
      // known, so a missing one is refused the way Chrome refuses it, and
      // an empty one — Tampermonkey's test.js — isn't fetched at all.
      // The static routing API of Chrome's service workers (install
      // event.addRoutes) — a speed-up, so nothing is lost without it.
      if (worker && typeof root.InstallEvent === "function" && !InstallEvent.prototype.addRoutes) {
        InstallEvent.prototype.addRoutes = () => Promise.resolve();
      }
      // WebKit runs an extension's worker on its web process's main thread,
      // and a worker's WebSocket waits there for the main thread to set up
      // its channel — for itself, for ever: the worker and every page of the
      // extension freeze. 1Password opens one as a sign-in succeeds. So a
      // worker's socket is made by the browser (ExtensionSocket.swift) and
      // its frames come and go over a native port.
      if (worker && typeof root.WebSocket === "function" && runtime && typeof runtime.connectNative === "function") {
        const connectNative = runtime.connectNative.bind(runtime);
        const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
        const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
        const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
        class WebSocket extends EventTarget {
          #port; #state = 0; #queue = Promise.resolve(); #origin; #hello;
          constructor(url, protocols) {
            super();
            let parsed;
            try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
            if (parsed.protocol === "http:") parsed.protocol = "ws:";
            if (parsed.protocol === "https:") parsed.protocol = "wss:";
            if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
            const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
            Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
            this.#origin = parsed.origin;
            this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
            this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
            this.#hello = { open: this.url, protocols: list, userAgent: navigator.userAgent };
            this.#connect();
          }
          // WebKit drops what a worker posts on a port it has only just
          // opened, without a word either way. So the opening is said again,
          // on the same port, until the browser answers anything at all.
          #connect() {
            const port = connectNative("bosk.socket");
            let ready = false, tries = 0;
            this.#port = port;
            const again = () => {
              if (ready || this.#state === 3) return;
              if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
              try { port.postMessage(this.#hello); } catch (e) {}
              setTimeout(again, 100 * Math.min(tries, 5));
            };
            port.onMessage.addListener((m) => {
              if (!ready) ready = true;
              if (m && m.ready === true) return;
              this.#take(m);
            });
            port.onDisconnect.addListener(() => {
              if (this.#state === 3) return;
              this.#fire("error");
              this.#closed(1006, "", false);
            });
            again();
          }
          get readyState() { return this.#state; }
          #fire(type, init) {
            let event;
            if (type === "message") event = new MessageEvent("message", init);
            else if (type === "close" && typeof CloseEvent === "function") event = new CloseEvent("close", init);
            else { event = new Event(type); if (init) for (const k in init) Object.defineProperty(event, k, { value: init[k] }); }
            const handler = this["on" + type];
            if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { setTimeout(() => { throw e; }); } }
            this.dispatchEvent(event);
          }
          #closed(code, reason, wasClean) {
            this.#state = 3;
            try { this.#port.disconnect(); } catch (e) {}
            this.#fire("close", { code, reason, wasClean });
          }
          #take(m) {
            if (!m || this.#state === 3) return;
            if ("opened" in m) { this.protocol = m.opened; this.#state = 1; this.#fire("open"); }
            else if ("text" in m) this.#fire("message", { data: m.text, origin: this.#origin });
            else if ("binary" in m) {
              const buffer = decode(m.binary);
              this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
            }
            else if ("failed" in m) this.#fire("error");
            else if ("closed" in m) this.#closed(m.closed, m.reason || "", !!m.clean);
          }
          send(data) {
            if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
            if (this.#state !== 1) return;
            const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
            if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
            const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
              : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
              : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
              : Promise.resolve(null);
            this.#queue = this.#queue.then(() => bytes).then((b) => b ? post({ sendBinary: encode(b) }) : post({ send: String(data) }));
          }
          close(code, reason) {
            if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
              throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
            }
            if (this.#state >= 2) return;
            this.#state = 2;
            const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
            this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
          }
        }
        for (const [k, v] of Object.entries(states)) { Object.defineProperty(WebSocket, k, { value: v }); Object.defineProperty(WebSocket.prototype, k, { value: v }); }
        Object.defineProperty(root, "WebSocket", { value: WebSocket, configurable: true, writable: true });
      }
      // The same loss meets a worker's port to an app on the Mac: what it
      // posts in its first moments never reaches the app, and comes back to
      // the worker's own listeners instead. iCloud Passwords says hello to
      // its helper that way, and without the helper's answer asks for the
      // code again and again. So on such a port, what the extension posts
      // is held from its first message until the browser says the port has
      // arrived — asked on the same port, as the socket asks — and then sent
      // in order. WebKit won't let connectNative be replaced in a worker, so
      // this is done on what every port shares, found through a port to the
      // browser itself; the question and the answer are kept from the
      // extension's listeners, and never reach the app.
      if (worker && runtime && typeof runtime.connectNative === "function") {
        let found = null;
        try { found = runtime.connectNative("bosk"); found.disconnect(); } catch (e) {}
        const portProto = found && Object.getPrototypeOf(found);
        const eventProto = found && found.onMessage && Object.getPrototypeOf(found.onMessage);
        if (portProto && eventProto && typeof portProto.postMessage === "function" && typeof eventProto.addListener === "function") {
          // Ports that go to the extension's own pages or tabs, not an app.
          const toPages = new WeakSet();
          for (const [space, name] of [[runtime, "connect"], [chrome.tabs, "connect"]]) {
            const connect = space && space[name];
            if (typeof connect !== "function") continue;
            put(space, name, (...args) => { const port = connect.apply(space, args); try { toPages.add(port); } catch (e) {} return port; });
          }
          const post = portProto.postMessage, add = eventProto.addListener, remove = eventProto.removeListener, has = eventProto.hasListener;
          const ours = (m) => !!m && typeof m === "object" && "__boskNative" in m;
          // Ports seen, each with what waits to be sent (null once it may go).
          const ports = new WeakMap();
          const start = (port) => {
            const state = { held: [] };
            let tries = 0;
            const flush = () => { const list = state.held; state.held = null; for (const m of list || []) post.call(port, m); };
            const again = () => {
              if (!state.held) return;
              // Unanswered, they go anyway: no worse than before.
              if (tries++ >= 20) { flush(); return; }
              try { post.call(port, { __boskNative: "here?" }); } catch (e) {}
              setTimeout(again, 100 * Math.min(tries, 5));
            };
            add.call(port.onMessage, (m) => {
              if (m && m.__boskNative === "here" && state.held) flush();
              // WebKit keeps a worker only while it has posted on an open
              // port in the last two minutes; what arrives on one doesn't
              // count. The browser's word now and then is answered on the
              // port, so a worker holding a port to an app stays, as in
              // Chrome — iCloud Passwords otherwise forgets it was paired.
              if (m && m.__boskNative === "alive") { try { post.call(port, { __boskNative: "beat" }); } catch (e) {} }
            });
            add.call(port.onDisconnect, () => { state.held = null; });
            again();
            return state;
          };
          put(portProto, "postMessage", function (message) {
            let state = ports.get(this);
            if (!state) {
              const native = !toPages.has(this) && this.sender == null && typeof this.name === "string" && !/^bosk(\.|$)/.test(this.name);
              state = native ? start(this) : { held: null };
              ports.set(this, state);
            }
            if (state.held) { state.held.push(message); return; }
            return post.call(this, message);
          });
          // A port's listeners, and only a port's (the namespaces' own
          // events are kept as they are), each behind one that lets the
          // question and the answer pass by.
          const wrapped = new WeakMap();
          const wrapper = (event, f, make) => {
            let byEvent = wrapped.get(event);
            if (!byEvent) { byEvent = new Map(); if (make) wrapped.set(event, byEvent); }
            let w = byEvent.get(f);
            if (!w && make) { w = function (m, ...rest) { if (ours(m)) return; return f.call(this, m, ...rest); }; byEvent.set(f, w); }
            return w;
          };
          put(eventProto, "addListener", function (f) {
            if (kept.has(this) || typeof f !== "function") return add.call(this, f);
            return add.call(this, wrapper(this, f, true));
          });
          put(eventProto, "removeListener", function (f) {
            const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
            if (!w) return remove.call(this, f);
            wrapped.get(this).delete(f);
            return remove.call(this, w);
          });
          put(eventProto, "hasListener", function (f) {
            const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
            return has.call(this, w || f);
          });
        }
      }
      // WebKit gives a worker the user agent of the last web page that set
      // one — Safari's, as Bosk's tabs send — not the Chrome one the
      // extension's pages have. Code that picks its path by it then takes
      // the Safari one: Bitwarden's asks a Safari app for a reply thousands
      // of times a second and floods the browser.
      // Its pages too: an extension reads navigator.userAgent to pick a code
      // path, a download, a welcome page, and finds nothing it knows in
      // Safari's. (Not WebKit's setting: see Extensions.init.)
      if (!inContent && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent)) {
        const chromeUA = navigator.userAgent.replace(/ Version\/[\d.]+.*$/, "").replace(/ Safari\/[\d.]+$/, "") + " Chrome/__BOSK_CHROME__ Safari/537.36";
        const proto = typeof WorkerNavigator !== "undefined" && worker ? WorkerNavigator.prototype : typeof Navigator !== "undefined" ? Navigator.prototype : null;
        try {
          if (proto) {
            Object.defineProperty(proto, "userAgent", { get: () => chromeUA, configurable: true });
            Object.defineProperty(proto, "appVersion", { get: () => chromeUA.replace(/^Mozilla\//, ""), configurable: true });
            Object.defineProperty(proto, "vendor", { get: () => "Google Inc.", configurable: true });
            if (!("userAgentData" in navigator)) {
              const major = "__BOSK_CHROME__".split(".")[0];
              const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
              const low = { brands, mobile: false, platform: "macOS" };
              const mac = (chromeUA.match(/Mac OS X (\d+)[_.](\d+)(?:[_.](\d+))?/) || []).slice(1).map((n) => n || "0").join(".") || "10.15.7";
              const high = {
                architecture: "arm", bitness: "64", model: "", platformVersion: mac, wow64: false,
                fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? "__BOSK_CHROME__" : b.version + ".0.0.0" })),
                uaFullVersion: "__BOSK_CHROME__",
              };
              const pick = (hints) => Object.assign({}, low, ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })));
              const data = Object.assign({}, low, { getHighEntropyValues: (hints) => Promise.resolve(pick(hints)), toJSON: () => low });
              Object.defineProperty(proto, "userAgentData", { get: () => data, configurable: true });
            }
          }
        } catch (e) {}
      }
      if (worker && typeof root.importScripts === "function") {
        const shipped = new Set(), empty = new Set();
        for (const p of __BOSK_SCRIPTS__) p.startsWith("-") ? empty.add(p.slice(1)) : shipped.add(p);
        const load = root.importScripts.bind(root);
        root.importScripts = (...urls) => {
          const wanted = [];
          for (const u of urls) {
            let url; try { url = new URL(u, location.href); } catch (e) { wanted.push(u); continue; }
            const path = decodeURIComponent(url.pathname);
            if (url.origin === location.origin && empty.has(path)) continue;
            if (url.origin === location.origin && !shipped.has(path)) {
              throw new DOMException("Failed to execute 'importScripts' on 'WorkerGlobalScope': The script at '" + url.href + "' failed to load.", "NetworkError");
            }
            wanted.push(u);
          }
          if (wanted.length) return load(...wanted);
        };
      }
      // The tab an extension's framed page is in, asked once (see __boskToFrame).
      let ownTab = null;
      // Who has something to say about a message, told between the
      // extension's worker and its own pages on a channel they share (one
      // origin): each says, as soon as its listeners have run, whether it
      // answers or lets the message pass, and the sender says so of what
      // it sends. A page with nothing to say can then stay silent only
      // as long as someone else may still answer (see the end of `dispatch`).
      // A page in a website's frame is on the website's side of the
      // channel and takes no part; it waits, as before.
      const channel = !inContent && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("bosk-messages") : null;
      const me = Math.random().toString(36).slice(2);
      const peers = new Set();
      const verdicts = new Map();
      const waiting = new Set();
      const present = new Set();
      // Pages that are there but didn't hear the last message sent to all —
      // WebKit doesn't bring every message to every page. Not waited for
      // until they say something about one they heard.
      const deaf = new Set();
      const keyOf = (message) => { try { const k = JSON.stringify(message); return k && k.length < 4000 ? k : null; } catch (e) { return null; } };
      const tell = (message, verdict, heard) => {
        const key = channel && keyOf(message);
        if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
      };
      if (channel) {
        channel.onmessage = ({ data }) => {
          if (!data || data.from === me) return;
          // The pages that listen, as they come and go.
          if (!background && data.hello) {
            const known = peers.has(data.from);
            peers.add(data.from);
            if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
            return;
          }
          if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
          // A popup that closes is thrown away without a word; so a page
          // left waiting asks who is still there.
          if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
          if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
          if (typeof data.key !== "string") return;
          const now = Date.now();
          for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
          const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
          verdicts.delete(data.key);
          verdicts.set(data.key, entry);
          entry.at = now;
          if (data.from === "worker") entry.worker = data;
          else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
          waiting.forEach((check) => check());
        };
        if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
      }
      // Only a page that listens for messages is waited for: one that
      // doesn't never hears them, so never says anything about them.
      let listening = false;
      const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
      const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
      const gather = (event, told) => {
        if (!event || typeof event.addListener !== "function") return;
        const add = event.addListener.bind(event);
        const remove = event.removeListener.bind(event);
        const listeners = new Set();
        let attached = false;
        const dispatch = function (message, sender, respond) {
          let settled = false, keep = false;
          const sendResponse = (value) => { if (!settled) { settled = true; respond(value); } };
          // Only the worker answers; any other page stays out of it.
          if (message && message.__boskPing === true) {
            if (background) { sendResponse("pong"); return; }
            return true;
          }
          if (message && message.__boskUserScript === true) {
            const route = root.__boskUserScriptMessage;
            return route && route(message.message, sender, sendResponse) && !settled ? true : undefined;
          }
          // A tab's message, handed on by the worker (see alsoFramed): taken
          // by the frame it names, in the tab it names; every other page lets
          // it pass without answering, as it would a message not for it.
          if (message && message.__boskToFrame) {
            const to = message.__boskToFrame;
            if (!embedded || !(to.urls || []).includes(location.href)) {
              if (!background) setTimeout(() => sendResponse(undefined), 10000);
              return background ? undefined : true;
            }
            if (!ownTab) ownTab = Promise.resolve(runtime.sendMessage({ __boskCall: { space: "tabs", method: "getCurrent", args: [] } }))
              .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
            ownTab.then((id) => {
              if (id !== to.tabId) return setTimeout(() => sendResponse(undefined), 10000);
              let kept = false;
              for (const listener of [...listeners]) {
                let result;
                try { result = listener(to.message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
                if (result === true) kept = true;
                else if (result && typeof result.then === "function") { kept = true; result.then(sendResponse, () => sendResponse(undefined)); }
              }
              if (!kept) sendResponse(undefined);
            });
            return true;
          }
          // A call one of the extension's pages in a website's frame can't
          // make itself (see `embedded`), made here for it — and only for
          // one of its pages: a content script gets no more than Chrome
          // gives it.
          if (message && message.__boskCall) {
            if (!background) return true;
            const { space, method, args } = message.__boskCall;
            const own = (() => { try { return new URL(sender.url).origin === location.origin; } catch (e) { return false; } })();
            if (!own) { sendResponse({ error: "chrome." + space + " isn't available to content scripts" }); return; }
            if (space === "tabs" && method === "getCurrent") { sendResponse({ value: sender.tab }); return; }
            let ns; try { ns = chrome[space]; } catch (e) {}
            if (!ns || typeof ns[method] !== "function") { sendResponse({ error: "chrome." + space + "." + method + " isn't available" }); return; }
            Promise.resolve().then(() => ns[method](...(args || [])))
              .then((value) => sendResponse({ value }), (e) => sendResponse({ error: String(e && e.message || e) }));
            return true;
          }
          for (const listener of [...listeners]) {
            let result;
            try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) keep = true;
            else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
          }
          if (!inContent) tell(message, keep || settled ? "answers" : "passes", true);
          if (keep || settled) return keep && !settled ? true : undefined;
          // Nothing here answers it. In Chrome that leaves the question to
          // the extension's other pages and its worker; WebKit takes the
          // first reply from any of them, and an empty one from a page that
          // only listens for something else — an offscreen document, an
          // options page — would arrive before the worker's real answer. So
          // a page that has nothing to say steps aside, and says nothing
          // only once everyone else has had ample time — or as soon as the
          // worker and every other open page have said they let it pass too,
          // or the worker sent it itself. Bitwarden's offscreen document
          // keeps its storage and answers a save with nothing: ten seconds
          // on each one got in the way of signing in.
          if (!background && !inContent) {
            const received = Date.now();
            const key = channel && keyOf(message);
            let check = () => {}, roll = null;
            const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
            const late = setTimeout(() => { done(); sendResponse(undefined); }, 10000);
            if (key) {
              // Only what was said about this message, not an identical one
              // a while ago.
              const fresh = (said) => said && said.at >= received - 2000;
              check = () => {
                const entry = verdicts.get(key);
                if (settled || !entry) return;
                const worker = entry.worker;
                if (fresh(worker) && worker.verdict === "answers") { done(); return; }
                const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
                if (said.some((p) => fresh(p) && p.verdict === "answers")) { done(); return; }
                if (!fresh(worker) || said.some((p) => !fresh(p))) return;
                done();
                sendResponse(undefined);
              };
              waiting.add(check);
              check();
              // Still waiting on someone after a moment: those who don't say
              // they are here within a second are gone, and those who do but
              // still have said nothing about this message didn't hear it.
              roll = setTimeout(() => {
                if (settled) return;
                const heard = new Set();
                const hear = (id) => heard.add(id);
                present.add(hear);
                channel.postMessage({ roll: true, from: me });
                setTimeout(() => {
                  present.delete(hear);
                  for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
                  const entry = verdicts.get(key);
                  for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
                  check();
                }, 1000);
              }, 200);
            }
            return true;
          }
          return undefined;
        };
        put(event, "addListener", (listener) => {
          listeners.add(listener);
          if (told) join();
          if (!attached) { attached = true; add(dispatch); }
        });
        put(event, "removeListener", (listener) => {
          listeners.delete(listener);
          if (told && listeners.size === 0) leave();
          if (attached && listeners.size === 0) { attached = false; remove(dispatch); }
        });
        put(event, "hasListener", (listener) => listeners.has(listener));
        put(event, "hasListeners", () => listeners.size > 0);
        // A worker may only add listeners while it starts; one that adds its
        // first later would be refused. So in a worker the one listener is
        // WebKit's from the start.
        if (background) { attached = true; add(dispatch); }
      };
      if (runtime) {
        const names = new Set();
        for (let o = runtime; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
        for (const name of names) {
          if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
          let f; try { f = runtime[name]; } catch (e) { continue; }
          if (typeof f === "function") put(runtime, name, f.bind(runtime));
        }
      }
      if (inContent) return;

      // In a website's frame, everything WebKit keeps to the extension's own
      // process goes through the worker instead. What stays direct is what
      // WebKit lets a content script call too. Namespaces the shim adds
      // itself further down answer through the browser, which is allowed.
      if (embedded) {
        const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
        const ask = (space, method, args) => {
          while (args.length && args[args.length - 1] === undefined) args.pop();
          let payload;
          try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
          return Promise.resolve(chrome.runtime.sendMessage({ __boskCall: { space, method, args: payload } })).then((reply) => {
            if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
            if (reply.error) throw new Error(reply.error);
            return reply.value;
          });
        };
        for (const space of spaces) {
          if (direct.has(space)) continue;
          let ns; try { ns = chrome[space]; } catch (e) { continue; }
          if (!ns || typeof ns !== "object") continue;
          const names = new Set();
          for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
          for (const name of names) {
            if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
            let f; try { f = ns[name]; } catch (e) { continue; }
            if (typeof f !== "function") continue;
            // A port can't be carried over: one that closes at once, as
            // Chrome's does when nothing answers, rather than a dead process.
            if (name === "connect") {
              put(ns, name, (...args) => {
                const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
                  postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
                setTimeout(() => {
                  put(runtime, "lastError", { message: "Could not establish connection. Receiving end does not exist." });
                  try { for (const f of [...port.onDisconnect.listeners]) f(port); } finally { try { delete runtime.lastError; } catch (e) {} }
                });
                return port;
              });
              continue;
            }
            put(ns, name, (...args) => {
              const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
              const answer = ask(space, name, args);
              if (!callback) return answer;
              answer.then((value) => callback(value), (error) => withLastError(error, callback));
            });
          }
        }
      }

      // WebKit unloads an extension's worker after half a minute idle, and
      // starts it again for an event only if it remembers a listener for
      // it — which it does for messages, the worker's listener being in
      // place from its first line (see gather).
      //
      // A reply that never came is answered Chrome's way: in callback
      // form, with lastError set — WebKit calls back with nothing and no
      // error, and code that pings a tab to see if its script is there
      // waits for ever.
      const replied = (promise, callback, gone) => {
        if (typeof callback !== "function") return promise;
        promise.then((r) => r === undefined ? withLastError(new Error(gone), callback) : callback(r),
          (e) => withLastError(e, callback));
      };
      let checkWorker = () => {};
      // When the worker was last heard from — a reply, a port message.
      let heard = 0;
      if (runtime && typeof runtime.sendMessage === "function") {
        const page = typeof document !== "undefined";
        // WebKit's own, looked up at each call — not held from the page's
        // first moment, when the page isn't yet the tab or popup it will be.
        const original = Object.getPrototypeOf(runtime).sendMessage;
        const send = (...args) => original.apply(chrome.runtime, args);
        // WebKit can also lose a worker without knowing — its process
        // stopped along with a tab's — and then answers every message with
        // nothing, for good. So after waking it, a page asks the worker
        // itself (its shim answers) at most every few seconds; no answer,
        // and the browser takes the extension up afresh.
        const hasWorker = (() => { try { const b = runtime.getManifest().background || {}; return !!(b.service_worker || b.scripts || b.page); } catch (e) { return false; } })();
        // The message itself doesn't wait on the answer: a worker busy
        // starting up can take seconds. An empty reply means gone; silence
        // for a quarter of a minute does too.
        let asking = false;
        const check = () => {
          if (!hasWorker || asking || Date.now() - heard < 5000) return;
          asking = true;
          // Asked three times, a second apart, then once more after waking
          // it — only then taken for gone: a restart has consequences
          // (welcome pages, a popup loading again), and a question can go
          // unanswered for reasons that pass. Waking a worker that runs
          // starts it over, so that is kept for last.
          const ping = Object.getPrototypeOf(runtime).sendMessage;
          const ask = () => Promise.race([ping.call(runtime, { __boskPing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
          const pause = (ms) => new Promise((w) => setTimeout(w, ms));
          const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
            () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
          const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
          const started = Date.now();
          attempt(0).then((r) => {
            // Any real answer from the worker meanwhile says it runs, too:
            // the question alone can go unheard from a page that listens.
            if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
            // (Bosk: said only by a page still on screen. A popup that is closing
            // gets no answer either, and its word would end a worker that runs.)
            else if (document.visibilityState === "visible") {
              if (__BOSK_VERBOSE__) native("debug.error", ["worker check: " + String(r) + " from " + location.pathname]).catch(() => {});
              native("background.revive", []).catch(() => {});
            }
          }).finally(() => { asking = false; });
        };
        // (Bosk: not in a background page, which cannot ask itself.)
        checkWorker = page && !background ? check : () => {};
        put(runtime, "sendMessage", (...args) => {
          const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
          // Never heard back by the one that sends it, so said for it.
          if (!inContent) tell(typeof args[0] === "string" && args.length > 1 && typeof args[1] !== "function" ? args[1] : args[0], "passes");
          checkWorker();
          const answer = send(...args).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
          return replied(answer, callback, "The message port closed before a response was received.");
        });
      }
      // A message for a tab reaches only its content scripts in WebKit. In
      // Chrome it reaches the extension's own pages framed in that tab too —
      // 1Password's sign-in banner is one, told this way to offer a passkey
      // instead of a password, and without it the site's request failed. So
      // the worker hands it to those frames as well, and the first answer
      // from either wins.
      const alsoFramed = (answer, tabId, message, options) => {
        const nav = chrome.webNavigation;
        if (!nav || typeof nav.getAllFrames !== "function" || typeof tabId !== "number") return answer;
        const own = runtime.getURL("");
        const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
        const framed = Promise.resolve(nav.getAllFrames({ tabId })).then((frames) => {
          const urls = (frames || []).filter((f) => f.url && f.url.startsWith(own) && f.frameId !== 0 && (wanted === null || f.frameId === wanted)).map((f) => f.url);
          if (!urls.length) return undefined;
          return Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __boskToFrame: { tabId, urls, message } });
        }, () => undefined);
        return new Promise((resolve, reject) => {
          let left = 2, failure = null;
          const none = () => { if (--left === 0) failure ? reject(failure) : resolve(undefined); };
          answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failure = e; none(); });
          framed.then((v) => v !== undefined ? resolve(v) : none(), () => none());
        });
      };
      if (chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
        const send = chrome.tabs.sendMessage.bind(chrome.tabs);
        put(chrome.tabs, "sendMessage", (tabId, message, options, callback) => {
          if (typeof options === "function") { callback = options; options = undefined; }
          const p = options === undefined ? send(tabId, message) : send(tabId, message, options);
          return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
        });
      }
      if (typeof document !== "undefined" && runtime && typeof runtime.connect === "function") {
        const connect = runtime.connect.bind(runtime);
        put(runtime, "connect", (...args) => {
          checkWorker();
          const port = connect(...args);
          try { port.onMessage.addListener(() => { heard = Date.now(); }); } catch (e) {}
          return port;
        });
      }

      gather(runtime && runtime.onMessage, true);
      gather(runtime && runtime.onMessageExternal);

      // Whole namespaces WebKit lacks, answered by the browser.
      const define = (name, methods, events = [], extra = {}) => {
        if (chrome[name]) return;
        const api = Object.assign({}, extra);
        for (const m of methods) api[m] = call(name + "." + m);
        for (const e of events) api[e] = event();
        put(chrome, name, api);
        if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
      };
      define("bookmarks",
        ["get", "getChildren", "getRecent", "getSubTree", "getTree", "search", "create", "move", "update", "remove", "removeTree"],
        ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"]);
      define("history",
        ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
        ["onVisited", "onVisitRemoved"]);
      define("downloads",
        ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon"],
        ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]);
      define("sidePanel", ["open", "setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior"]);
      define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
        { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
      define("tabGroups", ["get", "query", "update", "move"],
        ["onCreated", "onRemoved", "onUpdated", "onMoved"], { TAB_GROUP_ID_NONE: -1 });
      define("fontSettings",
        ["getFontList", "getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize",
         "clearDefaultFontSize", "getDefaultFixedFontSize", "setDefaultFixedFontSize", "clearDefaultFixedFontSize",
         "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"],
        ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]);
      define("management", ["getSelf", "getAll", "get", "setEnabled", "uninstallSelf"],
        ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);
      define("notifications", ["create", "update", "clear", "getAll", "getPermissionLevel"],
        ["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"]);
      define("tts", ["speak", "stop", "pause", "resume", "isSpeaking", "getVoices"], ["onVoicesChanged"]);
      define("identity",
        ["launchWebAuthFlow", "getAuthToken", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens"],
        ["onSignInChanged"],
        { getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, "") });

      // Chrome's settings objects: get, set and clear, and an event.
      const setting = (name) => ({
        get: call("setting.get:" + name), set: call("setting.set:" + name),
        clear: call("setting.clear:" + name), onChange: event(),
      });
      const settings = (prefix, names) =>
        Object.fromEntries(names.map((n) => [n, setting(prefix + "." + n)]));
      const put2 = (name, api) => {
        if (chrome[name]) return;
        put(chrome, name, api);
        if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
      };
      // Something only Chrome can do, answered the way Chrome answers when
      // it can't: a rejection, or lastError for a callback.
      const refuse = (what) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const error = new Error(what + " isn't available in Bosk");
        if (!callback) return Promise.reject(error);
        withLastError(error, callback);
      };

      define("search", ["query"]);
      define("idle", ["queryState", "getAutoLockDelay"], [],
        { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } });
      if (chrome.idle && !chrome.idle.onStateChanged) {
        // Asked every so often while anyone listens, the way Chrome
        // notices on its own.
        const changed = event(), add = changed.addListener;
        let every = 60, state = "active", timer = null;
        changed.addListener = (f) => {
          add(f);
          if (timer) return;
          timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
            if (now === state) return;
            state = now;
            for (const g of changed.listeners) try { g(now); } catch (e) { setTimeout(() => { throw e; }); }
          }).catch(() => {}), 15000);
        };
        put(chrome.idle, "onStateChanged", changed);
        put(chrome.idle, "setDetectionInterval", (seconds) => { every = Math.max(15, Number(seconds) || 60); });
      }
      define("power", ["requestKeepAwake", "releaseKeepAwake", "reportActivity"]);
      define("browsingData",
        ["remove", "removeAppcache", "removeCache", "removeCacheStorage", "removeCookies", "removeDownloads",
         "removeFileSystems", "removeFormData", "removeHistory", "removeIndexedDB", "removeLocalStorage",
         "removePasswords", "removeServiceWorkers", "removeWebSQL", "settings"]);
      define("sessions", ["getRecentlyClosed", "getDevices", "restore"], ["onChanged"], { MAX_SESSION_RESULTS: 25 });
      define("topSites", ["get"]);
      define("readingList", ["query", "addEntry", "removeEntry", "updateEntry"],
        ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"]);
      put2("system", {
        cpu: { getInfo: call("system.cpu.getInfo") },
        memory: { getInfo: call("system.memory.getInfo") },
        storage: { getInfo: call("system.storage.getInfo"), ejectDevice: refuse("system.storage.ejectDevice"),
                   getAvailableCapacity: refuse("system.storage.getAvailableCapacity"), onAttached: event(), onDetached: event() },
        display: { getInfo: call("system.display.getInfo"), onDisplayChanged: event() },
      });
      put2("privacy", {
        services: settings("privacy.services", ["alternateErrorPagesEnabled", "autofillAddressEnabled",
          "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
          "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
        network: settings("privacy.network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
        websites: settings("privacy.websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled",
          "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
          "thirdPartyCookiesAllowed", "topicsEnabled"]),
        IPHandlingPolicy: { DEFAULT: "default", DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: "default_public_and_private_interfaces",
          DEFAULT_PUBLIC_INTERFACE_ONLY: "default_public_interface_only", DISABLE_NON_PROXIED_UDP: "disable_non_proxied_udp" },
      });
      const contentSetting = () => ({
        get: (details, cb) => { const v = { setting: "allow" }; if (cb) cb(v); else return Promise.resolve(v); },
        set: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
        clear: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
        getResourceIdentifiers: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
      });
      put2("contentSettings", Object.fromEntries(["automaticDownloads", "autoVerify", "camera", "clipboard", "cookies",
        "images", "javascript", "location", "microphone", "notifications", "plugins", "popups", "sound"]
        .map((n) => [n, contentSetting()])));
      put2("proxy", { settings: setting("proxy.settings"), onProxyError: event() });
      put2("omnibox", { setDefaultSuggestion: () => {}, onInputStarted: event(), onInputChanged: event(),
        onInputEntered: event(), onInputCancelled: event(), onDeleteSuggestion: event() });
      put2("tabCapture", { capture: refuse("tabCapture.capture"), getMediaStreamId: refuse("tabCapture.getMediaStreamId"),
        getCapturedTabs: (cb) => { if (cb) cb([]); else return Promise.resolve([]); }, onStatusChanged: event() });
      // The picker Chrome would show, cancelled: an empty stream id.
      put2("desktopCapture", { chooseDesktopMedia: (sources, tab, cb) => { const f = typeof tab === "function" ? tab : cb; if (f) setTimeout(() => f("", {})); return 1; },
        cancelChooseDesktopMedia: () => {}, DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" } });
      put2("pageCapture", { saveAsMHTML: refuse("pageCapture.saveAsMHTML") });
      put2("debugger", { attach: refuse("debugger.attach"), detach: refuse("debugger.detach"),
        sendCommand: refuse("debugger.sendCommand"), getTargets: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
        onEvent: event(), onDetach: event() });
      put2("gcm", { register: refuse("gcm.register"), unregister: refuse("gcm.unregister"), send: refuse("gcm.send"),
        onMessage: event(), onMessagesDeleted: event(), onSendError: event() });
      put2("instanceID", { getID: refuse("instanceID.getID"), getToken: refuse("instanceID.getToken"),
        deleteID: refuse("instanceID.deleteID"), deleteToken: refuse("instanceID.deleteToken"),
        getCreationTime: refuse("instanceID.getCreationTime"), onTokenRefresh: event() });
      // Rules that show a button on matching pages: every button is always
      // shown in Bosk, so there is nothing for them to do.
      const rules = () => ({ addRules: (r, cb) => { if (cb) cb(r || []); }, removeRules: (i, cb) => { if (cb) cb(); },
        getRules: (i, cb) => { const f = typeof i === "function" ? i : cb; if (f) f([]); } });
      put2("declarativeContent", { onPageChanged: rules(),
        PageStateMatcher: function (o) { Object.assign(this, o); }, ShowAction: function () {}, ShowPageAction: function () {},
        SetIcon: function (o) { Object.assign(this, o); }, RequestContentScript: function (o) { Object.assign(this, o); } });

      // WebKit serves an extension's .wasm files without the application/wasm
      // type, so compiling one as it streams in fails. Most code falls back
      // to fetching it whole, with a warning; some has no fallback and
      // stops. The whole file is what they get from the start.
      if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
        const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
        const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
        WebAssembly.instantiateStreaming = async (source, imports) => {
          const response = await source;
          return own(response) ? WebAssembly.instantiate(await response.arrayBuffer(), imports) : instantiate(response, imports);
        };
        if (typeof WebAssembly.compileStreaming === "function") {
          const compile = WebAssembly.compileStreaming.bind(WebAssembly);
          WebAssembly.compileStreaming = async (source) => {
            const response = await source;
            return own(response) ? WebAssembly.compile(await response.arrayBuffer()) : compile(response);
          };
        }
      }

      // Members Chrome has on the namespaces WebKit has too, that WebKit
      // leaves out. Plenty are read at the top of a worker — an enum, an
      // event to listen to — where one missing member is a TypeError that
      // stops the whole worker before it has done anything.
      const fill = (name, members) => {
        const target = chrome[name];
        if (!target) return;
        for (const [key, value] of Object.entries(members)) {
          let there;
          try { there = target[key]; } catch (e) {}
          if (there === undefined) put(target, key, value);
        }
      };
      const resolve = (value) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const v = typeof value === "function" ? value(...args) : value;
        if (!callback) return Promise.resolve(v);
        setTimeout(() => callback(v));
      };
      const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
      const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
        "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
      fill("runtime", {
        onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
        onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
        requestUpdateCheck: (callback) => {
          if (typeof callback === "function") { setTimeout(() => callback("no_update", {})); return; }
          return Promise.resolve({ status: "no_update" });
        },
        restart: () => {}, restartAfterDelay: resolve(undefined),
        getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
        OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
        OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
        PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
        PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
        PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
        RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
        ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
          SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
      });
      // The popup Bosk shows is a page of its own, known to WebKit as a
      // tab with no place in the row (no index). Chrome has no current
      // tab in a popup, and lists it among the popup views; extensions lay
      // themselves out by that (Bitwarden, Proton Pass: or else they fill
      // the window as if in a tab).
      if (typeof document !== "undefined") {
        // Known at once for the manifest's popup page — pages lay themselves
        // out before any answer can come back — and settled by what WebKit
        // says of the tab.
        let popup = (() => {
          try {
            const m = runtime.getManifest(), a = m.action || m.browser_action || {};
            return !!a.default_popup && new URL(a.default_popup, location.origin + "/").pathname === location.pathname;
          } catch (e) { return false; }
        })();
        // Not in a website's frame: never the popup, and asking costs the
        // worker a message for every frame the extension opens.
        if (!embedded && chrome.tabs && typeof chrome.tabs.getCurrent === "function") {
          const getCurrent = chrome.tabs.getCurrent.bind(chrome.tabs);
          const current = () => Promise.resolve(getCurrent()).then((t) => {
            if (t && !(t.index >= 0 && t.index < 1e6)) { popup = true; return undefined; }
            if (t) popup = false;
            return t;
          });
          current().catch(() => {});
          put(chrome.tabs, "getCurrent", (callback) => {
            const p = current();
            if (typeof callback !== "function") return p;
            p.then((t) => callback(t), (e) => withLastError(e, callback));
          });
        }
        if (chrome.extension && typeof chrome.extension.getViews === "function") {
          const extension = chrome.extension;
          const getViews = extension.getViews.bind(extension);
          const views = (properties = {}) => {
            let list = [...(getViews(properties) || [])];
            if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
            if (popup && (!properties.type || properties.type === "popup") && !list.includes(root)) list.push(root);
            return list;
          };
          put(extension, "getViews", views);
          // WebKit's getViews is read-only, and so is chrome.extension: both
          // ignore any redefinition without a word. (Search then hands the
          // popup page a `chrome` of its own, built on WebKit's, so that
          // Malwarebytes does not lay itself out as a tab. Bosk does not:
          // WebKit finds a page's listeners through the global `chrome` and
          // `browser`, and with that replacement no event, message or storage
          // change reached the popup any more. Bitwarden's sync waited for
          // ever, and Dark Reader's popup stayed at "Loading".)
        }
      }
      fill("extension", {
        getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
        sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
        getExtensionTabs: () => [], setUpdateUrlData: () => {},
      });
      fill("tabs", {
        TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
        WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
        ZoomSettingsMode: enumOf("automatic", "manual", "disabled"),
        ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
        MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
        getZoomSettings: resolve({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 }),
        setZoomSettings: resolve(undefined), onZoomChange: event(),
        onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
        group: refuse("tabs.group"), ungroup: resolve(undefined),
        getSelected: (windowId, callback) => {
          const f = typeof windowId === "function" ? windowId : callback;
          chrome.tabs.query({ active: true, currentWindow: true }).then((t) => f && f(t[0]));
        },
        getAllInWindow: (windowId, callback) => {
          const f = typeof windowId === "function" ? windowId : callback;
          chrome.tabs.query({ currentWindow: true }).then((t) => f && f(t));
        },
      });
      if (chrome.tabs) {
        // Moving, sleeping and bringing forward tabs, by where they are in
        // the row — the one thing both sides agree on.
        const settle = () => new Promise((r) => setTimeout(r, 60));
        const byIndex = (api) => async (ids, extra) => {
          const out = [];
          for (const id of Array.isArray(ids) ? ids : [ids]) {
            const tab = await chrome.tabs.get(id);
            await native(api, [tab.index, extra]);
            await settle();
            out.push(await chrome.tabs.get(id).catch(() => tab));
          }
          return Array.isArray(ids) ? out : out[0];
        };
        const withCallback = (f) => (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const p = f(...args);
          if (!callback) return p;
          p.then((v) => callback(v), (e) => withLastError(e, callback));
        };
        fill("tabs", {
          move: withCallback(async (ids, props = {}) => {
            const list = Array.isArray(ids) ? ids : [ids];
            const out = [];
            let at = props.index ?? -1;
            for (const id of list) {
              out.push(await byIndex("tabs.move")(id, at));
              if (at !== -1) at++;
            }
            return Array.isArray(ids) ? out : out[0];
          }),
          discard: withCallback((id) => id === undefined
            ? chrome.tabs.query({ active: false, currentWindow: true }).then((t) => t[0] && byIndex("tabs.discard")(t[0].id))
            : byIndex("tabs.discard")(id)),
          highlight: withCallback(async (info = {}) => {
            const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
            await native("tabs.activate", [first]);
            await settle();
            return chrome.windows ? chrome.windows.getCurrent({ populate: true }) : undefined;
          }),
        });
      }
      fill("windows", {
        // Chrome's, and not WebKit's: an extension subscribing to it at
        // start — Session Buddy, inside a try — threw there and never
        // reached the rest, its button's listener included. Never fired:
        // a window's bounds are read when they are asked for.
        onBoundsChanged: event(),
        CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
        WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
      });
      fill("storage", {
        managed: { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() },
        AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
      });
      // Items built with Object.create(null) — Chrome stores them, WebKit
      // throws that an object is expected.
      const plainItems = (items) => items && typeof items === "object" && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items;
      // (Bosk's own, not from Search.) In Chrome, a change to storage reaches
      // the onChanged listeners of every context, the one that made it too.
      // WebKit (macOS 27.2) leaves out the page that made it: a popup's own
      // set never comes back to it. Bitwarden's state layer waits for that
      // echo after each write, so its login timed out one second after the
      // server said yes. A worker does get its own changes, so only pages
      // are helped: the change is worked out here, from the old values, and
      // given to the page's own listeners once the call is done. Should
      // WebKit deliver it too one day, the same change seen within a moment
      // is dropped.
      const echoes = [];
      const signature = (changes) => JSON.stringify(Object.keys(changes).sort().map((k) => [k, changes[k].newValue === undefined ? null : JSON.stringify(changes[k].newValue)]));
      const echoed = (changes, area) => {
        const now = Date.now();
        while (echoes.length && now - echoes[0].at > 1500) echoes.shift();
        const sig = signature(changes);
        const i = echoes.findIndex((e) => e.area === area && e.sig === sig);
        if (i < 0) return false;
        echoes.splice(i, 1);
        return true;
      };
      // WebKit's listeners, kept so the page's own changes can be given to
      // them; each is registered with WebKit behind a wrapper that drops an
      // echo of a change already given.
      const tracked = (event, areaOf) => {
        if (!event || typeof event.addListener !== "function") return { fire: () => {} };
        const add = event.addListener.bind(event), remove = event.removeListener.bind(event), has = event.hasListener.bind(event);
        const wrapped = new Map();
        put(event, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return add(listener, ...rest);
          let w = wrapped.get(listener);
          if (!w) { w = (changes, areaName) => echoed(changes, areaOf(areaName)) ? undefined : listener(changes, areaName); wrapped.set(listener, w); }
          return add(w, ...rest);
        });
        put(event, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
        put(event, "hasListener", (listener) => has(wrapped.get(listener) || listener));
        return { fire: (changes, areaName) => { for (const listener of [...wrapped.keys()]) { try { listener(changes, areaName); } catch (e) { setTimeout(() => { throw e; }); } } } };
      };
      const global = !inContent && !worker && chrome.storage ? tracked(chrome.storage.onChanged, (areaName) => areaName) : null;
      for (const area of ["local", "sync", "session"]) {
        const store = chrome.storage && chrome.storage[area];
        if (!store || typeof store.set !== "function") continue;
        const set = store.set.bind(store);
        if (!global) { put(store, "set", (items, ...rest) => set(plainItems(items), ...rest)); continue; }
        const own = tracked(store.onChanged, () => area);
        const get = typeof store.get === "function" ? store.get.bind(store) : () => Promise.resolve({});
        const fire = (changes) => {
          echoes.push({ area, sig: signature(changes), at: Date.now() });
          own.fire(changes, area);
          global.fire(changes, area);
        };
        // The change Chrome would report, or null when nothing changed.
        const changesOf = (name, old, arg) => {
          const changes = {};
          if (name === "set") {
            for (const key of Object.keys(arg || {})) {
              const text = JSON.stringify(arg[key]);
              if (text === undefined) continue;
              if (key in old && JSON.stringify(old[key]) === text) continue;
              changes[key] = key in old ? { oldValue: old[key], newValue: JSON.parse(text) } : { newValue: JSON.parse(text) };
            }
          } else {
            const keys = name === "clear" ? Object.keys(old) : Array.isArray(arg) ? arg : [arg];
            for (const key of keys) if (key in old) changes[key] = { oldValue: old[key] };
          }
          return Object.keys(changes).length ? changes : null;
        };
        for (const name of ["set", "remove", "clear"]) {
          const original = store[name];
          if (typeof original !== "function") continue;
          const fn = original.bind(store);
          put(store, name, (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            if (name === "set") args[0] = plainItems(args[0]);
            const keys = name === "set" ? Object.keys(args[0] || {}) : name === "clear" ? null : args[0];
            const run = (old) => new Promise((resolve, reject) => {
              const after = () => { const changes = changesOf(name, old || {}, args[0]); if (changes) fire(changes); };
              if (callback) {
                fn(...args, (result) => {
                  let failed = false;
                  try { failed = !!chrome.runtime.lastError; } catch (e) {}
                  try { callback(result); } finally { if (!failed) after(); resolve(result); }
                });
              } else {
                Promise.resolve(fn(...args)).then((result) => { after(); resolve(result); }, reject);
              }
            });
            const done = Promise.resolve().then(() => get(keys)).catch(() => ({})).then(run);
            if (callback) { done.catch(() => {}); return undefined; }
            return done;
          });
        }
      }
      fill("scripting", {
        ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
        StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
      });
      // The popup an extension sets for its button, told to the browser too:
      // Bosk opens a popup itself (see Extensions.press), and has to know
      // which page it is now.
      for (const name of ["action", "browserAction"]) {
        const a = chrome[name];
        if (!a || typeof a.setPopup !== "function") continue;
        const setPopup = a.setPopup.bind(a);
        put(a, "setPopup", (details = {}, callback) => {
          const tell = (index) => native("action.popup", [details.popup || "", index]).catch(() => {});
          if (typeof details.tabId === "number" && chrome.tabs) chrome.tabs.get(details.tabId).then((t) => tell(t.index), () => {});
          else tell(-1);
          return setPopup(details, callback);
        });
      }
      fill("action", {
        getUserSettings: resolve({ isOnToolbar: true }), onUserSettingsChanged: event(),
        setBadgeTextColor: resolve(undefined), getBadgeTextColor: resolve([255, 255, 255, 255]),
      });
      fill("webNavigation", {
        onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
        TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
          "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
        TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
      });
      fill("webRequest", {
        OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
        OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
        OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
        OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
        ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
        handlerBehaviorChanged: resolve(undefined), onActionIgnored: event(),
      });
      fill("declarativeNetRequest", {
        GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
        MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
        MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
        DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
        getAvailableStaticRuleCount: resolve(30000), getDisabledRuleIds: resolve([]), updateStaticRules: resolve(undefined),
        testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"), onRuleMatchedDebug: event(),
        RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
          MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
        ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
        DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
        RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
        UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
      });
      const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
        "launcher", "browser_action", "page_action", "action");
      fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
      fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });

      // Rules WebKit can't carry out — a header it doesn't know how to set,
      // say — are refused one by one, where Chrome would take them all. The
      // rest still go in: one rule Bosk can't honour shouldn't cost an
      // extension every other rule, or its startup.
      const dnr = chrome.declarativeNetRequest;
      // Before WebKit sees them, rules are put the way it takes them: a
      // redirect to one of the extension's own files by path rather than by
      // address, and without the resource types it has no name for.
      const unknownTypes = new Set(["webtransport", "webbundle", "object"]);
      const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
      const mendRule = (rule) => {
        if (!rule || typeof rule !== "object") return rule;
        const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
        const redirect = r.action && r.action.redirect;
        if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
          r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
        }
        const c = r.condition;
        if (c && Array.isArray(c.resourceTypes)) {
          c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
          if (!c.resourceTypes.length) return null;
        }
        if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
        return r;
      };
      if (dnr && typeof dnr.isRegexSupported === "function") {
        const original = dnr.isRegexSupported.bind(dnr);
        put(dnr, "isRegexSupported", (options, callback) => {
          const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
            () => ({ isSupported: false, reason: "syntaxError" }));
          if (typeof callback !== "function") return p;
          p.then((r) => callback(r));
        });
      }
      if (dnr) for (const name of ["updateSessionRules", "updateDynamicRules"]) {
        if (typeof dnr[name] !== "function") continue;
        const original = dnr[name].bind(dnr);
        put(dnr, name, (options = {}, callback) => {
          if (options && Array.isArray(options.addRules)) options = { ...options, addRules: options.addRules.map(mendRule).filter(Boolean) };
          const attempt = async (opts, left) => {
            try { return await original(opts); }
            catch (e) {
              const at = /rule at index (\d+)/.exec(String(e && e.message));
              if (!at || !Array.isArray(opts.addRules) || left <= 0) throw e;
              const index = Number(at[1]);
              const rule = opts.addRules[index];
              try { native("debug.error", ["declarativeNetRequest: rule " + (rule && rule.id) + " left out — " + e.message]).catch(() => {}); } catch (x) {}
              return attempt({ ...opts, addRules: opts.addRules.filter((_, i) => i !== index) }, left - 1);
            }
          };
          const p = attempt(options, 100);
          if (typeof callback !== "function") return p;
          p.then(() => callback(), (e) => withLastError(e, callback));
        });
      }

      // Context menu entries for places Bosk has no menu for — the old
      // toolbar button contexts are the button's menu now, and there is no
      // app launcher at all.
      for (const name of ["contextMenus", "menus"]) {
        const menus = chrome[name];
        if (!menus || typeof menus.create !== "function") continue;
        const mend = (props) => {
          if (!props || !Array.isArray(props.contexts)) return props;
          const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
          return { ...props, contexts: contexts.length ? contexts : ["page"] };
        };
        const create = menus.create.bind(menus), update = menus.update.bind(menus);
        put(menus, "create", (props, callback) => create(mend(props), callback));
        put(menus, "update", (id, props, callback) => update(id, mend(props), callback));
      }

      // webRequest listeners with options WebKit doesn't take — blocking
      // needs a policy-installed extension in Chrome's MV3 too; extra headers
      // WebKit reports anyway — are added with the options it does take.
      if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
        const target = chrome.webRequest[key];
        if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
        const add = target.addListener.bind(target);
        put(target, "addListener", (listener, filter, spec) => {
          // WebKit can't read ws:// and wss:// patterns, and refuses the
          // whole listener over one; Chrome watches sockets too. The
          // listener is kept for everything else.
          if (filter && Array.isArray(filter.urls)) {
            const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
            if (!urls.length) return;
            filter = { ...filter, urls };
          }
          // Added after a worker's startup, WebKit refuses it; Chrome takes
          // it. It isn't heard, but neither does it stop the code that added
          // it — a listener for every request can't join the late list
          // (it would wake the worker for all of them).
          const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
          try {
            if (!Array.isArray(spec)) return add(listener, filter);
            const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
            try { return add(listener, filter, kept); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return add(listener, filter); }
          } catch (e) { late(e); }
        });
      }

      // Tabs as Chrome describes them. Every tab has a groupId (-1 when in
      // no group — Bosk has none), which code tests before anything else;
      // and with the "tabs" permission an extension sees every tab's address
      // and title, where WebKit shows them only for sites it has host
      // access to.
      if (chrome.tabs) {
        const seesTabs = (() => { try { return (runtime.getManifest().permissions || []).includes("tabs"); } catch (e) { return false; } })();
        const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
        // Mends in place; a promise only when the browser has to be asked.
        const mend = (list) => {
          const tabs = list.filter(isTab);
          for (const t of tabs) if (t.groupId === undefined) try { t.groupId = -1; } catch (e) {}
          const blind = seesTabs ? tabs.filter((t) => !t.url && t.index >= 0) : [];
          if (!blind.length) return null;
          return native("tabs.describe", [blind.map((t) => t.index)]).then((info) => {
            blind.forEach((t, i) => {
              const d = info && info[i];
              if (!d) return;
              try { if (d.url) t.url = d.url; if (d.title && !t.title) t.title = d.title; } catch (e) {}
            });
          }, () => {});
        };
        const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
          : isTab(value) ? [value] : value && Array.isArray(value.tabs) ? value.tabs : [];
        const mendResult = (target, name) => {
          if (!target || typeof target[name] !== "function") return;
          const original = target[name].bind(target);
          put(target, name, (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            const p = Promise.resolve(original(...args)).then(async (r) => { await mend(tabsIn(r)); return r; });
            if (!callback) return p;
            p.then((r) => callback(r), (e) => withLastError(e, callback));
          });
        };
        for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(chrome.tabs, name);
        for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
        // Listeners given a tab: the tab is mended before they see it.
        const mendArgs = (target, positions) => {
          if (!target || typeof target.addListener !== "function") return;
          const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
          const wrapped = new Map();
          put(target, "addListener", (listener, ...rest) => {
            const w = function (...args) {
              const pending = mend(positions.map((i) => args[i]));
              if (!pending) return listener.apply(this, args);
              pending.then(() => listener.apply(this, args));
            };
            wrapped.set(listener, w);
            return add(w, ...rest);
          });
          put(target, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
          put(target, "hasListener", (listener) => wrapped.has(listener));
        };
        mendArgs(chrome.tabs.onCreated, [0]);
        mendArgs(chrome.tabs.onUpdated, [2]);
        mendArgs(chrome.action && chrome.action.onClicked, [0]);
        mendArgs(chrome.contextMenus && chrome.contextMenus.onClicked, [1]);
        mendArgs(chrome.menus && chrome.menus.onClicked, [1]);
        mendArgs(chrome.commands && chrome.commands.onCommand, [1]);
      }

      // Permissions. WebKit knows its own and throws on any other name,
      // where Chrome answers false. The ones Bosk answers itself are
      // Bosk's to grant: those a manifest names are granted, optional
      // ones are asked for.
      if (chrome.permissions) {
        const webkit = new Set(["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
          "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
          "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]);
        const ours = new Set(["bookmarks", "history", "downloads", "downloads.open", "downloads.shelf", "downloads.ui",
          "tabGroups", "sidePanel", "offscreen", "notifications", "tts", "fontSettings", "management", "identity",
          "identity.email", "idle", "power", "privacy", "browsingData", "sessions", "topSites", "search", "system.cpu",
          "system.memory", "system.storage", "system.display", "readingList", "contentSettings", "proxy", "favicon",
          "clipboardRead", "geolocation", "userScripts"]);
        const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
        const declared = new Set(manifest.permissions || []);
        const split = (list = []) => ({
          theirs: list.filter((p) => webkit.has(p)), mine: list.filter((p) => ours.has(p)),
          unknown: list.filter((p) => !webkit.has(p) && !ours.has(p)),
        });
        const p = chrome.permissions;
        const contains = p.contains.bind(p), request = p.request.bind(p), getAll = p.getAll.bind(p), remove = p.remove.bind(p);
        const granted = () => native("permissions.granted", []).then((list) => new Set([...declared, ...(list || [])]));
        const withCb = (f) => (arg, callback) => {
          const pr = f(arg || {});
          if (typeof callback !== "function") return pr;
          pr.then((v) => callback(v), (e) => withLastError(e, callback));
        };
        put(p, "contains", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine, unknown } = split(permissions);
          if (unknown.length) return false;
          if (mine.length) { const have = await granted(); if (!mine.every((m) => have.has(m))) return false; }
          return theirs.length || origins.length ? contains({ permissions: theirs, origins }) : true;
        }));
        put(p, "request", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine, unknown } = split(permissions);
          if (unknown.length) return false;
          if (mine.length) {
            const have = await granted();
            const missing = mine.filter((m) => !have.has(m));
            if (missing.length && !(await native("permissions.request", [missing]))) return false;
          }
          return theirs.length || origins.length ? request({ permissions: theirs, origins }) : true;
        }));
        put(p, "getAll", (callback) => {
          const pr = (async () => {
            const all = await getAll();
            const have = await granted();
            return { ...all, permissions: [...new Set([...(all.permissions || []), ...[...have].filter((m) => ours.has(m))])] };
          })();
          if (typeof callback !== "function") return pr;
          pr.then((v) => callback(v), (e) => withLastError(e, callback));
        });
        put(p, "remove", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine } = split(permissions);
          if (mine.length) await native("permissions.remove", [mine]);
          return theirs.length || origins.length ? remove({ permissions: theirs, origins }) : true;
        }));
      }

      // chrome.userScripts — what Tampermonkey, Violentmonkey and the
      // advanced rules of the ad blockers run on — carried out through
      // WebKit's registered content scripts. The browser writes each script
      // into a file of the extension's (content scripts come from files),
      // wrapped so the globs Chrome takes are honoured and, for Chrome's
      // USER_SCRIPT world, so its messages reach onUserScriptMessage rather
      // than the extension's own onMessage. The list lives with the browser,
      // and is registered again whenever the worker starts.
      const scripting = chrome.scripting;
      const wantsUserScripts = (() => { try { return (runtime.getManifest().permissions || []).includes("userScripts"); } catch (e) { return false; } })();
      if (!chrome.userScripts && wantsUserScripts && scripting && typeof scripting.registerContentScripts === "function") {
        const tag = "bosk-us-";
        const content = async (script) => ({
          id: tag + script.id,
          matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
          excludeMatches: script.excludeMatches || [],
          js: [await native("userScripts.file", [script])],
          runAt: script.runAt || "document_idle",
          allFrames: !!script.allFrames,
          world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
          persistAcrossSessions: false,
        });
        const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
        const list = () => native("userScripts.list", []).then((l) => l || []);
        const save = (l) => native("userScripts.save", [l]);
        const sync = async () => {
          const want = await list();
          const have = new Set((await registered()).map((s) => s.id));
          const missing = want.filter((s) => !have.has(tag + s.id));
          if (!missing.length) return;
          const scripts = await Promise.all(missing.map(content));
          // Two starts of the worker racing each other: the later one takes
          // the registration over.
          await scripting.registerContentScripts(scripts).catch(async (e) => {
            if (!/duplicate/i.test(String(e && e.message))) throw e;
            await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
            await scripting.registerContentScripts(scripts);
          });
        };
        const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
        const api = {
          register: async (scripts) => {
            const l = await list();
            for (const s of scripts) if (l.some((o) => o.id === s.id)) throw new Error("Duplicate script id '" + s.id + "'");
            await scripting.registerContentScripts(await Promise.all(scripts.map(content)));
            await save([...l, ...scripts]);
          },
          update: async (scripts) => {
            const l = await list();
            const merged = scripts.map((s) => {
              const old = l.find((o) => o.id === s.id);
              if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
              return { ...old, ...s };
            });
            await scripting.unregisterContentScripts({ ids: merged.map((s) => tag + s.id) }).catch(() => {});
            await scripting.registerContentScripts(await Promise.all(merged.map(content)));
            await save(l.map((o) => merged.find((m) => m.id === o.id) || o));
          },
          unregister: async (filter) => {
            const l = await list();
            const gone = pick(filter, l);
            const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
            if (ids.length) await scripting.unregisterContentScripts({ ids });
            await save(l.filter((o) => !gone.includes(o)));
          },
          getScripts: async (filter) => pick(filter, await list()),
          configureWorld: (properties) => native("userScripts.world", [properties || {}]),
          getWorldConfigurations: () => native("userScripts.worlds", []),
          resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
          execute: async (injection) => {
            const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
            return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
              injectImmediately: !!injection.injectImmediately });
          },
        };
        const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const p = f(...args);
          if (!callback) return p;
          p.then((v) => callback(v), (e) => withLastError(e, callback));
        }]));
        put2("userScripts", { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } });
        if (background) sync().catch((e) => { try { native("debug.error", ["userScripts: " + e.message]).catch(() => {}); } catch (x) {} });

        // Messages from the USER_SCRIPT world come tagged (see the file's
        // wrapper); they go to onUserScriptMessage and onUserScriptConnect.
        const onMessage = runtime.onUserScriptMessage, onConnect = runtime.onUserScriptConnect;
        root.__boskUserScriptMessage = (message, sender, respond) => {
          let keep = false;
          for (const f of [...onMessage.listeners]) {
            const r = f(message, sender, respond);
            if (r === true) keep = true;
            else if (r && typeof r.then === "function") { keep = true; r.then(respond); }
          }
          return keep;
        };
        if (runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
          const marker = "bosk-us:";
          const add = runtime.onConnect.addListener.bind(runtime.onConnect);
          const remove = runtime.onConnect.removeListener.bind(runtime.onConnect);
          const wrapped = new Map();
          try {
            add((port) => {
              if (!String(port.name).startsWith(marker)) return;
              const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
              for (const f of [...onConnect.listeners]) f(view);
            });
          } catch (e) {}
          put(runtime.onConnect, "addListener", (listener) => {
            const w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
            wrapped.set(listener, w);
            return add(w);
          });
          put(runtime.onConnect, "removeListener", (listener) => { const w = wrapped.get(listener); if (w) { wrapped.delete(listener); remove(w); } });
        }
      }

      // WebKit says "install" again when an extension is taken up afresh in
      // the same session — after a Reload, or a worker brought back — where
      // Chrome says "update"; extensions open their welcome page on
      // "install". The first one of a session is marked, and any later one
      // told as the update it is.
      if (background && runtime.onInstalled && typeof runtime.onInstalled.addListener === "function") {
        let decided = null;
        const seenBefore = () => decided || (decided = native("background.loadedBefore", []).then((v) => !!v, () => false));
        const add = runtime.onInstalled.addListener.bind(runtime.onInstalled);
        const remove = runtime.onInstalled.removeListener.bind(runtime.onInstalled);
        const wrapped = new Map();
        put(runtime.onInstalled, "addListener", (listener) => {
          const w = (details) => {
            if (!details || details.reason !== "install") return listener(details);
            seenBefore().then((seen) => listener(seen ? { ...details, reason: "update", previousVersion: runtime.getManifest().version } : details));
          };
          wrapped.set(listener, w);
          return add(w);
        });
        put(runtime.onInstalled, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
        put(runtime.onInstalled, "hasListener", (listener) => wrapped.has(listener));
      }

      // A worker may add listeners only while it starts; WebKit throws for
      // one added later, where Chrome takes it. So for every event this
      // extension's code mentions, the worker has one listener of WebKit's
      // from the start, and a late one joins the list behind it. Events it
      // never mentions still take late listeners without throwing — they
      // just aren't heard. (Request events are left alone: a listener for
      // all of them would wake the worker for every request.)
      if (background) {
        const mentioned = new Set(__BOSK_EVENTS__);
        for (const space of Object.keys(chrome)) {
          if (space === "webRequest") continue;
          let ns; try { ns = chrome[space]; } catch (e) { continue; }
          if (!ns || typeof ns !== "object") continue;
          const names = new Set();
          for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
          for (const key of names) {
            if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
            let target; try { target = ns[key]; } catch (e) { continue; }
            if (!target || typeof target.addListener !== "function" || target.listeners) continue;
            const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
            const late = new Set();
            if (mentioned.has(space + "." + key)) {
              try {
                add(function (...args) {
                  let answer;
                  for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
                  return answer;
                });
              } catch (e) {}
            }
            put(target, "addListener", (listener, ...rest) => {
              try { return add(listener, ...rest); }
              catch (e) { if (/startup/i.test(String(e && e.message))) late.add(listener); else throw e; }
            });
            put(target, "removeListener", (listener) => { late.delete(listener); try { remove(listener); } catch (e) {} });
          }
        }
      }

      // What one of the extension's pages or its worker posts to another
      // before their port has opened — at once after connect, or from inside
      // onConnect — WebKit keeps until the other end takes the port, then
      // hands on once for each end's world: between two of the extension's
      // own, the same world, so twice. iCloud Passwords' popup asks its
      // worker for its state that way, and was answered twice. So between
      // the extension's own ends every message goes numbered by the end
      // that sends it, and a number already heard is let go by. A content
      // script's port, or an app's, goes as it is.
      if (runtime && typeof runtime.connect === "function" && runtime.onConnect) {
        const own = runtime.getURL("");
        const numbered = new WeakSet();
        // Set on the port itself, not with `put`, which holds what it touches
        // for good: a port is the extension's to let go. Its onMessage is held
        // by what is set here, so it isn't made afresh without it.
        const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
        const number = (port) => {
          const event = port && port.onMessage, post = port && port.postMessage;
          if (!event || typeof event.addListener !== "function" || typeof post !== "function" || numbered.has(port)) return port;
          numbered.add(port);
          const me = Math.random().toString(36).slice(2);
          let sent = 0;
          const heard = new Map();
          const listeners = new Set();
          event.addListener.call(event, (message, ...rest) => {
            const tag = message && typeof message === "object" ? message.__boskPort : null;
            if (Array.isArray(tag)) {
              if (tag[1] <= (heard.get(tag[0]) || 0)) return;
              heard.set(tag[0], tag[1]);
              message = message.message;
            }
            for (const f of [...listeners]) { try { f(message, ...rest); } catch (e) { setTimeout(() => { throw e; }); } }
          });
          // WebKit makes a port's onMessage afresh once nothing holds it, and
          // a fresh one has none of what is set below: a listener added to it
          // later would hear the numbered wrapper. Held on the port, it stays.
          set(port, "onMessage", event);
          set(port, "postMessage", (message) => post.call(port, { __boskPort: [me, ++sent], message }));
          set(event, "addListener", (f) => { listeners.add(f); });
          set(event, "removeListener", (f) => { listeners.delete(f); });
          set(event, "hasListener", (f) => listeners.has(f));
          set(event, "hasListeners", () => listeners.size > 0);
          return port;
        };
        const connect = runtime.connect;
        // Only a port to the extension itself: another extension would hear
        // the numbered wrapper, not the message.
        put(runtime, "connect", (...args) => {
          const port = connect.apply(runtime, args);
          return typeof args[0] === "string" && args[0] !== runtime.id ? port : number(port);
        });
        const onConnect = runtime.onConnect;
        const add = onConnect.addListener, remove = onConnect.removeListener, has = onConnect.hasListener;
        const wrapped = new WeakMap();
        // The worker's sender is the bare origin, with no slash after it.
        const fromOwn = (port) => !!port && !!port.sender && (String(port.sender.url) + "/").startsWith(own);
        put(onConnect, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return add.call(onConnect, listener, ...rest);
          let w = wrapped.get(listener);
          if (!w) { w = (port) => listener(fromOwn(port) ? number(port) : port); wrapped.set(listener, w); }
          return add.call(onConnect, w, ...rest);
        });
        put(onConnect, "removeListener", (listener) => remove.call(onConnect, wrapped.get(listener) || listener));
        put(onConnect, "hasListener", (listener) => has.call(onConnect, wrapped.get(listener) || listener));
      }

      // (Bosk's own, not from Search.) WebKit can end a worker and still count it as loaded;
      // then each message to it goes nowhere, for good, and only a load of the whole extension
      // helps (ExtensionManager.revive). So the worker holds a port to Bosk and answers its
      // pings on it. A ping without an answer, or the port gone, and Bosk loads the extension
      // again. (The shim's connectNative leaves a port named "bosk.…" as it is.)
      if (worker && runtime && typeof runtime.connectNative === "function") {
        const hold = () => {
          let port;
          try { port = runtime.connectNative("bosk.alive"); } catch (e) { return; }
          port.onMessage.addListener((m) => { if (m && m.ping !== undefined) { try { port.postMessage({ pong: m.ping }); } catch (e) {} } });
          port.onDisconnect.addListener(() => setTimeout(hold, 5000));
        };
        hold();
      }
      // Members of namespaces WebKit has.
      if (chrome.i18n && !chrome.i18n.detectLanguage) put(chrome.i18n, "detectLanguage", call("i18n.detectLanguage"));
      if (runtime && !runtime.getContexts) put(runtime, "getContexts", call("runtime.getContexts"));

      // Chrome's old FileSystem API — requestFileSystem, entries, FileWriter and
      // `filesystem:` URLs — which WebKit never had. Extensions still save to it:
      // GoFullPage writes every capture there and shows, copies and downloads it
      // by a `filesystem:<origin>/persistent/...` URL it builds itself. So it is
      // rebuilt on the origin private file system: PERSISTENT and TEMPORARY are
      // the folders "persistent" and "temporary" at its root, so a filesystem: URL
      // and the file it names have the same path. WebKit can't load that scheme,
      // so where such a URL is handed to something that loads it is swapped for
      // the file: a blob: URL in an image, a link or fetch; a data: URL for a
      // download or a new tab, which the browser loads outside this page.
      // Extension pages only: a worker has no DOM to mend, and a content script
      // shares the page's origin.
      (() => {
        const root = globalThis;
        if (root.requestFileSystem || root.webkitRequestFileSystem || typeof document === "undefined"
            || !(root.navigator && navigator.storage && navigator.storage.getDirectory)) return;

        const TEMPORARY = 0, PERSISTENT = 1;
        const kinds = ["temporary", "persistent"];
        // Chrome answers with DOMExceptions whose name says what went wrong; the
        // legacy code comes with the name (NotFoundError is 8, and so on).
        const fail = (name, message) => new DOMException(message || name, name);
        const asError = (e) => e instanceof DOMException ? e : fail(e && e.name || "InvalidStateError", e && e.message || String(e));
        // Chrome calls back later, never in the same turn, success or not.
        // A callback that throws is reported as uncaught, not as a rejection.
        const invoke = (f, v) => { try { f(v); } catch (e) { setTimeout(() => { throw e; }); } };
        const settle = (promise, success, error) => {
          promise.then((v) => { if (typeof success === "function") invoke(success, v); },
            (e) => { if (typeof error === "function") invoke(error, asError(e)); });
        };

        // Paths are kept as their segments; "/a/b" is ["a", "b"].
        const segments = (base, path) => {
          path = String(path ?? "");
          const out = path.startsWith("/") ? [] : base.split("/").filter(Boolean);
          for (const part of path.split("/")) {
            if (!part || part === ".") continue;
            if (part === "..") out.pop(); else out.push(part);
          }
          return out;
        };
        const join = (segs) => "/" + segs.join("/");

        const top = [];
        const folder = (type) => top[type] || (top[type] = navigator.storage.getDirectory()
          .then((d) => d.getDirectoryHandle(kinds[type], { create: true })));
        const walk = async (type, segs, create = false) => {
          let dir = await folder(type);
          for (const name of segs) dir = await dir.getDirectoryHandle(name, { create });
          return dir;
        };
        // The handle at a path, whichever kind it is, or null.
        const lookup = async (type, segs) => {
          if (!segs.length) return folder(type);
          const dir = await walk(type, segs.slice(0, -1));
          const name = segs[segs.length - 1];
          try { return await dir.getFileHandle(name); } catch (e) {
            if (e.name !== "TypeMismatchError") { if (e.name === "NotFoundError") return null; throw e; }
          }
          return dir.getDirectoryHandle(name);
        };
        const need = async (type, segs) => {
          const handle = await lookup(type, segs).catch((e) => { if (e.name === "NotFoundError") return null; throw e; });
          if (!handle) throw fail("NotFoundError", "A requested file or directory could not be found.");
          return handle;
        };

        // OPFS files come without a type; a blob: URL or download wants one.
        const types = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
          svg: "image/svg+xml", pdf: "application/pdf", txt: "text/plain", html: "text/html", json: "application/json",
          mp4: "video/mp4", webm: "video/webm" };
        const typed = (file) => {
          const type = file.type || types[(file.name.split(".").pop() || "").toLowerCase()] || "";
          return type === file.type ? file : new File([file], file.name, { type, lastModified: file.lastModified });
        };

        // blob: URLs already made, by "<type>:<path>", so the same file set on an
        // image twice gets the same URL, and at once. Changing a file drops its.
        const made = new Map();
        const forget = (type, path) => {
          for (const [key, url] of made) {
            const [t, p] = [Number(key[0]), key.slice(2)];
            if (t === type && (p === path || p.startsWith(path === "/" ? "/" : path + "/"))) {
              made.delete(key);
              Promise.resolve(url).then((u) => { if (u) setTimeout(() => URL.revokeObjectURL(u), 60000); }, () => {});
            }
          }
        };

        const systems = [];
        const system = (type) => systems[type] || (systems[type] = (() => {
          const fs = { name: location.host + ":" + (type ? "Persistent" : "Temporary") };
          fs.root = new DirectoryEntry(fs, type, "/");
          return fs;
        })());

        class Entry {
          constructor(fs, type, path) {
            Object.defineProperty(this, "_type", { value: type });
            this.filesystem = fs;
            this.fullPath = path;
            this.name = path === "/" ? "" : path.split("/").pop();
          }
          get _segs() { return segments("/", this.fullPath); }
          toURL() {
            return "filesystem:" + location.origin + "/" + kinds[this._type]
              + (this.fullPath === "/" ? "/" : this._segs.map(encodeURIComponent).map((s) => "/" + s).join(""));
          }
          toInternalURL() { return this.toURL(); }
          getParent(success, error) {
            settle(Promise.resolve(new DirectoryEntry(this.filesystem, this._type, join(this._segs.slice(0, -1)))), success, error);
          }
          getMetadata(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind === "directory") return { modificationTime: new Date(), size: 0 };
              const file = await handle.getFile();
              return { modificationTime: new Date(file.lastModified), size: file.size };
            })(), success, error);
          }
          remove(success, error) {
            settle((async () => {
              const segs = this._segs;
              if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
              const handle = await need(this._type, segs);
              // Not recursive: a directory with something in it is refused, as in
              // Chrome — WebKit says UnknownError there, Chrome InvalidModificationError.
              await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1]).catch((e) => {
                throw handle.kind === "directory" && e.name !== "NotFoundError" ? fail("InvalidModificationError", "The directory is not empty.") : e;
              });
              forget(this._type, this.fullPath);
            })(), success, error);
          }
          moveTo(parent, name, success, error) { settle(this._transfer(parent, name, true), success, error); }
          copyTo(parent, name, success, error) { settle(this._transfer(parent, name, false), success, error); }
          async _transfer(parent, name, move) {
            if (!(parent instanceof DirectoryEntry)) throw fail("TypeMismatchError", "The parent is not a directory.");
            name = name == null || name === "" ? this.name : String(name);
            if (!name || name.includes("/") || name === "." || name === "..") throw fail("EncodingError", "Invalid name.");
            const from = this._segs, to = [...parent._segs, name];
            const same = parent._type === this._type;
            if (!from.length) throw fail("InvalidModificationError", "The root directory cannot be moved or copied.");
            if (same && (join(to) === this.fullPath || join(to).startsWith(this.fullPath + "/")))
              throw fail("InvalidModificationError", "An entry cannot be moved or copied onto or into itself.");
            const handle = await need(this._type, from);
            const into = await need(parent._type, parent._segs);
            if (into.kind !== "directory") throw fail("NotFoundError");
            // What is already there is replaced if it is a file over a file, or an
            // empty directory over a directory; otherwise Chrome refuses.
            const there = await lookup(parent._type, to).catch(() => null);
            if (there) {
              if (there.kind !== handle.kind) throw fail("InvalidModificationError", "An entry of another kind is in the way.");
              await into.removeEntry(name).catch(() => { throw fail("InvalidModificationError", "The directory in the way is not empty."); });
              forget(parent._type, join(to));
            }
            let moved = false;
            if (move && same && typeof handle.move === "function") {
              try { await handle.move(into, name); moved = true; } catch (e) {}
            }
            if (!moved) {
              await copy(handle, into, name);
              if (move) await (await walk(this._type, from.slice(0, -1))).removeEntry(from[from.length - 1], { recursive: true });
            }
            if (move) forget(this._type, this.fullPath);
            const Kind = this.isDirectory ? DirectoryEntry : FileEntry;
            return new Kind(parent.filesystem, parent._type, join(to));
          }
        }
        const copy = async (handle, into, name) => {
          if (handle.kind === "file") {
            const w = await (await into.getFileHandle(name, { create: true })).createWritable();
            await w.write(await handle.getFile());
            return w.close();
          }
          const dir = await into.getDirectoryHandle(name, { create: true });
          for await (const [child, h] of handle.entries()) await copy(h, dir, child);
        };

        class DirectoryEntry extends Entry {
          get isFile() { return false; }
          get isDirectory() { return true; }
          createReader() { return new DirectoryReader(this); }
          getFile(path, options, success, error) { settle(this._get(path, options, "file"), success, error); }
          getDirectory(path, options, success, error) { settle(this._get(path, options, "directory"), success, error); }
          async _get(path, options, kind) {
            const create = !!(options && options.create), exclusive = !!(options && options.exclusive);
            const segs = segments(this.fullPath, path);
            if (!segs.length) {
              if (kind === "file") throw fail("TypeMismatchError", "The root is a directory.");
              if (create && exclusive) throw fail("InvalidModificationError", "The directory already exists.");
              return this.filesystem.root;
            }
            const dir = await walk(this._type, segs.slice(0, -1)).catch((e) => {
              throw e.name === "TypeMismatchError" ? fail("NotFoundError") : e;
            });
            const name = segs[segs.length - 1];
            if (create && exclusive) {
              const there = await lookup(this._type, segs).catch(() => null);
              if (there) throw fail("InvalidModificationError", "The entry already exists.");
            }
            await (kind === "file" ? dir.getFileHandle(name, { create }) : dir.getDirectoryHandle(name, { create }));
            const Kind = kind === "file" ? FileEntry : DirectoryEntry;
            return new Kind(this.filesystem, this._type, join(segs));
          }
          removeRecursively(success, error) {
            settle((async () => {
              const segs = this._segs;
              if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
              await need(this._type, segs);
              await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1], { recursive: true });
              forget(this._type, this.fullPath);
            })(), success, error);
          }
        }

        // Chrome hands a directory's entries over in batches, then an empty one to
        // say it's done; callers loop until they see it.
        class DirectoryReader {
          constructor(dir) { this._dir = dir; this._left = null; }
          readEntries(success, error) {
            settle((async () => {
              const dir = this._dir;
              if (!this._left) {
                const handle = await need(dir._type, dir._segs);
                this._left = [];
                for await (const [name, h] of handle.entries()) {
                  const Kind = h.kind === "file" ? FileEntry : DirectoryEntry;
                  this._left.push(new Kind(dir.filesystem, dir._type, join([...dir._segs, name])));
                }
              }
              return this._left.splice(0, 100);
            })(), success, error);
          }
        }

        class FileEntry extends Entry {
          get isFile() { return true; }
          get isDirectory() { return false; }
          file(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind !== "file") throw fail("TypeMismatchError");
              return typed(await handle.getFile());
            })(), success, error);
          }
          createWriter(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind !== "file") throw fail("TypeMismatchError");
              return new FileWriter(this, handle, (await handle.getFile()).size);
            })(), success, error);
          }
        }

        // One write or truncate at a time, each a writable opened on the file as it
        // is and closed — OPFS commits on close — with Chrome's events around it:
        // writestart, write, writeend, or error then writeend.
        class FileWriter extends EventTarget {
          constructor(entry, handle, length) {
            super();
            Object.defineProperty(this, "_entry", { value: entry });
            Object.defineProperty(this, "_handle", { value: handle });
            Object.defineProperty(this, "_token", { value: null, writable: true });
            this.readyState = 0; this.position = 0; this.length = length; this.error = null;
            this.onwritestart = this.onprogress = this.onwrite = this.onabort = this.onerror = this.onwriteend = null;
          }
          _fire(type, loaded, total) {
            const event = new ProgressEvent(type, { lengthComputable: true, loaded, total });
            this.dispatchEvent(event);
            const handler = this["on" + type];
            if (typeof handler === "function") handler.call(this, event);
          }
          _run(size, work, after) {
            if (this.readyState === 1) throw fail("InvalidStateError", "A write is already in progress.");
            this.readyState = 1; this.error = null;
            const run = this._token = {};
            setTimeout(async () => {
              if (this._token !== run) return;
              this._fire("writestart", 0, size);
              try {
                const w = await this._handle.createWritable({ keepExistingData: true });
                try { await work(w); await w.close(); } catch (e) { await w.abort().catch(() => {}); throw e; }
                if (this._token !== run) return;
                after();
                forget(this._entry._type, this._entry.fullPath);
                this.readyState = 2;
                this._fire("progress", size, size);
                this._fire("write", size, size);
              } catch (e) {
                if (this._token !== run) return;
                this.error = asError(e);
                this.readyState = 2;
                this._fire("error", 0, size);
              }
              this._fire("writeend", this.readyState === 2 ? size : 0, size);
            });
          }
          write(data) {
            if (!(data instanceof Blob)) throw new TypeError("Failed to execute 'write' on 'FileWriter': parameter 1 is not of type 'Blob'.");
            const at = this.position;
            this._run(data.size, (w) => w.write({ type: "write", position: at, data }), () => {
              this.position = at + data.size;
              this.length = Math.max(this.length, this.position);
            });
          }
          truncate(size) {
            size = Math.max(0, Number(size) || 0);
            this._run(0, (w) => w.truncate(size), () => {
              this.length = size;
              this.position = Math.min(this.position, size);
            });
          }
          seek(offset) {
            if (this.readyState === 1) throw fail("InvalidStateError", "A write is in progress.");
            offset = Number(offset) || 0;
            if (offset < 0) offset = Math.max(0, this.length + offset);
            this.position = Math.min(offset, this.length);
          }
          abort() {
            if (this.readyState !== 1) return;
            this._token = null;
            this.readyState = 2;
            this.error = fail("AbortError", "The write was aborted.");
            this._fire("abort", 0, 0);
            this._fire("writeend", 0, 0);
          }
        }
        for (const [k, v] of [["INIT", 0], ["WRITING", 1], ["DONE", 2]]) {
          Object.defineProperty(FileWriter, k, { value: v });
          Object.defineProperty(FileWriter.prototype, k, { value: v });
        }

        const requestFileSystem = (type, size, success, error) => {
          type = Number(type);
          settle(type === TEMPORARY || type === PERSISTENT
            ? folder(type).then(() => system(type))
            : Promise.reject(fail("InvalidModificationError", "Unknown file system type.")), success, error);
        };

        // filesystem:<this origin>/<persistent|temporary>/<path>, or null.
        const parse = (url) => {
          const s = String(url);
          if (!s.startsWith("filesystem:")) return null;
          const m = /^filesystem:([^/]+:\/\/[^/]+)\/(temporary|persistent)(\/[^?#]*)?/i.exec(s);
          if (!m || m[1] !== location.origin) return null;
          let segs;
          try { segs = segments("/", (m[3] || "/").split("/").map(decodeURIComponent).join("/")); } catch (e) { return null; }
          return { type: kinds.indexOf(m[2].toLowerCase()), segs };
        };
        const resolveURL = (url, success, error) => {
          settle((async () => {
            const at = parse(url);
            if (!at) throw fail(String(url).startsWith("filesystem:") ? "SecurityError" : "EncodingError", "Not a filesystem: URL of this origin.");
            const handle = await need(at.type, at.segs);
            const fs = system(at.type);
            if (!at.segs.length) return fs.root;
            return new (handle.kind === "file" ? FileEntry : DirectoryEntry)(fs, at.type, join(at.segs));
          })(), success, error);
        };

        const fileAt = async (url) => {
          const at = parse(url);
          if (!at) throw fail("NotFoundError");
          const handle = await need(at.type, at.segs);
          if (handle.kind !== "file") throw fail("NotFoundError");
          return typed(await handle.getFile());
        };
        // The blob: URL now standing for a filesystem: URL, made once per file.
        const blobURL = (url) => {
          const at = parse(url);
          if (!at) return Promise.reject(fail("NotFoundError"));
          const key = at.type + ":" + join(at.segs);
          if (!made.has(key)) {
            const p = fileAt(url).then((file) => { const u = URL.createObjectURL(file); made.set(key, u); return u; });
            made.set(key, p);
            p.catch(() => { if (made.get(key) === p) made.delete(key); });
          }
          return Promise.resolve(made.get(key));
        };
        const ready = (url) => { const at = parse(url); const u = at && made.get(at.type + ":" + join(at.segs)); return typeof u === "string" ? u : null; };
        const dataURL = (url) => fileAt(url).then((file) => new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(file);
        }));

        const define = (target, key, value) => {
          try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
        };
        define(root, "TEMPORARY", TEMPORARY);
        define(root, "PERSISTENT", PERSISTENT);
        define(root, "requestFileSystem", requestFileSystem);
        define(root, "webkitRequestFileSystem", requestFileSystem);
        define(root, "resolveLocalFileSystemURL", resolveURL);
        define(root, "webkitResolveLocalFileSystemURL", resolveURL);
        // Code for this API asks for quota first; OPFS has its own, so any is granted.
        const quota = {
          requestQuota: (size, success, error) => settle(Promise.resolve(size), success, error),
          queryUsageAndQuota: (success, error) => settle(navigator.storage.estimate().then((e) => [e.usage || 0, e.quota || 0]),
            (v) => typeof success === "function" && success(v[0], v[1]), error),
        };
        if (!navigator.webkitPersistentStorage) define(navigator, "webkitPersistentStorage", quota);
        if (!navigator.webkitTemporaryStorage) define(navigator, "webkitTemporaryStorage", quota);
        for (const [name, Kind] of [["FileSystemEntry", Entry], ["FileSystemDirectoryEntry", DirectoryEntry],
          ["FileSystemFileEntry", FileEntry], ["FileSystemDirectoryReader", DirectoryReader]]) {
          // WebKit has these for dropped files; its instanceof checks keep its own.
          if (!root[name]) define(root, name, Kind);
        }
        if (!root.FileWriter) define(root, "FileWriter", FileWriter);

        // Where a filesystem: URL is loaded. An image or link gets the blob: URL
        // once it's made — at once when it already was, so a src set again stays
        // put — and reads back the filesystem: URL, as in Chrome. A file that
        // isn't there leaves the URL as it was, so the image fails as it would.
        const shown = new WeakMap();
        const hook = (proto, prop) => {
          const d = proto && Object.getOwnPropertyDescriptor(proto, prop);
          if (!d || !d.set || !d.get) return;
          Object.defineProperty(proto, prop, Object.assign({}, d, {
            get() {
              const value = d.get.call(this), was = shown.get(this);
              return was && was.blob === value ? was.url : value;
            },
            set(value) {
              const url = typeof value === "string" ? value : null;
              if (!url || !url.startsWith("filesystem:") || !parse(url)) { shown.delete(this); return d.set.call(this, value); }
              const now = ready(url);
              if (now) { shown.set(this, { url, blob: now }); return d.set.call(this, now); }
              const was = { url, blob: null };
              shown.set(this, was);
              blobURL(url).then((blob) => {
                if (shown.get(this) !== was) return;
                was.blob = blob;
                d.set.call(this, blob);
              }, () => { if (shown.get(this) === was) { shown.delete(this); d.set.call(this, url); } });
            },
          }));
        };
        hook(root.HTMLImageElement && HTMLImageElement.prototype, "src");
        hook(root.HTMLAnchorElement && HTMLAnchorElement.prototype, "href");
        // React and templates set the attribute, not the property.
        const setAttribute = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (name, value) {
          if (typeof value === "string" && value.startsWith("filesystem:")) {
            const n = String(name).toLowerCase();
            if ((n === "src" && this instanceof HTMLImageElement) || (n === "href" && this instanceof HTMLAnchorElement)) {
              this[n] = value;
              return;
            }
          }
          return setAttribute.call(this, name, value);
        };

        if (typeof root.fetch === "function") {
          const fetch = root.fetch;
          root.fetch = function (input, init) {
            const url = typeof input === "string" ? input : input instanceof URL ? input.href : null;
            if (!url || !url.startsWith("filesystem:") || !parse(url)) return fetch.apply(this, arguments);
            return fileAt(url).then((file) => new Response(file, { status: 200, headers: { "Content-Type": file.type || "application/octet-stream", "Content-Length": String(file.size) } }),
              () => { throw new TypeError("Load failed"); });
          };
        }

        // The browser downloads and opens tabs from outside this page, where a blob:
        // URL of this page means nothing: those get the file itself, as a data: URL.
        const chrome = root.chrome || root.browser;
        const lastError = (e, callback) => {
          const runtime = chrome && chrome.runtime;
          try { Object.defineProperty(runtime, "lastError", { value: { message: String(e && e.message || e) }, configurable: true }); } catch (x) {}
          try { callback(); } finally { try { delete runtime.lastError; } catch (x) {} }
        };
        const held = [];
        const swap = (space, method, urls) => {
          const ns = chrome && chrome[space];
          const original = ns && ns[method];
          if (typeof original !== "function") return;
          held.push(ns); // WebKit's namespace objects are dropped when nothing holds them, and what was set with them.
          define(ns, method, function (options, ...rest) {
            const list = options && urls(options);
            if (!list || !list.some((u) => typeof u === "string" && parse(u))) return original.call(this, options, ...rest);
            const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
            const p = Promise.all(list.map((u) => typeof u === "string" && parse(u) ? dataURL(u) : u)).then((done) => {
              const copy = Object.assign({}, options, { url: Array.isArray(options.url) ? done : done[0] });
              return original.call(this, copy, ...rest);
            });
            if (!callback) return p;
            p.then((v) => callback(v), (e) => lastError(e, callback));
          });
        };
        const one = (o) => typeof o.url === "string" ? [o.url] : Array.isArray(o.url) ? o.url : null;
        swap("downloads", "download", one);
        swap("tabs", "create", one);
        swap("windows", "create", one);
      })();

      // Errors in an extension's own pages and worker are told to the browser,
      // which lists them — the only window onto a worker there is.
      if (root.addEventListener) {
        const tell = (text) => { try { native("debug.error", [String(text).slice(0, 2000)]).catch(() => {}); } catch (e) {} };
        root.addEventListener("error", (e) => tell((e.message || "error") + " @ " + String(e.filename || "").split("/").slice(3).join("/") + ":" + e.lineno));
        root.addEventListener("unhandledrejection", (e) => tell("unhandled: " + (e.reason && ((e.reason.message || "") + " — " + (e.reason.stack || "")) || e.reason)));
        // (Bosk's own.) In a Debug build, the status of each request an extension page or worker
        // makes, and the server's answer when it fails: a login error that the extension hides
        // shows here. Never what is sent, and never a successful answer (it can hold tokens).
        if (__BOSK_VERBOSE__ && !inContent && typeof root.fetch === "function") {
          const fetch = root.fetch.bind(root);
          root.fetch = (input, init) => fetch(input, init).then((response) => {
            try {
              const where = new URL(response.url || String(input && input.url || input));
              const path = where.origin + where.pathname;
              if (response.ok) tell("fetch " + response.status + " " + path);
              else response.clone().text().then((text) => tell("fetch " + response.status + " " + path + " " + text.slice(0, 500)), () => {});
            } catch (e) {}
            return response;
          }, (error) => { tell("fetch failed " + String(input && input.url || input).split("?")[0] + " " + error); throw error; });
        }
        // (Bosk's own.) In a Debug build, each chrome.* call of an extension page or worker
        // that fails: an extension can hide the error, as Bitwarden's login does.
        if (__BOSK_VERBOSE__ && !inContent) {
          const watch = (ns, where) => {
            const names = new Set();
            for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
            for (const name of names) {
              if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
              let f; try { f = ns[name]; } catch (e) { continue; }
              if (typeof f === "function") {
                put(ns, name, (...args) => {
                  let result;
                  try { result = f.apply(ns, args); } catch (e) { tell("api " + where + name + " threw: " + (e && e.message || e)); throw e; }
                  if (result && typeof result.then === "function") result.then(null, (e) => tell("api " + where + name + " rejected: " + (e && e.message || e)));
                  return result;
                });
              } else if (f && typeof f === "object" && !Array.isArray(f) && where.split(".").length < 3) watch(f, where + name + ".");
            }
          };
          for (const space of Object.keys(chrome)) {
            let ns; try { ns = chrome[space]; } catch (e) { continue; }
            if (ns && typeof ns === "object") watch(ns, space + ".");
          }
        }
        // In a test run, what the extension says went wrong, too.
        if (__BOSK_VERBOSE__ && root.console) {
          let told = 0;
          for (const level of ["error", "warn"]) {
            const original = console[level].bind(console);
            console[level] = (...args) => {
              original(...args);
              if (told++ < 60) tell("console." + level + ": " + args.map((a) => {
                if (a instanceof Error) return a.message + " — " + (a.stack || "");
                try { return typeof a === "string" ? a : JSON.stringify(a); } catch (e) { return String(a); }
              }).join(" "));
            };
          }
        }
      }
    })();
    """#
}
