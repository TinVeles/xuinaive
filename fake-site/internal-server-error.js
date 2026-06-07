(function () {
  function randomHex(bytes) {
    var data = new Uint8Array(bytes);
    if (window.crypto && window.crypto.getRandomValues) {
      window.crypto.getRandomValues(data);
    } else {
      for (var i = 0; i < data.length; i += 1) data[i] = Math.floor(Math.random() * 256);
    }
    return Array.prototype.map.call(data, function (b) {
      return b.toString(16).padStart(2, '0');
    }).join('');
  }

  function formatUtc(date) {
    return date.toISOString().replace('T', ' ').replace(/\.\d{3}Z$/, ' UTC');
  }

  function init() {
    var doc = document;
    var host = window.location.hostname || 'gtgroundai.bot.nu';
    var timeEl = doc.getElementById('cf-error-time');
    var hostEl = doc.getElementById('cf-hostname');
    var rayEl = doc.getElementById('cf-ray-id');
    var ipWrap = doc.getElementById('cf-footer-item-ip');
    var ipReveal = doc.getElementById('cf-footer-ip-reveal');
    var ipValue = doc.getElementById('cf-footer-ip');

    if (timeEl) timeEl.textContent = formatUtc(new Date());
    if (hostEl) hostEl.textContent = host;
    if (rayEl) rayEl.textContent = randomHex(8);
    doc.title = '500: Internal server error - ' + host;

    if (ipWrap && ipReveal && 'classList' in ipWrap) {
      ipWrap.classList.remove('hidden');
      ipReveal.addEventListener('click', function () {
        ipReveal.classList.add('hidden');
        if (ipValue) ipValue.classList.remove('hidden');
      });
    }
  }

  if (document.addEventListener) document.addEventListener('DOMContentLoaded', init);
  else init();
})();
