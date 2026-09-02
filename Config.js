// Config layer: must's config.toml (subset), amla's plugin config, path helpers.
// Pure JS — no Quickshell imports — so it is unit-testable in isolation.

function expandTilde(p, home) {
  var s = String(p || "").trim()
  if (s === "~") return home
  if (s.indexOf("~/") === 0) return home + s.substring(1)
  return s
}

// Minimal TOML subset: [section] headers, key = 'str' | "str" | [ 'a', 'b' ].
// Numbers/bools come through as strings; amla only needs strings and string
// arrays. Anything unparseable is skipped, matching must's forgiving defaults.
function parseToml(text) {
  var root = {}
  var sections = {}
  var current = root
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var hashAt = findUnquoted(line, "#")
    if (hashAt >= 0)
      line = line.substring(0, hashAt)
    line = line.trim()
    if (!line)
      continue
    if (line.charAt(0) === "[") {
      var end = line.indexOf("]")
      if (end < 0)
        continue
      var name = line.substring(1, end).trim()
      if (!sections[name])
        sections[name] = {}
      current = sections[name]
      continue
    }
    var eq = findUnquoted(line, "=")
    if (eq < 0)
      continue
    var key = line.substring(0, eq).trim()
    var raw = line.substring(eq + 1).trim()
    current[key] = parseTomlValue(raw)
  }
  return { root: root, sections: sections }
}

function findUnquoted(line, ch) {
  var quote = ""
  for (var i = 0; i < line.length; i++) {
    var c = line.charAt(i)
    if (quote) {
      if (c === quote)
        quote = ""
    } else if (c === "'" || c === "\"") {
      quote = c
    } else if (c === ch) {
      return i
    }
  }
  return -1
}

function parseTomlValue(raw) {
  if (raw.charAt(0) === "[") {
    var inner = raw.substring(1, raw.lastIndexOf("]") >= 0 ? raw.lastIndexOf("]") : raw.length)
    var parts = []
    var buf = ""
    var quote = ""
    for (var i = 0; i < inner.length; i++) {
      var c = inner.charAt(i)
      if (quote) {
        if (c === quote)
          quote = ""
        else
          buf += c
      } else if (c === "'" || c === "\"") {
        quote = c
      } else if (c === ",") {
        if (buf.trim())
          parts.push(buf.trim())
        buf = ""
      } else {
        buf += c
      }
    }
    if (buf.trim())
      parts.push(buf.trim())
    return parts
  }
  if ((raw.charAt(0) === "'" && raw.charAt(raw.length - 1) === "'" && raw.length >= 2) ||
      (raw.charAt(0) === "\"" && raw.charAt(raw.length - 1) === "\"" && raw.length >= 2))
    return raw.substring(1, raw.length - 1)
  return raw
}

function strArray(v) {
  if (Array.isArray(v))
    return v.map(function (x) { return String(x) }).filter(function (x) { return x.length > 0 })
  var s = String(v || "").trim()
  return s.length > 0 ? [s] : []
}

function truthy(v) {
  return String(v).toLowerCase() === "true"
}

// must config.toml → amla's view of it.
function mustConfig(text, home) {
  var parsed = parseToml(text)
  var root = parsed.root
  var sub = parsed.sections.subsonic || {}

  var musicDirs = strArray(root.music_dirs)
  if (musicDirs.length === 0)
    musicDirs = strArray(root.music_dir)
  if (musicDirs.length === 0)
    musicDirs = ["~/Music"]

  return {
    musicDirs: musicDirs.map(function (p) { return expandTilde(p, home) }),
    tempDirs: strArray(root.temp_dirs).map(function (p) { return expandTilde(p, home) }),
    subsonic: {
      enabled: sub.enabled !== undefined ? truthy(sub.enabled) : false,
      url: String(sub.url || "").replace(/\/+$/, ""),
      username: String(sub.username || ""),
      password: String(sub.password || ""),
      serverName: String(sub.server_name || "Subsonic"),
      serverBadge: String(sub.server_badge || "S")
    }
  }
}

// amla plugin config (~/.config/amla/config.json).
function parsePluginConfig(text) {
  var obj = {}
  try { obj = JSON.parse(String(text || "{}")) } catch (e) { obj = {} }
  return {
    targetPlayer: obj.targetPlayer === "cliamp" ? "cliamp" : "must",
    mustBin: obj.mustBin === undefined ? "" : String(obj.mustBin)
  }
}

function serializePluginConfig(cfg) {
  return JSON.stringify({
    targetPlayer: cfg.targetPlayer,
    mustBin: cfg.mustBin || ""
  }, null, 2) + "\n"
}
