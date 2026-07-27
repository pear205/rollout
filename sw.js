/* =========================================================
   오늘도 출동 — 서비스워커
   하위 경로 배포(https://pear205.github.io/rollout/) 기준이므로
   모든 경로는 반드시 상대경로로 쓴다 (self.location 기준으로 풀린다).
   ========================================================= */

const VERSION = 'v1';
const SHELL_CACHE = `rollout-shell-${VERSION}`;
const RUNTIME_CACHE = `rollout-runtime-${VERSION}`;
const CURRENT_CACHES = [SHELL_CACHE, RUNTIME_CACHE];

// 앱 셸 — 오프라인에서도 핵심 기능(준비물 계산)이 돌아가야 하므로 미리 채워둔다
const SHELL_URLS = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-192-maskable.png',
  './icons/icon-512-maskable.png',
  './icons/icon.svg'
];

// index.html이 실제로 불러오는, 버전이 고정된 외부 정적 자원 — cache-first가 맞는 대상
//   - fonts.googleapis.com / fonts.gstatic.com : Space Grotesk (Google Fonts)
//   - cdn.jsdelivr.net : Pretendard Variable css, @supabase/supabase-js@2 UMD 번들
const CDN_CACHE_FIRST_HOSTS = [
  'fonts.googleapis.com',
  'fonts.gstatic.com',
  'cdn.jsdelivr.net'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then(cache => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(names => Promise.all(
        names
          .filter(name => name.startsWith('rollout-') && !CURRENT_CACHES.includes(name))
          .map(name => caches.delete(name))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);

  // Supabase 요청(인증 토큰·유저 데이터 포함) — 절대 가로채거나 캐시하지 않는다.
  // respondWith를 호출하지 않으면 브라우저 기본 네트워크 경로로 그대로 나간다.
  if (url.hostname === 'supabase.co' || url.hostname.endsWith('.supabase.co')) {
    return;
  }

  // GET 이외(POST/PATCH/DELETE 등)는 캐시 대상이 아니다. 기본 동작에 맡긴다.
  if (req.method !== 'GET') {
    return;
  }

  const isAppShellDoc = req.mode === 'navigate' || url.pathname.endsWith('/index.html');

  // 앱 셸 문서: network-first. cache-first로 하면 배포해도 옛 화면이 계속 보인다.
  if (isAppShellDoc) {
    event.respondWith(networkFirst(req));
    return;
  }

  // 버전 고정된 외부 CDN 정적 자원: cache-first
  if (CDN_CACHE_FIRST_HOSTS.includes(url.hostname)) {
    event.respondWith(cacheFirst(req));
    return;
  }

  // 같은 출처의 나머지 정적 자원(manifest.json, 아이콘 등): stale-while-revalidate
  if (url.origin === self.location.origin) {
    event.respondWith(staleWhileRevalidate(req));
    return;
  }

  // 그 외 출처는 서비스워커가 관여하지 않는다.
});

async function networkFirst(req) {
  try {
    const fresh = await fetch(req);
    const cache = await caches.open(SHELL_CACHE);
    cache.put(req, fresh.clone());
    return fresh;
  } catch (err) {
    const cached = await caches.match(req, { ignoreSearch: true });
    if (cached) return cached;
    const shell = await caches.match('./index.html');
    if (shell) return shell;
    return new Response(
      '오프라인 상태이고 캐시된 화면도 없어요. 한 번이라도 접속한 뒤 다시 시도해주세요.',
      { status: 503, statusText: 'Offline', headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
    );
  }
}

async function cacheFirst(req) {
  const cached = await caches.match(req);
  if (cached) return cached;
  try {
    const fresh = await fetch(req);
    const cache = await caches.open(RUNTIME_CACHE);
    cache.put(req, fresh.clone());
    return fresh;
  } catch (err) {
    return new Response('', { status: 504, statusText: 'Offline' });
  }
}

async function staleWhileRevalidate(req) {
  const cache = await caches.open(RUNTIME_CACHE);
  const cached = await cache.match(req);
  const networkPromise = fetch(req)
    .then(fresh => { cache.put(req, fresh.clone()); return fresh; })
    .catch(() => null);
  return cached || (await networkPromise) || new Response('', { status: 504, statusText: 'Offline' });
}
