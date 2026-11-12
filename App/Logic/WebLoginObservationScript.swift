import Foundation

enum WebLoginObservationScript {
  static func source(service: WebLoginService) -> String {
    guard service == .mobile || service == .xunlei else { return "" }
    // 只观察服务网页自己发送的授权头，不发起请求、不读取正文。
    return """
      (() => {
        const domain = '\(service.domain)';
        const isMobile = \(service == .mobile ? "true" : "false");
        const observe = (rawURL, authorization) => {
          try {
            const target = new URL(rawURL, location.href);
            if (target.protocol !== 'https:' || !(target.hostname === domain || target.hostname.endsWith('.' + domain))) return;
            if (typeof authorization !== 'string') return;
            if (!(isMobile ? /^Basic /i : /^Token /i).test(authorization)) return;
            const result = { authorization };
            if (isMobile) {
              const auth = window.MCloudVM && window.MCloudVM.$store && window.MCloudVM.$store.state.auth;
              if (auth && typeof auth.accountPhone === 'string') result.phone = auth.accountPhone;
              if (auth && auth.userDomainId != null) result.userDomainID = String(auth.userDomainId);
            }
            window.webkit.messageHandlers.diskitWebLogin.postMessage(result);
          } catch (_) {}
        };
        const originalFetch = window.fetch;
        if (originalFetch) window.fetch = function(input, init) {
          try {
            const headers = new Headers(init && init.headers || input && input.headers || {});
            observe(typeof input === 'string' || input instanceof URL ? input : input.url, headers.get('Authorization'));
          } catch (_) {}
          return originalFetch.apply(this, arguments);
        };
        const urls = new WeakMap();
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
          urls.set(this, url);
          return originalOpen.apply(this, arguments);
        };
        const originalSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          if (String(name).toLowerCase() === 'authorization') observe(urls.get(this), value);
          return originalSetHeader.apply(this, arguments);
        };
      })();
      """
  }
}
