// Marks the page, so a test can see that content scripts run.
document.documentElement.dataset.boskTestExtension = "loaded";
const banner = document.createElement("div");
banner.textContent = "Bosk Test Extension is running";
banner.style.cssText = "position:fixed;bottom:8px;right:8px;z-index:2147483647;background:#2a7;color:#fff;" +
  "font:12px -apple-system,sans-serif;padding:4px 8px;border-radius:6px;";
document.documentElement.appendChild(banner);
