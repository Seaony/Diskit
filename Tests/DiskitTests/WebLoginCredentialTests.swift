import Foundation
import JavaScriptCore
import Testing

@Test func webLoginAuthorizationExtractsOnlyExpectedSchemes() {
  let token = Data("pc:13800138000:local-only".utf8).base64EncodedString()
  let mobile = WebLoginCredentialParser.authorization(
    "Basic " + token, service: .mobile, userDomainID: "space")
  #expect(mobile?.phone == "13800138000")
  #expect(mobile?.token == token)
  #expect(mobile?.userDomainID == "space")
  #expect(
    WebLoginCredentialParser.authorization("Basic " + token, service: .mobile, phone: "other")
      == nil)
  #expect(WebLoginCredentialParser.authorization("Token local", service: .xunlei)?.token == "local")
  #expect(
    WebLoginCredentialParser.manual("Authorization: Token local", service: .xunlei)?.token
      == "local")
  #expect(
    WebLoginCredentialParser.manual("Cookie: phpdisk_info=local", service: .lanzou)?.cookie
      == "phpdisk_info=local")
  #expect(WebLoginCredentialParser.authorization("Bearer local", service: .xunlei) == nil)
  #expect(
    WebLoginCredentialParser.authorization("Token local\r\nInjected", service: .xunlei) == nil)
}

@Test func webLoginCookiesStayWithinServiceAndRequireLoginMarkers() throws {
  func cookie(_ name: String, _ value: String, _ domain: String) throws -> HTTPCookie {
    try #require(
      HTTPCookie(properties: [
        .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
      ]))
  }
  let cookies = try [
    cookie("__pus", "local-one", ".quark.cn"), cookie("__puus", "local-two", ".quark.cn"),
    cookie("steal", "ignored", "quark.cn.attacker.invalid"),
  ]
  #expect(
    WebLoginCredentialParser.cookies(cookies, service: .quark)?.cookie
      == "__pus=local-one; __puus=local-two")
  #expect(WebLoginCredentialParser.cookies(cookies, service: .uc) == nil)
  #expect(
    try WebLoginCredentialParser.cookies(
      [cookie("tracking", "local", ".woozooo.com")], service: .lanzou) == nil)
  #expect(!WebLoginService.xunlei.allows(URL(string: "https://xunlei.com.attacker.invalid")))
  #expect(!WebLoginService.xunlei.allows(URL(string: "http://pan.xunlei.com")))
}

@MainActor @Test func demoWebLoginNeverRunsRealValidation() async throws {
  var validationCalled = false
  let result: Result<WebLoginCredentials, Error> = await withCheckedContinuation { continuation in
    let state = WebLoginState(
      service: .xunlei, options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]), demoWait: {},
      validate: { _ in validationCalled = true }
    ) {
      continuation.resume(returning: $0)
    }
    state.demonstrateSuccess()
  }
  #expect(!validationCalled)
  #expect(try result.get().token == "demo-local-only")
}

@MainActor @Test func demoWebLoginErrorReloadStaysLocal() {
  let state = WebLoginState(
    service: .mobile,
    options: RuntimeOptions(environment: ["DISKIT_DEMO": "1", "DISKIT_DEMO_STATE": "web-error"]),
    validate: { _ in Issue.record("演示不应调用真实校验") }, finish: { _ in })
  #expect(state.loadError != nil)
  state.reload()
  #expect(state.loadError == nil)
  #expect(state.reloadID == 0)
  #expect(!state.isLoading)
}

@MainActor @Test func closedWebLoginIgnoresLateCredentials() {
  var completed = false
  let state = WebLoginState(
    service: .xunlei, options: RuntimeOptions(environment: ["DISKIT_DEMO": "1"]), demoWait: {},
    validate: { _ in Issue.record("关闭后不能校验") }, finish: { _ in completed = true })
  state.stop()
  state.capture(WebLoginCredentials(token: "late"), manual: true)
  #expect(!state.checking)
  #expect(!completed)
}

@Test func webLoginRejectsMalformedMobileIdentityAndUnsafeManualHeaders() {
  for decoded in ["pc::token", "pc:phone:", "web:phone:token", "pc:phone", "pc:bad\nphone:token"] {
    let encoded = Data(decoded.utf8).base64EncodedString()
    #expect(WebLoginCredentialParser.authorization("Basic " + encoded, service: .mobile) == nil)
  }
  for value in ["Basic !", "Basic ", "Bearer token"] {
    #expect(WebLoginCredentialParser.authorization(value, service: .mobile) == nil)
  }
  #expect(WebLoginCredentialParser.authorization("Basic /w==", service: .mobile) == nil)
  #expect(WebLoginCredentialParser.authorization("Token two words", service: .xunlei) == nil)
  #expect(WebLoginCredentialParser.authorization("Token ", service: .xunlei) == nil)
  #expect(WebLoginCredentialParser.authorization("Token value", service: .quark) == nil)
  #expect(WebLoginCredentialParser.manual("Cookie: ", service: .tianyi) == nil)
  #expect(WebLoginCredentialParser.manual("a=1\r\nb=2", service: .uc) == nil)
  let token = Data("pc:phone:token:with:colons".utf8).base64EncodedString()
  let result = WebLoginCredentialParser.manual(
    " Authorization: Basic " + token + "\n", service: .mobile, phone: "phone", userDomainID: "bad\nspace")
  #expect(result?.phone == "phone")
  #expect(result?.token == token)
  #expect(result?.userDomainID == nil)
  #expect(WebLoginCredentialParser.manual("local", service: .xunlei)?.token == "local")
}

@Test(arguments: [WebLoginService.mobile, .xunlei])
func webLoginObservationPreservesRequestsAndRejectsForeignHeaders(service: WebLoginService) throws {
  let context = try #require(JSContext())
  context.evaluateScript("""
    var messages = [], calls = [];
    var location = { href: 'https://\(service.domain)/' };
    class URL {
      constructor(raw) {
        var match = new RegExp('^(https?:)//([^/]+)').exec(String(raw));
        if (!match) throw Error('invalid');
        this.protocol = match[1]; this.hostname = match[2]; this.href = String(raw);
      }
    }
    class Headers {
      constructor(value) { this.value = value; }
      get(name) { return this.value[name] || null; }
    }
    function XMLHttpRequest() {}
    XMLHttpRequest.prototype.open = function(method, url) { calls.push(['open', method, url]); return 'opened'; };
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) { calls.push(['header', name, value]); return 'set'; };
    var sentinel = {};
    var window = {
      MCloudVM: { $store: { state: { auth: { accountPhone: 'phone', userDomainId: 42 } } } },
      webkit: { messageHandlers: { diskitWebLogin: { postMessage: value => messages.push(value) } } },
      fetch: function(input, init) { calls.push(['fetch', input, init]); return sentinel; }
    };
    """)
  #expect(context.exception == nil)
  context.evaluateScript(WebLoginObservationScript.source(service: service))
  #expect(context.exception == nil)
  let prefix = service == .mobile ? "Basic" : "Token"
  context.evaluateScript("""
    var own = 'https://\(service.domain)/request';
    var header = { headers: { Authorization: '\(prefix) local' } };
    var preserved = window.fetch(own, header) === sentinel;
    window.fetch('https://\(service.domain).attacker.invalid/request', header);
    window.fetch('http://\(service.domain)/request', header);
    window.fetch(own, { headers: { Authorization: 'Bearer rejected' } });
    var xhr = new XMLHttpRequest();
    var opened = xhr.open('POST', own);
    var set = xhr.setRequestHeader('Authorization', '\(prefix) second');
    """)
  #expect(context.exception == nil)
  #expect(context.objectForKeyedSubscript("preserved")?.toBool() == true)
  #expect(context.objectForKeyedSubscript("opened")?.toString() == "opened")
  #expect(context.objectForKeyedSubscript("set")?.toString() == "set")
  #expect(context.evaluateScript("calls.length")?.toInt32() == 6)
  #expect(context.evaluateScript("messages.length")?.toInt32() == 2)
  #expect(context.evaluateScript("messages[0].authorization")?.toString() == "\(prefix) local")
  #expect(context.evaluateScript("messages[1].authorization")?.toString() == "\(prefix) second")
  if service == .mobile {
    #expect(context.evaluateScript("messages[0].phone")?.toString() == "phone")
    #expect(context.evaluateScript("messages[0].userDomainID")?.toString() == "42")
  } else {
    #expect(context.evaluateScript("'phone' in messages[0]")?.toBool() == false)
  }
}

@Test func webLoginCookieServicesDoNotInstallRequestObserver() {
  for service in [WebLoginService.quark, .uc, .tianyi, .lanzou] {
    #expect(WebLoginObservationScript.source(service: service).isEmpty)
  }
}
