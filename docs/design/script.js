(function () {
  "use strict";

  var STORAGE_KEY = "shorthand.links";
  var DOMAIN = "short.hn";

  var form = document.getElementById("shorten-form");
  var urlInput = document.getElementById("url-input");
  var aliasInput = document.getElementById("alias-input");
  var urlError = document.getElementById("url-error");
  var aliasError = document.getElementById("alias-error");
  var result = document.getElementById("result");
  var resultOriginal = document.getElementById("result-original");
  var resultShort = document.getElementById("result-short");
  var copyBtn = document.getElementById("copy-btn");
  var anotherBtn = document.getElementById("another-btn");
  var recentWrap = document.getElementById("recent");
  var recentList = document.getElementById("recent-list");
  var toast = document.getElementById("toast");
  var toastText = document.getElementById("toast-text");

  var toastTimer = null;

  function loadLinks() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function saveLinks(links) {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(links));
    } catch (e) {
      /* storage unavailable — links still work for this session */
    }
  }

  function normalizeUrl(value) {
    var trimmed = value.trim();
    if (!trimmed) return null;
    if (!/^https?:\/\//i.test(trimmed)) {
      trimmed = "https://" + trimmed;
    }
    try {
      var parsed = new URL(trimmed);
      if (!parsed.hostname || parsed.hostname.indexOf(".") === -1) return null;
      return parsed.href;
    } catch (e) {
      return null;
    }
  }

  function slugify(value) {
    return value
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "");
  }

  function randomCode(len) {
    var chars = "abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRSTUVWXY23456789";
    var out = "";
    for (var i = 0; i < len; i++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }

  function setFieldError(input, errorEl, message) {
    errorEl.textContent = message || "";
    input.setAttribute("aria-invalid", message ? "true" : "false");
  }

  function truncate(value, max) {
    return value.length > max ? value.slice(0, max - 1) + "…" : value;
  }

  function showToast(message) {
    toastText.textContent = message;
    toast.classList.add("is-visible");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("is-visible");
    }, 2200);
  }

  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    var temp = document.createElement("textarea");
    temp.value = text;
    temp.setAttribute("readonly", "");
    temp.style.position = "absolute";
    temp.style.left = "-9999px";
    document.body.appendChild(temp);
    temp.select();
    try {
      document.execCommand("copy");
    } catch (e) {
      /* clipboard unavailable */
    }
    document.body.removeChild(temp);
    return Promise.resolve();
  }

  function renderRecent() {
    var links = loadLinks();
    if (!links.length) {
      recentWrap.hidden = true;
      return;
    }
    recentWrap.hidden = false;
    recentList.innerHTML = "";
    links.slice(0, 5).forEach(function (link) {
      var item = document.createElement("div");
      item.className = "recent-item";

      var text = document.createElement("div");
      var shortEl = document.createElement("div");
      shortEl.className = "short";
      shortEl.textContent = DOMAIN + "/" + link.code;
      var originalEl = document.createElement("div");
      originalEl.className = "original";
      originalEl.textContent = link.original;
      text.appendChild(shortEl);
      text.appendChild(originalEl);

      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "recent-copy";
      btn.setAttribute("aria-label", "Copy " + DOMAIN + "/" + link.code);
      btn.innerHTML =
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';
      btn.addEventListener("click", function () {
        copyToClipboard("https://" + DOMAIN + "/" + link.code).then(function () {
          showToast("Copied " + DOMAIN + "/" + link.code);
        });
      });

      item.appendChild(text);
      item.appendChild(btn);
      recentList.appendChild(item);
    });
  }

  function addLink(original, code) {
    var links = loadLinks();
    links = links.filter(function (l) {
      return l.code !== code;
    });
    links.unshift({ original: original, code: code, createdAt: Date.now() });
    saveLinks(links.slice(0, 20));
    renderRecent();
  }

  function existingCodeFor(url) {
    var links = loadLinks();
    for (var i = 0; i < links.length; i++) {
      if (links[i].original === url) return links[i].code;
    }
    return null;
  }

  function codeTaken(code) {
    return loadLinks().some(function (l) {
      return l.code === code;
    });
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();

    var rawUrl = urlInput.value;
    var rawAlias = aliasInput.value;
    var normalized = normalizeUrl(rawUrl);
    var hasError = false;

    if (!rawUrl.trim()) {
      setFieldError(urlInput, urlError, "Enter a URL to shorten.");
      hasError = true;
    } else if (!normalized) {
      setFieldError(urlInput, urlError, "That doesn't look like a valid URL.");
      hasError = true;
    } else {
      setFieldError(urlInput, urlError, "");
    }

    var alias = slugify(rawAlias);
    if (rawAlias.trim() && !alias) {
      setFieldError(aliasInput, aliasError, "Use letters, numbers, and dashes only.");
      hasError = true;
    } else if (alias && alias.length < 3) {
      setFieldError(aliasInput, aliasError, "Custom back-halves need at least 3 characters.");
      hasError = true;
    } else if (alias && codeTaken(alias)) {
      setFieldError(aliasInput, aliasError, "That back-half is already taken. Try another.");
      hasError = true;
    } else {
      setFieldError(aliasInput, aliasError, "");
    }

    if (hasError) {
      var firstInvalid = form.querySelector('[aria-invalid="true"]');
      if (firstInvalid) firstInvalid.focus();
      return;
    }

    var code = alias || existingCodeFor(normalized) || randomCode(6);
    while (!alias && codeTaken(code)) {
      code = randomCode(6);
    }

    addLink(normalized, code);

    resultOriginal.textContent = truncate(normalized, 64);
    resultOriginal.title = normalized;
    resultShort.textContent = DOMAIN + "/" + code;
    result.dataset.short = "https://" + DOMAIN + "/" + code;
    result.classList.add("is-visible");

    window.requestAnimationFrame(function () {
      result.scrollIntoView({ behavior: "smooth", block: "nearest" });
    });
  });

  copyBtn.addEventListener("click", function () {
    var value = result.dataset.short;
    if (!value) return;
    copyToClipboard(value).then(function () {
      showToast("Link copied to clipboard");
    });
  });

  anotherBtn.addEventListener("click", function () {
    result.classList.remove("is-visible");
    form.reset();
    setFieldError(urlInput, urlError, "");
    setFieldError(aliasInput, aliasError, "");
    urlInput.focus();
  });

  renderRecent();
})();
