import './styles.css';

const repoUrl = 'https://github.com/jasonkneen/openclicky';
const releasesUrl = `${repoUrl}/releases`;
const fallbackStats = {
  stars: 332,
  forks: 60,
  issues: 3,
};

const capabilities = [
  {
    title: 'Screen-aware answers',
    body: 'OpenClicky can use the current window as context, point at UI, and give grounded help without making you describe everything.',
  },
  {
    title: 'Background agents',
    body: 'Send coding, research, file, and automation tasks off to Agent Mode while the main companion stays available.',
  },
  {
    title: 'Native computer-use path',
    body: 'Use direct app control, local bridges, captions, and cursor overlays before falling back to visible browser or window automation.',
  },
  {
    title: 'Realtime voice flow',
    body: 'Use push-to-talk, toggle listening, and “Hey Clicky” style activation paths for fast spoken work with interruption-friendly feedback.',
  },
  {
    title: 'Browser Workspace',
    body: 'Keep web research and browser actions inside OpenClicky’s own workspace, with inline chat, page context, screenshots, and inspector notes.',
  },
  {
    title: 'Connected local skills',
    body: 'Route Gmail, Calendar, Drive, GitHub, Spotify, Notes, PDFs, spreadsheets, images, docs, and repo tasks through bundled local skills.',
  },
];

const workflow = [
  {
    title: 'Voice companion lane',
    body: 'Fast answers, screen-aware guidance, cursor labels, screenshots, web lookup, image galleries, and direct Mac actions.',
  },
  {
    title: 'Agent Mode lane',
    body: 'Autonomous coding, research, document work, browser automation, repo edits, tests, local files, and multi-step app workflows.',
  },
  {
    title: 'Local-first control',
    body: 'Secrets stay local, Google Workspace uses local gogcli, and OpenClicky avoids hosted key sync or forced cloud accounts.',
  },
  {
    title: 'Durable memory and skills',
    body: 'OpenClicky can remember stable preferences, learn repeated workflows, and reuse bundled or user-created skills across sessions.',
  },
];

const integrations = [
  'OpenAI and Anthropic model routes',
  'ElevenLabs and native voice output',
  'Google Workspace through local gogcli',
  'GitHub repo work and review flows',
  'Spotify, Apple Notes, PDFs, docs, sheets, and local files',
  'OpenClicky bridge endpoints for cursor, captions, screenshots, and speech',
];

function formatCompact(value) {
  return new Intl.NumberFormat('en-GB', {
    notation: 'compact',
    maximumFractionDigits: 1,
  }).format(value);
}

function statCard(id, value, label) {
  return `<div class="stat"><b id="${id}">${value}</b><span>${label}</span></div>`;
}

function renderApp(stats = fallbackStats) {
  document.querySelector('#app').innerHTML = `
    <header class="wrap nav" aria-label="Main navigation">
      <a class="brand" href="#top" aria-label="OpenClicky home"><span class="mark" aria-hidden="true">⌁</span> OpenClicky</a>
      <nav class="nav-links">
        <a href="#features">Features</a>
        <a href="#workflow">Workflow</a>
        <a href="#open-source">Open source</a>
        <a href="#download">Download</a>
        <a href="${repoUrl}">GitHub</a>
      </nav>
    </header>

    <main id="top">
      <section class="wrap hero">
        <div>
          <div class="eyebrow"><span class="dot" aria-hidden="true"></span> Native macOS companion for people who work out loud</div>
          <h1>Talk to your Mac. Let OpenClicky do the moving.</h1>
          <p class="lede">OpenClicky is a voice-first menu-bar companion with screen awareness, floating captions, a compact notch-style HUD, local background agents, and direct computer-use controls for real macOS work.</p>
          <div class="actions">
            <a class="button" href="${releasesUrl}">Download for macOS</a>
            <a class="button ghost" href="${repoUrl}">View source</a>
          </div>
          <div class="meta-row" aria-label="Project status">
            <a class="chip" href="${repoUrl}" aria-label="OpenClicky GitHub repository"><strong id="github-stars">${formatCompact(stats.stars)}</strong> GitHub stars</a>
            <span class="chip"><strong id="github-forks">${formatCompact(stats.forks)}</strong> forks</span>
            <span class="chip">MIT licensed</span>
            <span class="chip">Local-first</span>
          </div>
          <p class="requirements">Requires macOS 14.2 or newer. Direct distribution; bring your own OpenAI, Anthropic, and voice provider keys.</p>
        </div>

        <div class="mock" aria-label="OpenClicky product preview">
          <div class="screen">
            <div class="bar"><span class="pill"></span><span class="pill"></span><span class="pill"></span></div>
            <div class="panel-content">
              <span class="caption">Agent Mode</span>
              <p class="message">“Look at this window, fix the issue, and keep the app open while you work.”</p>
              <div class="agent-card">
                <strong>OpenClicky is working in the background</strong>
                <p>Screen context captured. Repo checked. Patch in progress. You keep talking; the agent keeps moving.</p>
              </div>
              <div class="agent-card">
                <strong>Cursor guidance without grabbing control</strong>
                <p>Point, label, type, search, read, build, and explain from the same compact macOS surface.</p>
              </div>
            </div>
          </div>
          <div class="caption-bubble">Click here</div>
          <div class="cursor" aria-hidden="true">➤</div>
        </div>
      </section>

      <section class="wrap section" id="features">
        <h2>Built for voice-led work, not chatbot theatre.</h2>
        <div class="grid">
          ${capabilities.map((item) => `<article class="card"><h3>${item.title}</h3><p>${item.body}</p></article>`).join('')}
        </div>
      </section>

      <section class="wrap section" id="workflow">
        <div class="split">
          <div>
            <h2>One companion, two lanes.</h2>
            <p class="lede">OpenClicky keeps quick voice help in the foreground and sends longer work to explicit background agents only when that is the right route.</p>
          </div>
          <ul class="stack">
            ${workflow.map((item) => `<li><strong>${item.title}</strong>${item.body}</li>`).join('')}
          </ul>
        </div>
      </section>

      <section class="wrap section integrations" id="integrations">
        <h2>Useful routes out of the box.</h2>
        <div class="integration-list">
          ${integrations.map((item) => `<span>${item}</span>`).join('')}
        </div>
      </section>

      <section class="wrap section" id="open-source">
        <h2>Open source, inspectable, and built in public.</h2>
        <div class="stat-strip" aria-label="GitHub repository statistics">
          ${statCard('stat-stars', formatCompact(stats.stars), 'GitHub stars')}
          ${statCard('stat-forks', formatCompact(stats.forks), 'forks')}
          ${statCard('stat-issues', formatCompact(stats.issues), 'open issues')}
          ${statCard('stat-license', 'MIT', 'licence')}
        </div>
        <p class="note">Stats load from the GitHub API for <a href="${repoUrl}">jasonkneen/openclicky</a>; the app includes current fallbacks so it still reads correctly offline.</p>
      </section>

      <section class="wrap download" id="download">
        <div class="download-inner">
          <div>
            <h2>Download OpenClicky</h2>
            <p>Install the macOS app, grant Accessibility, Microphone, and Screen Recording permissions, then add your local model keys in Settings.</p>
          </div>
          <a class="button" href="${releasesUrl}">Get OpenClicky</a>
        </div>
      </section>
    </main>

    <footer class="wrap">
      <p>OpenClicky is local-first direct-distribution software. No hosted Google login, no key sync, no forced cloud account. Expected site: <a href="https://openclicky.ai/">OpenClicky.ai</a>.</p>
    </footer>
  `;
}

async function getGitHubStats() {
  try {
    const response = await fetch('https://api.github.com/repos/jasonkneen/openclicky', {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!response.ok) return fallbackStats;
    const repo = await response.json();
    return {
      stars: Number(repo.stargazers_count) || fallbackStats.stars,
      forks: Number(repo.forks_count) || fallbackStats.forks,
      issues: Number(repo.open_issues_count) || fallbackStats.issues,
    };
  } catch {
    return fallbackStats;
  }
}

renderApp();
getGitHubStats().then(renderApp);
