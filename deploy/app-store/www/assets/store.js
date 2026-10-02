// Theme toggle for the app-store pages.
//
// The pages start on data-theme="light". This script replaces that only when a previous visit
// saved a choice, so the first paint is already the default and a dark operating system does
// not flip it.
(function () {
  var root = document.documentElement;
  var key = "prabhix-store-theme";

  /** What the page is actually showing. Light unless a saved choice or this script set dark. */
  function current() {
    return root.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }

  var saved = localStorage.getItem(key);
  if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);

  var btn = document.getElementById("theme-toggle");
  if (!btn) return;

  // The button's accessible name has to say which way it goes. It read "Toggle theme" in both
  // states, which tells a screen-reader user nothing about what pressing it will do.
  function label() {
    btn.setAttribute("aria-label", current() === "dark" ? "Switch to light theme" : "Switch to dark theme");
  }
  label();

  btn.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    localStorage.setItem(key, next);
    label();
  });
})();
