// PanelFullscreen.swift
// Makes "fullscreen" inside a web panel fill just that panel instead of the whole display.
// The page's fullscreen calls are replaced with a CSS takeover of the panel, and the page is told
// it's fullscreen (fullscreenElement + fullscreenchange events), so YouTube's own UI keeps working.

import WebKit

enum PanelFullscreen {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private static let source = #"""
    (() => {
      if (window.__panelFullscreen) return;
      window.__panelFullscreen = true;
      let current = null;     // element actually filling the panel
      let requested = null;   // element the page asked to make fullscreen (what it expects to read back)

      const style = document.createElement('style');
      style.textContent = `
        .__pd-fs { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
                   max-width: none !important; max-height: none !important; margin: 0 !important;
                   transform: none !important; z-index: 2147483647 !important; background: #000 !important; }
        html.__pd-fs-root, html.__pd-fs-root body { overflow: hidden !important; }`;
      const addStyle = () => { if (!style.isConnected) (document.head || document.documentElement).appendChild(style); };

      // Like a real browser: the change is announced on a later tick, once, bubbling up to document.
      const announce = (el) => setTimeout(() => {
        const target = el.isConnected ? el : document;
        target.dispatchEvent(new Event('fullscreenchange', { bubbles: true }));
        target.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: true }));
        window.dispatchEvent(new Event('resize'));
      }, 0);

      // Sites like YouTube ask for the *whole page* to go fullscreen and rely on the window growing.
      // In a panel that would change nothing, so fill the panel with the main video's player instead.
      const videoPlayerFor = (el) => {
        if (el !== document.documentElement && el !== document.body && !el.contains(document.querySelector('video'))) return el;
        const videos = [...document.querySelectorAll('video')]
          .map(v => ({ v, r: v.getBoundingClientRect() }))
          .filter(({ r }) => r.width > 0 && r.height > 0)
          .sort((a, b) => b.r.width * b.r.height - a.r.width * a.r.height);
        if (!videos.length) return el;
        const v = videos[0].v;
        return v.closest('#movie_player, .html5-video-player, [data-player], .video-player, .player') || v.parentElement || v;
      };

      function enter() {
        // A second request while already filling the panel (e.g. the fullscreen button again) toggles back.
        if (current) return leave();
        const el = videoPlayerFor(this);
        requested = this;
        addStyle();
        current = el;
        el.classList.add('__pd-fs');
        document.documentElement.classList.add('__pd-fs-root');
        announce(el);
        return Promise.resolve();
      }

      function leave() {
        const el = current;
        if (!el) return Promise.resolve();
        current = null;
        requested = null;
        el.classList.remove('__pd-fs');
        document.documentElement.classList.remove('__pd-fs-root');
        announce(el);
        return Promise.resolve();
      }

      for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'])
        Element.prototype[name] = enter;
      for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'])
        Document.prototype[name] = leave;
      for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'])
        Object.defineProperty(Document.prototype, name, { get: () => requested, configurable: true });
      for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled', 'webkitFullScreenKeyboardInputAllowed'])
        Object.defineProperty(Document.prototype, name, { get: () => true, configurable: true });
      Object.defineProperty(Document.prototype, 'webkitIsFullScreen', { get: () => !!current, configurable: true });

      // Bare <video> fullscreen (used by some players).
      HTMLVideoElement.prototype.webkitEnterFullscreen = function () { enter.call(this); };
      HTMLVideoElement.prototype.webkitEnterFullScreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
      HTMLVideoElement.prototype.webkitExitFullscreen = function () { leave(); };

      // Esc leaves panel-fullscreen, like it would real fullscreen.
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && current) { e.stopImmediatePropagation(); leave(); }
      }, true);
    })();
    """#
}
