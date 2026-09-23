// Shows the number of open tabs as the badge, so the badge path is tested.
async function updateBadge() {
  const tabs = await chrome.tabs.query({});
  await chrome.action.setBadgeText({ text: String(tabs.length) });
}
chrome.tabs.onCreated.addListener(updateBadge);
chrome.tabs.onRemoved.addListener(updateBadge);
chrome.runtime.onInstalled.addListener(updateBadge);
chrome.runtime.onStartup.addListener(updateBadge);
updateBadge();
