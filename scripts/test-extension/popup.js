chrome.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
  document.getElementById("tab").textContent = tab ? "Active tab: " + tab.title : "No active tab";
});
