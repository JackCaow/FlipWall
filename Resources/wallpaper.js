(() => {
  'use strict';
  const wall = document.getElementById('wall');
  let library = [], tiles = [], generation = 0;
  let pictures = new Map();
  let paused = false, last = 0, wave = 0, elapsed = 0, lastSlot = -1, actualColumns = 5;
  let options = { columns: 5, interval: 3, duration: 1.25, brightness: .78, paused: false, epoch:0 };
  let active = null;
  const sample = (unavailable, target, board) => {
    const candidates = library.filter(v => !unavailable.has(v.id));
    const counts = new Map(), adjacent = new Set();
    for (const tile of board) {
      if (tile === target) continue;
      const channel = (tile.pendingVideo || tile.video).channel;
      counts.set(channel,(counts.get(channel) || 0) + 1);
      if (Math.abs(tile.row-target.row) + Math.abs(tile.col-target.col) === 1) adjacent.add(channel);
    }
    let winner = null, best = Infinity;
    for (const video of candidates) {
      const score = (counts.get(video.channel) || 0) * 10 + (adjacent.has(video.channel) ? 30 : 0)
          + (target.video?.channel === video.channel ? 25 : 0) + Math.random();
      if (score < best) { best = score; winner = video; }
    }
    return winner;
  };
  function picture(video) {
    const img = new Image();
    img.src = video.image;
    img.alt = video.title;
    img.dataset.videoId = video.id;
    img.draggable = false;
    return img;
  }
  function build(force = false) {
    if (!library.length) return;
    let columns = Math.min(8, Math.max(1, Math.round(options.columns)));
    const rowCount = columns => Math.min(10, Math.max(1, Math.round(columns * innerHeight / innerWidth * 16 / 9)));
    // Keep two fresh covers available for a pair, or one for a single row.
    let rows = rowCount(columns);
    while (columns > 1 && columns * rows + (rows > 1 ? 2 : 1) > library.length) {
      columns--;
      rows = rowCount(columns);
    }
    rows = Math.min(rows, Math.max(1, Math.floor((library.length - 2) / columns)));
    if (!force && actualColumns === columns && tiles.length === columns * rows) return;
    active = null;
    actualColumns = columns;
    wall.style.gridTemplateColumns = `repeat(${columns},minmax(0,1fr))`;
    wall.style.gridTemplateRows = `repeat(${rows},minmax(0,1fr))`;
    const board = document.createDocumentFragment();
    const assigned = [], used = new Set();
    tiles = Array.from({length: columns * rows}, (_, i) => {
      const location = {row:Math.floor(i / columns),col:i % columns};
      const video = sample(used,location,assigned);
      used.add(video.id);
      const node = document.createElement('div'); node.className = 'tile';
      const cover = document.createElement('div');
      cover.className = 'face';
      cover.append(pictures.get(video.id));
      const flap = document.createElement('div');
      flap.className = 'face flap';
      node.append(cover, flap);
      board.append(node);
      const tile = {node, cover, flap, video, ...location};
      assigned.push(tile);
      return tile;
    });
    wall.replaceChildren(board);
    wave = 0; lastSlot = -1;
    last = 0;
  }
  function nextWave(slot, start) {
    const index = slot % tiles.length;
    const first = tiles[index];
    const below = tiles[index + actualColumns];
    const selected = below ? [first, below] : [first];
    const unavailable = new Set(tiles.map(tile => tile.video.id));
    if (library.length - unavailable.size < selected.length) return;

    const updates = selected.map(tile => {
      const video = sample(unavailable, tile, tiles);
      unavailable.add(video.id);
      tile.pendingVideo = video;
      return {tile, video, image: pictures.get(video.id)};
    });
    // The moving sheet's front is the old upper cover. Its back is the new
    // lower cover, drawn in the lower tile so it lands upright at full size.
    first.node.classList.add('peeling');
    first.node.classList.toggle('paired', Boolean(below));
    first.flap.replaceChildren(first.cover.firstElementChild);
    first.cover.replaceChildren(updates[0].image);
    if (below) {
      below.node.classList.add('landing');
      below.flap.replaceChildren(updates[1].image);
    }
    active = {first, below, updates, start};
    wave = slot + 1;
  }

  function renderFlap(tile, angle) {
    const edgeOn = Math.abs(angle) >= 90;
    tile.flap.style.visibility = edgeOn ? 'hidden' : 'visible';
    tile.flap.style.transform = `rotateX(${angle}deg)`;
    tile.flap.style.setProperty('--shade', String(.36 * Math.abs(angle) / 90));
  }

  function tick(stamp) {
    if (paused || !tiles.length) return 500;
    const dt = last ? Math.max(0, stamp - last) : 0;
    last = stamp;
    if (!options.epoch) options.epoch = stamp;
    const period = Math.max(1500, options.interval * 1000);
    const relative = stamp - options.epoch - 650;
    const slot = Math.floor(relative / period);
    if (slot >= 0 && slot !== lastSlot && !active) {
      const start = options.epoch + 650 + slot * period;
      // Joining a display late must not replay several missed waves.
      if (stamp - start < 200) nextWave(slot, start);
      lastSlot = slot;
    }
    if (active) {
      const {first, below, updates, start} = active;
      const p = Math.min(1, Math.max(0, (stamp - start) / (options.duration * 1000)));
      const rotation = 180 * p * p * (3 - 2 * p);
      if (p === 1 || (!below && rotation >= 90)) {
        for (const {tile, video, image} of updates) {
          if (image.parentElement !== tile.cover) tile.cover.replaceChildren(image);
          tile.flap.style.visibility = 'hidden';
          tile.flap.replaceChildren();
          tile.video = video;
          tile.pendingVideo = null;
        }
        first.node.classList.remove('peeling', 'paired');
        below?.node.classList.remove('landing');
        active = null;
      } else {
        renderFlap(first, -Math.min(90, rotation));
        if (below) renderFlap(below, Math.min(90, 180 - rotation));
      }
    }
    elapsed += dt;
    const next = options.epoch + 650 + (Math.max(-1,slot) + 1) * period;
    return active ? 1000 / 30 : Math.max(33, next - stamp);
  }
  function setPaused(value) {
    paused = Boolean(value);
    last = 0;
  }
  window.flipWall = {
    // The native AppKit host advances the clock. Desktop WKWebViews can
    // suspend requestAnimationFrame when Finder occludes their window.
    advance: tick,
    videoAt(x, y) {
      const face = document.elementFromPoint(x, y)?.closest('.face');
      return face?.querySelector('img')?.dataset.videoId ?? null;
    },
    async setLibrary(videos) {
      const version = ++generation;
      const ready = await Promise.all(videos.map(async video => {
        try {
          const img = picture(video);
          await img.decode();
          return {video, img};
        } catch (_) {
          return null;
        }
      }));
      if (generation !== version) return false;
      const decoded = ready.filter(Boolean);
      if (!decoded.length) return false;
      const unique = new Map(decoded.map(entry => [entry.video.id, entry]));
      library = [...unique.values()].map(({video}) => video);
      pictures = new Map([...unique].map(([id, {img}]) => [id, img]));
      build(true);
      return true;
    },
    configure(config) {
      const columnsChanged = config.columns !== undefined && config.columns !== options.columns;
      if (active && options.epoch && config.epoch) {
        active.start += config.epoch - options.epoch;
      }
      options = {...options, ...config};
      document.documentElement.style.setProperty('--brightness', String(options.brightness));
      if (columnsChanged) build();
      setPaused(options.paused);
    },
    status() {
      return {effect:'peel-down', ready:library.length > 0, images:library.length, tiles:tiles.length, paused,
              active:active ? 1 : 0, elapsed, wave, columns:actualColumns, epoch:options.epoch, interval:options.interval,
              currentIDs:tiles.map(tile=>tile.video.id), pendingIDs:active?.updates.map(({video}) => video.id) ?? [],
              pendingPositions:active?.updates.map(({tile}) => ({row:tile.row, col:tile.col})) ?? [],
              currentChannels:tiles.map(tile=>tile.video.channel),
              loaded:[...wall.querySelectorAll('img')].every(img => img.complete && img.naturalWidth > 0),
              transforms:active?.updates.flatMap(({tile}) => tile.flap.style.visibility === 'visible'
                ? [tile.flap.style.transform] : []) ?? []};
    }
  };
  let resizeTimer;
  window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(build,150); });
})();
