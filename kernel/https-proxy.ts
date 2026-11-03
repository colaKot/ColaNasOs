import http from 'node:http';
import https from 'node:https';
import net from 'node:net';

/**
 * HTTPS 入口：TLS 终止后把 HTTP 请求（以及 WebSocket upgrade）转发到内核的
 * 本机 HTTP 监听。这样 HTTPS 是**额外入口**，不影响 Electron / 内部 HTTP。
 *
 * 只绑 0.0.0.0 的 httpsPort；目标固定 127.0.0.1:targetPort，避免开代理成开放转发。
 */
export interface HttpsProxyOptions {
  port: number;
  targetPort: number;
  cert: string;
  key: string;
  log: { info: (msg: string) => void; warn: (msg: string, err?: unknown) => void };
}

export interface HttpsProxyHandle {
  close(): void;
}

export function startHttpsProxy(opts: HttpsProxyOptions): HttpsProxyHandle | null {
  let server: https.Server;
  try {
    server = https.createServer({ cert: opts.cert, key: opts.key }, (req, res) => {
      const upstream = http.request(
        {
          host: '127.0.0.1',
          port: opts.targetPort,
          method: req.method,
          path: req.url,
          headers: { ...req.headers, host: `127.0.0.1:${opts.targetPort}` },
        },
        (up) => {
          res.writeHead(up.statusCode ?? 502, up.headers);
          up.pipe(res);
        },
      );
      upstream.on('error', () => {
        if (!res.headersSent) res.writeHead(502);
        res.end('bad gateway');
      });
      req.pipe(upstream);
    });

    // WebSocket / SSE upgrade：TLS 层已解密，按原始 HTTP 报文转发到内部端口
    server.on('upgrade', (req, socket, head) => {
      const target = net.connect(opts.targetPort, '127.0.0.1');
      target.on('connect', () => {
        const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
        for (let i = 0; i < req.rawHeaders.length; i += 2) {
          lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
        }
        lines.push('', '');
        target.write(lines.join('\r\n'));
        if (head?.length) target.write(head);
        socket.pipe(target);
        target.pipe(socket);
      });
      target.on('error', () => socket.destroy());
      socket.on('error', () => target.destroy());
    });

    server.on('error', (err) => {
      opts.log.warn(`https proxy error: ${String(err)}`);
    });
    server.listen(opts.port, '0.0.0.0', () => {
      opts.log.info(`https entry listening on ${opts.port}`);
    });
    return {
      close: () => {
        try {
          server.close();
        } catch {
          /* 已关闭 */
        }
      },
    };
  } catch (err) {
    opts.log.warn(`https proxy failed: ${String(err)}`);
    return null;
  }
}