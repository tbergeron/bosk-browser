import Foundation

/// The page script that removes ads from YouTube videos. YouTube sends its ads from the same
/// servers as the video, so the ad blocker's rule list cannot block them. The ads are fields in
/// the player data: in `ytInitialPlayerResponse` in the page, and in the JSON that the player gets
/// from `/youtubei/v1/player`. The script removes those fields before the player reads them.
/// It must run in the page world at document start, before the YouTube scripts.
///
/// When YouTube planned an ad that does not play, its video server sends a backoff (no video)
/// for the length of the ad: the video starts 10 to 15 s late. After the first backoff, the script
/// loads the video again at the same time with a changed player request, which YouTube answers
/// with no backoff at the start, and keeps the change for the next videos in the page.
/// Only one reload: each reload after it stops the video (measured 2026-10-03). The method comes
/// from uBlock Origin's YouTube filters; YouTube changes often, so it can stop working.
public enum YouTubeAdScript {
    /// The ad fields in a player response. The video data (`streamingData`) is not touched.
    static let adKeys = ["adPlacements", "adSlots", "playerAds"]

    /// - Parameter allowedSites: The sites where the user turned the ad blocker off. The script
    ///   does nothing on them. A YouTube frame in another site's page uses that page's site.
    public static func source(allowedSites: Set<String>) -> String {
        let sites = String(decoding: try! JSONSerialization.data(withJSONObject: allowedSites.sorted()), as: UTF8.self)
        let keys = String(decoding: try! JSONSerialization.data(withJSONObject: adKeys), as: UTF8.self)
        return #"""
            (() => {
              if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return;
              const origins = location.ancestorOrigins;
              const top = origins && origins.length ? new URL(origins[origins.length - 1]).hostname : location.hostname;
              const site = top.toLowerCase().replace(/^www\./, '');
              if (\#(sites).some((s) => site === s || site.endsWith('.' + s))) return;
              const keys = \#(keys);
              const clean = (response) => {
                if (response && typeof response === 'object') for (const key of keys) delete response[key];
              };

              // On after the first backoff. Off for good when YouTube refuses the changed request.
              let changed = false;
              let refused = false;
              let reloadedAt = 0;
              const loadAgain = () => {
                const player = document.getElementById('movie_player');
                if (!player || !player.loadVideoById || !player.getVideoData) return;
                reloadedAt = Date.now();
                player.loadVideoById(player.getVideoData().video_id, player.getCurrentTime ? player.getCurrentTime() : 0);
              };
              const onBackoff = () => {
                if (changed || refused) return;
                changed = true;
                loadAgain();
              };

              // Player responses come alone or inside `playerResponse` (the watch page data).
              const prune = (value) => {
                if (value && typeof value === 'object') {
                  clean(value);
                  clean(value.playerResponse);
                  // YouTube can refuse the changed request ("This content isn't available"). Then load the
                  // video with the normal request: it plays after the backoff.
                  if (changed && value.responseContext && value.playabilityStatus &&
                      value.playabilityStatus.status === 'UNPLAYABLE') {
                    changed = false;
                    refused = true;
                    setTimeout(loadAgain);
                  }
                }
                return value;
              };
              // A Proxy, so the functions still look native to the page.
              JSON.parse = new Proxy(JSON.parse, {
                apply: (target, self, args) => prune(Reflect.apply(target, self, args)),
              });
              if (typeof Response !== 'undefined') {
                Response.prototype.json = new Proxy(Response.prototype.json, {
                  apply: (target, self, args) => Reflect.apply(target, self, args).then(prune),
                });
              }
              // The page sets this with an object literal, not with JSON.parse.
              let initial;
              Object.defineProperty(window, 'ytInitialPlayerResponse', {
                configurable: true,
                get: () => initial,
                set: (value) => { initial = prune(value); },
              });

              // The player request is the only request with `attestationRequest`.
              JSON.stringify = new Proxy(JSON.stringify, {
                apply: (target, self, args) => {
                  const request = args[0];
                  if (changed && request && typeof request === 'object' && request.attestationRequest &&
                      request.context && request.context.client && request.playbackContext) {
                    request.params = '8AUB';
                    const context = request.playbackContext.contentPlaybackContext || {};
                    context.lactMilliseconds = String(Date.now());
                    context.referer = String(context.referer || '').replace(/(#reloadxhr)?$/, '#reloadxhr');
                  }
                  return Reflect.apply(target, self, args);
                },
              });

              // A video response is UMP: parts of (type, size, data). The backoff is field 4 of part 35
              // (the next request policy). Numbers in UMP: the leading 1 bits of the first byte give the length.
              const umpNumber = (bytes, i) => {
                const first = bytes[i];
                if (first < 0x80) return [first, i + 1];
                if (first < 0xc0) return [(first & 0x3f) + bytes[i + 1] * 64, i + 2];
                if (first < 0xe0) return [(first & 0x1f) + (bytes[i + 1] + bytes[i + 2] * 256) * 32, i + 3];
                if (first < 0xf0) return [(first & 0x0f) + (bytes[i + 1] + bytes[i + 2] * 256 + bytes[i + 3] * 65536) * 16, i + 4];
                return [bytes[i + 1] + bytes[i + 2] * 256 + bytes[i + 3] * 65536 + bytes[i + 4] * 16777216, i + 5];
              };
              const hasBackoff = (bytes) => {
                for (let i = 0; i < bytes.length;) {
                  let type, size;
                  [type, i] = umpNumber(bytes, i);
                  [size, i] = umpNumber(bytes, i);
                  const end = i + size;
                  if (type === 35) {
                    // Protocol buffer fields: (field << 3 | wire type), then the value.
                    const varint = () => { let value = 0, scale = 1, byte; do { byte = bytes[i++]; value += (byte & 127) * scale; scale *= 128; } while (byte & 128 && i < end); return value; };
                    while (i < end) {
                      const key = varint(), field = key >> 3, wire = key & 7;
                      if (wire === 0) { const value = varint(); if (field === 4 && value > 0) return true; }
                      else if (wire === 2) i += varint();
                      else if (wire === 5) i += 4;
                      else if (wire === 1) i += 8;
                      else break;
                    }
                  }
                  i = end;
                }
                return false;
              };
              // A backoff has no video, so it is small. Only small responses are read twice.
              window.fetch = new Proxy(window.fetch, {
                apply: (target, self, args) => {
                  const response = Reflect.apply(target, self, args);
                  const url = String(args[0] && args[0].url || args[0]);
                  if (/\.googlevideo\.com\/videoplayback/.test(url)) {
                    // A backoff for a request from before the last reload is old news.
                    const startedAt = Date.now();
                    response.then((r) => {
                      if (Number(r.headers.get('content-length')) > 1000) return;
                      return r.clone().arrayBuffer().then((buffer) => {
                        if (startedAt >= reloadedAt && hasBackoff(new Uint8Array(buffer))) onBackoff();
                      });
                    }).catch(() => {});
                  }
                  return response;
                },
              });
            })();
            """#
    }
}
