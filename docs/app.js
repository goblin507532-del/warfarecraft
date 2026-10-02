/* Site wiring: download links, IP copy, screenshot gallery, build version and the release list.
   Everything is read from config.js + the GitHub API, so the page stays static and needs no hosting. */
(function () {
  "use strict";

  var cfg = window.WARFARE || {};

  /* site.json holds every editable text and link; the admin page writes it, config.js stays as the fallback.
     It is fetched before anything else so the page never flashes the built-in copy. */
  function applySite(site) {
    if (!site) return;
    var text = {
      "t-eyebrow": site.eyebrow, "t-lead": site.lead, "t-about": site.aboutSub,
      "t-start": site.startSub, "t-shots": site.shotsSub, "t-updates": site.updatesSub,
      "t-donate": site.donateSub, "t-fine": site.fineprint
    };
    Object.keys(text).forEach(function (id) {
      var el = document.getElementById(id);
      if (el && text[id]) el.textContent = text[id];
    });
    var titleEl = document.getElementById("t-title");
    if (titleEl && site.title) titleEl.innerHTML = site.title;

    if (Array.isArray(site.cards) && site.cards.length) {
      var grid = document.getElementById("about-grid");
      if (grid) {
        grid.innerHTML = "";
        site.cards.forEach(function (card) {
          var article = document.createElement("article");
          article.className = "card";
          var h = document.createElement("h3");
          h.textContent = card.h || "";
          var p = document.createElement("p");
          p.textContent = card.p || "";
          article.appendChild(h);
          article.appendChild(p);
          grid.appendChild(article);
        });
      }
    }
    ["server", "payPhone", "payPhoneRaw", "payName", "payLink",
      "donateBoosty", "donateAlerts", "donateDirect", "discord", "telegram"].forEach(function (key) {
      if (site[key]) cfg[key] = site[key];
    });
  }
  var repo = (cfg.ghUser || "__GH_USER__") + "/" + (cfg.ghRepo || "__GH_REPO__");
  var releases = "https://github.com/" + repo + "/releases";

  function link(id, url) {
    var el = document.getElementById(id);
    if (el && url) el.href = url;
  }

  function boot() {
  // ---- downloads: the "latest" endpoints stay valid after every publish
  var exeUrl = releases + "/latest/download/WarfareLauncher-win.zip";
  var jarUrl = releases + "/latest/download/warfaremapskits-1.0.0.jar";
  if (!cfg.preview) {
  link("dl-exe", exeUrl);
  link("dl-exe2", exeUrl);
  link("dl-jar", jarUrl);
  link("dl-jar2", jarUrl);
  link("gh-link", "https://github.com/" + repo);
  }
  link("dc-link", cfg.discord);
  link("tg-link", cfg.telegram);

  // ---- donations: only show a card whose link is actually filled in
  [["donate-1", cfg.donateBoosty], ["donate-2", cfg.donateAlerts], ["donate-3", cfg.donateDirect]]
    .forEach(function (pair) {
      var el = document.getElementById(pair[0]);
      if (!el) return;
      var url = pair[1];
      if (url && url.indexOf("__") !== 0) {
        el.href = url;
        el.hidden = false;
      }
    });

  var phone = cfg.payPhone || "";
  var phoneEl = document.getElementById("pay-phone");
  if (phoneEl && phone) phoneEl.textContent = phone;
  var nameEl = document.getElementById("pay-name");
  if (nameEl && cfg.payName) {
    nameEl.textContent = "Получатель: " + cfg.payName;
    nameEl.hidden = false;
  }
  var payBtn = document.getElementById("pay-link");
  if (payBtn && cfg.payLink) {
    payBtn.href = cfg.payLink;
    payBtn.hidden = false;
  }
  var payCopy = document.getElementById("pay-copy");
  if (payCopy) {
    payCopy.addEventListener("click", function () {
      var value = (cfg.payPhoneRaw || phone || "").replace(/\s/g, "");
      navigator.clipboard.writeText(value).then(function () {
        payCopy.textContent = "скопировано";
        setTimeout(function () { payCopy.textContent = "Скопировать"; }, 1400);
      }).catch(function () {
        var range = document.createRange();
        range.selectNodeContents(phoneEl);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      });
    });
  }

  // ---- server address
  var ip = cfg.server || "26.133.174.202:12345";
  var ipEl = document.getElementById("ip");
  if (ipEl) ipEl.textContent = ip;
  function copyIp(btn) {
    navigator.clipboard.writeText(ip).then(function () {
      var old = btn.textContent;
      btn.textContent = "скопировано";
      setTimeout(function () { btn.textContent = old; }, 1400);
    });
  }
  ["ip-copy", "ip-copy2"].forEach(function (id) {
    var b = document.getElementById(id);
    if (b) b.addEventListener("click", function () { copyIp(b); });
  });

  // ---- screenshots: shot-1..shot-12, however many are actually there
  var grid = document.getElementById("shots-grid");
  var box = document.getElementById("lightbox");
  var boxImg = document.getElementById("lightbox-img");
  if (grid) {
    for (var i = 1; i <= 12; i++) {
      (function (n) {
        var url = "img/shot-" + n + ".jpg";
        var probe = new Image();
        probe.onload = function () {
          var img = document.createElement("img");
          img.src = url;
          img.alt = "Скрин " + n;
          img.loading = "lazy";
          img.addEventListener("click", function () {
            boxImg.src = url;
            box.hidden = false;
          });
          grid.appendChild(img);
        };
        probe.src = url;
      })(i);
    }
  }
  if (box) {
    box.addEventListener("click", function () { box.hidden = true; });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") box.hidden = true; });
  }

  // ---- funding tiles: raised so far, progress to the next patch, days of hosting left.
  // Values come from funding.json, which is edited by hand (SBP transfers to a phone have no API to read).
  function money(n, currency) {
    return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " " + currency;
  }

  function dayWord(n) {
    var mod10 = n % 10, mod100 = n % 100;
    if (mod10 === 1 && mod100 !== 11) return "день";
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return "дня";
    return "дней";
  }

  function ddmm(iso) {
    var d = new Date(iso + "T00:00:00");
    if (isNaN(d)) return iso;
    return ("0" + d.getDate()).slice(-2) + "." + ("0" + (d.getMonth() + 1)).slice(-2);
  }

  function setBar(id, fraction) {
    var el = document.getElementById(id);
    if (el) el.style.width = Math.max(0, Math.min(100, fraction * 100)).toFixed(1) + "%";
  }

  fetch("funding.json", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (f) {
      if (!f) return;
      var cur = f.currency || "₽";
      var raised = Number(f.raised) || 0;
      var goal = Math.max(1, Number(f.goal) || 1);

      var raisedEl = document.getElementById("fund-raised");
      if (raisedEl) raisedEl.textContent = money(raised, cur) + " / " + money(goal, cur);
      setBar("fund-bar", raised / goal);
      var fundNote = document.getElementById("fund-note");
      if (fundNote) {
        var left = Math.max(0, goal - raised);
        fundNote.textContent = (f.goalNote || "") + (left > 0 ? " · не хватает " + money(left, cur) : " · цель закрыта");
      }

      var pct = Math.max(0, Math.min(100, Number(f.patchPercent) || 0));
      var pctEl = document.getElementById("patch-pct");
      if (pctEl) pctEl.textContent = pct + "%";
      setBar("patch-bar", pct / 100);
      var patchNote = document.getElementById("patch-note");
      if (patchNote) {
        patchNote.textContent = "выйдет " + ddmm(f.patchDate) + (f.patchNote ? " · " + f.patchNote : "");
      }

      var until = new Date((f.hostPaidUntil || "") + "T00:00:00");
      var hostEl = document.getElementById("host-left");
      var hostNote = document.getElementById("host-note");
      if (!isNaN(until)) {
        var days = Math.max(0, Math.ceil((until - new Date()) / 86400000));
        var period = Math.max(1, Number(f.hostPeriodDays) || 30);
        if (hostEl) hostEl.textContent = days + " " + dayWord(days);
        setBar("host-bar", days / period);
        if (hostNote) {
          hostNote.textContent = days > 0
            ? "оплачен до " + ddmm(f.hostPaidUntil) + " · дальше сервер выключится"
            : "срок вышел — сервер держится на честном слове";
        }
      }

      var upd = document.getElementById("fund-updated");
      if (upd && f.updated) upd.textContent = "Обновлено " + ddmm(f.updated) + ".";
    })
    .catch(function () {});

  // ---- current build, written by the admin launcher on every publish
  fetch("version.json", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (v) {
      if (!v) return;
      var badge = document.getElementById("ver-badge");
      if (badge) badge.textContent = "сборка " + v.version;
      var note = document.getElementById("updates-box");
      if (note && v.notes) {
        var p = document.createElement("p");
        p.innerHTML = "<strong>Текущая сборка " + v.version + "</strong> · " + v.files + " файлов · "
          + Math.round((v.size || 0) / 1048576) + " МБ";
        note.prepend(p);
      }
    })
    .catch(function () {});

  // ---- release list straight from GitHub (only once a real repo is configured)
  var updates = document.getElementById("updates-box");
  var repoReady = repo.indexOf("__") === -1;
  if (updates && !repoReady) {
    var stale = updates.querySelector(".muted");
    if (stale) stale.textContent = "Сборка раздаётся с моего ПК. Список версий появится, когда выложу репозиторий.";
  }
  if (updates && repoReady) {
    fetch("https://api.github.com/repos/" + repo + "/releases?per_page=8")
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (list) {
        var stale = updates.querySelector(".muted");
        if (stale) stale.remove();
        if (!list.length) {
          updates.insertAdjacentHTML("beforeend", "<p class='muted'>Релизов пока нет.</p>");
          return;
        }
        list.forEach(function (rel) {
          var div = document.createElement("div");
          div.className = "rel";
          var date = (rel.published_at || "").slice(0, 10);
          div.innerHTML = "<div class='rel-top'><span class='rel-tag'>" + (rel.tag_name || "") + "</span>"
            + "<span class='rel-date'>" + date + "</span>"
            + "<a href='" + rel.html_url + "'>скачать</a></div>";
          if (rel.body) {
            var body = document.createElement("p");
            body.className = "rel-body";
            body.textContent = rel.body.slice(0, 600);
            div.appendChild(body);
          }
          updates.appendChild(div);
        });
      })
      .catch(function () {});
  }
  }

  // texts and links first, then everything that depends on them
  fetch("site.json", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (site) { applySite(site); boot(); })
    .catch(function () { boot(); });
})();