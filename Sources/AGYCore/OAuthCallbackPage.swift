import CryptoKit
import Foundation

enum OAuthCallbackPage {
    static func response(for callback: OAuthAttempt.Callback, language: AppLanguage = .simplifiedChinese) -> Data {
        let copy: (status: String, appearance: String, title: String.LocalizationValue, message: String.LocalizationValue) = switch callback {
        case .code:
            ("200 OK", "success", "Google 授权成功", "可以关闭此标签页，返回 AGY Switcher。")
        case .denied:
            ("200 OK", "cancelled", "授权已取消", "可以关闭此标签页，返回 AGY Switcher。")
        case .invalid:
            ("400 Bad Request", "invalid", "授权链接无效", "请返回 AGY Switcher，重新发起授权。")
        }
        let title = language.text(copy.title)
        let message = language.text(copy.message)

        let page = """
            <!doctype html>
            <html lang="\(language.rawValue)">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>\(title) · AGY Switcher</title>
              <style>\(stylesheet)</style>
            </head>
            <body>
              <main>
                <header class="brand"><span aria-hidden="true">⇄</span> AGY Switcher</header>
                <section class="card \(copy.appearance)" aria-labelledby="title">
                  <div class="status-icon" aria-hidden="true"></div>
                  <h1 id="title">\(title)</h1>
                  <p>\(message)</p>
                </section>
              </main>
            </body>
            </html>
            """

        let headers = "HTTP/1.1 \(copy.status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src '\(stylesheetHash)'\r\n\r\n"
        return Data((headers + page).utf8)
    }

    private static let stylesheetHash = "sha256-" + Data(SHA256.hash(data: Data(stylesheet.utf8))).base64EncodedString()

    private static let stylesheet = """
        :root {
          color-scheme: light dark;
          font-family: system-ui, "PingFang SC", "Microsoft YaHei", sans-serif;
          --background: #f4f7f6;
          --halo: #dbeee7;
          --surface: #fff;
          --ink: #172622;
          --muted: #546560;
          --border: #dce7e3;
          --shadow: rgb(29 66 55 / 10%);
          --success: #126950;
          --success-fill: #dff4eb;
          --warning: #8d510a;
          --warning-fill: #fdf0dc;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --background: #101716;
            --halo: #1b322b;
            --surface: #192421;
            --ink: #edf6f2;
            --muted: #afc1ba;
            --border: #31443e;
            --shadow: rgb(0 0 0 / 28%);
            --success: #8cdec1;
            --success-fill: #20473b;
            --warning: #f2c384;
            --warning-fill: #493625;
          }
        }
        * { box-sizing: border-box; }
        body {
          min-height: 100vh;
          min-height: 100svh;
          margin: 0;
          padding: 1.5rem;
          display: grid;
          place-items: center;
          color: var(--ink);
          background: radial-gradient(ellipse at 50% 26%, var(--halo), transparent 68%), var(--background);
          text-align: center;
        }
        main { width: min(100%, 31rem); }
        .brand {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: .55rem;
          margin-bottom: 1.25rem;
          font-size: .875rem;
          font-weight: 650;
        }
        .brand span {
          display: grid;
          place-items: center;
          width: 1.75rem;
          height: 1.75rem;
          border: 1px solid var(--border);
          border-radius: .55rem;
          background: var(--surface);
          color: var(--success);
          font-size: 1.125rem;
        }
        .card {
          padding: clamp(2rem, 7vw, 3.25rem) 1.5rem;
          border: 1px solid var(--border);
          border-radius: 1.75rem;
          background: var(--surface);
          box-shadow: 0 1rem 3rem var(--shadow);
        }
        .status-icon {
          display: grid;
          place-items: center;
          width: 4.25rem;
          height: 4.25rem;
          margin: 0 auto 1.5rem;
          border-radius: 1.4rem;
          background: var(--success-fill);
          color: var(--success);
        }
        .success .status-icon::before {
          content: "";
          width: .75rem;
          height: 1.45rem;
          border: solid currentColor;
          border-width: 0 .2rem .2rem 0;
          transform: translateY(-.2rem) rotate(45deg);
        }
        .cancelled .status-icon { background: var(--background); color: var(--muted); }
        .cancelled .status-icon::before { content: ""; width: 1.35rem; border-top: .2rem solid; }
        .invalid .status-icon { background: var(--warning-fill); color: var(--warning); }
        .invalid .status-icon::before { content: "!"; font-size: 1.75rem; font-weight: 700; }
        h1 { margin: 0; font-size: clamp(1.5rem, 5vw, 2rem); line-height: 1.3; }
        p { margin: .75rem 0 0; color: var(--muted); line-height: 1.7; }
        """
}
