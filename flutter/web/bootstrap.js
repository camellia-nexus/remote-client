// Camellia Web Client Bootstrap
// Extracted for strict Content Security Policy (CSP-001) compliance.

window.__CAMELLIA_REMOTE_WEB__ = window.__CAMELLIA_REMOTE_WEB__ || {
  appName: "Camellia",
  version: "",
  buildDate: "",
  apiServer: "",
  isPublicServer: true
};

function removeLoading() {
  var loader = document.getElementById("loading");
  if (loader) {
    loader.remove();
  }
}

window.addEventListener("flutter-first-frame", removeLoading);
window.addEventListener("load", function () {
  window.setTimeout(removeLoading, 8000);
});
